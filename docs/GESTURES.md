# AirTrackpad: Gesture Language & Temporal State Machine Specification

**Specification Version:** 1.0.0  
**Status:** Canonical Source of Truth  
**Target Platform:** macOS (Apple Silicon)  

---

## 1. Mathematical Foundations & Metrics

All hand calculations operate on normalized 2D landmark coordinates:
$$P_i = (x_i, y_i) \in [0.0, 1.0]^2$$
where $(0, 0)$ is bottom-left and $(1, 1)$ is top-right of the camera image.

### 1.1 Hand Scale Metric ($S_{hand}$)
To ensure gestures function consistently regardless of whether the user is close to or far from the webcam, all geometric distances are normalized by the palm scale $S_{hand}$:
$$S_{hand} = \| P_{\text{wrist}} - P_{\text{middleMCP}} \|_2$$
where $\| \cdot \|_2$ denotes Euclidean distance:
$$\| A - B \|_2 = \sqrt{(A_x - B_x)^2 + (A_y - B_y)^2}$$

If $S_{hand} < 0.05$ (hand too far or detection degenerate), the frame is tagged as invalid.

---

### 1.2 Finger Classification ($F_k$)
For each finger $k \in \{\text{Thumb}, \text{Index}, \text{Middle}, \text{Ring}, \text{Little}\}$:
Let $P_{\text{tip}}$, $P_{\text{dip}}$, $P_{\text{pip}}$, $P_{\text{mcp}}$ be the respective joint landmarks.

#### Rotation-Invariant Extension Metric:
Rather than relying on screen-space $Y$ coordinates, finger extension is evaluated via two geometric criteria:
1. **Distance Ratio from Wrist:**
   $$R_{\text{dist}} = \frac{\| P_{\text{tip}} - P_{\text{wrist}} \|_2}{\| P_{\text{pip}} - P_{\text{wrist}} \|_2}$$
   - When extended: $R_{\text{dist}} \ge 1.30$.
   - When folded: $R_{\text{dist}} \le 1.05$.

2. **Joint Alignment (Cosine of Vector Angle):**
   Let $\vec{u} = P_{\text{pip}} - P_{\text{mcp}}$ and $\vec{v} = P_{\text{tip}} - P_{\text{pip}}$.
   $$\cos(\theta) = \frac{\vec{u} \cdot \vec{v}}{\|\vec{u}\|_2 \|\vec{v}\|_2}$$
   - When extended: $\cos(\theta) \ge 0.70$ (nearly straight).
   - When folded: $\cos(\theta) < 0.20$ or $\vec{u} \cdot \vec{v} < 0$.

3. **Thumb Extension Metric:**
   The thumb lacks a DIP joint. Extension is determined by distance from the palm center and MCP:
   $$R_{\text{thumb}} = \frac{\| P_{\text{thumbTip}} - P_{\text{pinkyMCP}} \|_2}{S_{hand}}$$
   - Extended: $R_{\text{thumb}} \ge 0.85$.
   - Folded: $R_{\text{thumb}} < 0.65$.

**Finger States:**
$$\text{State}(F_k) \in \{ \text{Extended}, \text{Folded}, \text{PartiallyExtended}, \text{Uncertain} \}$$

**Extended Finger Count ($N_{\text{ext}}$):**
$$N_{\text{ext}} = \sum_{k \in \text{Fingers}} \mathbb{I}(\text{State}(F_k) == \text{Extended})$$

---

### 1.3 Centroid of Extended Fingertips ($C_t$)
$$C_t = \frac{1}{N_{\text{ext}}} \sum_{k \in \text{Extended}} P_{\text{tip}, k}$$

### 1.4 Normalized Fingertip Spread ($\sigma_t$)
Spread represents the average relative distance of all extended fingertips from their centroid:
$$\sigma_t = \frac{1}{N_{\text{ext}} \cdot S_{hand}} \sum_{k \in \text{Extended}} \| P_{\text{tip}, k} - C_t \|_2$$

---

## 2. Gesture Priority & Conflict Resolution

