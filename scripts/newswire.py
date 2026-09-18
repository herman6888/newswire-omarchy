#!/usr/bin/env python3
"""
newswire.py — 中文资讯抓取引擎（零依赖，仅用 Python 标准库）

设计对齐 hermes-newswire：无 LLM、无 API key、本地缓存、离线可用。
抓取中文 RSS/Atom 源 -> 解析 -> 去重 -> 落盘缓存 -> 输出 JSON 给 QML。

用法:
  newswire.py refresh [--config feeds.json] [--lang zh|en]   抓取全部源，写缓存，输出 JSON
  newswire.py dump [--lang zh|en]                           只输出缓存 JSON（无网络，毫秒级）
  newswire.py status [--lang zh|en]                         输出缓存健康信息
  newswire.py markread <id> [--lang zh|en]                  标记已读

  newswire.py config get                                    输出合并后的配置 JSON
  newswire.py config set '<json>'                           合并写入 config.json（原子写）
  newswire.py feeds list [--lang zh|en]                     列出当前语言的源（含派生 id）
  newswire.py feeds enable <id> [--lang X]                  启用源
  newswire.py feeds disable <id> [--lang X]                 停用源
  newswire.py feeds add <name> <url> [--lang X]             新增源
  newswire.py feeds remove <id> [--lang X]                  删除源

缓存: ~/.cache/omarchy-newswire-zh/cache.json
配置: ~/.config/omarchy-newswire-zh/config.json  （运行时唯一真源，缺省回落 manifest defaults）
"""

import copy
import hashlib
import ipaddress
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

CACHE_DIR = os.environ.get(
    "NEWSWIRE_ZH_CACHE",
    os.path.join(os.path.expanduser("~"), ".cache", "omarchy-newswire-zh"),
)
CACHE_FILE = os.path.join(CACHE_DIR, "cache.json")
READ_FILE = os.path.join(CACHE_DIR, "read.json")

CONFIG_DIR = os.environ.get(
    "NEWSWIRE_ZH_CONFIG",
    os.path.join(os.path.expanduser("~"), ".config", "omarchy-newswire-zh"),
)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")

# 用户可写的 feeds 文件必须放在插件目录之外。omarchy-shell 用 inotifywait 盯着
# ~/.config/omarchy/plugins 的 close_write/create/delete/move，写插件目录里的
# feeds.json 会打出 "Local plugin changed, reloading: herman.newswire-zh"，
# 用户点一下开关 = 整个 widget 热重载 = 弹窗被关掉、状态丢失（T3 Bug1 主因）。
FEEDS_FILE = os.path.join(CONFIG_DIR, "feeds.json")

# 设置页可写的配置项 + 兜底默认值（优先级：config.json > manifest defaults > 这里）
CONFIG_DEFAULTS = {
    "defaultLang": "en",
    "refreshIntervalSec": 1800,
    "paused": False,
    "showSource": True,
    "showAge": True,
    "pauseOnHover": True,
    "rotateDwellSec": 5,
    "textPixelSize": 13,
    "translate": {
        "enabled": False,
        "baseUrl": "http://192.168.8.89:8731/v1",
        "apiKey": "",
        "model": "halogen-qwen3.8-flash-next",
        # 译文目标语言。可在设置页选择，默认中文。
        "targetLang": "zh",
    },
}
# 支持的译文目标（新增语言时在这里登记 + 补 _TRANSLATE_SYSTEM）
TRANSLATE_TARGETS = ("zh", "en")
TRANSLATE_TIMEOUT = 30.0    # 单请求上限；实测本网关 zh→en 约 24.5s，15s 会超时
TRANSLATE_BATCH = 3          # 每次请求打包的标题数（本地网关 ~2.2s/条，3 条 ≈ 7s）
TRANSLATE_MAX_BATCHES = 8   # 上限保护；实际由 TRANSLATE_BUDGET 提前截断
TRANSLATE_BUDGET = 25.0     # 单次 refresh 翻译总预算（秒）；超预算立即停，剩余下次补
# 目标准语言不同，单批耗时差异很大（zh→en 约为 en→zh 的 3~6 倍），按目标分预算。
TRANSLATE_BUDGET_BY_TARGET = {"zh": 25.0, "en": 60.0}
TRANSLATE_CACHE_MAX = 1500  # translations 段最多保留条数

