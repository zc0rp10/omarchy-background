import QtQuick
import QtQuick.Window

// The music-driven wave ribbon: thin GPU-drawn lines, one per strand (see
// waves.vert / waves.frag), drawn straight over the window's ground colour.
Item {
  id: view

  required property var spectrum
  property color colorStart: "#f5c2e7"
  property color colorEnd: "#89b4fa"
  // Amplitudes are fractions of the screen height.
  property real screenHeight: height
  // false while windows cover this screen: nothing below changes any more,
  // so Qt stops re-rendering this screen and it keeps its last frame.
  property bool live: true

  property int segments: 512        // line segments per strand across the screen

  property vector4d bands: spectrum.bands
  property vector4d phase: spectrum.phase
  readonly property vector4d amp: Qt.vector4d(
    screenHeight * (spectrum.restAmp.x + spectrum.gainAmp.x * bands.x),
    screenHeight * (spectrum.restAmp.y + spectrum.gainAmp.y * bands.y),
    screenHeight * (spectrum.restAmp.z + spectrum.gainAmp.z * bands.z),
    screenHeight * (spectrum.restAmp.w + spectrum.gainAmp.w * bands.w))

  opacity: Math.min(1, spectrum.energy * 1.2)
  visible: opacity > 0.01

  // Plain values instead of bindings, so updates can be paused while covered.
  Component.onCompleted: { bands = spectrum.bands; phase = spectrum.phase }
  onLiveChanged: if (live) { bands = spectrum.bands; phase = spectrum.phase }

  Connections {
    target: view.spectrum
    enabled: view.live
    function onBandsChanged() { view.bands = view.spectrum.bands }
    function onPhaseChanged() { view.phase = view.spectrum.phase }
  }

  // Every strand in one mesh: one draw and one uniform update per frame.
  ShaderEffect {
    anchors.fill: parent
    mesh: GridMesh { resolution: Qt.size(view.segments, view.spectrum.strands * 4 - 1) }
    blending: true

    property vector2d size: Qt.vector2d(width, height)
    property vector4d amp: view.amp
    property vector4d freq: view.spectrum.freq
    property vector4d phase: view.phase
    property vector4d spread: view.spectrum.spread
    property vector4d fan: view.spectrum.fan
    property color colorStart: view.colorStart
    property color colorEnd: view.colorEnd
    property real strands: view.spectrum.strands
    property real lineWidth: view.spectrum.lineWidth
    property real centerY: 0.5
    property real centerScale: view.spectrum.centerScale
    property real edgeScale: view.spectrum.edgeScale
    property real pixel: 1 / Screen.devicePixelRatio

    vertexShader: Qt.resolvedUrl("waves.vert.qsb")
    fragmentShader: Qt.resolvedUrl("waves.frag.qsb")
  }
}