To avoid conflicting mouse and gesture actions, the system enforces a strict priority hierarchy:

```
┌────────────────────────────────────────────────────────┐
│  PRIORITY 1: 5-Finger Mission Control Sequence         │
├────────────────────────────────────────────────────────┤
│  PRIORITY 2: 4-Finger Desktop Fast Swipe               │
├────────────────────────────────────────────────────────┤
│  PRIORITY 3: 2-Finger Pinch Click & Hold-Drag          │
├────────────────────────────────────────────────────────┤
│  PRIORITY 4: 1-Finger Cursor Navigation                │
└────────────────────────────────────────────────────────┘
```

### Invariant Rules:
1. **Cursor Lock on Multi-Touch:** As soon as $N_{\text{ext}} \ge 2$, cursor movement **MUST IMMEDIATELY FREEZE**. The cursor remains locked at its current screen coordinates.
2. **Deterministic Preemption:** A higher-order gesture immediately cancels lower-order gesture candidate states.
3. **Safety Timeout on Drag:** If $N_{\text{ext}} = 0$ or hand tracking is interrupted while a synthetic mouse-down is active, `.leftMouseUp` is dispatched immediately.

---

## 3. Detailed Gesture Specifications

---

### Gesture 1: One-Finger Cursor Navigation
```text
State: ONE_FINGER_CURSOR
Icon: ☝
```

#### Activation Preconditions:
- Exactly 1 finger extended:
  $$\text{State}(\text{Index}) == \text{Extended}$$
  $$\text{State}(\text{Middle}) == \text{Folded}, \quad \text{State}(\text{Ring}) == \text{Folded}, \quad \text{State}(\text{Little}) == \text{Folded}$$
- Tracking confidence $> 0.5$ for index fingertip and wrist.

#### Operational Logic:
1. **Tracked Anchor:** Index fingertip coordinate $P_{\text{indexTip}} = (x_t, y_t)$.
2. **Camera-to-Screen Mapping:**
   Given interaction bounding box $[\text{minX}, \text{maxX}] \times [\text{minY}, \text{maxY}]$ and screen bounds $(W, H)$:
   $$x_{\text{norm}} = \text{clamp}\left(\frac{(1.0 - x_t) - \text{minX}}{\text{maxX} - \text{minX}}, 0.0, 1.0\right) \quad \text{(with mirroring)}$$
   $$y_{\text{norm}} = \text{clamp}\left(\frac{(1.0 - y_t) - \text{minY}}{\text{maxY} - \text{minY}}, 0.0, 1.0\right) \quad \text{(inverted Vision Y)}$$
3. **Filtering:**
   Pass $(x_{\text{norm}}, y_{\text{norm}})$ through a dual-axis **One Euro Filter**:
   $$\text{cutoff} = f_{\text{min}} + \beta \cdot |v_t|$$
   - Defaults: $f_{\text{min}} = 1.0\text{ Hz}$, $\beta = 0.007$, $d_{\text{cutoff}} = 1.0\text{ Hz}$.
4. **Dead-Zone & Acceleration:**
   Let $\Delta = \| P_{\text{filtered}, t} - P_{\text{screen}, t-1} \|_2$.
   - If $\Delta < \Delta_{\text{deadzone}}$ (e.g. 0.0015): maintain previous screen position (zero jitter).
   - If $\Delta \ge \Delta_{\text{deadzone}}$: apply non-linear velocity curve:
     $$v_{\text{cur}} = \text{sensitivity} \cdot \Delta^{1.2}$$
5. **Output Action:**
   $$\text{AbstractGestureEvent.cursorMoved(screenPos)}$$

---

### Gesture 2: Two-Finger Pinch Click
```text
State: TWO_FINGER_DETECTED ➔ PINCH_CANDIDATE ➔ PINCHED ➔ RELEASE
Icon: ☝☝
```

#### Activation Preconditions:
- Exactly 2 extended/active fingers:
  - Mode A: Index + Middle finger extended.
  - Mode B: Index + Thumb active pinch.

