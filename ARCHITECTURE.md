# XDR Brightness Booster — Architecture Plan

A macOS menu-bar app that unlocks the HDR brightness headroom of Apple XDR displays
for ordinary SDR content. Functional equivalent of Vivid / BrightIntosh.

- **Distribution:** open source, free
- **Backends:** two, user-switchable (EDR multiply overlay + gamma table)
- **Dev target:** MacBook Pro `Mac16,8` (M4 Pro), built-in Liquid Retina XDR, macOS 27 / Xcode 27 / Swift 6.4

---

## 1. The core idea

Apple XDR panels sustain 1000 nits and peak at 1600, but macOS clamps SDR content to
roughly 500 nits. The extra range is reserved for genuine HDR (EDR) content.

The app **presents itself as an HDR application** to make macOS unlock that headroom,
then uses the headroom to brighten everything else on screen.

Two measurable quantities drive everything:

| API | Meaning |
|---|---|
| `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` | Capability probe — is this display XDR at all? (`> 1.0`) |
| `NSScreen.maximumExtendedDynamicRangeColorComponentValue` | **Live headroom.** Rises once EDR engages. Poll this. |
| `NSScreen.maximumReferenceExtendedDynamicRangeColorComponentValue` | Reference-mode ceiling; useful for reference display presets |

There is a deliberate **chicken-and-egg**: displaying EDR content is what causes the
headroom to rise. So every backend must engage first, poll for headroom, *then* ramp gain.

Everything below uses public API only. No private frameworks, no screen recording
permission, no kernel extensions.

---

## 2. Module architecture

```
App/
  AppDelegate                  NSApplication lifecycle, agent-mode (LSUIElement)
  BoostCoordinator             ← the brain. Owns state, decides on/off/how much
Engine/
  BrightnessBackend            protocol both backends conform to
  OverlayBackend               EDR multiply overlay (Metal)
  GammaBackend                 CGSetDisplayTransferByTable
  DisplayRegistry              enumerates + tracks displays, capability probing
  HeadroomMonitor              polls maxEDR, emits ready/lost per display
  GainModel                    maps (maxEDR, user setting) → gain factor
Policy/
  PowerPolicy                  battery / low-power-mode auto-disable
  ConflictMonitor              f.lux, Night Shift, other brightness tools
  ThermalPolicy                reacts to macOS XDR backlight cooldown
UI/
  StatusItemController         menu-bar icon + menu
  SliderView                   brightness slider
  SettingsWindow               SwiftUI preferences
  OnboardingWindow             first-run explanation + safety notice
Core/
  Settings                     UserDefaults-backed, observable
  SafetyNet                    guarantees display restoration on exit/crash
  Diagnostics                  ring-buffer log for bug reports
```

**Design rule:** `BoostCoordinator` is the only thing that decides *whether* boost is
active. Backends are dumb — they only know how to apply a gain factor and how to stop.

---

## 3. The backend protocol

Both backends must be hot-swappable at runtime without stranding a display.

```swift
@MainActor
protocol BrightnessBackend: AnyObject {
    var identifier: BackendKind { get }
    var isActive: Bool { get }

    /// Must be idempotent. Called on enable and on display topology change.
    func activate(on displays: [BoostDisplay])

    /// Must fully restore the display to its untouched state. Called on
    /// disable, backend switch, sleep, and termination. MUST NOT fail silently.
    func deactivate()

    /// Apply a new gain. 1.0 == no boost.
    func setGain(_ gain: Double, for displayID: CGDirectDisplayID)

    /// Topology changed: displays added/removed/moved.
    func displaysChanged(_ displays: [BoostDisplay])
}
```

`BoostDisplay` wraps `CGDirectDisplayID` + the `NSScreen` + capability flags, because
`NSScreen` instances are replaced wholesale on reconfiguration and must never be cached.

---

## 4. Backend A — EDR multiply overlay

The better default. Does not clip HDR video, leaves no persistent system state.

### How it works

A transparent, click-through window per display whose Metal layer is composited onto
everything beneath it with a **multiply** blend. Render a colour of `(k,k,k)` where
`k > 1.0` and the entire screen beneath is multiplied by `k`, pushing SDR pixels up
into the EDR range that the layer itself just unlocked.

### Window configuration

```swift
styleMask:          [.borderless, .fullSizeContentView]
level:              NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
collectionBehavior: [.stationary, .canJoinAllSpaces, .ignoresCycle,
                     .canJoinAllApplications, .fullScreenAuxiliary]
isOpaque:           false
hasShadow:          false
backgroundColor:    .clear
ignoresMouseEvents: true      // critical — never steal input
hidesOnDeactivate:  false
animationBehavior:  .none
```

