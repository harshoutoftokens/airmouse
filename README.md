# AirTrackpad

> **Use your Mac like a trackpad — in the air.** Webcam hand tracking (Apple Vision) turned into
> pointer movement, clicks, drags, scrolling, desktop switching and Mission Control.

Built in Swift 6 for Apple Silicon. Everything runs on-device; no images are stored or uploaded.

---

## Gestures

| Gesture | How | Result |
| :--- | :--- | :--- |
| ☝ **Point** | Index finger up, others curled. Move your **hand** | Pointer moves (with acceleration: slow = precise, fast = far) |
| ✊ **Lift** | Make a fist (or relax the hand), reposition, point again | Pointer stays put — like lifting your finger off a trackpad |
| 🤏 **Click** | Quick thumb–index pinch | Left click where you were pointing |
| 🤏🤏 **Double-click** | Two quick pinches | Double click (follows the system double-click speed) |
| 🤏 **Drag** | Pinch, then move — or pinch and hold still ~0.45 s | Mouse down → drag → let go to drop |
| 🤌 **Right-click** | Thumb–middle pinch (index stays away) | Right click / context menu |
| ✌ **Scroll** | Index + middle up, move hand up/down (or sideways) | Smooth trackpad scrolling with momentum |
| 🖐 **Switch desktop** | All four fingers up, one quick sideways swipe | Next / previous Space. Bringing the hand back is ignored |
| 🖐→🤏→🖐 **Mission Control** | Open palm, gather all fingertips together, open again | Mission Control |

A ring follows the pointer while AirTrackpad is in control: it tightens as your fingers close,
turns solid when a press registers, shows arrows while scrolling and flashes on desktop switches.

**Emergency stop:** `⌃ Esc` (or the menu bar item) pauses all gestures and releases any held button.
Gestures also pause automatically for a moment whenever you type.

---

## What changed in 1.1

The original build was "finicky and sticky". Root causes and fixes:

**Desktop switching.** The synthetic trackpad swipe used the opposite sign from the macOS 26 convention,
and ended at ~30 % progress, so the Dock slid partway toward the wrong side and snapped back. The swipe
detector also accepted slow drifts, and re-armed after 0.4 s, so the hand's return stroke switched straight back.
- Dock-swipe encoding rebuilt after [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)
  (MIT, verified against macOS 26.6.2). It commits via velocity (animated, fast or instant styles), has a
  macOS 27 code path, and a ⌃←/⌃→ fallback.
- After each switch the app checks which Space it actually landed on. If the direction was inverted on
  this machine it self-corrects (and remembers); if swipes have no effect it falls back to the keyboard shortcut.
- At the first/last desktop the swipe is blocked with a red flash instead of a rubber-band bounce.
- Swipes now need a fast stroke (peak speed + distance + sideways dominance) measured on the palm
  center, which survives motion blur. The **opposite direction is locked for ~1 s**, so returning the hand
  can't undo the switch; the same direction re-arms quickly for hopping several desktops.

**Pinch, click & drag.**
- "Pinch distance" also counted index↔middle proximity, so the ✌ scroll pose clicked. It is now thumb–index only.
- Pinches with the other fingers relaxed or extended (👌) were rejected. Any natural pinch works now.
- Every click/drag event was posted twice (HID + session tap). Now posted once.
- One dropped camera frame ended a drag. Drags and scrolls now ride out ~0.25 s dropouts, a fingertip
  hidden behind the thumb no longer reads as "open", and a watchdog releases everything if the camera stops.
- Hysteresis + confirmation frames, "fresh pinch" (no phantom click when a pinched hand enters view),
  fist rejection, real double-click counts, and drag that starts as soon as you move (or after a short hold).
- The pointer freezes while pressed and **motion caused by closing the fingers is rolled back**, so clicks
  land where you were pointing.

**Pointer.**
- It tracked the fingertip, which is exactly what moves when you pinch. It now tracks a knuckle anchor
  (after Ultraleap TouchFree's "index stable" point and [Gstrl](https://github.com/TomYang-TZ/Gstrl)'s palm tracking).