#### Distance Metric & Hysteresis:
Let $D_{\text{pinch}}$ be the normalized distance between the two active fingertips:
$$D_{\text{pinch}} = \frac{\| P_{\text{finger1Tip}} - P_{\text{finger2Tip}} \|_2}{S_{hand}}$$

- **Pinch Thresholds:**
  - $D_{\text{start}} = 0.20$ (Trigger pinch active)
  - $D_{\text{release}} = 0.28$ (Trigger pinch released)

#### Temporal Quick-Pinch Sequence:
1. $t_0$: System enters `PINCH_CANDIDATE` when $D_{\text{pinch}} < D_{\text{start}}$.
2. $t_1$: Pinch is maintained. Record $T_{\text{pinch}} = t_{\text{curr}} - t_0$.
3. $t_2$: User releases the pinch: $D_{\text{pinch}} > D_{\text{release}}$.
4. **Click Validation Criterion:**
   $$\Delta T_{\text{pinch}} = t_2 - t_0 < T_{\text{clickMax}} \quad (\text{Default: } 350\text{ ms})$$
5. **Output Action:**
   $$\text{AbstractGestureEvent.leftClick(currentCursorPos)}$$
   Enter `COOLDOWN` ($250\text{ ms}$). Exactly one click is dispatched.

---

### Gesture 3: Two-Finger Pinch and Hold (Drag)
```text
State: PINCHED ➔ HOLD_DELAY ➔ DRAGGING ➔ PINCH_RELEASE ➔ MOUSE_UP
```

#### Temporal Sequence:
1. $t_0$: Pinch confirmed ($D_{\text{pinch}} < D_{\text{start}}$).
2. Pinch is sustained beyond click threshold:
   $$t_{\text{curr}} - t_0 \ge T_{\text{dragHoldDelay}} \quad (\text{Default: } 350\text{ ms})$$
3. Transition to `DRAGGING`:
   - Dispatch $\text{AbstractGestureEvent.leftMouseDown(currentCursorPos)}$.
   - Set internal flag `isDragging = true`.
   - Store anchor position $P_{\text{anchor}} = C_{t_0}$.
4. **While in `DRAGGING`:**
   - Movement of the pinched hand translates to relative cursor dragging:
     $$P_{\text{cursor}, t} = P_{\text{cursor}, t-1} + \kappa \cdot (C_t - C_{t-1})$$
   - Dispatch $\text{AbstractGestureEvent.leftMouseDragged(newCursorPos)}$.
5. **Release:**
   When $D_{\text{pinch}} > D_{\text{release}}$ or fingers open:
   - Dispatch $\text{AbstractGestureEvent.leftMouseUp(currentCursorPos)}$.
   - Set `isDragging = false`.
   - Transition to `COOLDOWN` ($200\text{ ms}$).

#### Critical Safety Invariant:
If at ANY point while `isDragging == true`:
- The hand is lost for $> 4$ frames,
- The camera stream is interrupted,
- An unhandled exception occurs, or
- The user presses `ESC` (Emergency Stop),

the backend **MUST IMMEDIATELY POST `.leftMouseUp`**.

---

### Gesture 4: Four-Finger Fast Swipe (Desktop Switching)
```text
State: FOUR_FINGER_CANDIDATE ➔ SWIPING ➔ TRIGGER ➔ COOLDOWN
Icon: ☝☝☝☝ (← or →)
```

#### Activation Preconditions:
- 4 extended fingers (Index, Middle, Ring, Little) detected:
  $$N_{\text{ext}} \ge 4$$
- Stability: Maintained for at least 2 consecutive frames.

#### Motion & Kinematic Equations:
Track the extended fingertip centroid $C_t = (x_t, y_t)$ over a rolling sliding window of frames $W = [t_{\text{start}}, t_{\text{now}}]$:
$$\Delta X = x_{t_{\text{now}}} - x_{t_{\text{start}}}, \quad \Delta Y = y_{t_{\text{now}}} - y_{t_{\text{start}}}$$
$$\Delta t = t_{\text{now}} - t_{\text{start}}$$
$$V_x = \frac{\Delta X}{\Delta t}, \quad V_y = \frac{\Delta Y}{\Delta t}$$

