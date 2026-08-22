# Fader

> Volume mixer for Mac. Per-app volume, finally.

A free, open-source macOS menu bar app for **per-app volume control** — turn
down one noisy app without touching anything else, and let calls quiet
everything else automatically. Built in Swift 6 with SwiftUI + CoreAudio
Process Taps.

[**Download**](https://github.com/mianjazibali/fader/releases/latest) ·
[**Website**](https://mianjazibali.github.io/fader) ·
[**Roadmap**](ROADMAP.md) ·
[**Report a bug**](https://github.com/mianjazibali/fader/issues/new/choose)

---

## What it does

- 🎚️ **Per-app volume slider** — every app currently producing audio gets
  its own slider. Drag to turn it up or down; changes apply in ~10 ms via a
  realtime IOProc.
- 🔇 **One-click mute** — tap the speaker icon to silence any one app
  instantly. A muted app stays visible (and stays muted) even after it goes
  quiet, so you never lose track of it or get surprised when it starts
  playing again.
- 📞 **Auto-lower for calls** — the moment a communication app (Zoom,
  Teams, Slack) starts actually talking, every other app automatically
  quiets down by a configurable amount, then comes back once the call ends.
- 🎛️ **Stays in sync with your volume keys** — per-app volume is relative
  to your Mac's system volume, so F11/F12 and Control Center still work
  exactly like they always have — no double-attenuation, no surprises.
- 🪟 **Menu bar only** — `LSUIElement = true`, no Dock icon, no window on
  launch. A single running instance is enforced, so a stray relaunch can
  never spin up a second audio pipeline fighting the first.
- ⚡ **Low overhead** — well under 1% CPU, even while actively mixing
  audio.
- 🎤 **No microphone access, ever** — Fader never touches your mic. You'll
  see macOS's *purple* system-audio recording indicator while it runs
  (expected for any app that adjusts other apps' audio, same as
  SoundSource) — it never triggers the *orange* microphone dot.

---

## Architecture

Three layered phases, each behind the `AudioEngine` protocol so the UI is
unchanged across phases:

```
┌───────────────────────────────────────────────────────────────┐
│ SwiftUI MenuBarExtra panel                                     │
│   Observable AudioState → ControlCenterView → AppRowView, …    │
└───────────────────────────────────────────────────────────────┘
                        ↑↓ any AudioEngine
┌───────────────────────────────────────────────────────────────┐
│ Phase 2: AudioProcessDetector                                  │
│   • kAudioHardwarePropertyProcessObjectList                    │
│   • kAudioProcessPropertyIsRunningOutput + IsRunning listeners  │
│   • 0.2 Hz fallback poll for HAL state-change latency           │
└───────────────────────────────────────────────────────────────┘
                                ↓
┌───────────────────────────────────────────────────────────────┐
│ Phase 3: AudioGainController (per-app real-time gain)          │
│                                                                │
│   ProcessTap (one per app, CATapMutedWhenTapped)               │
│      ↓                                                         │
│   AggregateOutputDevice (private, captures taps)               │
│      IOProc: applies per-app gain, mixes stereo                │
│      ↓                                                         │
│   FloatRingBuffer (lock-free SPSC, 8192 samples)               │
│      ↓                                                         │
│   PlaybackDevice (IOProc on user's default output)             │
│      adds to outputData → speakers                             │
└───────────────────────────────────────────────────────────────┘
```

Tapped apps' direct path to the speakers is silenced (`CATapMutedWhenTapped`)
so we don't get double audio. Non-tapped apps flow through the system mixer
unchanged. Each new tap is primed with its correct gain *before* its IOProc
starts, and gain is computed without re-multiplying by system volume — the
hardware already applies that once, to everything — so a freshly (re)created
tap can't briefly play at the wrong level.

---

## Build & run

Requires **macOS 14.2+**, **Xcode 16+** (or the Command Line Tools),
**Swift 6+**.

```bash
make sign           # build → wrap in .app → ad-hoc sign
open build/Fader.app   # launch as menu bar app
```

For development:

```bash
make debug          # debug build
make run            # build + sign + open
make icon            # regenerate AppIcon.icns from SVG
make dmg             # build a distributable Fader.dmg (Applications symlink included)
```

### Runtime flags

| Flag | Effect |
|---|---|
| (none) | Production: Phase 3 enabled, menu bar only |
| `--no-gain` | Disable Phase 3 (detection only) |
| `--mock` | Fixed 6-app mock fixture instead of live CoreAudio detection |
| `--debug` | Verbose stats to stderr — HAL snapshots, frame counters |
| `--preview` | Mock engine in a floating window (design work) |
| `--preview-live` | Live engine in a floating window (useful when a menu bar manager like Ice hides the real icon) |
| `--test-gain-cycle` | Auto-cycle the first active app through 25% / 100% / mute / 100% / 50% every 3s |

---

## Permissions

- **AppleScript Automation** — for compatible apps (Music, Spotify, TV,
  Podcasts), Fader uses AppleScript to also move the app's own volume
  slider. macOS will prompt "Fader wants to control X" on first contact.
- **System Audio Capture (TCC)** — Process Taps require an explicit grant
  on macOS 14.4+. The privacy string is in `Info.plist`.
- **No microphone permission requested, ever.** Fader will trigger macOS's
  *purple* system-audio/screen-recording indicator while running — that's
  the correct category for Process Taps, not a bug. It will never trigger
  the *orange* microphone indicator.

---

## Project layout

```
fader/
├── Package.swift                    SwiftPM, macOS 14.2+, Swift 6
├── Makefile                         build/sign/bundle/dmg helpers
├── README.md / CLAUDE.md / ROADMAP.md
├── Resources/Icon/                  AppIcon.svg → AppIcon.icns
├── Sources/Fader/
│   ├── App/                         @main (FaderApp: single-instance lock,
│   │                                 engine startup), AppDelegate
│   ├── Models/                      AudioApp, AudioState (@Observable)
│   ├── Audio/                       Detector, Engine (Core/Mock), GainController,
│   │                                ProcessTap, AggregateOutputDevice,
│   │                                PlaybackDevice, RingBuffer, AppleScriptVolume, …
│   ├── Services/PermissionsManager  Accessibility hooks (future hotkeys)
│   ├── UI/                          ControlCenterView, AppRowView,
│   │                                FluidSlider, SettingsView, Brand, …
│   └── Resources/Info.plist / Fader.entitlements
├── docs/                            Landing page (GitHub Pages) — a real
│   │                                interactive demo with generated audio,
│   │                                not just screenshots
│   └── audio/                       CC0 demo audio + CREDITS.md
└── build/Fader.app                  output bundle
```

---

## What's been fixed since the fork

Real bugs, found and fixed on top of the original codebase:

- **Mono/Bluetooth output scrambled audio** — the playback IOProc now
  down/up-mixes the ring buffer's stereo frames to the real device's actual
  channel count instead of copying raw floats 1:1 (was scrambled/muffled on
  mono outputs, e.g. a Bluetooth headset in call mode).
- **App didn't survive output-device changes** — switching
  speakers/headphones/Bluetooth used to leave audio silently undelivered
  until the app restarted. The pipeline now rebuilds itself automatically on
  a default-output-device change.
- **Live call audio going silent** — macOS silently zeroes Process Tap
  content for real call audio (a privacy protection, not a bug). Apps with
  simultaneous mic input + output are now skipped for tap creation instead
  of tapping them into silence.
- **AppKit crash switching to Settings** — `NSHostingController`'s
  `sizingOptions` continuous auto-tracking could fail to converge on a
  content-height change and crash. Fixed by sizing the window once instead
  of continuously.
- **Muted apps disappearing, then coming back muted with no warning** — the
  app list only showed apps *currently* producing audio, so muting one and
  having it go quiet made it vanish; it would resume later still muted with
  no visual cue why it was silent. Muted (or otherwise adjusted) apps now
  stay visible.
- **Apps briefly playing at full volume on resume** — pausing then
  resuming playback rebuilds every tap (not just the one that changed),
  and a freshly created tap defaulted to full gain until the correct volume
  was pushed a beat later. Fixed by priming each tap's gain before its
  realtime thread starts, plus tightening app-state detection latency.
- **Tapped apps were quieter than their own native volume at 100%** —
  system volume was being multiplied in twice: once manually, once again
  by the hardware (which applies it to the final output buffer regardless
  of which client wrote it). A tapped app at 100% could never match — only
  undershoot — its own untapped volume. Fixed by removing the redundant
  multiplication.
- **A second launch could fight the first over the same audio hardware** —
  double-clicking the app, or a stray dev build, while the real instance
  was already running would spin up a second CoreAudioEngine (its own
  Process Taps and aggregate device) on the same taps. Now enforced via a
  non-blocking file lock; a second launch exits immediately.

See [ROADMAP.md](ROADMAP.md) for what's shipped by phase and what's still
open.

---

## Website

The [landing page](https://mianjazibali.github.io/fader) (`docs/`) isn't
just screenshots — the hero panel is a real, working demo: drag the
sliders, mute an app, hit "Simulate joining a call" and hear the other
apps duck live, all running two CC0 audio loops mixed through the Web
Audio API. See `docs/audio/CREDITS.md` for sources.

---

## Honest status

Fader is a **working daily-driver app**, not a proof of concept — the
Phase 3 audio pipeline is real (two IOProcs + a lock-free ring buffer),
verified under stress, and it's what this project's own author runs day to
day. It's distributed as a signed-but-not-notarized `.dmg` (ad-hoc
signature — first launch needs one approval via [System Settings →
Privacy & Security → Open
Anyway](https://support.apple.com/en-gb/guide/mac-help/mh40616/mac)) —
see [ROADMAP.md](ROADMAP.md) for Developer ID / Notarization and the rest
of the open distribution work.

---

## Acknowledgements

Forked from [altuzar/sonicflow](https://github.com/altuzar/sonicflow).
Architecture inspired by SoundSource, BackgroundMusic, and similar pro
audio utilities. CoreAudio Process Tap API by Apple (macOS 14.2+).
