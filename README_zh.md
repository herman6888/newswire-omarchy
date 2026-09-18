# 快讯 Newswire — Omarchy 双语滚动资讯插件

[Omarchy](https://omarchy.org) 桌面（Quickshell）的 bar 小部件：把 RSS/Atom
新闻源直接滚动在你的顶/底栏上，中英双语界面，可选 LLM 翻译。

对标 [hermes-newswire](https://github.com/tony-simons-aiowa/hermes-newswire)，
为 Omarchy 重写，内置中文 + 英文内容源。

```
📰  Solidot · FAST 发现极短周期、最轻双中子星系统 · 14 分钟前  ◆  ...
```

## 特性

- **滚动 ticker**：标题在 bar 内连续滚动，悬停暂停，点击展开完整列表；
  短到装得下的标题走定时轮播，不会静止卡在第一条
- **弹出列表**：未读加粗 + 圆点、来源标签、相对时间，点击用浏览器打开并标记已读
- **默认零 LLM / 零 API key**：抓取、解析、去重、缓存 100% 本地，
  日常路径不花任何模型 token
- **离线可用**：本地 JSON 缓存，断网时照常显示，恢复后静默刷新
- **中英双语界面（EN / CN）**：弹窗头部一键切换整个界面和信息源组，
  首次安装默认英文
- **可选翻译引擎**：指向任意 OpenAI 兼容接口（`/chat/completions`），
  把非目标语言的标题翻译显示（例如英文源显示中文，方便非英语母语用户）。
  按 hash 缓存，每条标题只翻一次；翻译失败静默回退原文；
  原文保留在 `title_orig`，链接永不改写
- **SSRF 防护**：源 URL 一律视为不可信输入——只允许 http/https，
  拦截回环/私网/链路本地/CGNAT/云元数据地址（字面量 + DNS 解析后双重校验），
  重定向逐跳校验（最多 3 跳），5s 连接 / 12s 总超时，3MB body 上限，
  入库前剥离所有 HTML
- **CJK 渲染**：默认 Noto Sans CJK SC，可配置
- **无任何遥测**

## 安装

```bash
omarchy plugin add https://github.com/<you>/omarchy-newswire-zh.git
omarchy plugin enable herman.newswire-zh center
```

或手动：把本仓库 clone 到 `~/.config/omarchy/plugins/herman.newswire-zh/`，
保存即热重载。

需要 PATH 里有 `python3`（仅标准库，无需 pip 安装任何包）。

## 配置

所有用户数据都在 `~/.config/omarchy-newswire-zh/`——运行期**永不写插件目录**
（写它会触发 shell 对整个插件热重载，用着用着弹窗就被关掉）。

| 路径 | 用途 |
|---|---|
| `~/.config/omarchy-newswire-zh/config.json` | 运行时设置（0600 权限；可能含翻译 API key） |
| `~/.config/omarchy-newswire-zh/feeds.json` | 你的自定义源列表（首次运行从仓库预设 seed 一份） |
| `~/.cache/omarchy-newswire-zh/` | 新闻缓存 + 翻译缓存（按语言分开） |

设置页（弹窗头部 ⚙）可改：

- **自动刷新间隔**——默认每 30 分钟
- **新闻源管理**——按语言启用 / 停用 / 删除 / 添加，带实时状态
  （坏源或空源显示红色 ✗，不再静默失败）
- **翻译引擎**——开关、Base URL、API Key、模型、目标语言（中文 / English）、测试按钮
- **外观**——字号、显示来源、显示相对时间、悬停暂停

bar 级设置（滚动区最小/最大宽度、滚动速度、右侧安全间隙、字体）在
`manifest.json` 默认值里，可在 shell layout 中按条目覆盖。

## 交互

| 操作 | 效果 |
|---|---|
| 左键点 ticker | 展开 / 收起弹窗列表 |
| 中键点 ticker | 立即刷新 |
| 悬停 | 暂停滚动 |
| `语言： CN/EN` 按钮（弹窗头部） | 切换界面 + 信息源语言 |
| ⚙ 按钮（弹窗头部） | 打开设置页 |
| 点击标题 | 浏览器打开 + 标记已读 |
| IPC | `quickshell ipc herman.newswire-zh open/close/toggle/refresh/nextHeadline/setLang/toggleLang/configGet/feedsList/translateTest` |

## CLI

抓取引擎是独立的纯标准库 Python 脚本，方便单独测试：

```bash
python3 scripts/newswire.py refresh --lang zh      # 抓取 + 缓存 +（可选）翻译
python3 scripts/newswire.py dump --lang en         # 打印缓存标题
python3 scripts/newswire.py config get             # 查看合并后的生效配置
python3 scripts/newswire.py feeds list --lang zh   # 列出信息源及稳定 id
python3 scripts/newswire.py translate-test '{"translate":{...},"text":"..."}'
```

## 架构

```
manifest.json         插件清单（bar-widget，center 区）
Widget.qml          bar ticker：滚动/轮播定时器、悬停、triggerPress 派发、IPC + 子进程桥接
NewsPopup.qml       弹窗：新闻列表 + 设置视图（语言按钮、⚙）
scripts/newswire.py  引擎：抓取/解析/去重/缓存/翻译（仅 Python 标准库）
feeds.json          出厂预设源（只读默认值；用户副本在 ~/.config）
```

数据流：`newswire.py refresh` → 解析 RSS/Atom → 去重 → JSON 缓存 →
widget 读缓存 → QML 渲染。引擎以子进程方式运行（绝不阻塞 UI）；
设置写入经单一队列进程串行执行，避免互踩。

## 开发验证

```bash
python3 -m py_compile scripts/newswire.py
/usr/lib/qt6/bin/qmllint Widget.qml NewsPopup.qml   # 应 0 Error
journalctl --user -o cat | grep -i newswire          # 运行日志应干净
```

## 已知限制

- 36氪 / PingWest 返回 JS 反爬挑战页（无有效公开 RSS），已从预设移除；
  需要时自建 RSSHub 代理接入
- 微博 / 知乎 / B站 / 头条热榜已通过 [NewsNow](https://newsnow.busiyi.world)
  公共 JSON API 内置支持（自带适配器，无需自建）。信息源 URL 指向
  `https://newsnow.busiyi.world/api/s?id=<源>` 即自动走 JSON 解析
- 本项目所用网关上 EN→ZH 翻译单批约 25s，预算可能截断当批——
  剩余标题下次刷新自动补齐（缓存保证不重复翻译）

## License

MIT

English documentation: [README.md](README.md)。
