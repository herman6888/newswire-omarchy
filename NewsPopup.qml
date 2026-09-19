import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

/// 快讯弹出列表：可滚动、可点击打开、未读加粗、来源标签（中英双语）
PopupWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false

  property string lang: "en"
  readonly property bool isEn: lang === "en"
  property string uiFont: "Noto Sans CJK SC"

  property var articles: []
  property var sources: []
  property int updated: 0
  property bool refreshing: false
  property string lastError: ""

  // ---- 设置视图状态 ----
  property bool settingsMode: false
  property var cfg: ({})            // Widget 传入的运行时配置（config.json 合并结果）
  property var feeds: []            // 当前语言的源（含派生 id）
  property string feedsStatus: ""
  property string translateStatus: ""

  // 注：文本框类控件的初值在设置视图 Component.onCompleted 里从 cfg 取一次，
  // 之后由用户持有，避免「写回配置 → 绑定回推」打断正在输入的光标。

  readonly property var loc: isEn ? {
    title: "Newswire",
    noCache: "· no cache",
    count: " items",
    refreshing: "Refreshing…",
    refresh: "Refresh",
    emptyList: "No items — hit Refresh",
    emptyListFiltered: "No items from this source",
    loadingList: "Fetching news…",
    settings: "Settings",
    back: "Back",
    langPrefix: "Lang: ",
    sLang: "DEFAULT LANGUAGE",
    sRefresh: "AUTO-REFRESH INTERVAL",
    sRefreshHint: "seconds (min 60)",
    sFeeds: "FEEDS",
    sNamePh: "name",
    sUrlPh: "https://…/rss",
    sAdd: "Add",
    sTranslate: "TRANSLATION ENGINE (OpenAI-compatible)",
    sTrTarget: "TARGET LANGUAGE",
    sTrOn: "Translate headlines not already in the target language (works in both UI languages)",
    sTrBaseUrl: "Base URL",
    sTrApiKey: "API key (optional)",
    sTrModel: "Model",
    sTest: "Test",
    sMisc: "MISCELLANEOUS",
    sPaused: "Pause scrolling",
    sAlwaysScroll: "Always scroll (marquee, even short headlines)",
    sPauseOnHover: "Pause on hover (default on: mouse over the bar stops scrolling)",
    sShowSource: "Show source",
    sShowAge: "Show relative time",
    sFontSize: "Font size",
    sTickerWidth: "Ticker width",
    sFeedOk: "ok",
    srcAll: "All",
    sFeedEmpty: "\u2717 no items / parse failed",
  } : {
    title: "中文快讯",
    noCache: "· 无缓存",
    count: " 条",
    refreshing: "刷新中…",
    refresh: "刷新",
    emptyList: "暂无内容，点右上角刷新",
    emptyListFiltered: "该来源暂无内容",
    loadingList: "正在抓取资讯…",
    settings: "设置",
    back: "返回",
    langPrefix: "语言： ",
    sLang: "默认语言",
    sRefresh: "自动刷新间隔",
    sRefreshHint: "秒（最小 60）",
    sFeeds: "新闻源",
    sNamePh: "名称",
    sUrlPh: "https://…/rss",
    sAdd: "添加",
    sTranslate: "翻译引擎（OpenAI 兼容）",
    sTrTarget: "目标语言",
    sTrOn: "把非目标语言的标题翻译成所选语言（中/英界面都生效）",
    sTrBaseUrl: "Base URL",
    sTrApiKey: "API Key（可留空）",
    sTrModel: "模型名",
    sTest: "测试",
    sMisc: "其它",
    sPaused: "暂停滚动",
    sAlwaysScroll: "始终滚动（跑马灯，短标题也滚）",
    sPauseOnHover: "鼠标悬停暂停（默认开：鼠标停在标题条上会停滚）",
    sShowSource: "显示来源",
    sShowAge: "显示相对时间",
    sFontSize: "字号",
    sTickerWidth: "滚动区宽度",
    sFeedOk: "正常",
    srcAll: "全部",
    sFeedEmpty: "✗ 无内容/解析失败",
  }

  // ---- 来源过滤（点源状态块切换；空 = 全部）----
  property string sourceFilter: ""
  readonly property var visibleArticles: sourceFilter === ""
    ? articles
    : (articles || []).filter(function (a) { return a && a.source === sourceFilter })

  signal refreshRequested()
  signal openRequested(string url)
  signal markReadRequested(string id)

  // 设置视图 → Widget（统一走 python 子命令落盘，再回推运行时配置）
  signal configPatch(string patchJson)
  signal feedsOp(string payloadJson)
  signal feedsListRequested(string lang)
  signal langSwitchRequested(string lang)
  signal translateTest(string payloadJson)

  function sendConfig(obj) { root.configPatch(JSON.stringify(obj)) }

  function toggleFeed(id, enabled) {
    root.feedsOp(JSON.stringify({ op: enabled ? "enable" : "disable", id: String(id) }))
  }

  function removeFeed(id) {
    root.feedsOp(JSON.stringify({ op: "remove", id: String(id) }))
  }

  function addFeed(name, url) {
    var n = String(name || "").trim()
    var u = String(url || "").trim()
    if (u.length === 0) {
      root.feedsStatus = root.isEn ? "URL required" : "必须填 URL"
      return
    }
    root.feedsOp(JSON.stringify({ op: "add", name: n, url: u }))
  }

  function runTranslateTest(baseUrl, apiKey, model, targetLang) {
    var tgt = String(targetLang || "zh")
    root.translateStatus = root.isEn ? "Testing…" : "测试中…"
    root.translateTest(JSON.stringify({
      translate: {
        baseUrl: String(baseUrl || ""), apiKey: String(apiKey || ""),
        model: String(model || ""), targetLang: tgt
      },
      text: tgt === "en" ? "央行宣布降息，市场普遍上涨" : "Markets rally as inflation cools for a third month"
    }))
  }

  function cfgGet(key, fallback) {
    var c = root.cfg
    if (c && typeof c === "object" && c[key] !== undefined && c[key] !== null) return c[key]
    return fallback
  }

  function cfgTranslate(key, fallback) {
    var t = root.cfg && typeof root.cfg === "object" ? root.cfg.translate : null
    if (t && typeof t === "object" && t[key] !== undefined && t[key] !== null) return t[key]
    return fallback
  }

  // T3 Bug1：坏源可见化。从 refresh 的 sources 段按 url 查状态，
  // 已启用但 items=0 / parse error → 设置页该源条目上显红色小字，不静默。
  function feedStatus(url) {
    var list = root.sources || []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (!s) continue
      if (String(s.url || "") !== String(url || "")) continue
      var n = Number(s.items || 0)
      if (s.ok && n > 0) return { bad: false, text: root.loc.sFeedOk + " " + n }
      var err = String(s.error || "").trim()
      return { bad: true, text: root.loc.sFeedEmpty + (err ? " · " + err.slice(0, 40) : "") }
    }
    return { bad: false, text: "" }
  }

  // 进入设置视图：拉一次源列表，并把当前配置镜像进控件
  function enterSettings() {
    root.settingsMode = true; console.warn("[NW] ENTER SETTINGS")
    root.feedsStatus = ""
    root.translateStatus = ""
    root.feedsListRequested(root.lang)
  }

  function exitSettings() {
    root.settingsMode = false
  }

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color fg: luminance(bg) > 0.6 ? "#1a1a1a" : Color.popups.text
  readonly property color safeMuted: luminance(bg) > 0.6 ? "#5a5a5a" : Color.muted

  readonly property int margin: 10
  readonly property int cardPadding: 12
  readonly property int listMaxHeight: 440

  implicitWidth: 420
  implicitHeight: Math.min(560, Math.max(160, contentCol.implicitHeight + cardPadding * 2))

  visible: open || card.opacity > 0
  color: "transparent"

  // 只在设置视图里拿键盘（xdg_popup 自带焦点抓取，关闭即释放）。
  // 绝不使用 HyprlandFocusGrab（全局抓取）—— 会劫持锁屏键盘。
  grabFocus: root.settingsMode

  function close() {
    root.open = false
    // 关闭时回到列表视图；键盘抓取由 grabFocus: settingsMode 自动释放
    root.settingsMode = false
  }
  function openPopup() { root.open = true }
  function toggle() { root.open = !root.open }

  onOpenChanged: {
    console.warn("[NW] popup open=" + open + " bar=" + (!!bar))
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  // 安全：不使用 HyprlandFocusGrab（全局键盘抓取）。该抓取会在锁屏时
  // 截走键盘，导致锁屏密码无法输入（实测踩过）。本弹窗为纯鼠标交互，
  // 不需要键盘。关闭方式：再次点击 ticker / 头部 ✕ / 其他 popout 抢占。
  anchor {
    id: popupAnchor
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.bar || !root.anchorWindow) return
      var target = root.anchorItem
      var w = root.implicitWidth
      var h = root.implicitHeight
      var localX = target.width / 2 - w / 2
      var localY = target.height + root.margin

      if (root.bar.position === "bottom") localY = -h - root.margin
      else if (root.bar.position === "left") { localX = target.width + root.margin; localY = target.height / 2 - h / 2 }
      else if (root.bar.position === "right") { localX = -w - root.margin; localY = target.height / 2 - h / 2 }

      var point = root.anchorWindow.contentItem.mapFromItem(target, localX, localY)
      if (root.bar.position === "top" || root.bar.position === "bottom")
        point.x = Math.max(root.margin, Math.min(point.x, root.anchorWindow.width - w - root.margin))
      else
        point.y = Math.max(root.margin, Math.min(point.y, root.anchorWindow.height - h - root.margin))

      popupAnchor.rect.x = Math.round(point.x)
      popupAnchor.rect.y = Math.round(point.y)
    }
  }

  Rectangle {
    id: card
    anchors.fill: parent
    radius: 0
    color: root.bg
    border.color: root.borderColor
    border.width: 2
    opacity: root.open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    Column {
      id: contentCol
      anchors.fill: parent
      anchors.margins: root.cardPadding
      spacing: 8

      // ---- 标题栏（锚定布局，不靠硬编码宽度撑开）----
      Item {
        width: parent.width
        height: 24

        // 设置视图的返回按钮（列表模式下宽度收为 0，不占位）
        Rectangle {
          id: backBtn
          z: 10
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: root.settingsMode
          width: visible ? backLabel.implicitWidth + 16 : 0
          height: 24
          radius: 0
          color: backMouse.containsMouse ? Qt.alpha(root.accent, 0.18) : "transparent"
          border.color: Qt.alpha(root.accent, 0.5)
          border.width: visible ? 1 : 0
          Text {
            id: backLabel
            anchors.centerIn: parent
            text: "‹ " + root.loc.back
            color: root.accent
            font.family: root.uiFont
            font.pixelSize: 12
          }
          MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.exitSettings()
          }
        }

        Text {
          id: titleText
          anchors.left: backBtn.right
          anchors.leftMargin: root.settingsMode ? 8 : 0
          anchors.verticalCenter: parent.verticalCenter
          text: root.settingsMode ? root.loc.settings : root.loc.title
          color: root.fg
          font.family: root.uiFont
          font.pixelSize: 15
          font.bold: true
        }

        Rectangle {
          id: closeBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: 24
          height: 24
          radius: 0
          color: closeMouse.containsMouse ? Qt.alpha(root.urgent, 0.18) : "transparent"
          border.color: Qt.alpha(root.urgent, 0.5)
          border.width: 1
          Text {
            anchors.centerIn: parent
            text: "✕"
            color: root.urgent
            font.pixelSize: 12
          }
          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.close()
          }
        }

        Rectangle {
          id: settingsBtn
          anchors.right: langBtn.left
          anchors.rightMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.settingsMode
          width: visible ? settingsLabel.implicitWidth + 16 : 0
          height: 24
          radius: 0
          color: settingsMouse.containsMouse ? Qt.alpha(root.accent, 0.18) : "transparent"
          border.color: Qt.alpha(root.accent, 0.5)
          border.width: visible ? 1 : 0
          Text {
            id: settingsLabel
            anchors.centerIn: parent
            text: "⚙ " + root.loc.settings
            color: root.accent
            font.family: root.uiFont
            font.pixelSize: 12
          }
          MouseArea {
            id: settingsMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.enterSettings()
          }
        }

        // 语言切换按钮（从 bar 移过来，放在设置按钮后面）
        Rectangle {
          id: langBtn
          anchors.right: closeBtn.left
          anchors.rightMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.settingsMode
          width: visible ? langBtnLabel.implicitWidth + 16 : 0
          height: 24
          radius: 0
          color: langBtnMouse.containsMouse ? Qt.alpha(root.accent, 0.18) : "transparent"
          border.color: Qt.alpha(root.accent, 0.5)
          border.width: visible ? 1 : 0
          Text {
            id: langBtnLabel
            anchors.centerIn: parent
            text: root.loc.langPrefix + (root.isEn ? "EN" : "CN")
            color: root.accent
            font.family: root.uiFont
            font.pixelSize: 12
          }
          MouseArea {
            id: langBtnMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.langSwitchRequested(root.isEn ? "zh" : "en")
          }
        }

        Rectangle {
          id: refreshBtn
          anchors.right: settingsBtn.left
          anchors.rightMargin: 6
          visible: !root.settingsMode
          anchors.verticalCenter: parent.verticalCenter
          width: refreshLabel.implicitWidth + 16
          height: 24
          radius: 0
          color: refreshMouse.containsMouse ? Qt.alpha(root.accent, 0.18) : "transparent"
          border.color: Qt.alpha(root.accent, 0.5)
          border.width: 1
          Text {
            id: refreshLabel
            anchors.centerIn: parent
            text: root.refreshing ? root.loc.refreshing : root.loc.refresh
            color: root.accent
            font.family: root.uiFont
            font.pixelSize: 12
          }
          MouseArea {
            id: refreshMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.refreshRequested()
          }
        }

        Text {
          anchors.left: titleText.right
          anchors.leftMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          text: root.updated > 0
            ? ("· " + root.articles.length + root.loc.count)
            : root.loc.noCache
          color: root.safeMuted
          font.family: root.uiFont
          font.pixelSize: 12
        }
      }

  // ---- 源状态（设置视图隐藏；可点击 = 按来源过滤，再点取消）----
      Flow {
        width: parent.width
        spacing: 6
        visible: !root.settingsMode && root.sources.length > 0
        Repeater {
          model: [{ name: root.loc.srcAll, ok: true, all: true }].concat(root.sources)
          delegate: Rectangle {
            required property var modelData
            readonly property bool isAll: modelData.all === true
            readonly property bool active: isAll ? root.sourceFilter === ""
                                               : root.sourceFilter === modelData.name
            width: srcTxt.implicitWidth + 12
            height: 20
            radius: 0
            color: active ? Qt.alpha(root.accent, 0.35)
                         : Qt.alpha(modelData.ok ? root.accent : root.urgent, 0.12)
            border.color: active ? root.accent
                                : Qt.alpha(modelData.ok ? root.accent : root.urgent, 0.4)
            border.width: 1
            Text {
              id: srcTxt
              anchors.centerIn: parent
              text: modelData.name + (isAll || modelData.ok ? "" : " ✕")
              color: active ? root.fg : (modelData.ok ? root.fg : root.urgent)
              font.family: root.uiFont
              font.pixelSize: 11
              font.bold: active
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.sourceFilter = active || isAll ? "" : modelData.name
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        visible: !root.settingsMode
        color: Qt.alpha(root.borderColor, 0.4)
      }

      // ---- 设置视图 ----
      // 注意：Loader 失活后 height 仍缓存着上一次加载的高度（实测 460），会把后面的
      // 新闻列表挤到窗口外（flick.y=563 > 窗口高 560）→ 列表“被清空”。
      // Column 不参与布局的前提是 visible=false，所以这里必须同时绑 visible。
      Loader {
        id: settingsLoader
        width: parent.width
        active: root.settingsMode
        visible: root.settingsMode
        height: root.settingsMode ? implicitHeight : 0
        sourceComponent: settingsComponent
      }

      // ---- 新闻列表 ----
      Flickable {
        id: flick
        width: parent.width
        visible: !root.settingsMode
        // T3 修复：有文章时列表高度不得塔缩为 0（热重载/视图切换瞬间 implicitHeight
        // 可能瞬时报 0，导致头部显示 N 条但列表空白），保底 200px。
        height: root.articles.length > 0
          ? Math.max(200, Math.min(root.listMaxHeight, listContent.implicitHeight))
          : Math.min(root.listMaxHeight, listContent.implicitHeight)
        contentHeight: listContent.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // T3 修复：内容变短/视图切回时，contentY 可能残留在越界位置（规口停在最后一项
        // 下方的空白区），看起来“列表空了”。内容高度变化时强制夹回可见区间。
        onContentHeightChanged: {
          var max = Math.max(0, contentHeight - height)
          if (contentY > max) contentY = max
        }
        onVisibleChanged: if (visible) contentY = 0
        // 切语言时列表内容整体换掉（弹窗保持打开，visible 不变，不会触发上面的重置），
        // 显式归零，避免视口停在新列表的旧偏移位置。
        // 注意：Flickable 自身没有 lang 属性，必须监听 root.lang。
        Connections {
          target: root
          function onLangChanged() { flick.contentY = 0 }
        }

        Column {
          id: listContent
          width: parent.width
          spacing: 2

          Text {
            visible: root.visibleArticles.length === 0
            width: parent.width
            text: root.refreshing ? root.loc.loadingList
                 : (root.sourceFilter !== "" ? root.loc.emptyListFiltered : root.loc.emptyList)
            color: root.safeMuted
            font.family: root.uiFont
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            topPadding: 20
            bottomPadding: 20
          }

          Repeater {
            model: root.visibleArticles
            delegate: Rectangle {
              required property var modelData
              width: listContent.width
              height: delegateCol.implicitHeight + 12
              color: rowMouse.containsMouse ? Qt.alpha(root.accent, 0.10) : "transparent"

              Column {
                id: delegateCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 6
                spacing: 2

                Row {
                  width: parent.width
                  spacing: 6
                  Rectangle {
                    visible: !modelData.read
                    width: 6; height: 6; radius: 3
                    color: root.accent
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    width: parent.width - (modelData.read ? 0 : 12)
                    text: modelData.title
                    color: modelData.read ? root.safeMuted : root.fg
                    font.family: root.uiFont
                    font.pixelSize: 13
                    font.bold: !modelData.read
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }
                }

                Row {
                  width: parent.width
                  spacing: 8
                  Text {
                    text: modelData.source
                    color: root.accent
                    font.family: root.uiFont
                    font.pixelSize: 11
                  }
                  Text {
                    text: modelData.age
                    color: root.safeMuted
                    font.family: root.uiFont
                    font.pixelSize: 11
                  }
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.openRequested(modelData.url)
                  root.markReadRequested(modelData.id)
                }
              }
            }
          }
        }
      }

    } // contentCol
  } // card

  // ---- 设置视图组件 ----
  // 同一弹窗内切换内容（不新开窗口）。所有写操作走 Widget 的 python 子命令。
  Component {
    id: settingsComponent

      Flickable {
        id: sFlick
        width: settingsLoader.width
        height: Math.min(460, sCol.implicitHeight)
        // Loader 用 implicitHeight 参与 Column 布局，而 Flickable 默认 implicitHeight=0，
        // 不显式绑会导致窗口高度塔缩（settings 时 winH=160）。
        implicitHeight: Math.min(460, sCol.implicitHeight)
        contentHeight: sCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: sCol
          width: sFlick.width
          spacing: 10

          // ---------- 默认语言（已移到弹窗头部按钮，此处隐藏）----------
          Column {
            width: parent.width
            spacing: 4
            visible: false
            Text {
              text: root.loc.sLang
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
              font.bold: true
            }
            ButtonGroup {
              options: [{ value: "zh", label: "中文" }, { value: "en", label: "English" }]
              value: root.lang
              fontFamily: root.uiFont
              fontSize: 12
              foreground: root.fg
              background: root.bg
              accent: root.accent
              onChanged: function (v) {
                if (v !== root.lang) {
                  root.langSwitchRequested(v)
                  // 语言切换后源列表要跟着换（否则设置里仍显示旧语言的源）
                  root.feedsListRequested(v)
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg; visible: false }

          // ---------- 自动刷新间隔 ----------
          Row {
            width: parent.width
            spacing: 10
            NumberField {
              id: refreshField
              label: root.loc.sRefresh
              value: Math.max(60, Math.round(Number(root.cfgGet("refreshIntervalSec", 1800))) || 1800)
              from: 60
              to: 86400
              stepSize: 60
              fieldWidth: 130
              fontFamily: root.uiFont
              fontSize: 12
              foreground: root.fg
              accent: root.accent
              anchors.verticalCenter: parent.verticalCenter
              onModified: function (v) { root.sendConfig({ refreshIntervalSec: Math.max(60, v) }) }
            }
            Text {
              text: root.loc.sRefreshHint
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- 新闻源 ----------
          Column {
            width: parent.width
            spacing: 4
            Text {
              text: root.loc.sFeeds + " · " + (root.lang === "en" ? "EN" : "CN")
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
              font.bold: true
            }

            Repeater {
              model: root.feeds
              delegate: Rectangle {
                required property var modelData
                // 多一行失败状态时把行高撑开，避免第三行文字溢出
                readonly property bool feedBad: !!(modelData && modelData.enabled) && root.feedStatus(modelData.url).bad
                width: sCol.width
                height: feedBad ? 46 : 34
                color: Qt.alpha(root.borderColor, 0.18)
                border.color: Qt.alpha(root.borderColor, 0.35)
                border.width: 1

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: 6
                  anchors.rightMargin: 4
                  spacing: 6

                  ToggleSwitch {
                    id: feedSwitch
                    anchors.verticalCenter: parent.verticalCenter
                    checked: !!(modelData && modelData.enabled)
                    foreground: root.fg
                    accent: root.accent
                    onToggled: { console.warn("[NW] feed toggle id=" + modelData.id + " -> " + (!checked)); root.toggleFeed(modelData.id, !checked) }
                  }

                  Column {
                    width: parent.width - feedSwitch.width - delBtn.width - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text {
                      width: parent.width
                      text: modelData ? modelData.name : ""
                      color: (modelData && modelData.enabled) ? root.fg : root.safeMuted
                      font.family: root.uiFont
                      font.pixelSize: 11
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      text: modelData ? modelData.url : ""
                      color: root.safeMuted
                      font.family: root.uiFont
                      font.pixelSize: 9
                      elide: Text.ElideMiddle
                    }
                    // 已启用但拿不到内容 → 红色状态小字（未启用不报，避免误报）
                    Text {
                      visible: feedBad
                      width: parent.width
                      text: root.feedStatus(modelData.url).text
                      color: root.urgent
                      font.family: root.uiFont
                      font.pixelSize: 9
                      elide: Text.ElideRight
                    }
                  }

                  Rectangle {
                    id: delBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22
                    height: 22
                    radius: 0
                    color: delMouse.containsMouse ? Qt.alpha(root.urgent, 0.2) : "transparent"
                    border.color: Qt.alpha(root.urgent, 0.45)
                    border.width: 1
                    Text {
                      anchors.centerIn: parent
                      text: "✕"
                      color: root.urgent
                      font.pixelSize: 10
                    }
                    MouseArea {
                      id: delMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeFeed(modelData.id)
                    }
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: 6
              TextField {
                id: addNameField
                width: 96
                placeholderText: root.loc.sNamePh
                font.family: root.uiFont
                font.pixelSize: 11
                foreground: root.fg
                accent: root.accent
                verticalPadding: 4
                anchors.verticalCenter: parent.verticalCenter
              }
              TextField {
                id: addUrlField
                width: parent.width - addNameField.width - addBtn.implicitWidth - parent.spacing * 2
                placeholderText: root.loc.sUrlPh
                font.family: root.uiFont
                font.pixelSize: 11
                foreground: root.fg
                accent: root.accent
                verticalPadding: 4
                anchors.verticalCenter: parent.verticalCenter
                onAccepted: root.addFeed(addNameField.text, addUrlField.text)
              }
              Rectangle {
                id: addBtn
                anchors.verticalCenter: parent.verticalCenter
                width: addBtnLabel.implicitWidth + 14
                height: 26
                radius: 0
                color: addBtnMouse.containsMouse ? Qt.alpha(root.accent, 0.2) : Qt.alpha(root.accent, 0.08)
                border.color: Qt.alpha(root.accent, 0.5)
                border.width: 1
                Text {
                  id: addBtnLabel
                  anchors.centerIn: parent
                  text: root.loc.sAdd
                  color: root.accent
                  font.family: root.uiFont
                  font.pixelSize: 11
                }
                MouseArea {
                  id: addBtnMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addFeed(addNameField.text, addUrlField.text)
                }
              }
            }

            Text {
              visible: root.feedsStatus.length > 0
              width: parent.width
              text: root.feedsStatus
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
              wrapMode: Text.Wrap
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- 翻译引擎 ----------
          Column {
            width: parent.width
            spacing: 6
            Text {
              text: root.loc.sTranslate
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: 8
              ToggleSwitch {
                id: trSwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: !!root.cfgTranslate("enabled", false)
                foreground: root.fg
                accent: root.accent
                onHovered: function(h) { console.warn("[NW] trSwitch hover=" + h) }
                onToggled: { console.warn("[NW] translate toggle -> " + (!checked)); root.sendConfig({ translate: { enabled: !checked } }) }
              }
              Text {
                width: parent.width - trSwitch.width - parent.spacing
                text: root.loc.sTrOn
                color: root.fg
                font.family: root.uiFont
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              text: root.loc.sTrTarget
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
            }
            SearchableDropdown {
              id: trTargetDropdown
              label: ""
              showLabel: false
              placeholderText: root.isEn ? "Search language…" : "搜索语言…"
              emptyText: root.isEn ? "No matches" : "无匹配"
              options: [
                { value: "zh", label: "简体中文 (zh)" },
                { value: "en", label: "English (en)" },
                { value: "ja", label: "日本語 (ja)" },
                { value: "ko", label: "한국어 (ko)" },
                { value: "fr", label: "Français (fr)" },
                { value: "de", label: "Deutsch (de)" },
                { value: "es", label: "Español (es)" },
                { value: "ru", label: "Русский (ru)" },
                { value: "pt", label: "Português (pt)" },
                { value: "it", label: "Italiano (it)" },
                { value: "ar", label: "‪العربية (ar)" },
                { value: "vi", label: "Tiếng Việt (vi)" },
                { value: "th", label: "ไทย (th)" },
                { value: "id", label: "Bahasa Indonesia (id)" },
                { value: "hi", label: "हिन्दी (hi)" },
                { value: "tr", label: "Türkçe (tr)" },
                { value: "nl", label: "Nederlands (nl)" },
                { value: "pl", label: "Polski (pl)" },
                { value: "uk", label: "Українська (uk)" },
                { value: "ms", label: "Bahasa Melayu (ms)" }
              ]
              value: String(root.cfgTranslate("targetLang", "zh"))
              fontFamily: root.uiFont
              foreground: root.fg
              background: root.bg
              accent: root.accent
              onChanged: function (v) {
                if (String(v) !== String(root.cfgTranslate("targetLang", "zh"))) {
                  root.sendConfig({ translate: { targetLang: String(v) } })
                }
              }
            }

            Text {
              text: root.loc.sTrBaseUrl
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
            }
            TextField {
              id: trBaseUrlField
              width: parent.width
              text: String(root.cfgTranslate("baseUrl", ""))
              placeholderText: "http://192.168.8.89:8731/v1"
              font.family: root.uiFont
              font.pixelSize: 11
              foreground: root.fg
              accent: root.accent
              verticalPadding: 4
              onAccepted: root.sendConfig({ translate: { baseUrl: text } })
              onEditingFinished: root.sendConfig({ translate: { baseUrl: text } })
            }

            Text {
              text: root.loc.sTrApiKey
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
            }
            TextField {
              id: trApiKeyField
              width: parent.width
              text: String(root.cfgTranslate("apiKey", ""))
              password: true
              font.family: root.uiFont
              font.pixelSize: 11
              foreground: root.fg
              accent: root.accent
              verticalPadding: 4
              onAccepted: root.sendConfig({ translate: { apiKey: text } })
              onEditingFinished: root.sendConfig({ translate: { apiKey: text } })
            }

            Text {
              text: root.loc.sTrModel
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
            }
            TextField {
              id: trModelField
              width: parent.width - trTestBtn.width - 6
              text: String(root.cfgTranslate("model", ""))
              font.family: root.uiFont
              font.pixelSize: 11
              foreground: root.fg
              accent: root.accent
              verticalPadding: 4
              onAccepted: root.sendConfig({ translate: { model: text } })
              onEditingFinished: root.sendConfig({ translate: { model: text } })
            }

            Row {
              width: parent.width
              spacing: 8
              Rectangle {
                id: trTestBtn
                width: trTestLabel.implicitWidth + 14
                height: 26
                radius: 0
                color: trTestMouse.containsMouse ? Qt.alpha(root.accent, 0.2) : Qt.alpha(root.accent, 0.08)
                border.color: Qt.alpha(root.accent, 0.5)
                border.width: 1
                Text {
                  id: trTestLabel
                  anchors.centerIn: parent
                  text: root.loc.sTest
                  color: root.accent
                  font.family: root.uiFont
                  font.pixelSize: 11
                }
                MouseArea {
                  id: trTestMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.runTranslateTest(trBaseUrlField.text, trApiKeyField.text, trModelField.text, String(trTargetGroup.value))
                }
              }
              Text {
                width: parent.width - trTestBtn.width - parent.spacing
                text: root.translateStatus
                color: root.safeMuted
                font.family: root.uiFont
                font.pixelSize: 10
                wrapMode: Text.Wrap
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- 其它 ----------
          Column {
            width: parent.width
            spacing: 2
            Text {
              text: root.loc.sMisc
              color: root.safeMuted
              font.family: root.uiFont
              font.pixelSize: 10
              font.bold: true
            }

            Repeater {
              model: [
                { key: "paused", label: root.loc.sPaused },
                { key: "alwaysScroll", label: root.loc.sAlwaysScroll },
                { key: "pauseOnHover", label: root.loc.sPauseOnHover },
                { key: "showSource", label: root.loc.sShowSource },
                { key: "showAge", label: root.loc.sShowAge }
              ]
              delegate: Row {
                required property var modelData
                width: sCol.width
                height: 26
                spacing: 8
                ToggleSwitch {
                  id: miscSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: !!root.cfgGet(modelData.key, false)
                  foreground: root.fg
                  accent: root.accent
                  onToggled: { console.warn("[NW] misc toggle " + modelData.key + " -> " + (!checked)); var o = {}; o[modelData.key] = !checked; root.sendConfig(o) }
                }
                Text {
                  text: modelData.label
                  color: root.fg
                  font.family: root.uiFont
                  font.pixelSize: 11
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Row {
              width: parent.width
              spacing: 8
              Text {
                text: root.loc.sFontSize
                color: root.fg
                font.family: root.uiFont
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
              }
              PanelSlider {
                id: fontSlider
                width: parent.width - fontValText.width - parent.spacing * 2 - 8
                minimum: 9
                maximum: 20
                step: 1
                integer: true
                value: Math.max(9, Math.min(20, Math.round(Number(root.cfgGet("textPixelSize", 13))) || 13))
                anchors.verticalCenter: parent.verticalCenter
                onReleased: function (v) { root.sendConfig({ textPixelSize: Math.round(v) }) }
                onMoved: function (v) { fontValText.text = String(Math.round(v)) }
              }
              Text {
                id: fontValText
                text: String(Math.max(9, Math.min(20, Math.round(Number(root.cfgGet("textPixelSize", 13))) || 13)))
                color: root.safeMuted
                font.family: root.uiFont
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              width: parent.width
              spacing: 8
              Text {
                text: root.loc.sTickerWidth
                color: root.fg
                font.family: root.uiFont
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
              }
              PanelSlider {
                id: tickerWSlider
                width: parent.width - tickerWValText.width - parent.spacing * 2 - 8
                minimum: 160
                maximum: 1200
                step: 20
                integer: true
                value: Math.max(160, Math.min(1200, Math.round(Number(root.cfgGet("tickerMaxWidth", 520))) || 520))
                anchors.verticalCenter: parent.verticalCenter
                onReleased: function (v) { root.sendConfig({ tickerMaxWidth: Math.round(v) }) }
                onMoved: function (v) { tickerWValText.text = String(Math.round(v)) + "px" }
              }
              Text {
                id: tickerWValText
                text: String(Math.max(160, Math.min(1200, Math.round(Number(root.cfgGet("tickerMaxWidth", 520))) || 520))) + "px"
                color: root.safeMuted
                font.family: root.uiFont
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }
    }
  }