- New default **Trackpad mode**: relative motion with pointer acceleration, distance-invariant (works the same
  near or far from the camera), and a speed dead zone so a still hand never drifts. Direct (absolute) mode is still available.
- Output is eased at ~125 Hz between 30 fps camera frames, so the pointer glides instead of stepping.
- Works across multiple displays.

**Scrolling** is posted as real trackpad scroll events (gesture phases + momentum), so apps rubber-band,
coast and swipe between pages naturally.

**Other.** Built-in camera preferred (an iPhone Continuity Camera could previously take over silently);
native YUV capture; frame rate pinned to 30 fps on the device; Center Stage disabled; gesture-triggered video
"Reactions" disabled; settings apply live; settings migrate (your old values were the original defaults
and are replaced by the new tuning, UI preferences are kept).

---

## Build & run

Requirements: macOS 13+ on Apple Silicon, Xcode 16+ (Swift 6).

```bash
make setup-cert   # once: local signing identity so permissions survive rebuilds
make run          # release build → AirTrackpad.app → launch
make test         # 119 headless unit / replay / regression tests
make logs         # live log of swipes, clicks, drags and desktop-switch results
```

On first launch grant **Camera** and **Accessibility** (System Settings → Privacy & Security). The menu bar
🖐 icon has Pause, the live HUD (`⌘D`), Settings (`⌘,`) and *Test Desktop Switch* — use the test items to
confirm switching works on your Mac independently of hand tracking.

---

## Troubleshooting

| Symptom | Try |
| :--- | :--- |
| Desktop doesn't switch | Menu → Test Desktop Switch. If that fails, Settings → Desktops → Transition → *Keyboard shortcut*, and make sure System Settings → Keyboard → Shortcuts → Mission Control → "Move left/right a space" are on. |
| Desktop switches the "wrong" way | Settings → Desktops → Direction (hand-direction vs. natural/trackpad). |
| Swipes fire when you just move | Lower *Swipe sensitivity*. Swipes need all four fingers up. |
| Pinch missed / accidental clicks | Settings → Click & Scroll → *Pinch trigger distance* (watch PINCH in the HUD while pinching). |
| Pointer too slow/fast or shaky | Settings → Pointer → speed, acceleration, *Responsive ↔ Steady*. |
| Hand lost often | Better lighting; keep the hand ~40–80 cm from the camera and inside the frame. |

To help tune gestures, press **Record** in the HUD, perform the gesture, press it again; the JSON lands
in `~/Library/Application Support/AirTrackpad/Recordings/` and can be replayed in tests.

---

## Architecture

```
AVCaptureSession (built-in camera, 30 fps, 420v)
  → VisionHandTracker            21 landmarks per hand (VNDetectHumanHandPoseRequest)
  → FingerClassifier             finger states, robust hand scale, palm center, knuckle anchor, pinch distances
  → GestureStateMachine          pose classifier + stabilizer, PinchDetector, SwipeDetector,
                                 FiveFingerDetector, CursorEngine (One Euro, acceleration, rollback)
  → AbstractGestureEvent         platform-free events
  → ActionRouter                 125 Hz output easing, scroll phases + momentum, safety releases
  → CGEventInputBackend          Quartz events (HID tap), SpaceSwitcher (Dock swipe / ⌃←→), Mission Control
```

See [docs/GESTURES.md](docs/GESTURES.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/RESEARCH.md](docs/RESEARCH.md).

## Credits & references

- [jurplel/InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT) — Dock-swipe encodings, macOS 27 payload, Space index lookup.
- [noah-nuebling/mac-mouse-fix](https://github.com/noah-nuebling/mac-mouse-fix) — reference for Dock-swipe and scroll-phase behaviour (no code copied).
- [TomYang-TZ/Gstrl](https://github.com/TomYang-TZ/Gstrl) (MIT) — palm-center tracking, swipe cooldown, multi-display clamping lessons.
- [ultraleap/TouchFree](https://github.com/ultraleap/TouchFree) (Apache-2.0) — stable index anchor, press/drag dead-zone pattern.
- Casiez et al., *1€ Filter* (CHI 2012).
