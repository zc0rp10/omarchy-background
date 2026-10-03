import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import QtQuick

// One cava process shared by every screen. Folds the 48 cava bars into four
// broad bands (bass, low-mid, mid, treble), smooths them heavily so the waves
// swell rather than twitch, and advances each wave's phase at a speed that
// rises with loudness. Emits nothing and stops its frame loop when silent.
Item {
  id: spectrum

  readonly property string configPath: decodeURIComponent(String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, ""))
  // cava bar ranges per band (48 log-spaced bars, 40 Hz - 12 kHz)
  readonly property var bandRanges: [[0, 8], [8, 18], [18, 32], [32, 48]]
  readonly property var phaseSpeed: [0.35, -0.5, 0.8, -1.1]   // rad/s at rest
  readonly property real tau: 2 * Math.PI

  // Look, shared by every screen. Amplitudes are fractions of the screen height.
  // Four big sine lobes, bass longest/largest .. treble shortest/smallest; each
  // band's loudness swells its lobe on top of a resting amplitude.
  readonly property vector4d restAmp: Qt.vector4d(0.12, 0.07, 0.04, 0.02)
  readonly property vector4d gainAmp: Qt.vector4d(0.14, 0.10, 0.06, 0.035)
  readonly property vector4d freq: Qt.vector4d(tau * 2.3, tau * 3.4, tau * 4.7, tau * 6.5)
  readonly property vector4d spread: Qt.vector4d(2.9, 2.0, 3.2, 3.6)
  readonly property vector4d fan: Qt.vector4d(0.55, 0.3, 0.5, 0.2)
  readonly property int strands: 22
  readonly property real lineWidth: 1.1
  readonly property real centerScale: 1.25   // waves swell in the middle ...
  readonly property real edgeScale: 0.6      // ... and calm down towards the edges

  // Reaction: the whole ribbon speeds up and slows down together, smoothly.
  // Target speed multiplier = restSpeed + loudSpeed*loudness + driveSpeed*drive,
  // eased over speedEase s. Drive tracks build-ups: the sound changing faster
  // than the track's own recent norm (rolls, risers, denser hats), so it still
  // works after cava's autosens has levelled the volume.
  readonly property real restSpeed: 0.4
  readonly property real loudSpeed: 1.2
  readonly property real driveSpeed: 1.6
  readonly property real speedEase: 0.5     // s

  property var targets: [0, 0, 0, 0]
  property real b0: 0
  property real b1: 0
  property real b2: 0
  property real b3: 0
  // Assigned once per frame in step(): a binding over b0..b3 would fire four
  // change signals (and four amp recomputes per screen) every frame.
  property vector4d bands: Qt.vector4d(0, 0, 0, 0)
  property vector4d phase: Qt.vector4d(0, 1.3, 2.1, 0.7)
  property real energy: 0

  // Change tracking (fed per cava frame, consumed per display frame).
  property var prevTargets: [0, 0, 0, 0]
  property real fluxPending: 0     // summed spectral change since the last display frame
  property real fluxShort: 0       // spectral change rate, ~0.4 s window
  property real fluxLong: 0        // spectral change rate, ~8 s window (the track's norm)
  property real drive: 0
  property real speed: restSpeed
  // Off entirely on the power-saver profile (on battery): cava is stopped and
  // the waves fade out, leaving the normal wallpaper.
  readonly property bool allowed: PowerProfiles.profile !== PowerProfile.PowerSaver
  // Set by Background.qml: false while every screen is covered by windows, so
  // nobody can see the waves. cava and the frame loop pause until one shows.
  property bool wanted: true
  // Only music drives the waves: a Spotify client (the official app,
  // spotify_player or ncspot) must be playing. Videos, calls and the rest of
  // the desktop's sound leave the plain wallpaper.
  readonly property var musicPlayerPattern: /spotify|ncspot/i
  readonly property bool musicPlaying: (Mpris.players ? Mpris.players.values : []).some(function(p) {
    return p.isPlaying && spectrum.musicPlayerPattern.test((p.dbusName || "") + " " + (p.identity || "") + " " + (p.desktopEntry || ""))
  })
  // Lags musicPlaying going off by a few seconds, so a track change or a short
  // pause doesn't restart cava; the waves still fade as the sound stops.
  property bool musicLive: false
  readonly property bool active: allowed && wanted && musicLive
  // Stays true through short quiet passages so the waves don't flicker out.
  readonly property bool hasSignal: holdTimer.running

  function ingest(line) {
    var parts = String(line).split(";")
    var next = []
    var sum = 0
    for (var b = 0; b < 4; b++) {
      var r = bandRanges[b], acc = 0
      for (var i = r[0]; i < r[1]; i++) acc += Math.min(1000, parseInt(parts[i]) || 0)
      var v = acc / ((r[1] - r[0]) * 1000)
      next.push(v)
      sum += v
    }
    // Spectral flux: how much each band rose since the previous cava frame.
    var f0 = Math.max(0, next[0] - prevTargets[0])
    var f1 = Math.max(0, next[1] - prevTargets[1])
    var f2 = Math.max(0, next[2] - prevTargets[2])
    var f3 = Math.max(0, next[3] - prevTargets[3])
    prevTargets = next
    // Build-ups show up as more change in the mids/highs (rolls, risers, hats).
    // Only collect change while frames consume it; otherwise noise piles up
    // and bursts into drive (and inflates fluxLong) when frames resume.
    if (frameLoop.running) fluxPending += f0 * 0.5 + f1 + f2 * 1.2 + f3 * 1.5
    else fluxPending = 0

    targets = next
    if (sum > 0.002) holdTimer.restart()
  }

  function follow(cur, tgt, dt) {
    // ~0.12 s attack, ~0.8 s release (frame-rate independent)
    var tau = tgt > cur ? 0.12 : 0.8
    return cur + (tgt - cur) * (1 - Math.exp(-dt / tau))
  }

  function ease(cur, tgt, dt, tau) {
    return cur + (tgt - cur) * (1 - Math.exp(-dt / tau))
  }

  function step(dt) {
    b0 = follow(b0, targets[0], dt)
    b1 = follow(b1, targets[1], dt)
    b2 = follow(b2, targets[2], dt)
    b3 = follow(b3, targets[3], dt)
    bands = Qt.vector4d(b0, b1, b2, b3)
    var loud = Math.min(1, (b0 + b1 + b2 + b3) * 0.75)
    var fade = hasSignal ? 0.25 : 0.6
    energy += ((hasSignal ? 1 : 0) - energy) * (1 - Math.exp(-dt / fade))
    if (!hasSignal && energy < 0.003) energy = 0

    // Drive: recent change rate relative to the track's norm, 0 at normal,
    // 1 at ~3x normal. Rises in ~0.3 s, falls in ~1.5 s.
    var rate = dt > 0 ? fluxPending / dt : 0
    fluxPending = 0
    fluxShort = ease(fluxShort, rate, dt, 0.4)
    fluxLong = ease(fluxLong, rate, dt, 8.0)
    var rawDrive = Math.max(0, Math.min(1, (fluxShort / (fluxLong + 0.05) - 1) / 2))
    drive = ease(drive, rawDrive, dt, rawDrive > drive ? 0.3 : 1.5)
    if (!hasSignal) drive = 0

    speed = ease(speed, restSpeed + loudSpeed * loud + driveSpeed * drive, dt, speedEase)
    phase = Qt.vector4d((phase.x + phaseSpeed[0] * speed * dt) % tau,
                        (phase.y + phaseSpeed[1] * speed * dt) % tau,
                        (phase.z + phaseSpeed[2] * speed * dt) % tau,
                        (phase.w + phaseSpeed[3] * speed * dt) % tau)

  }

  Timer {
    id: holdTimer
    interval: 1500
  }

  // Driven by the display's frame clock for smooth, vsync-aligned motion.
  FrameAnimation {
    id: frameLoop
    running: (spectrum.hasSignal || spectrum.energy > 0) && spectrum.wanted
    onTriggered: spectrum.step(Math.min(frameTime, 0.1))
  }

  // cava is started and stopped imperatively in both directions. (A binding
  // on `running` would be dropped by the first imperative restart, after which
  // power-saver would no longer stop it.)
  Process {
    id: cava
    command: ["cava", "-p", spectrum.configPath]
    running: false
    stdout: SplitParser {
      onRead: data => spectrum.ingest(data)
    }
    onStarted: startTimer.interval = 10000
    onRunningChanged: if (!running) holdTimer.stop()
  }

  // Starts cava when it becomes active, and restarts it after it exits
  // (PipeWire restart, resume). Backs off to 5 min if it keeps failing, for
  // example when cava isn't installed.
  Timer {
    id: startTimer
    interval: 10000
    repeat: true
    triggeredOnStart: true
    running: spectrum.active && !cava.running
    onTriggered: {
      cava.running = true
      interval = Math.min(interval * 2, 300000)
    }
  }

  Connections {
    target: spectrum
    // Resuming with the waves still up (paused behind windows): bridge the gap
    // until cava's first frames, or they would fade out and straight back in.
    function onActiveChanged() {
      if (!spectrum.active) cava.running = false
      else if (spectrum.energy > 0) holdTimer.restart()
    }
    function onMusicPlayingChanged() {
      if (spectrum.musicPlaying) {
        musicOffTimer.stop()
        spectrum.musicLive = true
      } else {
        musicOffTimer.restart()
      }
    }
  }

  Timer {
    id: musicOffTimer
    interval: 5000
    onTriggered: spectrum.musicLive = false
  }

  Component.onCompleted: musicLive = musicPlaying
}

