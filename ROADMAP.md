# Fader Roadmap

Honest list of what's done, what's pending polish, and what's a real
investment.

---

## ✅ Shipped

### Phase 1 — UI (done)
- SwiftUI `MenuBarExtra(.window)` panel, `LSUIElement = true`
  (menu-bar-only, no Dock icon)
- Native macOS-style slider (icons flanking the track, plain adaptive
  fill, no separate thumb) — matches the system volume control, not a
  reinvented one
- Per-app rows: name, icon-free (removed — the slider + name is enough),
  mute icon, real audio-derived level meter (brightens the fill's
  opacity, not simulated)
- Settings screen: Auto-Lower for Calls (rename of "ducking" — toggle,
  amount slider), About (version + report-a-bug link only)
- Every icon button that's actually clickable (mute, settings, back,
  power) gets a visible resting-state circular background — no more
  "looks like a static icon until you hover it"
- Single flat brand accent color, matching the website exactly
- Menu bar icon always opens to the main screen, never the last-viewed
  one
- App icon: SVG → ICNS pipeline
- Menu bar glyph is a real vector shape matching the website's mark
  exactly (`FaderMark`), not an SF Symbol standing in for it — same
  glyph in the menu bar, the in-app header badge, and on the site

### Phase 2 — Live detection (done)
- `kAudioHardwarePropertyProcessObjectList` enumeration
- Per-process listeners on both `kAudioProcessPropertyIsRunningOutput`
  *and* the broader `IsRunning` — the narrower property's own change
  notification is unreliable in practice, so re-checking on either
  catches a pause → resume transition faster
- 0.2 Hz fallback poll for whatever both listeners still miss (tightened
  from 1 Hz — this interval directly bounds how long a resumed app can
  play un-gain-controlled before Fader catches up)
- Helper-bundle filtering (`.helper`, `.gpu`, `.renderer`, `xpcservice`)
- System-process hide-list (CoreSpeech, audiomxd, accessibility
  daemons…)
- App categorization (communication / browser / media / game) driving
  auto-lower-for-calls
- Cold-cache app icon + display-name resolution via `NSRunningApplication`

### Phase 3 — Per-app gain (done)
- `CATapDescription` + `AudioHardwareCreateProcessTap` per active app
- Capture path: private aggregate device → IOProc applies per-app gain →
  mixes stereo → writes to ring buffer
- Lock-free SPSC `FloatRingBuffer` (8192 samples, ~85 ms @ 48 kHz)
- Playback path: IOProc on user's real default output → reads ring
  buffer → adds to outputData (mixes with non-tapped apps)
- Realtime callbacks are allocation-free and lock-free
- Gain values: aligned-32-bit `Float` written by main, read by IOProc —
  and now primed with the correct value *before* a freshly (re)created
  tap's IOProc starts, not after
- Gain is **not** re-multiplied by system volume — the hardware already
  applies that once to the final output buffer regardless of which
  client wrote it; doing it again in software meant tapped apps were
  quieter than their own native volume at 100%
- Auto-lower for calls: state-driven, `.onChange(isAnyCommunicationActive)`
  re-syncs gains
- Click-to-mute on icon + mute glyph + context menu; muted (or otherwise
  adjusted) apps stay visible in the list even after they go quiet,
  instead of disappearing and silently reappearing muted later
- System-volume sync: per-app volume is relative to system volume, so
  F11/F12 and Control Center still work as expected