`.canJoinAllApplications` + `.fullScreenAuxiliary` are what keep the boost alive over
other apps' fullscreen spaces. Without them the effect vanishes in fullscreen video.

### Metal layer configuration

```swift
colorPixelFormat  = .rgba16Float                      // must be float for >1.0 values
colorspace        = CGColorSpace(name: .extendedLinearSRGB)
layer.wantsExtendedDynamicRangeContent = true         // unlocks the headroom
layer.isOpaque          = false
layer.pixelFormat       = .rgba16Float
layer.compositingFilter = "multiply"                  // ← the whole trick
```

### Cost optimisation

The overlay is a flat colour, so it needs no real drawable:

```swift
autoResizeDrawable    = false
drawableSize          = CGSize(width: 1, height: 1)   // 1 pixel, stretched
preferredFramesPerSecond = 5
clearColor            = MTLClearColorMake(k, k, k, 1.0)
```

The render pass opens an encoder and immediately calls `endEncoding()` — the clear
colour *is* the frame. One pixel at 5fps is effectively free.

### Fade-in

Start the window at `alphaValue = 0`, set it to `1` from the command buffer's
completion handler on the first successful frame. Prevents a visible flash of
unmultiplied black when the overlay appears.

---

## 5. Backend B — gamma table

Simpler, zero GPU, but has real downsides the UI must disclose.

```swift
// Capture the user's current (possibly colour-profiled) table first.
CGGetDisplayTransferByTable(displayID, 256, &red, &green, &blue, &count)

// Scale every entry — preserves the user's colour profile shape.
for i in 0..<256 { red[i] *= gain; green[i] *= gain; blue[i] *= gain }

CGSetDisplayTransferByTable(displayID, 256, &red, &green, &blue)
```

Scaling the *captured* table rather than synthesising a fresh ramp is important — it
preserves display calibration and colour profiles.

An EDR trigger is still required: gamma alone cannot exceed the SDR ceiling. So this
backend still needs a **tiny** (1×1, non-multiplying) EDR window somewhere offscreen-ish
to hold the headroom open, with gamma doing the actual amplification.

### Known drawbacks — surface these in the UI

- **Clips HDR video.** Content above SDR max gets flattened to SDR max.
- **Conflicts with f.lux and Night Shift** — they fight over the same table.
- **Not self-restoring.** Requires a watchdog and a guaranteed cleanup path.

### Drift watchdog

macOS silently resets the gamma table on wake, display reconfiguration, and user
brightness changes. Poll the last entry of the table on an interval; if it deviates
from `captured × gain` beyond a small tolerance, reapply. Log every reapplication —
frequent drift is the signature of a conflicting app.

---

## 6. Gain model

```
gain = 1 + bonusGamma × min(maxEDR / referenceEDR, userBrightness)
```

Community-derived reference constants, by display class:

| Display class | referenceEDR | bonusGamma | Max gain |
|---|---|---|---|
| Built-in XDR (most MacBook Pro) | 3.2 | 0.59 | ~1.59× |
| Built-in, 600-nit SDR models | 2.66 | 0.50 | ~1.50× |
| Studio Display / Pro Display XDR | 2.66 | 0.60 | ~1.60× |

Treat these as **starting points to calibrate, not gospel.** Verify on your `Mac16,8`
against a known reference before shipping.

Note the gain is ~1.6×, not 2×. The marketing "double" comes from the product of this
digital gain *and* the backlight increase EDR mode already triggered.

**Clamp hard.** Never let a bug or a malformed setting drive gain past the model's
ceiling — that is how you produce an unreadable or blown-out screen.

---

## 7. Lifecycle — this is the hard part

The effect is ten lines. The lifecycle is the actual product. Per display, run a
small state machine:

```
      idle
       │ enable
       ▼
  engaging ──── maxEDR > 1.05 ────► ready ──── gain tracks maxEDR
       │                              │
       │ 25s timeout                  │ maxEDR drops
       ▼                              ▼
   cooldown (30s) ──── retry ────► engaging
       │
       │ 3 consecutive failures
       ▼
   isolated  ──── keeps polling; recovers automatically
```

Key behaviours:

- **Engage timeout / cooldown.** If headroom never rises, back off rather than spin.
  Retrying instantly in a loop burns battery and never succeeds.
- **Per-display isolation.** One uncooperative external display must never disable
  boost on the working built-in panel. Isolate it, keep polling, recover silently.
- **Adaptive polling.** ~500ms at rest; burst to ~16ms for 30s after a display
  parameter change, when headroom is actually in motion.
