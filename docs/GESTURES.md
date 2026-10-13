# AirTrackpad: Gesture Language & State Machine

**Specification Version:** 1.1.0 (matches `Sources/AirTrackpadCore/Gesture/`)
**Defaults:** `GestureConfig`, `AppSettings`, `CursorEngine`, `ActionRouter`

---

## 1. Per-frame measurements (`FingerClassifier.extractMetrics`)

All coordinates are Vision-normalized `[0, 1]²`, mirrored so +x is the user's right, y up.

| Metric | Definition | Why |
| :--- | :--- | :--- |
| Hand scale *s* | `max(|wrist − middleMCP|, |indexMCP − littleMCP| / 0.72)` | Palm length collapses when the palm tilts, knuckle width when the hand turns; the max survives both. Every distance below is divided by *s* ("palm lengths"). |
| Palm center | Confidence-weighted mean of wrist + 4 MCPs | Drives swipes. Stable under finger motion and motion blur. |
| Cursor anchor | `0.50·indexMCP + 0.35·middleMCP + 0.15·indexPIP` | Barely moves when the fingertip curls into a pinch (TouchFree "index stable" idea). |
| Pinch distance | `|thumbTip − indexTip| / s` | Left click / drag. **Thumb-based only.** |
| Middle pinch | `|thumbTip − middleTip| / s` | Right click. |
| Reach (per finger) | `|tip − MCP| / s` (thumb: tip → index MCP) | Folded ≈ 0.3, extended ≈ 0.7–0.9. Backs up the state classifier. |
| Spread | Mean fingertip distance from the fingertip centroid / *s* | Mission Control open/gathered. |

Finger states use rotation-invariant ratios (tip vs. PIP distance from the wrist, MCP→PIP vs. PIP→tip alignment).

## 2. Poses (`PoseClassifier`, `PoseStabilizer`)

| Pose | Rule |
| :--- | :--- |
| `openHand` | index, middle, ring, little up (reach-checked), ≥ 3 of them fully extended |
| `scroll` | index up, middle **extended** (reach ≥ 0.5), ring & little not extended |
| `pointing` | index up, middle not clearly up, ring & little not extended |
| `fist` | nothing up |
| `other` | anything else |

A raw pose must persist for 2 consecutive frames to become stable (3 for pointing ↔ scroll and for leaving
`openHand`). While the raw pose is already heading to a different gesture, pointer/scroll output is held.

## 3. Priority

```
pressed / dragging  (owns the hand until the pinch opens)
  > desktop swipe
  > Mission Control
  > cooldown (0.3 s after swipe / 0.5 s after Mission Control)
  > pinch press (left), thumb–middle pinch (right click)
  > pose: pointing → pointer, scroll → scroll, others → pointer frozen ("lift")
```

## 4. Pointer (`CursorEngine`)

1. Hand scale smoothed (τ = 0.4 s).
2. Anchor filtered with an isotropic One Euro filter; speed measured in palm lengths/s
   (defaults: `minCutoff 1.55 Hz`, `beta 1.25`, `dCutoff 1 Hz` at smoothing 0.5).
3. **Trackpad mode (default):** per-frame motion in palm lengths × gain. Speed dead zone: speeds below
   `restSpeed` (≈0.085 palm/s) are subtracted, so tremor never accumulates into drift.
   Gain = `700 pt/palm × speed × (minGain … maxGain)` eased between 0.5 and 4 palm/s
   (acceleration 0.7 → 0.55× … 1.56×).
4. **Direct mode:** filtered anchor mapped through the calibration box onto the display under the pointer,
   then a leash dead zone (1.5 pt, growing to +18 pt as a pinch closes).
5. While a pinch is visibly closing (closing speed > 0.8 palm/s), gain drops toward 15 %.
6. Output stage: deltas eased at ~125 Hz (τ = 12 ms), applied to the pointer's *actual* position (so a
   physical mouse can be used at the same time), clamped to the nearest display.

## 5. Click, drag, right click (`PinchDetector`)

