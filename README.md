# Brightness

A macOS menu-bar app that unlocks the HDR brightness headroom of Apple XDR
displays for ordinary SDR content.

Apple's XDR panels sustain around 1000 nits and peak at 1600, but macOS caps
normal content near the panel's SDR reference (500–600 nits depending on model).
The remaining range is reserved for genuine HDR content. This app presents
itself as an HDR application to unlock that range, then applies it to everything
on screen.

Measured on a MacBook Pro `Mac16,8` (M4 Pro): reported headroom rises from
**1.0 to 2.67**, yielding a **1.60x** gain — roughly 600 to 960 nits.

Public API only. No private frameworks, no screen recording permission, no
kernel extensions.

---

## Requirements

- macOS 14 or later
- An XDR-capable display: MacBook Pro 14"/16" (M1 Pro/Max or later), Pro Display
  XDR, or Studio Display
- Xcode 16+ / Swift 6 toolchain to build

Displays that report no EDR headroom are detected and skipped.

## Build

```bash
./Scripts/build.sh release
open build/Brightness.app
```

The script compiles with SwiftPM and assembles a `.app` bundle in `build/`,
ad-hoc signed so it runs locally.

Inspect what your displays advertise without launching the UI:

```bash
./build/Brightness.app/Contents/MacOS/Brightness --diagnose
```

## Usage

The app lives in the menu bar; there is no Dock icon.

| Action | Shortcut |
|---|---|
| Toggle boost | <kbd>Cmd</kbd><kbd>Opt</kbd><kbd>B</kbd> |
| Brighter | <kbd>Cmd</kbd><kbd>Opt</kbd><kbd>↑</kbd> |
| Dimmer | <kbd>Cmd</kbd><kbd>Opt</kbd><kbd>↓</kbd> |

---

## How it works

### Multiply overlay (default)

A borderless, click-through window per display, at `CGShieldingWindowLevel()`,
joining all spaces and all applications. Its content is a `CAMetalLayer` with:

```swift
metalLayer.wantsExtendedDynamicRangeContent = true   // unlocks the headroom
metalLayer.compositingFilter = "multiply"            // applies it to everything beneath
colorPixelFormat = .rgba16Float                      // required to express values > 1.0
colorspace = CGColorSpace(name: .extendedLinearSRGB)
```

The layer renders nothing but a clear colour of `(k, k, k)` where `k > 1.0`. The
window server multiplies everything beneath by `k`.

Because the frame is a flat colour, the drawable is **1×1 pixel at 5fps**,
stretched across the display. The clear colour *is* the frame, so the GPU cost is
negligible.

This backend preserves HDR video and leaves no persistent system state — if the
process dies, the windows die with it.

### Gamma table

Captures the display's existing transfer table with
`CGGetDisplayTransferByTable`, scales every entry, and writes it back. Scaling
the captured table rather than synthesising a new ramp preserves the user's
colour profile.

Gamma alone cannot exceed the SDR ceiling, so a 1×1 EDR trigger window still
holds the headroom open while gamma does the amplifying.

Trade-offs, disclosed in the UI: **clips HDR video**, competes with Night Shift
and f.lux, and needs a drift watchdog because macOS silently resets the table on
wake, reconfiguration, and brightness changes.

### Auto-calibration

Rather than shipping a table of device models, the app measures each display's
real headroom at runtime and keeps the running maximum.

Reported headroom is `peakNits / sdrWhiteNits`, so it differs per panel — a
500-nit-SDR display settles near 3.2, a 600-nit one near 2.67. Usable gain is
then `headroom × 0.60`, because XDR panels only hold peak brightness over small
areas and sustain roughly 1000 of 1600 nits full-field.

Both panel types therefore converge on about 960 sustained nits, without any
per-model constants. Calibration persists and can be reset from Settings.

### Engagement state machine

Displaying EDR content is what *causes* the headroom to rise, so the app cannot
simply read a value and apply it. Per display:

```
idle → engaging ──(headroom > 1.05)──→ ready
         │                               │
         │ 25s timeout                   │ headroom lost
         ▼                               ▼
     cooldown (30s) ──retry──→ engaging
         │
         │ 3 consecutive failures
         ▼
     isolated (keeps polling, recovers on its own)
```

Per-display isolation matters: one uncooperative external monitor must never
disable boost on a working built-in panel. Polling rests at 500ms and bursts to
16ms for 30s after any display change.

---

## Safety

The gamma backend writes persistent display state, so restoration is layered:

1. `applicationWillTerminate`
2. `atexit`
3. `SIGINT` / `SIGTERM` / `SIGHUP` handlers
4. Unconditional `CGDisplayRestoreColorSyncSettings()` at every launch, clearing
   anything stranded by a previous crash
5. Full deactivation before system sleep

Verified: gamma restores correctly on graceful quit, on signal, and after
`SIGKILL`. Gain is hard-clamped and can never exceed the headroom the display is
currently granting.

## Battery and heat

Running an XDR panel near full brightness draws noticeably more power and warms
the machine. The app can turn itself off automatically on battery, and does so by
default in Low Power Mode.

---

## Project layout

```
Sources/Brightness/
  App/      AppDelegate, BoostCoordinator (the state machine), entry point
  Engine/   backends, display registry, gain model, calibration, Metal overlay
  Policy/   battery / low-power, conflicting-app detection
  UI/       menu bar, settings, onboarding
  Core/     settings, diagnostics ring buffer, safety net, hotkeys
```

## Releases

Tagging a version builds, signs, notarises and publishes a DMG automatically:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The workflow can also be run manually from the Actions tab.

Packaging works locally too:

```bash
VERSION=1.0.0 ./Scripts/package.sh
```

### Signing secrets

Without these the workflow still produces a working DMG, but it is only
ad-hoc signed and Gatekeeper will block it on first launch. Users can work
around that (`xattr -dr com.apple.quarantine`), but a notarised build is
what makes the app installable by people who are not developers.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application `.p12`, base64 encoded |
| `MACOS_CERTIFICATE_PWD` | Password for that `.p12` |
| `MACOS_CERTIFICATE_NAME` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `KEYCHAIN_PASSWORD` | Any throwaway string; unlocks the temporary CI keychain |
| `APPLE_ID` | Apple ID used for notarisation |
| `APPLE_TEAM_ID` | Your 10-character team ID |
| `APPLE_APP_PASSWORD` | App-specific password, from appleid.apple.com |

To produce the base64 certificate:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

## Licence

MIT — see [LICENSE](LICENSE).

This is an independent clean-room implementation written from public API
documentation and measurement. It is not derived from the source of any existing
app. Prior art worth crediting for establishing the technique:
[BrightIntosh](https://github.com/niklasr22/BrightIntosh) (GPL-3.0),
[BetterDisplay](https://github.com/waydabber/BetterDisplay), and the commercial
[Vivid](https://www.getvivid.app/).

**Note for forkers:** because this project is MIT, do not paste code in from
those GPL-licensed projects — it would make the combined work GPL.