- **Sleep/wake.** `NSWorkspace.willSleepNotification` → full deactivate.
  `didWakeNotification` → re-engage from `idle`. Gamma *must* be restored before sleep.
- **Display reconfiguration.** `CGDisplayRegisterReconfigurationCallback` plus
  `NSApplication.didChangeScreenParametersNotification`. Never cache `NSScreen`.
- **Thermal cooldown.** macOS itself throttles XDR backlight when the machine is hot.
  Detect the headroom drop, show a non-alarming notice, resume when it recovers.

---

## 8. Policy layer

| Policy | Trigger | Default |
|---|---|---|
| Battery | on battery power | auto-disable (opt-in setting) |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | auto-disable |
| Conflicting app | f.lux / other brightness tools running | warn once, don't force |
| Thermal | headroom drops while active | pause + notice, auto-resume |
| Per-display | user excludes a display | never boost it |

---

## 9. Safety net — non-negotiable

The gamma backend writes persistent display state. If the app dies without cleaning up,
the user's display stays wrong until logout. Defend in depth:

1. `applicationWillTerminate` → `deactivate()` on all backends
2. `atexit` handler → `CGDisplayRestoreColorSyncSettings()`
3. `SIGINT`/`SIGTERM`/`SIGHUP` handlers → same
4. On launch, unconditionally call `CGDisplayRestoreColorSyncSettings()` to clear any
   state stranded by a previous crash
5. Watchdog timer: if the coordinator stops heartbeating, restore

The overlay backend is inherently safe — if the process dies the window dies with it.
This is a strong argument for making the overlay the default.

---

## 10. UI

Menu-bar only (`LSUIElement = true`), no Dock icon.

- **Status item:** glyph reflects state (off / on / paused-thermal / error)
- **Menu:** toggle, brightness slider, per-display submenu, backend picker,
  settings, quit
- **Global hotkey:** increase / decrease / toggle
- **Settings (SwiftUI):** launch at login (`SMAppService`), backend choice, battery
  policy, per-display excludes, diagnostics export
- **Onboarding:** one screen explaining what it does, the battery/thermal tradeoff,
  and that HDR video clips in gamma mode

---

## 11. Build roadmap

| Milestone | Deliverable | Proves |
|---|---|---|
| **M0** | Single-file PoC: fullscreen multiply overlay, hardcoded gain | The trick works on M4 Pro |
| **M1** | Menu-bar app, overlay backend, on/off toggle | Usable daily |
| **M2** | Headroom monitor + gain model + slider | Correct, tunable brightness |
| **M3** | Multi-display + reconfiguration + sleep/wake | Doesn't break on real-world use |
| **M4** | Gamma backend + watchdog + safety net | Second backend, switchable |
| **M5** | Policy layer (battery, thermal, conflicts) | Good citizen |
| **M6** | Settings, onboarding, hotkeys, launch-at-login | Shippable |
| **M7** | Notarised DMG + GitHub release + README | Public v1.0 |

M0–M2 is a genuinely useful tool. M3 is where most of the real engineering lives.

---

## 12. Licensing

| Your licence | May adapt GPL refs (BrightIntosh, BetterDisplay v1) |
|---|---|
| **GPL-3.0** | Yes |
| MIT / Apache-2.0 | **No** — clean-room reimplementation only |

This plan is written for clean-room reimplementation, so either choice remains open.
API names, constants and techniques are facts and are not themselves copyrightable;
source code is.

Do not reuse the Vivid name, icon, or marketing copy.

---

## 13. Testing

Automated coverage is limited — the effect is visual and hardware-dependent. Focus on:

- **Unit:** gain model math, clamping, state machine transitions
- **Fake display registry:** drive the state machine through hotplug/sleep/timeout
  sequences without real hardware
- **Manual matrix:** built-in only / + external non-XDR / clamshell / fullscreen video /
  sleep-wake / display swap mid-boost / force-quit-then-relaunch (gamma restoration)
- **Instruments:** confirm overlay GPU cost is negligible; measure real battery delta

Log aggressively into a diagnostics ring buffer from day one. Remote bug reports on
this class of app are otherwise unactionable.

---

## 14. Principal risks

| Risk | Mitigation |
|---|---|
| Stranded gamma state after crash | Layered safety net (§9); default to overlay backend |
| macOS changes EDR behaviour in a point release | Both backends; capability-probe rather than version-check |
| Battery and thermal complaints | Honest onboarding; battery policy on by default |
| Reference constants wrong for some model | Calibrate per model; conservative clamp; user-tunable slider |
| Overlay lost in fullscreen spaces | `.canJoinAllApplications` + `.fullScreenAuxiliary`; test explicitly |
