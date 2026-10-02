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

  function loadWaveColors(raw) {
    waveStart = themeColor(raw, "magenta", themeColor(raw, "color5", waveStart))
    waveEnd = themeColor(raw, "accent", themeColor(raw, "blue", themeColor(raw, "color4", waveEnd)))
  }

  FileView {
    id: themeColorsFile
    path: root.themeColorsPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.loadWaveColors(text())
  }

  AudioSpectrum {
    id: audioSpectrum
  }

  // Waves fully faded in: they are opaque, so the wallpaper images below are skipped.
  readonly property bool wavesCover: audioSpectrum.energy * 1.2 >= 1

  // Window floating state comes from Hyprland's client list; refresh it when
  // windows come, go, move or change floating mode.
  readonly property var toplevelEvents: ["openwindow", "closewindow", "movewindow", "movewindowv2", "changefloatingmode", "fullscreen"]

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.toplevelEvents.indexOf(event.name) >= 0) Hyprland.refreshToplevels()
    }
  }

  // Plain fill in the wallpaper's own ground colour; covers the wallpaper's
  // artwork while the live waves play so the two don't stack.
  property color wallpaperGround: Color.background

  Process {
    id: groundProc
    command: ["magick", root.currentBackground + "[0]", "-format", "%[hex:p{8,8}]", "info:"]
    stdout: StdioCollector {
      onStreamFinished: {
        var hex = String(text || "").trim()
        if (/^[0-9A-Fa-f]{6}/.test(hex)) root.wallpaperGround = "#" + hex.substring(0, 6)
      }
    }
  }

  // A theme switch replaces the theme folder, which can drop the file watch.
  onCurrentBackgroundChanged: {
    themeColorsFile.reload()
    if (currentBackground) groundProc.running = true
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
      // animate. Terminals and TUIs (Omarchy tags them "terminal") are
      // see-through, so the waves keep running behind them, as they do behind
      // floating windows.
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool desktopCovered: {
        var ws = hyprMonitor ? hyprMonitor.activeWorkspace : null
        if (!ws) return false
        var windows = ws.toplevels.values
        for (var i = 0; i < windows.length; i++) {
          var ipc = windows[i].lastIpcObject
          if (!ipc || !ipc.class) return true   // not refreshed yet: assume opaque
          if (ipc.floating) continue
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
