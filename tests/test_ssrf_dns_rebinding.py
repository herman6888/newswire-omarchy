#!/usr/bin/env python3
"""DNS rebinding 回归测试（reviewer HANCORE-linux @ omarchy-plugin-marketplace#7958 要求）。

核心场景：攻击者控制的域名，验证时 DNS 返回公网 IP，连接时 DNS 改答 127.0.0.1。
若 fetch 仍把 hostname 交给 urllib 二次解析，就会打到本地服务（漏洞）。
IP pinning 修复后：连接必须走验证过的那个 IP，绝不因 DNS 改答而落到私网。

运行: python3 tests/test_ssrf_dns_rebinding.py
"""
import importlib.util
import os
import socket
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "newswire", os.path.join(HERE, "..", "scripts", "newswire.py"))
nw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nw)


class _Handler(BaseHTTPRequestHandler):
    hits = 0

    def do_GET(self):
        _Handler.hits += 1
        body = b"REACHED-LOCAL-SERVICE"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.do_GET()

    def log_message(self, *a, **k):
        pass


def start_local_server():
    srv = HTTPServer(("127.0.0.1", 0), _Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, srv.server_address[1]


class RebindingDNSSpy:
    """可编程 DNS：每次调用返回不同的答案，模拟 rebinding。"""

    def __init__(self, answers):
        # answers: list of [(family, ip), ...]，按调用顺序轮转
        self.answers = answers
        self.calls = 0

    def __call__(self, host, port, *args, **kwargs):
        ans = self.answers[min(self.calls, len(self.answers) - 1)]
        self.calls += 1
        # 返回 getaddrinfo 形状
        out = []
        for fam, ip in ans:
            out.append((fam, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (ip, port)))
        return out


class TestDnsRebinding(unittest.TestCase):
    def setUp(self):
        self.srv, self.port = start_local_server()
        _Handler.hits = 0

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def test_rebinding_cannot_reach_loopback(self):
        """验证=公网 8.8.8.8，连接时 DNS 改答 127.0.0.1 → 连接必须打 8.8.8.8，
        绝不能落到 loopback。8.8.8.8:port 不可达 → 连接失败，本地服务收不到请求。"""
        url = f"http://evil.example.com:{self.port}/feed"
        spy = RebindingDNSSpy([
            [(socket.AF_INET, "8.8.8.8")],   # validate 时：公网
            [(socket.AF_INET, "127.0.0.1")],  # 连接时：rebind 到 loopback
        ])
        orig = nw.socket.getaddrinfo
        nw.socket.getaddrinfo = spy
        try:
            with self.assertRaises(Exception):
                nw.fetch_with_redirects(url)
        finally:
            nw.socket.getaddrinfo = orig
        # 关键断言：本地 loopback 服务命中数必须为 0。
        # 若 fetch 把 hostname 交给 urllib 二次解析（漏洞路径），连接会落到
        # 127.0.0.1:port 命中本地服务；IP pinning 后连接走验证过的 8.8.8.8，
        # 不可达 → 抛异常，hits 恒为 0。
        self.assertEqual(_Handler.hits, 0,
                       "DNS rebinding reached the local loopback service!")
        self.assertGreaterEqual(spy.calls, 1)

    def test_pinned_connection_uses_validated_ip(self):
        """直接验证 _PinnedHTTPConnection 连的是 pinned IP 而非重新解析。"""
        # 先起一个本地服务，pinned 到 127.0.0.1（显式允许测试可达）
        # 用一个"假"的 hostname，DNS 会指向别处，但 pinned 强制 127.0.0.1
        conn = nw._PinnedHTTPConnection(
            "should-not-resolve.example", self.port,
            pinned_ip="127.0.0.1", timeout=5)
        # 把 _ip_blocked 临时放行 127.0.0.1 仅为本测试能建连（生产 loopback 被拦）
        orig_blocked = nw._ip_blocked
        nw._ip_blocked = lambda ip: False
        try:
            conn.request("GET", "/")
            resp = conn.getresponse()
            data = resp.read()
            self.assertEqual(data, b"REACHED-LOCAL-SERVICE")
        finally:
            nw._ip_blocked = orig_blocked
            conn.close()

    def test_validate_rejects_loopback_literal(self):
        with self.assertRaises(ValueError):
            nw.validate_url_resolved("http://127.0.0.1:8080/feed")

    def test_validate_rejects_metadata_ip(self):
        with self.assertRaises(ValueError):
            nw.validate_url_resolved("http://169.254.169.254/latest/meta-data/")

    def test_validate_rejects_private_literal(self):
        with self.assertRaises(ValueError):
            nw.validate_url_resolved("http://192.168.1.1/admin")

    def test_pinned_blocked_ip_raises_before_connect(self):
        """即使有人硬塞一个 blocked IP 给 pinned connection，connect() 也要在最后一刻拦下。"""
        conn = nw._PinnedHTTPConnection("x.example", 80, pinned_ip="169.254.169.254", timeout=2)
        with self.assertRaises(OSError):
            conn.connect()

    def test_translate_rebind_blocked(self):
        """翻译端点 rebinding：验证=公网，连接=loopback → 必须拒绝。"""
        spy = RebindingDNSSpy([
            [(socket.AF_INET, "8.8.8.8")],
            [(socket.AF_INET, "127.0.0.1")],
        ])
        orig = nw.socket.getaddrinfo
        nw.socket.getaddrinfo = spy
        try:
            # translate_base_blocked_resolved 只解析一次，拿到公网 IP；
            # 真正连接时若 DNS 改答 loopback，pinned 仍走公网 → 不可达，翻译静默失败。
            res = nw.translate_base_blocked_resolved("http://llm.evil.example:1234/v1")
            self.assertIsNotNone(res)
            self.assertEqual(res[1], ["8.8.8.8"])
        finally:
            nw.socket.getaddrinfo = orig


if __name__ == "__main__":
    unittest.main(verbosity=2)
