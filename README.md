# Newswire — Bilingual scrolling news ticker for Omarchy

A bar widget for the [Omarchy](https://omarchy.org) shell (Quickshell) that scrolls
news headlines from RSS/Atom feeds directly in your top/bottom bar — with a
Chinese/English bilingual UI and optional LLM-powered translation.

Inspired by [hermes-newswire](https://github.com/tony-simons-aiowa/hermes-newswire),
rebuilt for Omarchy with Chinese + English content sources.

```
📰  Solidot · FAST discovers shortest-period double neutron star · 14 min ago  ◆  ...
```

## Features

- **Scrolling ticker** — headlines scroll continuously in the bar; pause on hover;
  click to open the full list. Headlines short enough to fit the viewport rotate
  on a dwell timer instead of sitting still.
- **Popup list** — unread items bolded with a dot, source tags, relative time,
  click to open in your browser and mark as read.
- **Zero LLM / zero API key by default** — fetching, parsing, dedupe, and caching
  are 100% local. No model tokens spent on the routine path.
- **Offline capable** — JSON cache on disk; the ticker keeps showing cached
  headlines when the network is down and silently refreshes when it returns.
- **Bilingual UI (EN / CN)** — one click in the popup header switches the whole
  interface and the feed set between English and Chinese. First install defaults
  to English.
- **Optional translation engine** — point it at any OpenAI-compatible endpoint
  (`/chat/completions`) and non-target-language headlines get translated
  (e.g. English sources shown in Chinese, for non-native English readers).
  Hash-cached so each headline is translated once; failures silently fall back
  to the original title. Original titles are preserved (`title_orig`) and links
  are never rewritten.
- **SSRF-hardened fetcher** — feed URLs are treated as untrusted input:
  http/https only, loopback/private/link-local/CGNAT/metadata addresses blocked
  (literal + post-DNS resolution), redirects validated per hop (max 3),
  5 s connect / 12 s total timeout, 3 MB body cap, all HTML stripped before storage.
- **CJK rendering** — Noto Sans CJK SC by default, configurable.
- **No telemetry.** Ever.

## Install

```bash
omarchy plugin add https://github.com/herman6888/newswire-omarchy.git
omarchy plugin enable herman.newswire-zh center
```

Or manually: clone this repo into `~/.config/omarchy/plugins/herman.newswire-zh/`
— the shell hot-reloads on save.

Requires `python3` on PATH (stdlib only, no pip packages needed).

## Uninstall

```bash
omarchy plugin disable herman.newswire-zh
rm -rf ~/.config/omarchy/plugins/herman.newswire-zh
# optional: also remove your settings and caches
rm -rf ~/.config/omarchy-newswire-zh ~/.cache/omarchy-newswire-zh
```

## Configuration

All user state lives in `~/.config/omarchy-newswire-zh/` — the plugin directory
is never written at runtime (writing into it would trigger a full shell plugin
reload mid-use).

| Path | Purpose |
|---|---|
| `~/.config/omarchy-newswire-zh/config.json` | Runtime settings (mode 0600; may contain your translation API key) |
| `~/.config/omarchy-newswire-zh/feeds.json` | Your custom feed list, seeded from the bundled `feeds.json` preset on first run |
| `~/.cache/omarchy-newswire-zh/` | Article cache + translation cache (per language) |

The settings page (⚙ in the popup header) lets you change:

- **Auto-refresh interval** — default every 30 minutes
- **Feeds** — enable / disable / add / remove per language, with live status
  (a broken or empty source shows a red ✗ instead of failing silently)
- **Translation engine** — enable/disable, base URL, API key, model,
  target language (Chinese / English), and a Test button
- **Appearance** — font size, show source, show relative time, pause on hover

Bar-level settings (min/max ticker width, scroll speed, right gap, fonts) are
in `manifest.json` defaults and can be overridden per-layout in your shell config.

## Interaction

| Action | Effect |
|---|---|
| Left-click ticker | Open / close the popup list |
| Middle-click ticker | Refresh now |
| Hover | Pause scrolling |
| `语言： CN/EN` button (popup header) | Switch UI + feed language |
| ⚙ button (popup header) | Open settings page |
| Click a headline | Open in browser + mark as read |
| IPC | `quickshell ipc herman.newswire-zh open/close/toggle/refresh/nextHeadline/setLang/toggleLang/configGet/feedsList/translateTest` |

## CLI

The fetcher is a standalone stdlib-only Python script — handy for testing:

```bash
python3 scripts/newswire.py refresh --lang zh      # fetch + cache + (optional) translate
python3 scripts/newswire.py dump --lang en         # print cached headlines
python3 scripts/newswire.py config get             # merged effective config
python3 scripts/newswire.py feeds list --lang zh   # list feeds with stable ids
python3 scripts/newswire.py translate-test '{"translate":{...},"text":"..."}'
```

## Architecture

```
manifest.json         plugin manifest (bar-widget, center section)
Widget.qml          bar ticker: scroll/dwell timers, hover, triggerPress dispatch, IPC + process bridge
NewsPopup.qml       popup: headline list + settings view (language button, ⚙)
scripts/newswire.py  engine: fetch/parse/dedupe/cache/translate (Python stdlib only)
feeds.json          bundled preset feeds (read-only default; user copy lives in ~/.config)
```

Data flow: `newswire.py refresh` → parse RSS/Atom → dedupe → JSON cache →
widget reads cache → QML renders. The engine runs as a spawned subprocess
(never blocks the UI); settings writes go through a single queued process to
avoid clobbering.

## Development

```bash
python3 -m py_compile scripts/newswire.py
/usr/lib/qt6/bin/qmllint Widget.qml NewsPopup.qml   # 0 errors expected
journalctl --user -o cat | grep -i newswire          # clean runtime log
```

## Known limitations

- 36氪 / PingWest serve JS anti-bot challenge pages (no valid public RSS);
  removed from presets. Route through a self-hosted RSSHub if needed.
- Weibo / Zhihu / Bilibili / Toutiao hot lists are included via the
  [NewsNow](https://newsnow.busiyi.world) public JSON API (built-in adapter,
  no self-hosting required). Point any feed URL at
  `https://newsnow.busiyi.world/api/s?id=<source>` and it is parsed natively.
- On this project's gateway, EN→ZH translation batches can take ~25 s; the
  per-target budget may cut a batch short — the remainder is translated on the
  next refresh (cache guarantees no duplicate work).

## License

MIT

中文文档见 [README_zh.md](README_zh.md)。