#### Swipe Acceptance Criteria:
A horizontal swipe is triggered if and only if ALL of the following hold:
1. **Horizontal Displacement:**
   $$|\Delta X| \ge \Delta X_{\text{min}} \quad (\text{Default: } 0.10 \text{ in normalized coordinates})$$
2. **Horizontal Velocity:**
   $$|V_x| \ge V_{\text{min}} \quad (\text{Default: } 0.45 \text{ norm/sec})$$
3. **Directional Dominance:**
   $$|\Delta X| \ge 2.0 \cdot |\Delta Y| \quad (\text{Ensures horizontal intent, rejecting vertical tilt})$$
4. **Duration Bounded:**
   $$\Delta t \le T_{\text{swipeMax}} \quad (\text{Default: } 300\text{ ms})$$

#### Output Action:
- If mirrored camera and $\Delta X > 0$ (hand moved right):
  $$\text{AbstractGestureEvent.switchSpace(direction: .right)}$$
  $\rightarrow$ Injects `Control + Right Arrow`.
- If mirrored camera and $\Delta X < 0$ (hand moved left):
  $$\text{AbstractGestureEvent.switchSpace(direction: .left)}$$
  $\rightarrow$ Injects `Control + Left Arrow`.
- Transition to `COOLDOWN` ($500\text{ ms}$). Clear sliding window.

---

### Gesture 5: Five-Finger Pinch ➔ Open Palm ➔ Mission Control
```text
Sequence: FIVE_FINGER_DETECTED ➔ CONTRACTING ➔ PINCH_LOCKED ➔ EXPANDING ➔ OPEN_PALM ➔ TRIGGER
Icon: 🖐 ➔ 🤏 ➔ 🖐
```

#### Detailed State Transition Pipeline:

```
[IDLE]
  │ (5 fingers detected, Spread > 0.50)
  ▼
[FIVE_FINGER_OPEN]
  │ (dSpread/dt < -0.3, Spread decreasing)
  ▼
[FIVE_FINGER_CONTRACTING]
  │ (Spread <= 0.22, fingertips converge)
  ▼
[FIVE_FINGER_PINCH_LOCKED]  <--- GESTURE ARMED (DO NOT TRIGGER HERE)
  │ (dSpread/dt > +0.3, Spread increasing)
  ▼
[FIVE_FINGER_EXPANDING]
  │ (Spread >= 0.48 within T_sequenceMax)
  ▼
[MISSION_CONTROL_TRIGGERED]
  │ (Dispatch event)
  ▼
[COOLDOWN] (600ms)
```

#### Mathematical Formulas & Thresholds:
1. **Spread Metric:**
   $$\sigma_t = \frac{1}{5 \cdot S_{hand}} \sum_{k=1}^5 \| P_{\text{tip}, k} - C_t \|_2$$
   - $\sigma_{\text{open}} \approx 0.50 - 0.75$
   - $\sigma_{\text{pinched}} \le 0.22$

2. **Step 1: Open Palm Initialization:**
   $$N_{\text{ext}} == 5, \quad \sigma_t \ge 0.50$$
   Start tracking temporal sequence timer $t_{\text{start}} = t$.

3. **Step 2: Contracting Phase:**
   $$\frac{\Delta \sigma}{\Delta t} < -0.25 \text{ sec}^{-1}$$
   Fingertips are converging toward centroid.

4. **Step 3: Pinch Lock (Armed State):**
   $$\sigma_t \le 0.22$$
   Set state = `FIVE_FINGER_PINCH_LOCKED`.
   **CRITICAL SAFETY REQUIREMENT:** Mission Control is **NOT** fired here. The pinch merely arms the trigger.

5. **Step 4: Expanding Phase:**
   From `PINCH_LOCKED`, fingertips diverge outward:
   $$\frac{\Delta \sigma}{\Delta t} > +0.25 \text{ sec}^{-1}$$