| Parameter | Default |
| :--- | :--- |
| Press / release threshold | 0.22 / 0.32 palm lengths (hysteresis) |
| Confirmation | 2 consecutive frames on press and on release |
| Occlusion | frames where a fingertip wasn't actually observed (low confidence or extrapolated) hold the state |
| Freshness | a press requires the fingers to have been seen clearly open first |
| Fist guard | index reach ≥ 0.35 to press |
| Drag start | hand travel ≥ 0.16 palm while pinched, or hold ≥ 0.45 s |
| Double click | within `NSEvent.doubleClickInterval`, ≤ 8 pt travel |
| Post-click settle | pointer frozen 0.12 s |

On **press** the pointer motion emitted since the fingers were last steady (≤ 0.25 s, < 90 pt) is undone,
then the pointer freezes. Release before a drag starts → `leftClick(count)`. Drag → `leftMouseDown`,
pointer follows the hand as `leftMouseDragged`, release → motion from the un-pinch (≤ 0.1 s) is undone,
then `leftMouseUp`.

Right click: thumb–middle pinch (press 0.24) while the index stays away → `rightClick` once; left
presses are blocked while it's held. Any pinch press also sends `cancelMomentum` (stops scroll inertia,
like touching a trackpad). A Mission Control gather cancels pinch arming, so an abandoned gather can't
turn into a click.

## 6. Scroll (✌)

Starts one frame after the pose stabilizes. Anchor motion in palm lengths × 900 pt × sensitivity ×
(1 … 1.8 acceleration), speed dead zone 0.12 palm/s, axis rails (minor axis dropped below 40 %).
Natural scrolling (default): content follows the hand. Events carry phases `began → changed → ended`;
the output stage drains them at ~125 Hz and adds momentum (τ = 0.33 s) after `ended`.

## 7. Desktop swipe (`SwipeDetector`)

Armed after the stable pose has been `openHand` for 2 frames; stays armed 0.35 s through blur dropouts.
Fires mid-stroke when, within the last 0.45 s of palm-center samples:

- horizontal travel ≥ **0.75 palm** (≈ 7–8 cm),
- peak horizontal speed ≥ **2.6 palm/s**,
- horizontal ≥ 1.6 × vertical.

Lockout: the **opposite direction is blocked for 0.95 s** (return stroke), the same direction for 0.40 s
(repeat hops allowed). A blocked stroke is swallowed so it can't fire after the lockout ends.
The sensitivity setting divides both distance and speed thresholds.

Direction: by default hand → right means desktop on the right; *natural* inverts it (like a trackpad).

### Dispatch (`SpaceSwitcher`)

- Skips the switch with a red flash at the first/last Space (via `CGSCopyManagedDisplaySpaces`).
- macOS ≤ 26: three Dock-control events (`began/changed/ended`, field 55 = 30, 110 = 23, 123 = 1),
  progress ±0.000016, velocity ±40 (animated) / ±80 (fast) / ±2000 (instant); positive = right.
- macOS 27+: same fields plus an IOHID fluid-gesture + velocity payload appended to the serialized event,
  a companion gesture event, and a sign read through the natural-scrolling preference.
- Keyboard style: ⌃← / ⌃→ (Control + Fn + keypad flags, as the shortcut is registered).
- Isolated switches are verified ~0.35–0.9 s later; a wrong-way move flips and persists the sign
  (per macOS version) and corrects; two no-effect switches fall back to the keyboard shortcut.

## 8. Mission Control (`FiveFingerDetector`)

`idle → open (spread ≥ 0.40, open palm with thumb) → contracting → armed (spread ≤ 0.22) → expanding →
trigger (spread ≥ 0.40)` within 1.4 s measured from when contraction began. Pointing or scrolling abandons
the sequence; pinch-clicks are held off from contraction onward.

## 9. Robustness rules

- Tracking dropouts shorter than 0.25 s are ignored (drag held, scroll open, swipe samples kept).
- Swipes only count once the hand has been in view for 0.3 s (a hand sweeping into view is already moving).
- Frame watchdog: if camera frames stop for 0.35 s (camera unplugged, capture error), everything is released.
- Longer loss: `leftMouseUp` if dragging, scroll `ended`, full reset.
- Gestures pause while typing (0.6 s after any key press) and on `⌃ Esc`.
- The router never leaves a button down: pause, emergency stop (also when AirTrackpad's own window is
  focused) and quit all release it, and nothing queued is posted after the router is disabled.
- The camera is pinned to 30 fps; all frame-count thresholds are tuned for that rate.