CONNECT_TIMEOUT = 6.0
TOTAL_TIMEOUT = 12.0
MAX_BYTES = 3 * 1024 * 1024  # 3 MB per feed
MAX_ITEMS_PER_FEED = 25
MAX_TOTAL_ITEMS = 120
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 omarchy-newswire-zh/1.0"
)

# ---------------------------------------------------------------- SSRF guards
# 源 URL 是不可信输入：只允许 http/https，禁止回环/私网/链路本地/CGNAT/元数据地址。
# 与 hermes-newswire 同一套防线：先校验字面量，再校验 DNS 解析结果。

_BLOCKED_NETS = [
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.0.0.0/24"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("224.0.0.0/4"),
    ipaddress.ip_network("240.0.0.0/4"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("ff00::/8"),
]


def _ip_blocked(ip_str: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True
    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved \
            or ip.is_multicast or ip.is_unspecified:
        return True
    return any(ip in net for net in _BLOCKED_NETS)


def _host_literal_blocked(host: str) -> bool:
    """字面量形式的私网地址：十进制/十六进制/八进制等历史写法也要拦住。"""
    host = host.strip("[]")
    if host.lower() in ("localhost", "localhost.localdomain"):
        return True
    # 纯数字 / 0x 前缀 / 八进制 形式的"伪主机名"
    if re.fullmatch(r"[0-9]+", host) or re.fullmatch(r"0[xX][0-9a-fA-F]+", host):
        return True
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False  # 普通域名，交给 DNS 后校验
    return _ip_blocked(host)


def validate_url(url: str) -> str:
    """校验并返回规范化 URL；不安全则抛 ValueError。"""
    parsed = urllib.parse.urlsplit(url.strip())
    if parsed.scheme not in ("http", "https"):
        raise ValueError("scheme not allowed")
    host = parsed.hostname
    if not host:
        raise ValueError("missing host")
    if _host_literal_blocked(host):
        raise ValueError("blocked host literal")
    # 解析后校验：域名必须全部解析到公网地址
    try:
        infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80),
                                  proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        raise ValueError("dns failed")
    for info in infos:
        if _ip_blocked(info[4][0]):
            raise ValueError("resolves to blocked address")
    return url.strip()


# ---------------------------------------------------------------- fetching

def http_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.6",
    })
    # 我们自己不做重定向跟随：逐跳校验，交给调用方处理
    opener = urllib.request.build_opener(_NoRedirect())
    resp = opener.open(req, timeout=CONNECT_TIMEOUT)
    code = getattr(resp, "status", 200)
    if 300 <= code < 400:
        loc = resp.headers.get("Location")
        resp.close()
        raise _Redirect(code, loc)
    try:
        data = resp.read(MAX_BYTES + 1)
    finally:
        resp.close()
    if len(data) > MAX_BYTES:
        raise ValueError("body too large")
    return data


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class _Redirect(Exception):
    def __init__(self, code, location):
        self.code = code
        self.location = location


def fetch_with_redirects(url: str, max_hops: int = 3):
    current = validate_url(url)
    for _ in range(max_hops + 1):
        try:
            return http_get(current), current
        except _Redirect as r:
            if not r.location:
                raise ValueError("redirect without location")
            current = validate_url(urllib.parse.urljoin(current, r.location))
    raise ValueError("too many redirects")


# ---------------------------------------------------------------- parsing

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


def clean_text(s) -> str:
    if not s:
        return ""
    s = str(s)
    s = _TAG_RE.sub(" ", s)
    s = (s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
          .replace("&quot;", '"').replace("&#39;", "'").replace("&nbsp;", " "))
    s = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))) if int(m.group(1)) < 0x110000 else " ", s)
    return _WS_RE.sub(" ", s).strip()


def strip_html(s) -> str:
    """feed 里的 HTML 一律在入库前剥干净。"""
    return clean_text(s)


def parse_date(raw) -> int:
    if not raw:
        return 0
    raw = str(raw).strip()
    try:
        return int(parsedate_to_datetime(raw).timestamp())
    except Exception:
        pass
    try:
        iso = raw.replace("Z", "+00:00")
        from datetime import datetime
        return int(datetime.fromisoformat(iso).timestamp())
    except Exception:
        return 0