- AppleScript fallback for Music/Spotify/TV/Podcasts (also updates the
  app's own visible volume slider)
- Single-instance enforcement — a non-blocking `flock()` on a fixed file,
  held for the process's lifetime. A second launch (double-click, `open
  -a`, a stray dev build) while the real instance is running exits
  immediately instead of standing up a second CoreAudioEngine fighting
  the first over the same taps
- Crash-safe: signal handler restores default output (legacy from when
  we changed it; still installed as cheap safety net)
- **Volume persistence** — per-app volume + mute state saved to
  `UserDefaults` (debounced writes), restored the next time that app is
  seen, whether the change came from Fader's own slider or the app's
  own native volume control
- **Permissions onboarding** — neither Automation nor system-audio-capture
  TCC status has a synchronous "check without prompting" API (the
  latter's denial is completely silent — every CoreAudio call still
  returns `noErr`, the tap's buffers just stay zero), so both are
  inferred behaviorally: AppleScript's real `-1743` error for
  Automation, and sustained silence on an installed, active tap for
  audio capture. Surfaced as a dismissible in-app banner plus a
  permanent status row (with a direct System Settings link) in Settings
- **Smoother active-set changes** — switching which apps are tapped now
  only rebuilds the capture side (taps + aggregate device); the ring
  buffer and the playback IOProc actually wired to the speakers stay
  running throughout, so adding/removing a tapped app no longer causes
  an audible stop/restart on the output path. Live-verified with two
  simultaneous tapped apps (add and remove, in both orders) via
  `--debug` stats. Short of true in-place tap add/remove (mutating a
  running aggregate's tap list instead of recreating it) — that's a
  real CoreAudio property (`kAudioAggregateDevicePropertyTapList`) but
  under-documented and under-tested enough to be its own follow-up
  rather than something to land blind on the daily-driver build

### Fork fixes (done)
- **Headphone/Bluetooth hot-swap** — listens for
  `kAudioHardwarePropertyDefaultOutputDevice` changes and rebuilds the
  tap/aggregate/playback pipeline automatically; no more restarting the
  app after switching outputs
- **Mono output device handling** — the playback IOProc down/up-mixes
  the ring buffer's stereo frames to the real device's actual channel
  count instead of copying raw floats 1:1, fixing scrambled/muffled
  audio on mono outputs (e.g. Bluetooth in call mode)
- **Live call audio left untouched** — apps with simultaneous mic input
  + output (a live call) are skipped for tap creation, since macOS
  silently zeroes Process Tap content for call audio while
  `CATapMutedWhenTapped` still mutes the real output — tapping was
  strictly worse than doing nothing
- **AppKit crash switching to Settings** — `NSHostingController`'s
  `sizingOptions` continuous auto-tracking could fail to converge on a
  content-height change and crash; fixed by sizing the window once
  instead of continuously tracking it
- **Muted apps disappearing from view** — see Phase 3 above
- **Apps briefly playing at full volume on resume** — see Phase 3 above
- **Tapped apps quieter than native at 100%** — see Phase 3 above
- **Duplicate running instance** — see Phase 3 above

### Rebrand (done)
- Full identity change from the original fork: name, bundle ID
  (`com.fader.app`), app icon, brand colors (now a single flat accent,
  matching the website), website copy and design

### Distribution (partially done)
- `.dmg` installer (`make dmg`) with an Applications-folder symlink for
  drag-to-install, uploaded alongside the `.zip` release asset
- GitHub Issues enabled with a bug-report template
- Ad-hoc signed (not yet Developer ID / notarized — see below)

### Website (done)
- Full redesign: flat, editorial, single-accent-color system instead of
  the original dark-glassmorphic template look
- **Real interactive demo**, not screenshots — the hero panel's sliders,
  mute icons, and "simulate a call" button are fully functional and
  drive two real (CC0-licensed) audio loops mixed live through the Web
  Audio API, ducking exactly like the real app
- Download button triggers an immediate `.dmg` download and a dismissible
  support-modal (Buy Me a Coffee handoff — no payment details ever
  handled on our side)

### Quality of life
- `make sign / make run / make debug / make icon / make dmg` workflow
- `--debug`, `--preview`, `--preview-live`, `--mock`, `--no-gain`,
  `--test-gain-cycle` diagnostic flags

---

## 🪒 Polish (small)

| Task | Effort | Value |
|---|---|---|
| Real **RMS level meters** from the IOProc (currently peak, not RMS) | low | low-medium |
| **Sample-rate handling** — query device nominal sample rate, resample if tap and output disagree | low-med | medium |
| **Mute click suppression** — fade gain over 5–10 ms instead of instant 0 (avoids audible click on fast transitions) | low | medium |
| **Row entry/exit animations** — already partially present, could be smoother | low | low |
| **Settings panel expansion** — auto-lower attack/release sliders, output-device picker | low | medium |

---

## 🛠 Real work (medium)

| Task | Effort | Value |
|---|---|---|
| **Global hotkeys** — system-wide volume cmd+up/down with Accessibility permission | medium | high |
| **Auto-launch at login** via `SMAppService.mainApp` | low-med | medium |
| **Multiple output device support** — explicit picker, per-app routing | medium-high | medium |
| **App allowlist** — let user choose which apps Fader controls (not auto-tap everything) | medium | low-med |
| **True in-place tap add/remove** — mutate a running aggregate's `kAudioAggregateDevicePropertyTapList` instead of recreating the aggregate on every active-set change. The *playback* side (ring buffer + output IOProc) no longer rebuilds at all — see Phase 3 — this would remove the remaining *capture*-side rebuild too | medium-high | medium |
| **Crash diagnostics** — symbolicated reports, optional opt-in | medium | low |

---

## 🚢 Distribution (big)

| Task | Effort | Value |
|---|---|---|
| **Developer ID code signing** + Notarization — currently ad-hoc, needs a one-time [System Settings → Privacy & Security → Open Anyway](https://support.apple.com/en-gb/guide/mac-help/mh40616/mac) approval on first launch | medium | required for wide distribution |
| **Sparkle auto-update** integration | medium | high (post-launch) |
| **Privacy policy** — required for Notarization | low | required |
| **App Store submission** — *would require sandboxing, which breaks Process Taps. Probably not viable.* | n/a | n/a |
| **Pricing / licensing** — free? Set Apps Inc-style? donation-ware (currently just a Buy Me a Coffee prompt after download)? | n/a | n/a |

---

## 🧪 Things to test / verify

- Phase 3 audio on a multi-channel device (USB DAC, audio interface)
- Phase 3 audio on AirPods / Bluetooth output
- Multiple comm apps active simultaneously (Zoom + Teams)
- Apps with non-stereo output (mono → stereo upmix)
- Performance under stress (10+ concurrent audio apps)
- Behavior when CoreAudio HAL restarts (e.g. after a sample-rate change)
- macOS 15 Sequoia / 26 (whatever lands) — the purple audio-capture
  indicator behavior may change

---

## 🗂 Out of scope (for now)

- iOS / iPadOS port — Process Tap API isn't available there
- Cross-fade / EQ / effects beyond simple gain — that's a different
  product (and what Audio Hijack already does well)
- A free-form audio router — see Loopback

---

## Honest current state

This is a **working daily-driver app**, not a proof of concept — the
Phase 3 audio pipeline is genuinely working with two IOProcs and a ring
buffer, it ships as a signed `.dmg`, and it's what this project's own
author actually runs day to day. Developer ID signing/notarization is
the main thing standing between "works great for people willing to
approve it once via System Settings → Privacy & Security" and a fully
frictionless install for a wider audience.