6. **Step 5: Open Palm Confirmation & Trigger:**
   $$\sigma_t \ge 0.48$$
   Verify total sequence duration:
   $$\Delta T_{\text{total}} = t_{\text{now}} - t_{\text{start}} \in [0.25\text{ s}, 1.20\text{ s}]$$

7. **Output Action:**
   $$\text{AbstractGestureEvent.triggerMissionControl}$$
   $\rightarrow$ Dispatches `Control + Up Arrow` (or launches Mission Control).
   Transition to `COOLDOWN` ($600\text{ ms}$).

---

## 4. Formal State Machine Transition Table

| Current State | Input Condition | Next State | Action Output |
| :--- | :--- | :--- | :--- |
| `IDLE` | $N_{\text{ext}} == 1$ | `ONE_FINGER_CURSOR` | none |
| `IDLE` | $N_{\text{ext}} == 2$ | `TWO_FINGER_DETECTED` | Freeze cursor |
| `IDLE` | $N_{\text{ext}} == 4$ | `FOUR_FINGER_CANDIDATE` | Freeze cursor |
| `IDLE` | $N_{\text{ext}} == 5 \land \sigma \ge 0.50$ | `FIVE_FINGER_OPEN` | Freeze cursor |
| `ONE_FINGER_CURSOR` | $N_{\text{ext}} == 1$ | `ONE_FINGER_CURSOR` | `cursorMoved(pos)` |
| `ONE_FINGER_CURSOR` | $N_{\text{ext}} \ge 2$ | `TWO_FINGER_DETECTED` | Freeze cursor |
| `ONE_FINGER_CURSOR` | $N_{\text{ext}} == 0$ | `IDLE` | none |
| `TWO_FINGER_DETECTED` | $D_{\text{pinch}} < D_{\text{start}}$ | `PINCH_CANDIDATE` | Record $t_0$ |
| `PINCH_CANDIDATE` | $D_{\text{pinch}} > D_{\text{release}} \land \Delta t < T_{\text{clickMax}}$ | `COOLDOWN` | `leftClick(pos)` |
| `PINCH_CANDIDATE` | $\Delta t \ge T_{\text{dragHoldDelay}}$ | `DRAGGING` | `leftMouseDown(pos)` |
| `DRAGGING` | $D_{\text{pinch}} < D_{\text{release}}$ | `DRAGGING` | `leftMouseDragged(pos)` |
| `DRAGGING` | $D_{\text{pinch}} \ge D_{\text{release}} \lor N_{\text{ext}} == 0$ | `COOLDOWN` | `leftMouseUp(pos)` |
| `FOUR_FINGER_CANDIDATE`| Swipe criteria satisfied | `COOLDOWN` | `switchSpace(dir)` |
| `FOUR_FINGER_CANDIDATE`| $\Delta t > T_{\text{swipeMax}}$ | `IDLE` | none |
| `FIVE_FINGER_OPEN` | $\Delta \sigma / \Delta t < -0.25$ | `FIVE_FINGER_CONTRACTING` | none |
| `FIVE_FINGER_CONTRACTING`| $\sigma \le 0.22$ | `FIVE_FINGER_PINCH_LOCKED`| Arm sequence |
| `FIVE_FINGER_PINCH_LOCKED`| $\Delta \sigma / \Delta t > +0.25$ | `FIVE_FINGER_EXPANDING` | none |
| `FIVE_FINGER_EXPANDING` | $\sigma \ge 0.48 \land \Delta T \le T_{\text{seqMax}}$ | `COOLDOWN` | `triggerMissionControl`|
| `COOLDOWN` | $t - t_{\text{cooldownStart}} \ge T_{\text{cooldown}}$ | `IDLE` | none |
| `ANY_STATE` | Hand lost $> 4$ frames | `IDLE` | Release drag if active |
| `ANY_STATE` | Emergency Stop (`ESC`) | `IDLE` | Release drag, halt tracking |