def _localname(tag) -> str:
    return tag.split("}")[-1] if isinstance(tag, str) else ""


def parse_feed(data: bytes):
    """解析 RSS 2.0 / RSS 1.0 RDF / Atom，返回 item dict 列表。"""
    text = data.decode("utf-8", errors="replace")
    # 去掉非法控制字符，否则 ElementTree 直接炸
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)
    root = ET.fromstring(text.encode("utf-8"))

    items = []
    nodes = [n for n in root.iter() if _localname(n.tag) == "item"]
    if not nodes:
        nodes = [n for n in root.iter() if _localname(n.tag) == "entry"]

    for node in nodes[:MAX_ITEMS_PER_FEED]:
        fields = {}
        for child in node:
            name = _localname(child.tag)
            val = (child.text or "").strip()
            if name == "link":
                # Atom: <link href="..."/>  RSS: <link>text</link>
                href = child.get("href") or val
                rel = (child.get("rel") or "alternate").lower()
                if rel == "alternate" or "link" not in fields:
                    fields["link"] = href
            elif name in ("title", "description", "summary", "pubDate", "published",
                         "updated", "author", "creator"):
                if val and (name not in fields or len(val) > len(fields.get(name, ""))):
                    fields[name] = val
        title = clean_text(fields.get("title"))
        link = clean_text(fields.get("link"))
        if not title or not link:
            continue
        ts = parse_date(fields.get("pubDate") or fields.get("published") or fields.get("updated"))
        summary = strip_html(fields.get("description") or fields.get("summary") or "")[:280]
        items.append({"title": title[:200], "url": link, "ts": ts, "summary": summary})
    return items


# ---------------------------------------------------------------- cache

def cache_files(lang="zh"):
    """按语言分缓存文件；中文沿用旧文件名以兼容既有缓存。"""
    if lang == "en":
        return (os.path.join(CACHE_DIR, "cache_en.json"),
                os.path.join(CACHE_DIR, "read_en.json"))
    return (CACHE_FILE, READ_FILE)


def load_cache(lang="zh"):
    cache_file, _ = cache_files(lang)
    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            c = json.load(f)
        if isinstance(c, dict) and isinstance(c.get("articles"), list):
            return c
    except Exception:
        pass
    return {"updated": 0, "articles": [], "sources": []}


def save_cache(cache, lang="zh"):
    cache_file, _ = cache_files(lang)
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = cache_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False)
    os.replace(tmp, cache_file)


def load_feeds(path, lang="zh"):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"config load failed: {e}", file=sys.stderr)
        return []
    # 新格式：{"zh": [...], "en": [...]}；旧格式：扁平 feeds 列表
    if isinstance(data, dict) and ("zh" in data or "en" in data):
        feeds = data.get(lang) or data.get("zh") or []
    else:
        feeds = data.get("feeds") if isinstance(data, dict) else data
    out = []
    for entry in feeds or []:
        if isinstance(entry, str):
            out.append({"name": "", "url": entry, "enabled": True})
        elif isinstance(entry, dict) and entry.get("url"):
            out.append({
                "name": str(entry.get("name") or ""),
                "url": str(entry["url"]),
                "enabled": bool(entry.get("enabled", True)),
            })
    return out


def human_age(ts, now, lang="zh"):
    if not ts:
        return ""
    d = max(0, now - ts)
    if lang == "en":
        if d < 60:
            return "just now"
        if d < 3600:
            return f"{d // 60} min ago"
        if d < 86400:
            return f"{d // 3600} hr ago"
        return f"{d // 86400} d ago"
    if d < 60:
        return "刚刚"
    if d < 3600:
        return f"{d // 60} 分钟前"
    if d < 86400:
        return f"{d // 3600} 小时前"
    return f"{d // 86400} 天前"


def cmd_markread(article_id, lang="zh"):
    _, read_file = cache_files(lang)
    read = []
    try:
        with open(read_file, "r", encoding="utf-8") as f:
            r = json.load(f)
        if isinstance(r, list):
            read = r
    except Exception:
        pass
    if article_id and article_id not in read:
        read.append(article_id)
    # 防止无限增长：只保留最近 2000 条
    read = read[-2000:]
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = read_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(read, f)
    os.replace(tmp, read_file)
    return {"read": len(read)}


