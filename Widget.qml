import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

/// 快讯 bar widget —— 自适应宽度滚动标题 + 点击展开列表 + 中英双语
Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  // config.json 是运行时唯一真源（插件没有写 manifest settings 的 API）；
  // manifest settings 只作为兼容回落。runtimeCfg 由 `config get` 填充。
  property var runtimeCfg: ({})
  readonly property var cfg: {
    var o = {}
    if (settings && typeof settings === "object") { for (var k in settings) o[k] = settings[k] }
    if (runtimeCfg && typeof runtimeCfg === "object") { for (var k2 in runtimeCfg) o[k2] = runtimeCfg[k2] }
    return o
  }

  function num(key, fallback) {
    var v = root.cfg[key]
    return (typeof v === "number" && isFinite(v)) ? v : fallback
  }
  function boolv(key, fallback) {
    var v = root.cfg[key]
    return (typeof v === "boolean") ? v : fallback
  }
  function strv(key, fallback) {
    var v = root.cfg[key]
    return (typeof v === "string" && v.length > 0) ? v : fallback
  }

  // ---- 语言 ----
  // 首次安装（无 lang.json / 无 config.json）默认英文，用户切过之后以 lang.json 为准。
  property string lang: "en"
  readonly property bool isEn: lang === "en"
  readonly property string defaultLang: strv("defaultLang", "en") === "zh" ? "zh" : "en"
  readonly property string uiFont: isEn ? strv("enFont", "Noto Sans") : strv("cjkFont", "Noto Sans CJK SC")

  readonly property var loc: isEn ? {
    tickerEmpty: "Newswire · no items",
    tickerLoading: "Newswire · loading…",
    popupTitle: "Newswire",
    noCache: "· no cache",
    countSuffix: " items",
    refreshing: "Refreshing…",
    refresh: "Refresh",
    emptyList: "No items — hit Refresh",
    loadingList: "Fetching news…",
  } : {
    tickerEmpty: "中文快讯 · 暂无内容",
    tickerLoading: "正在加载…",
    popupTitle: "中文快讯",
    noCache: "· 无缓存",
    countSuffix: " 条",
    refreshing: "刷新中…",
    refresh: "刷新",
    emptyList: "暂无内容，点右上角刷新",
    loadingList: "正在抓取资讯…",
  }

  // ---- 自适应宽度 ----
  readonly property int tickerMinWidth: Math.max(80, Math.round(num("tickerMinWidth", 160)))
  readonly property int tickerMaxWidth: Math.max(tickerMinWidth + 40, Math.round(num("tickerMaxWidth", 520)))
  readonly property int gap: Math.max(4, Math.round(num("gap", 14)))
  readonly property int innerPad: Math.max(0, Math.round(num("innerPadding", 8)))

  readonly property int textSize: Math.max(9, Math.min(20, Math.round(num("textPixelSize", 13))))
  readonly property int stepMs: Math.max(10, Math.round(num("scrollStepMs", 30)))
  readonly property int stepPx: Math.max(1, Math.round(num("scrollPixels", 1)))
  readonly property bool pauseOnHover: boolv("pauseOnHover", true)
  readonly property bool scrollPaused: boolv("paused", false)
  // 短/中长度标题（装得下可视区、不需要滚动）在切下一条前的停留秒数
  readonly property int rotateDwellSec: Math.max(2, Math.round(num("rotateDwellSec", 5)))
  readonly property bool showSource: boolv("showSource", true)
  readonly property bool showAge: boolv("showAge", true)
  readonly property int refreshSec: Math.max(60, Math.round(num("refreshIntervalSec", 1800)))
  readonly property int rightGap: Math.max(0, Math.round(num("rightGap", 56)))
  readonly property int maxItems: Math.max(5, Math.round(num("maxItems", 60)))

  readonly property url scriptUrl: Qt.resolvedUrl("scripts/newswire.py")
  readonly property string scriptPath: scriptUrl.toString().replace(/^file:\/\//, "")

  // ---- 数据 ----
  property var articles: []
  property var sources: []
  property int updated: 0
  property bool refreshing: false
  property string lastError: ""
  property var readIds: []

  // ---- 滚动状态 ----
  property int index: 0
  property real tx: 0
  property bool hovering: false
  readonly property bool paused: scrollPaused || (hovering && pauseOnHover)
  // 跑马灯模式：短标题也滚动（从右侧入场滚出左侧），而不是居中轮播
  readonly property bool alwaysScroll: boolv("alwaysScroll", false)

  // T3 Bug2：滚动判定与自适应宽度解耦。
  // 旧写法 running = implicitWidth > tickerClip.width，而 clip 宽度本身 = clamp(implicitWidth + pad)，
  // 所以中长度标题（宽落在 min~max 之间）永远 “装得下” → Timer 永不启动 → 只看到 1 条新闻卡死。
  // 现在：装得下 = 不滞动但定时轮播（dwellTimer）；装不下 = 滞动（scrollTimer）。
  readonly property bool tickerActive: !root.vertical && root.articles.length > 0
  readonly property bool textFitsViewport: tickerText.implicitWidth > 0
                                         && tickerText.implicitWidth <= tickerClip.width

  readonly property bool vertical: bar ? bar.vertical : false
  implicitWidth: vertical ? (bar ? bar.barSize : 28)
                         : (newsIcon.width + gap + tickerClip.width + rightGap)
  implicitHeight: bar ? bar.barSize : 26

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color fg: bar
    ? (luminance(bar.background) > 0.6 ? "#1a1a1a" : bar.foreground)
    : "#e8e8e8"
  readonly property color dimFg: bar
    ? (luminance(bar.background) > 0.6 ? "#5a5a5a" : Qt.alpha(bar.foreground, 0.62))
    : "#999999"
  readonly property color accent: bar ? bar.urgent : "#4a9eff"

  function clampStr(s, n) {
    var v = String(s || "")
    return v.length > n ? v.slice(0, n) + "…" : v
  }

  function currentArticle() {
    if (root.articles.length === 0) return null
    if (root.index >= root.articles.length) root.index = 0
    return root.articles[root.index]
  }

  function composeLine(a) {
    if (!a) return root.loc.tickerEmpty
    var parts = []
    if (root.showSource && a.source) parts.push("◆ " + a.source)
    parts.push(root.clampStr(a.title, 90))
    if (root.showAge && a.age) parts.push(a.age)
    return parts.join("  ·  ")
  }

  function openUrl(url) {
    if (!url) return
    var q = Util.shellQuote(String(url))
    if (bar) bar.run("xdg-open " + q)
    else Qt.openUrlExternally(url)
  }

  function markRead(id) {
    if (!id) return
    var ids = root.readIds.slice()
    if (ids.indexOf(id) < 0) ids.push(id)
    root.readIds = ids.slice(-2000)
    if (markProc.running) return
    markProc.arg = String(id)
    markProc.running = true
  }

  function next() {
    if (root.articles.length === 0) return
    root.index = (root.index + 1) % root.articles.length
  }

  function resetScroll() {
    var w = tickerText.implicitWidth
    if (root.alwaysScroll) {
      // 跑马灯：从可视区右缘入场，向左滚出
      root.tx = tickerClip.width
      tickerText.x = root.tx
      return
    }
    // 短标题（比可视区窄）立即居中，不依赖滚动 Timer（Timer 对短标题不启动）
    root.tx = (w > 0 && w <= tickerClip.width) ? (tickerClip.width - w) / 2 : tickerClip.width
    tickerText.x = root.tx
    // 文本布局可能尚未完成，稍后再保证一次可见
    Qt.callLater(function () {
      var w2 = tickerText.implicitWidth
      if (!root.alwaysScroll && w2 > 0 && w2 <= tickerClip.width) {
        root.tx = (tickerClip.width - w2) / 2
        tickerText.x = root.tx
      }
    })
  }

  function step() {
    if (paused) return
    if (root.articles.length === 0) return
    var w = tickerText.implicitWidth
    if (!root.alwaysScroll && w <= tickerClip.width) {
      tickerText.x = (tickerClip.width - w) / 2
      return
    }
    root.tx -= stepPx
    if (root.tx <= -w) {
      next()
      // 下一条可能是短标题：走 resetScroll 保证居中可见，而不是停在屏外
      root.resetScroll()
      return
    }
    tickerText.x = root.tx
  }

  function loadCache() {
    if (!dumpProc.running) dumpProc.running = true
  }

  function refreshNetwork() {
    if (refreshProc.running) return
    root.refreshing = true
    refreshProc.running = true
  }

  // ---- 设置页通道：单一 Process + 队列（避免多个写操作互踩）----
  property var cmdQueue: []           // [{ args: [...], tag: "config"|"feeds"|"feedsList"|"translateTest" }]
  property string cmdTag: ""
  property bool langPersisted: false  // lang.json 里存过语言（优先于 config.defaultLang）

  function enqueueScript(args, tag) {
    root.cmdQueue = root.cmdQueue.concat([{ args: args, tag: tag }])
    root.pumpScript()
  }

  function pumpScript() {
    if (scriptProc.running || root.cmdQueue.length === 0) return
    var job = root.cmdQueue[0]
    root.cmdQueue = root.cmdQueue.slice(1)
    root.cmdTag = job.tag
    scriptProc.command = ["/usr/bin/env", "python3", root.scriptPath].concat(job.args)
    scriptProc.running = true
  }

  function handleScriptResult(text) {
    var data
    try { data = JSON.parse(text || "{}") } catch (e) { data = null }
    if (!data || typeof data !== "object") { console.warn("[NW] script json parse failed tag=" + root.cmdTag); return }

    if (root.cmdTag === "config") {
      if (data._cmdFailed) { console.warn("[NW] config set failed: " + data.error); return }
      // `config get` 直接返回合并后的配置；`config set` 包一层 { ok, config }
      root.runtimeCfg = (data.config && typeof data.config === "object") ? data.config : data
      if (!root.langPersisted) {
        var dl = root.runtimeCfg.defaultLang === "en" ? "en" : "zh"
        if (dl !== root.lang) root.lang = dl
      }
      console.warn("[NW] runtime config loaded, refreshIntervalSec=" + root.refreshSec)
      return
    }

    if (root.cmdTag === "feeds" || root.cmdTag === "feedsList") {
      if (Array.isArray(data.feeds)) popup.feeds = data.feeds
      if (data._cmdFailed) { popup.feedsStatus = String(data.error || "操作失败"); return }
      if (root.cmdTag === "feeds") {
        popup.feedsStatus = root.isEn ? "Saved · refreshing…" : "已保存，刷新中…"
        root.refreshNetwork()
      }
      return
    }

    if (root.cmdTag === "translateTest") {
      popup.translateStatus = data.ok
        ? ("✓ " + String(data.translated || ""))
        : ("✗ " + String(data.error || "no translation"))
      return
    }
  }

  Process {
    id: scriptProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleScriptResult(text)
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpScript)
  }

  function loadRuntimeConfig() { root.enqueueScript(["config", "get"], "config") }

  function applyPayload(text, isRefresh) {
    var data
    try { data = JSON.parse(text || "{}") }
    catch (e) {
      if (isRefresh) { root.refreshing = false; root.lastError = "JSON parse failed" }
      return
    }
    // T3 Bug2：60s 缓存兜底刷新不得打断当前滞动。内容没实际变化（updated 时间戳相同）
    // 就直接丢弃这次 payload，不重设 articles → tickerText.text 不重绑 → tx/implicitWidth 不动。
    var newUpdated = data.updated || 0
    var newArts = Array.isArray(data.articles) ? data.articles : []
    if (!isRefresh && newUpdated > 0 && newUpdated === root.updated
        && newArts.length === root.articles.length) {
      return
    }
    var arts = newArts
    var out = []
    for (var i = 0; i < arts.length && out.length < root.maxItems; i++) {
      var a = arts[i]
      if (!a || !a.title) continue
      var aid = String(a.id || a.url || i)
      out.push({
        id: aid,
        title: root.clampStr(a.title, 160),
        url: String(a.url || ""),
        source: root.clampStr(a.source || "", 24),
        age: String(a.age || ""),
        ts: a.ts || 0,
        summary: String(a.summary || "").slice(0, 280),
        read: root.readIds.indexOf(aid) >= 0
      })
    }
    root.articles = out
    root.sources = Array.isArray(data.sources) ? data.sources : []
    root.updated = newUpdated
    // T3 Bug2：保留当前滞动进度。只在索引越界时归零，不再无条件 resetScroll（旧写法
    // 会把正在滞动的条目 x 拉回屏内起点，看起来“跳一下”）。
    var clamped = root.index >= out.length
    if (clamped) root.index = 0
    if (clamped || root.tx === 0) Qt.callLater(root.resetScroll)
    if (isRefresh) {
      root.refreshing = false
      root.lastError = data.error ? String(data.error) : ""
    }
  }

  // ---- 语言切换 ----
  function applyLang(nl) {
    if (nl !== "zh" && nl !== "en") return
    if (nl === root.lang) return
    root.lang = nl
    root.articles = []
    root.index = 0
    root.tx = 0
    langWriteProc.arg = nl
    langWriteProc.running = true
    readProc.running = true
    root.loadCache()
    root.refreshNetwork()
  }
  function toggleLang() { applyLang(root.isEn ? "zh" : "en") }

  // ---- 进程 ----

  // 启动时读取持久化语言
  Process {
    id: langReadProc
    command: ["/usr/bin/env", "python3", "-c",
      "import json,os\ntry:\n print(json.load(open(os.path.expanduser('~/.cache/omarchy-newswire-zh/lang.json'))).get('lang',''))\nexcept Exception:\n print('')"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var l = (text || "").trim()
        root.langPersisted = (l === "en" || l === "zh")
        root.lang = root.langPersisted ? l : root.defaultLang
        Qt.callLater(function () {
          readProc.running = true
          root.loadCache()
          root.refreshNetwork()
          root.resetScroll()
        })
      }
    }
  }

  // 持久化语言选择
  Process {
    id: langWriteProc
    property string arg: "zh"
    command: ["/usr/bin/env", "python3", "-c",
      "import json,os,sys\np=os.path.expanduser('~/.cache/omarchy-newswire-zh/lang.json')\nos.makedirs(os.path.dirname(p),exist_ok=True)\njson.dump({'lang':sys.argv[1]},open(p,'w'))", arg]
  }

  // 已读列表（按语言分文件）
  Process {
    id: readProc
    command: ["/usr/bin/env", "python3", "-c",
      "import json,os\nf=os.path.expanduser('~/.cache/omarchy-newswire-zh/'+('read_en.json' if '" + root.lang + "'=='en' else 'read.json'))\nprint(json.dumps(json.load(open(f)) if os.path.exists(f) else []))"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ids
        try { ids = JSON.parse(text || "[]") } catch (e) { ids = [] }
        root.readIds = Array.isArray(ids) ? ids : []
        root.recomputeRead()
      }
    }
  }

  function recomputeRead() {
    var out = root.articles.slice()
    for (var i = 0; i < out.length; i++) {
      var copy = {}
      for (var k in out[i]) copy[k] = out[i][k]
      copy.read = root.readIds.indexOf(out[i].id) >= 0
      out[i] = copy
    }
    root.articles = out
  }

  // 标记已读落盘
  Process {
    id: markProc
    property string arg: ""
    command: ["/usr/bin/env", "python3", root.scriptPath, "markread", arg, "--lang", root.lang]
  }

  // 读缓存（无网络，毫秒级）
  Process {
    id: dumpProc
    command: ["/usr/bin/env", "python3", root.scriptPath, "dump", "--lang", root.lang]
    onRunningChanged: { if (running) dumpWatchdog.restart(); else dumpWatchdog.stop() }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(text, false)
    }
  }
  Timer { id: dumpWatchdog; interval: 8000; onTriggered: if (dumpProc.running) dumpProc.running = false }

  // 抓网络（后台，可能几秒）
  Process {
    id: refreshProc
    command: ["/usr/bin/env", "python3", root.scriptPath, "refresh", "--lang", root.lang]
    onRunningChanged: { if (running) refreshWatchdog.restart(); else refreshWatchdog.stop() }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(text, true)
    }
  }
  Timer { id: refreshWatchdog; interval: 45000; onTriggered: if (refreshProc.running) refreshProc.running = false }

  // ---- 视觉 ----

  // 布局随锚点位置自适应：
  //  - newswire 在 clock 右侧（默认）：[📰][ticker→] 图标在左
  //  - newswire 在 clock 左侧：[ticker←][📰] 图标贴右（挨着时钟），ticker 向左扩
  // _iconRight 由 recomputeLeftAvail 判定（widget 右缘在屏幕中线左侧）。
  property bool _iconRight: false

  // 📰 图标（纯展示）。语言切换按钮已按需求从 bar 移到弹窗头部，所以这里不再注册
  // 独立 clickTarget，也不定义 triggerPress —— bar 会落回 widget 根 triggerPress（弹弹窗）。
  Item {
    id: newsIcon
    anchors.verticalCenter: parent.verticalCenter
    x: root._iconRight ? parent.width - width : 0
    width: newsIconLabel.implicitWidth + 12
    height: parent.height

    Text {
      id: newsIconLabel
      anchors.centerIn: parent
      text: "📰"
      font.pixelSize: 12
      color: root.fg
    }
  }

  // ---- 动态左边界（newswire 位于 clock 锚点左侧时）----
  // clock 居中锚定，newswire 在锚点左边 → widget 右缘被钉死在 clock.left，
  // ticker 只能向左扩。可用宽度 = widget右缘 - 左区右缘 - 图标/间距。
  // 左区（menu/workspaces/stash）变宽 → 右缘右移 → ticker 自动收窄，互不遮挡。
  // 注：widget 右缘用 selfX + root.width 表达；tickerClip 变宽会把整个 center
  // 组往左推，selfX 等量减小，两者之和恒定 → 不会自激振荡。
  property real leftAvail: Infinity

  // 跳过自身子树（否则会把 tickerClip 自己当成边界）
  function inOurSubtree(c) {
    var p = c
    while (p) {
      if (p === root) return true
      p = p.parent
    }
    return false
  }

  function findLeftSectionRight(item, parent, cw, depth) {
    if (!item || !parent || depth > 6) return -Infinity
    var best = -Infinity
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (!c || !c.visible || c.width <= 0 || root.inOurSubtree(c)) continue
      // 坐标换算到窗口空间再判断（左区元素可能嵌套在 center 组里）
      var mx = c.mapToItem(parent, 0, 0).x
      var mRight = mx + c.width
      // 左锚定特征：左缘贴内容区左缘、位于半屏左侧、非全宽背景
      if (mx <= 12 && mRight < cw * 0.5 && c.width < cw * 0.9) {
        if (mRight > best) best = mRight
      } else if (depth < 6) {
        var sub = findLeftSectionRight(c, parent, cw, depth + 1)
        if (sub > best) best = sub
      }
    }
    return best
  }

  function recomputeLeftAvail() {
    var win = root.QsWindow ? root.QsWindow.window : null
    if (!win || !win.contentItem) return
    var cw = win.contentItem.width
    if (cw <= 0) return
    var leftSecRight = findLeftSectionRight(win.contentItem, win.contentItem, cw, 0)
    if (leftSecRight === -Infinity) return

    var selfX = root.mapToItem(win.contentItem, 0, 0).x
    var widgetRight = selfX + root.width
    // 图标朝向：widget 起点在屏幕中线左侧 → 贴 clock 左侧，图标翻到右边
    var iconRight = selfX < cw * 0.5
    if (root._iconRight !== iconRight) root._iconRight = iconRight
    var avail = Math.max(root.tickerMinWidth,
                        widgetRight - leftSecRight - newsIcon.width
                        - root.gap - root.rightGap - 8)
    if (Math.abs(avail - root.leftAvail) > 1) {
      console.warn("[NW] leftAvail=" + avail.toFixed(0)
                  + " (leftSecRight=" + leftSecRight.toFixed(0)
                  + " widgetRight=" + widgetRight.toFixed(0) + " cw=" + cw + ")")
      root.leftAvail = avail
    }
  }

  // ---- 动态右边界 ----
  // center 区整体居中：ticker 变宽会把整条 center 行往左推（更新图标抖动），
  // 太宽时右端盖住 right 区的 tray「<」。第三方 widget 拿到的 bar facade 不暴露
  // moduleSlots，所以这里直接走窗口 item 树：找 bar 窗口里「右锚定」的区块
  // （右缘贴内容区右缘、位于半屏右侧、非全宽背景），取其最左 x = right 区左缘。
  // tray 悬停展开 → right 区变宽 → 左缘左移 → ticker 自动收窄。
  property real rightAvail: Infinity

  function findRightSectionLeft(item, parent, cw, depth) {
    if (!item || !parent || depth > 6) return Infinity
    var best = Infinity
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (!c || !c.visible || c.width <= 0 || root.inOurSubtree(c)) continue
      // 坐标换算到窗口空间再判断
      var mx = c.mapToItem(parent, 0, 0).x
      var rightEdge = mx + c.width
      // 右锚定特征：右缘贴内容区右缘、起点在半屏右侧、不是全宽背景
      if (rightEdge >= cw - 12 && mx > cw * 0.5 && c.width < cw * 0.9) {
        if (mx < best) best = mx
      } else if (depth < 6) {
        var sub = findRightSectionLeft(c, parent, cw, depth + 1)
        if (sub < best) best = sub
      }
    }
    return best
  }

  function recomputeRightAvail() {
    var win = root.QsWindow ? root.QsWindow.window : null
    if (!win || !win.contentItem) { console.warn("[NW] rAvail: no win/contentItem"); return }
    var cw = win.contentItem.width
    if (cw <= 0) { console.warn("[NW] rAvail: cw=0"); return }
    var minX = findRightSectionLeft(win.contentItem, win.contentItem, cw, 0)
    if (minX === Infinity) return

    // ticker 起点（窗口坐标）= widget 自身 x + 图标 + 间距；再留 8px 呼吸位
    var selfX = root.mapToItem(win.contentItem, 0, 0).x
    var avail = Math.max(root.tickerMinWidth,
                        minX - selfX - newsIcon.width - root.gap - 8)
    if (Math.abs(avail - root.rightAvail) > 1) {
      console.warn("[NW] rightAvail=" + avail.toFixed(0) + " (rightSecX=" + minX.toFixed(0) + " cw=" + cw + ")")
      root.rightAvail = avail
    }
  }

  Timer {
    id: boundaryTimer
    interval: 300
    running: !root.vertical && !!root.bar
    repeat: true
    onTriggered: { root.recomputeRightAvail(); root.recomputeLeftAvail() }
  }

  // 自适应宽度滚动区
  Item {
    id: tickerClip
    anchors.verticalCenter: parent.verticalCenter
    // iconRight（在 clock 左侧）：clip 右对齐贴紧图标左侧，ticker 向左扩；
    // 否则图标在左，clip 紧跟图标右侧。
    x: root._iconRight ? (newsIcon.x - root.gap - tickerClip.width)
                      : (newsIcon.width + root.gap)
    // 固定宽度 = min(设定上限, 当前布局方向的动态边界)：不随标题长度变化。
    // _iconRight（在 clock 左侧）→ 由 leftAvail 封顶，向右被 clock 钉死无需右边界；
    // 否则（在 clock 右侧）→ 由 rightAvail 封顶（tray「<」不被遮挡）。
    width: root.vertical ? 0 : Math.min(root.tickerMaxWidth,
                                       root._iconRight ? root.leftAvail : root.rightAvail)
    height: parent.height
    clip: true
    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    // 可视区宽度变化时，短标题跟随居中（避免 Timer 不启动而停在屏外）
    onWidthChanged: if (tickerText.implicitWidth <= width) tickerText.x = (width - tickerText.implicitWidth) / 2

    Text {
      id: tickerText
      anchors.verticalCenter: parent.verticalCenter
      x: root.tx
      text: root.composeLine(root.currentArticle())
      color: root.fg
      font.family: root.uiFont
      font.pixelSize: root.textSize
      elide: Text.ElideNone
      // 文本重新布局完成后，短标题立即居中（Timer 对短标题不启动）
      onImplicitWidthChanged: if (implicitWidth > 0 && implicitWidth <= tickerClip.width) {
        root.tx = (tickerClip.width - implicitWidth) / 2
        x = root.tx
      }
    }

    Text {
      visible: root.articles.length === 0
      anchors.centerIn: parent
      text: root.refreshing ? root.loc.tickerLoading : root.loc.tickerEmpty
      color: root.dimFg
      font.family: root.uiFont
      font.pixelSize: Math.max(9, root.textSize - 1)
    }
  }

  Timer {
    id: scrollTimer
    interval: root.stepMs
    running: root.tickerActive && (root.alwaysScroll || !root.textFitsViewport)
    repeat: true
    onTriggered: root.step()
  }

  // 短/中长度标题：装得下所以不滚动，但必须定时换下一条，不能静止卡在第一条
  Timer {
    id: dwellTimer
    interval: root.rotateDwellSec * 1000
    running: root.tickerActive && !root.alwaysScroll && root.textFitsViewport && !root.paused
    repeat: true
    onTriggered: root.next()
  }

  // 缓存兜底刷新（读本地文件，不花网络）
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.loadCache()
  }

  // 网络刷新
  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { console.warn("[NW] auto-refresh tick, intervalSec=" + root.refreshSec); root.refreshNetwork() }
  }

  // 悬停暂停：用 HoverHandler（被动），不抢 bar 的点击/拖拽派发
  HoverHandler {
    id: hoverHandler
    onHoveredChanged: root.hovering = hovered
  }

  // bar 的点击派发器只把点击路由给暴露 triggerPress 的 widget（见 Bar.qml）
  function triggerPress(button) {
    if (button === Qt.MiddleButton) { root.refreshNetwork(); return }
    popup.toggle()
  }

  IpcHandler {
    target: "herman.newswire-zh"
    function open(): void { popup.openPopup() }
    function close(): void { popup.close() }
    function toggle(): void { popup.toggle() }
    function refresh(): void { root.refreshNetwork() }
    function nextHeadline(): void { root.next(); root.resetScroll() }
    function setLang(l: string): void { root.applyLang(String(l)) }
    function toggleLang(): void { root.toggleLang() }
  }

  NewsPopup {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    lang: root.lang
    articles: root.articles
    sources: root.sources
    updated: root.updated
    refreshing: root.refreshing
    lastError: root.lastError
    uiFont: root.uiFont
    cfg: root.runtimeCfg
    onRefreshRequested: root.refreshNetwork()
    onOpenRequested: function (url) { root.openUrl(url) }
    onMarkReadRequested: function (id) { root.markRead(id) }
    onConfigPatch: function (patchJson) { root.enqueueScript(["config", "set", patchJson], "config") }
    onFeedsOp: function (payloadJson) {
      var p
      try { p = JSON.parse(payloadJson) } catch (e) { return }
      var op = String(p.op || "")
      var args = ["feeds", op]
      if (op === "add") args = args.concat([String(p.name || ""), String(p.url || "")])
      else args.push(String(p.id || ""))
      args = args.concat(["--lang", root.lang])
      root.enqueueScript(args, "feeds")
    }
    onFeedsListRequested: function (lang) { root.enqueueScript(["feeds", "list", "--lang", String(lang)], "feedsList") }
    onLangSwitchRequested: function (lang) {
      root.enqueueScript(["config", "set", JSON.stringify({ defaultLang: String(lang) })], "config")
      root.applyLang(String(lang))
    }
    onTranslateTest: function (payloadJson) { root.enqueueScript(["translate-test", payloadJson], "translateTest") }
  }

  Component.onCompleted: {
    langReadProc.running = true
    root.loadRuntimeConfig()
  }
}
