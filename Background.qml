import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Ui

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    // Wave colours too: the wallpaper path can stay the same across a switch
    // (many themes ship "omarchy.png"), so its change handler isn't enough.
    if (pendingColorsRaw) loadWaveColors(pendingColorsRaw)
    // Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: {
    refreshBackground()
    Hyprland.refreshToplevels()
  }

  // --- Music visualizer (bjfa) ---
  readonly property string themeColorsPath: stateHome + "/omarchy/current/theme/colors.toml"
  property color waveStart: "#f5c2e7"
  property color waveEnd: "#89b4fa"

  function themeColor(raw, key, fallback) {
    var m = String(raw).match(new RegExp("^\\s*" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m"))
    return m ? m[1] : fallback
  }

  // Colour helpers for picking the wave gradient (channels 0..1).
  function rgbOf(hex) {
    return [parseInt(hex.substr(1, 2), 16) / 255, parseInt(hex.substr(3, 2), 16) / 255, parseInt(hex.substr(5, 2), 16) / 255]
  }
  function chromaOf(hex) { var c = rgbOf(hex); return Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]) }
  function hueOf(hex) {
    var c = rgbOf(hex), mx = Math.max(c[0], c[1], c[2]), d = mx - Math.min(c[0], c[1], c[2])
    if (d === 0) return 0
    var h = mx === c[0] ? (c[1] - c[2]) / d : mx === c[1] ? 2 + (c[2] - c[0]) / d : 4 + (c[0] - c[1]) / d
    return ((h * 60) + 360) % 360
  }
  function hueDist(a, b) { var d = Math.abs(hueOf(a) - hueOf(b)); return Math.min(d, 360 - d) }
  function colourDist(a, b) {
    var x = rgbOf(a), y = rgbOf(b)
    return Math.sqrt(Math.pow(x[0] - y[0], 2) + Math.pow(x[1] - y[1], 2) + Math.pow(x[2] - y[2], 2))
  }
  function luminance(hex) {
    var c = rgbOf(hex).map(function(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) })
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
  }
  function contrastOf(a, b) {
    var la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  // Wave gradient: the theme's magenta -> accent, which suits nearly every
  // theme. Only when that pair is grey or (nearly) the same colour, as in
  // solitude and lumon, use the theme's most colourful palette colour into a
  // second one of a different hue (or, failing that, its brightest colour).
  // Tested against all installed themes: only solitude, lumon, vantablack and
  // white change, and the last two stay greyscale.
  function loadWaveColors(raw) {
    // Missing keys fall back to fixed defaults, never to the previous theme's.
    var m = themeColor(raw, "magenta", themeColor(raw, "color5", "#f5c2e7"))
    var a = themeColor(raw, "accent", themeColor(raw, "blue", themeColor(raw, "color4", "#89b4fa")))
    var flat = (chromaOf(m) < 0.12 && chromaOf(a) < 0.12) || colourDist(m, a) < 0.12
    if (flat) {
      var bg = themeColor(raw, "background", "#000000")
      var keys = ["red", "yellow", "green", "cyan", "blue", "magenta", "accent", "bright_red", "bright_yellow",
                  "bright_green", "bright_cyan", "bright_blue", "bright_magenta"]
      var cands = []
      for (var i = 0; i < keys.length; i++) {
        var v = themeColor(raw, keys[i], "")
        if (v !== "" && cands.indexOf(v.toLowerCase()) < 0 && contrastOf(v, bg) >= 2.2) cands.push(v.toLowerCase())
      }
      if (cands.length > 0) {
        cands.sort(function(x, y) { return chromaOf(y) - chromaOf(x) })
        var first = cands[0], second = ""
        for (var j = 1; j < cands.length && second === ""; j++)
          if (hueDist(first, cands[j]) >= 40 && chromaOf(cands[j]) >= 0.12) second = cands[j]
        if (second === "") {
          var rest = cands.length > 1 ? cands.slice(1) : [themeColor(raw, "foreground", first)]
          second = rest[0]
          for (var k = 1; k < rest.length; k++) if (luminance(rest[k]) > luminance(second)) second = rest[k]
        }
        m = first
        a = second
      }
    }
    waveStart = m
    waveEnd = a
  }

  FileView {
    id: themeColorsFile
    path: root.themeColorsPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.loadWaveColors(text())
  }

  // Non-terminal windows the waves keep running behind, like terminals: they
  // share the terminals' translucent default opacity and a dark ground.
  readonly property var seeThroughClasses: ["dev.zed.Zed"]

  // Screens whose desktop is visible (not covered by a tiled non-terminal
  // window). With none, nobody can see the waves: cava and the frame loop stop.
  property var liveScreens: ({})
  readonly property bool anyScreenLive: Object.keys(liveScreens).some(function(k) { return liveScreens[k] })

  function setScreenLive(name, live) {
    var next = Object.assign({}, liveScreens)
    if (live === undefined) delete next[name]
    else next[name] = live
    liveScreens = next
  }

  AudioSpectrum {
    id: audioSpectrum
    wanted: root.anyScreenLive
  }

  // Waves fully faded in: they are opaque, so the wallpaper images below are skipped.
  readonly property bool wavesCover: audioSpectrum.energy * 1.2 >= 1

  // Window floating state comes from Hyprland's client list; refresh it when
  // windows come, go, move or change floating mode. (Hyprland sends both
  // movewindow and movewindowv2 for one move; listen to one.)
  readonly property var toplevelEvents: ["openwindow", "closewindow", "movewindowv2", "changefloatingmode", "fullscreen"]

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.toplevelEvents.indexOf(event.name) >= 0) Hyprland.refreshToplevels()
    }
  }

  // Plain fill in the wallpaper's own ground colour; covers the wallpaper's
  // artwork while the live waves play so the two don't stack.
  property color wallpaperGround: Color.background

  // The ground is the wallpaper's dominant colour: shrunk, reduced to 6
  // colours, most common one wins. Stable for flat-ground art and photos
  // alike, unlike a single corner pixel (which the crop may even hide).
  Process {
    id: groundProc
    property bool pending: false
    // First output line is the sampled path, so a result that arrives after
    // the wallpaper changed again is recognised as stale and ignored.
    command: ["bash", "-c", "printf '%s\\n' \"$1\"; magick \"$1[0]\" -scale 64x64! -colors 6 -depth 8 -format %c histogram:info:-",
              "sample-ground", root.currentBackground]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        if (lines[0] !== root.currentBackground) return
        var best = 0, hex = ""
        for (var i = 1; i < lines.length; i++) {
          var m = lines[i].match(/^\s*(\d+):.*(#[0-9A-Fa-f]{6})/)
          if (m && parseInt(m[1]) > best) { best = parseInt(m[1]); hex = m[2] }
        }
        root.wallpaperGround = hex !== "" ? hex : Color.background
      }
    }
    onExited: if (pending) { pending = false; running = true }
  }

  function sampleGround() {
    if (!currentBackground) return
    if (groundProc.running) groundProc.pending = true
    else groundProc.running = true
  }

  // A theme switch replaces the theme folder, which can drop the file watch.
  onCurrentBackgroundChanged: {
    themeColorsFile.reload()
    sampleGround()
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      // The wallpaper's ground colour as the window colour. The window is then
      // created without an alpha channel: while the waves play, Qt's per-frame
      // clear already paints the ground (no full-screen fill on top of it) and
      // the compositor knows the surface is opaque.
      color: root.wallpaperGround
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. The wallpaper
      // itself is static, so this favors correctness over a small render-loop
      // optimization.
      updatesEnabled: true

      property bool maskReady: false

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Image {
        id: base
        anchors.fill: parent
        visible: !root.wavesCover
        source: root.imageUrl(root.displayedBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          if (status === Image.Ready && root.finishingTransition) {
            root.incomingBackground = ""
            root.oldBackground = ""
            root.finishingTransition = false
          }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1 && !root.wavesCover
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady) && !root.wavesCover
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      // True when a tiled (or fullscreen) non-terminal window sits on this
      // screen's workspace, so the desktop is hidden and the waves need not
      // animate. Terminals and TUIs (Omarchy tags them "terminal") and the
      // seeThroughClasses are see-through, so the waves keep running behind
      // them, as they do behind floating windows.
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      onDesktopCoveredChanged: root.setScreenLive(modelData.name, !desktopCovered)
      Component.onCompleted: root.setScreenLive(modelData.name, !desktopCovered)
      Component.onDestruction: root.setScreenLive(modelData.name, undefined)
      readonly property bool desktopCovered: {
        var ws = hyprMonitor ? hyprMonitor.activeWorkspace : null
        if (!ws) return false
        var windows = ws.toplevels.values
        for (var i = 0; i < windows.length; i++) {
          var ipc = windows[i].lastIpcObject
          if (!ipc || !ipc.class) return true   // not refreshed yet: assume opaque
          if (ipc.floating) continue
          if (root.seeThroughClasses.indexOf(ipc.class) >= 0) continue
          var tags = ipc.tags || []
          var terminal = false
          for (var j = 0; j < tags.length; j++)
            if (String(tags[j]).replace(/\*$/, "") === "terminal") terminal = true
          if (!terminal) return true
        }
        return false
      }

      // Ground fill in the wallpaper's own colour, faded in with the waves so
      // the artwork and the strands never stack. Only drawn during the fade:
      // once the waves cover the screen the window's clear colour is the same
      // ground, so this would be a full-screen fill repeated every frame.
      Rectangle {
        anchors.fill: parent
        color: root.wallpaperGround
        opacity: Math.min(1, audioSpectrum.energy * 1.2)
        visible: opacity > 0.01 && !root.wavesCover
      }

      AudioWaves {
        anchors.fill: parent
        spectrum: audioSpectrum
        colorStart: root.waveStart
        colorEnd: root.waveEnd
        live: !panel.desktopCovered
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