def cmd_refresh(config_path, lang="zh"):
    feeds = [f for f in load_feeds(resolve_feeds_path(config_path), lang) if f["enabled"]]
    now = int(time.time())
    seen = set()
    collected = []
    source_status = []

    for feed in feeds:
        name = feed["name"] or urllib.parse.urlsplit(feed["url"]).netloc
        try:
            data, final_url = fetch_with_redirects(feed["url"])
            items = parse_feed(data)
            ok = len(items) > 0
            err = "" if ok else "no items"
        except Exception as e:
            items, ok, err = [], False, str(e)[:120]
        added = 0
        for it in items:
            key = it["url"].split("#")[0]
            if key in seen:
                continue
            seen.add(key)
            it["source"] = name
            it["id"] = str(abs(hash(key)) % (10 ** 12))
            collected.append(it)
            added += 1
        source_status.append({"name": name, "url": feed["url"], "ok": ok,
                            "items": added, "error": err})

    collected.sort(key=lambda a: a.get("ts") or 0, reverse=True)
    collected = collected[:MAX_TOTAL_ITEMS]
    for a in collected:
        a["age"] = human_age(a.get("ts"), now, lang)

    cache = {"updated": now, "lang": lang, "articles": collected,
             "sources": source_status}

    # 翻译：zh / en 两种界面都可开（T3 Bug3），失败不影响主流程
    try:
        tr = load_config().get("translate", {})
        if tr.get("enabled") and lang in ("zh", "en"):
            prev = load_cache(lang)
            if isinstance(prev.get("translations"), dict):
                cache["translations"] = prev["translations"]
            cache = apply_translations(cache, tr)
    except Exception as e:
        print(f"translate stage skipped: {str(e)[:120]}", file=sys.stderr)

    save_cache(cache, lang)
    return cache


def cmd_dump(lang="zh"):
    cache = load_cache(lang)
    if not cache["articles"]:
        return {"updated": 0, "lang": lang, "articles": [], "sources": [],
                "stale": True}
    return cache


def cmd_status(lang="zh"):
    cache = load_cache(lang)
    now = int(time.time())
    age = now - cache.get("updated", 0) if cache.get("updated") else -1
    ok = sum(1 for s in cache.get("sources", []) if s.get("ok"))
    total = len(cache.get("sources", []))
    cache_file, _ = cache_files(lang)
    return {
        "lang": lang,
        "cached": len(cache.get("articles", [])),
        "age_seconds": age,
        "sources_ok": ok,
        "sources_total": total,
        "cache_file": cache_file,
    }


def parse_lang(argv):
    for i, a in enumerate(argv):
        if a == "--lang" and i + 1 < len(argv):
            v = argv[i + 1].strip().lower()
            return v if v in ("zh", "en") else "zh"
    return "zh"


# ---------------------------------------------------------------- atomic write

def atomic_write_json(path, obj, mode=None) -> None:
    """tmp + rename，避免写一半被读到。mode 指定文件权限（如 0o600 用于含密钥的配置）。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_json_or(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return fallback


# ---------------------------------------------------------------- config

def manifest_defaults():
    """读 manifest.json 的 barWidget.defaults（读不到就返回空）。"""
    mpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "manifest.json")
    m = read_json_or(mpath, {})
    if isinstance(m, dict):
        d = m.get("barWidget", {}).get("defaults")
        if isinstance(d, dict):
            return d
    return {}


def merge_config(user_cfg):
    """defaults <- manifest defaults <- 用户 config.json，并做边界收敛。"""
    cfg = copy.deepcopy(CONFIG_DEFAULTS)
    md = manifest_defaults()
    for k, v in md.items():
        cfg[k] = v
    if isinstance(user_cfg, dict):
        for k, v in user_cfg.items():
            if k == "translate":
                continue
            cfg[k] = v
    tr = dict(CONFIG_DEFAULTS["translate"])
    user_tr = user_cfg.get("translate") if isinstance(user_cfg, dict) else None
    if isinstance(user_tr, dict):
        for k, v in user_tr.items():
            if k in tr:
                tr[k] = v
    # 边界收敛
    try:
        tr["baseUrl"] = str(tr.get("baseUrl") or "").strip().rstrip("/")
    except Exception:
        tr["baseUrl"] = ""
    tr["apiKey"] = str(tr.get("apiKey") or "")
    tr["model"] = str(tr.get("model") or "").strip()
    tgt = str(tr.get("targetLang") or "zh").strip().lower()
    tr["targetLang"] = tgt if tgt in TRANSLATE_TARGETS else "zh"
    tr["enabled"] = bool(tr.get("enabled", False))
    cfg["translate"] = tr
    try:
        cfg["refreshIntervalSec"] = max(60, int(cfg.get("refreshIntervalSec", 1800)))
    except Exception:
        cfg["refreshIntervalSec"] = CONFIG_DEFAULTS["refreshIntervalSec"]
    if cfg.get("defaultLang") not in ("zh", "en"):
        cfg["defaultLang"] = "en"
    for k in ("paused", "showSource", "showAge", "pauseOnHover"):
        cfg[k] = bool(cfg.get(k, CONFIG_DEFAULTS[k]))
    try:
        cfg["textPixelSize"] = max(9, min(20, int(cfg.get("textPixelSize", 13))))
    except Exception:
        cfg["textPixelSize"] = 13
    # 短标题（装得下、不需要滚动）在切下一条前的停留秒数
    try:
        cfg["rotateDwellSec"] = max(2, min(60, int(cfg.get("rotateDwellSec", 5))))
    except Exception:
        cfg["rotateDwellSec"] = CONFIG_DEFAULTS["rotateDwellSec"]
    return cfg


def load_config():
    return merge_config(read_json_or(CONFIG_FILE, {}))


def cmd_config_get():
    out = load_config()
    out["_configFile"] = CONFIG_FILE
    out["_manifestDefaults"] = manifest_defaults()
    return out


def cmd_config_set(raw_json):
    try:
        patch = json.loads(raw_json)
    except Exception as e:
        raise ValueError(f"invalid json: {e}")
    if not isinstance(patch, dict):
        raise ValueError("config set expects a JSON object")
    cur = read_json_or(CONFIG_FILE, {})
    if not isinstance(cur, dict):
        cur = {}
    for k, v in patch.items():
        if k.startswith("_"):
            continue
        if k == "translate" and isinstance(v, dict):
            tr = cur.get("translate") if isinstance(cur.get("translate"), dict) else {}
            for tk, tv in v.items():
                if tk in CONFIG_DEFAULTS["translate"]:
                    tr[tk] = tv
            cur["translate"] = tr
        else:
            cur[k] = v
    atomic_write_json(CONFIG_FILE, cur, mode=0o600)
    return {"ok": True, "config": merge_config(cur)}


# ---------------------------------------------------------------- feeds CRUD

def feed_id(lang, url):
    """由 lang+url 派生的稳定 id（不随列表位置变化）。"""
    return hashlib.sha1(f"{lang}|{url}".encode("utf-8")).hexdigest()[:12]


def factory_feeds_path():
    """出厂预设：插件目录里的 feeds.json。运行期只读，永不写（见 FEEDS_FILE 注释）。"""
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "feeds.json"))


def ensure_user_feeds():
    """用户 feeds 文件缺失时从出厂预设 seed 一份（一次性迁移）。返回用户文件路径。"""
    if not os.path.exists(FEEDS_FILE):
        preset = read_json_or(factory_feeds_path(), None)
        if not isinstance(preset, dict):
            preset = {"zh": [], "en": []}
        for k in ("zh", "en"):
            if not isinstance(preset.get(k), list):
                preset[k] = []
        atomic_write_json(FEEDS_FILE, preset, mode=0o600)
    return FEEDS_FILE


def resolve_feeds_path(config_path=None):
    """feeds 读写统一落到用户目录。

    - 未指定 / 指向插件目录出厂预设 → 用户文件（必要时先迁移）
    - 显式指定其它路径（测试/CLI）→ 原样使用
    """
    if config_path:
        ap = os.path.abspath(config_path)
        if ap != factory_feeds_path():
            return ap
    return ensure_user_feeds()


def feeds_path(config_path):
    return resolve_feeds_path(config_path)


def load_feeds_doc(config_path):
    """读完整 feeds.json，保证 zh/en 两个键都在。"""
    data = read_json_or(feeds_path(config_path), None)
    if not isinstance(data, dict):
        data = {}
    for k in ("zh", "en"):
        if not isinstance(data.get(k), list):
            data[k] = []
    return data


def list_feeds_with_ids(config_path, lang):
    out = []
    for entry in load_feeds(config_path, lang):
        out.append({
            "id": feed_id(lang, entry["url"]),
            "name": entry["name"] or urllib.parse.urlsplit(entry["url"]).netloc,
            "url": entry["url"],
            "enabled": bool(entry.get("enabled", True)),
        })
    return out


def _find_index(doc, lang, ident):
    entries = doc.get(lang) or []
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            continue
        u = str(e.get("url") or "")
        if feed_id(lang, u) == ident or str(e.get("id") or "") == ident:
            return i
    raise ValueError(f"feed not found: {ident}")


def cmd_feeds(sub, config_path, lang, extra):
    # 所有 feeds 子命令（包括 list）统一读用户目录，不能读插件出厂预设
    config_path = resolve_feeds_path(config_path)
    if sub == "list":
        return {"lang": lang, "feeds": list_feeds_with_ids(config_path, lang)}

    doc = load_feeds_doc(config_path)
    if sub in ("enable", "disable"):
        ident = extra[0] if extra else ""
        idx = _find_index(doc, lang, ident)
        doc[lang][idx]["enabled"] = (sub == "enable")
        atomic_write_json(feeds_path(config_path), doc, mode=0o600)
        return {"ok": True, "action": sub, "lang": lang,
                "feeds": list_feeds_with_ids(config_path, lang)}

    if sub == "add":
        name = (extra[0] if extra else "").strip()
        url = (extra[1] if len(extra) > 1 else "").strip()
        if not url:
            raise ValueError("feeds add needs <name> <url>")
        if not url.lower().startswith(("http://", "https://")):
            raise ValueError("url must be http(s)")
        host = urllib.parse.urlsplit(url).hostname or ""
        if _host_literal_blocked(host):
            raise ValueError("blocked host")
        if any(str(e.get("url")) == url for e in doc[lang] if isinstance(e, dict)):
            raise ValueError("url already exists")
        doc[lang].append({"name": name or host, "url": url, "enabled": True})
        atomic_write_json(feeds_path(config_path), doc, mode=0o600)
        return {"ok": True, "action": "add", "lang": lang,
                "feeds": list_feeds_with_ids(config_path, lang)}

    if sub == "remove":
        ident = extra[0] if extra else ""
        idx = _find_index(doc, lang, ident)
        removed = doc[lang].pop(idx)
        atomic_write_json(feeds_path(config_path), doc, mode=0o600)
        return {"ok": True, "action": "remove", "lang": lang,
                "removed": removed.get("name") or removed.get("url"),
                "feeds": list_feeds_with_ids(config_path, lang)}

    raise ValueError(f"unknown feeds subcommand: {sub}")


# ---------------------------------------------------------------- translation

_CJK_RE = re.compile(r"[\u4e00-\u9fff]")


def is_cjk_title(s: str) -> bool:
    """含 CJK 表意文字则视为中文标题，不送翻。"""
    return bool(_CJK_RE.search(s or ""))


# 翻译 baseUrl 的闸。**不能直接复用 _host_literal_blocked**：它走 _ip_blocked，会把
# RFC1918（192.168/10/172.16-31）一并拦掉，而本地 LLM 网关就装在这些段。
# 因此这里只拦“工作单点名的危险目标”：链路本地/云元数据(169.254.*)、未指定地址、
# 多播、保留段，以及十进制/十六进制/八进制混淆写法的伪主机名。
# 放行：192.168.* / 10.* / 172.16-31.*（本地网关）与 127.0.0.1（本机 mock/本地服务）。
_TRANSLATE_BLOCKED_NETS = [
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("224.0.0.0/4"),
    ipaddress.ip_network("240.0.0.0/4"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("ff00::/8"),
]


def translate_base_blocked(base_url: str) -> bool:
    """True = 不允许。字面量混淆写法（纯数字/0x/八进制）一律拦。"""
    try:
        parsed = urllib.parse.urlsplit((base_url or "").strip())
    except Exception:
        return True
    if parsed.scheme not in ("http", "https"):
        return True
    host = parsed.hostname
    if not host:
        return True
    h = host.strip("[]")
    if re.fullmatch(r"[0-9]+", h) or re.fullmatch(r"0[xX][0-9a-fA-F]+", h) \
            or re.fullmatch(r"0[0-7]+", h):
        return True
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        # 普通域名：只拦已知元数据主机名，本地网关场景不做 DNS 后校验
        if "metadata" in h.lower() or h.lower().endswith(".internal"):
            return True
        return False
    return any(ip in net for net in _TRANSLATE_BLOCKED_NETS)


_TRANSLATE_SYSTEM = {
    "zh": "你是新闻标题翻译引擎。把每条英文标题翻译成简洁的简体中文新闻标题。"
          "只输出译文，每行一条，行号与输入一一对应，不要编号、不要解释、不要引号。",
    "en": "You are a news-headline translation engine. Translate each Chinese headline "
          "into a concise, natural English news headline. "
          "Output only the translation, one per line, line-for-line with the input; "
          "no numbering, no explanation, no quotes.",
}


def title_needs_translation(s: str, tgt: str) -> bool:
    """zh 目标：跳过已是中文的标题；en 目标：只翻含中文的标题。"""
    if not s:
        return False
    has_cjk = bool(_CJK_RE.search(s))
    return (not has_cjk) if tgt == "zh" else has_cjk


def translate_titles(titles, tr_cfg, budget=None):
    """批量把需要翻译的标题译成 targetLang。返回 {title: translated}；任何失败都返回空 dict（静默）。

    budget: 总耗时上限（秒）。超预算就停止后续批次，已拿到的结果照常返回，
    剩下的标题下次 refresh 再补（translations 缓存保证不重复翻译）。
    """
    out = {}
    base = (tr_cfg.get("baseUrl") or "").strip()
    if not base or translate_base_blocked(base):
        return out
    tgt = str(tr_cfg.get("targetLang") or "zh").strip().lower()
    if tgt not in TRANSLATE_TARGETS:
        return out
    todo = [t for t in titles if title_needs_translation(t, tgt)]
    if not todo:
        return out
    deadline = (time.monotonic() + budget) if budget else None

    headers = {
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if tr_cfg.get("apiKey"):
        headers["Authorization"] = f"Bearer {tr_cfg['apiKey']}"

    for start in range(0, min(len(todo), TRANSLATE_BATCH * TRANSLATE_MAX_BATCHES), TRANSLATE_BATCH):
        if deadline is not None and time.monotonic() >= deadline:
            break
        batch = todo[start:start + TRANSLATE_BATCH]
        numbered = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(batch))
        body = {
            "model": tr_cfg.get("model") or "",
            "temperature": 0,
            "messages": [
                {"role": "system", "content": _TRANSLATE_SYSTEM[tgt]},
                {"role": "user", "content": numbered},
            ],
        }
        url = base + "/chat/completions"
        timeout = TRANSLATE_TIMEOUT
        if deadline is not None:
            timeout = max(1.0, min(TRANSLATE_TIMEOUT, deadline - time.monotonic()))
        try:
            req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                       headers=headers, method="POST")
            opener = urllib.request.build_opener(_NoRedirect())
            resp = opener.open(req, timeout=timeout)
            try:
                raw = resp.read(1024 * 1024)
            finally:
                resp.close()
            payload = json.loads(raw.decode("utf-8", errors="replace"))
            text = payload["choices"][0]["message"]["content"] or ""
        except Exception as e:
            print(f"translate skipped: {str(e)[:120]}", file=sys.stderr)
            return out

        lines = [ln.strip() for ln in re.split(r"\r?\n", str(text)) if ln.strip()]
        if len(lines) != len(batch):
            print(f"translate skipped: line count {len(lines)} != {len(batch)}", file=sys.stderr)
            return out
        for t, ln in zip(batch, lines):
            ln = re.sub(r"^\d+[.)、]\s*", "", ln).strip().strip('"“”')
            if ln and ln != t:
                out[t] = ln[:200]
    return out


def apply_translations(cache, tr_cfg, budget=None):
    """就地把非 CJK 标题换成译文，并维护 translations 缓存段。失败静默。

    缓存隔离：key 仍是 sha1(原文)[:16]，但 value 带 `lang` = 目标语言，读取时
    只认 lang 匹配的条目。这样以后支持多目标语言时，zh/en 两种模式（或不同
    targetLang）不会互相污染对方的缓存。
    """
    if not tr_cfg.get("enabled"):
        return cache
    tgt = str(tr_cfg.get("targetLang") or "zh").strip().lower()
    if tgt not in TRANSLATE_TARGETS:
        return cache
    if budget is None:
        budget = TRANSLATE_BUDGET_BY_TARGET.get(tgt, TRANSLATE_BUDGET)
    arts = cache.get("articles") or []
    store = cache.get("translations")
    if not isinstance(store, dict):
        store = {}

    def key(t):
        return hashlib.sha1(t.encode("utf-8")).hexdigest()[:16]

    missing = []
    for a in arts:
        t = a.get("title") or ""
        if not title_needs_translation(t, tgt):
            continue
        hit = store.get(key(t))
        if isinstance(hit, dict) and hit.get("lang", "zh") == tgt and hit.get(tgt):
            a["title_orig"] = t
            a["title"] = hit[tgt]
        elif t not in missing:
            missing.append(t)

    if missing:
        try:
            got = translate_titles(missing, tr_cfg, budget=budget)
        except Exception as e:
            print(f"translate failed: {str(e)[:120]}", file=sys.stderr)
            got = {}
        for t, tr_text in got.items():
            store[key(t)] = {tgt: tr_text, "src": t, "lang": tgt, "at": int(time.time())}
        for a in arts:
            t = a.get("title") or ""
            if t in got:
                a["title_orig"] = t
                a["title"] = got[t]

    if len(store) > TRANSLATE_CACHE_MAX:
        items = sorted(store.items(), key=lambda kv: kv[1].get("at", 0) if isinstance(kv[1], dict) else 0)
        store = dict(items[-TRANSLATE_CACHE_MAX:])
    cache["translations"] = store
    return cache


def cmd_translate_test(raw_json):
    """设置页“测试”按钮用：直接试一条，不落盘。"""
    try:
        args = json.loads(raw_json) if raw_json else {}
    except Exception as e:
        raise ValueError(f"invalid json: {e}")
    tr = dict(CONFIG_DEFAULTS["translate"])
    for k, v in (args.get("translate") or {}).items():
        if k in tr:
            tr[k] = v
    tgt = str(tr.get("targetLang") or "zh").strip().lower()
    tr["targetLang"] = tgt if tgt in TRANSLATE_TARGETS else "zh"
    text = str(args.get("text") or "The quick brown fox jumps over the lazy dog.")
    if translate_base_blocked(tr.get("baseUrl", "")):
        return {"ok": False, "error": "baseUrl blocked"}
    got = translate_titles([text], tr)
    if text in got:
        return {"ok": True, "translated": got[text]}
    return {"ok": False, "error": "no translation returned"}


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "dump"
    lang = parse_lang(argv)
    config = None
    for i, a in enumerate(argv):
        if a == "--config" and i + 1 < len(argv):
            config = argv[i + 1]
    if config is None:
        config = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "feeds.json")

    try:
        if cmd == "refresh":
            out = cmd_refresh(config, lang)
        elif cmd == "status":
            out = cmd_status(lang)
        elif cmd == "markread":
            out = cmd_markread(argv[2] if len(argv) > 2 else "", lang)
        elif cmd == "config":
            sub = argv[2] if len(argv) > 2 else "get"
            if sub == "set":
                out = cmd_config_set(argv[3] if len(argv) > 3 else "{}")
            else:
                out = cmd_config_get()
        elif cmd == "feeds":
            sub = argv[2] if len(argv) > 2 else "list"
            extra = [a for i, a in enumerate(argv[3:], start=3)
                     if not (a == "--lang" or (i > 0 and argv[i - 1] == "--lang"))]
            out = cmd_feeds(sub, config, lang, extra)
        elif cmd == "translate-test":
            out = cmd_translate_test(argv[2] if len(argv) > 2 else "{}")
        else:
            out = cmd_dump(lang)
    except Exception as e:
        # 任何异常都不能让 widget 拿不到东西：退回缓存
        out = cmd_dump(lang)
        out["error"] = str(e)[:200]
        out["_cmdFailed"] = True

    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
