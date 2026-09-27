# AirTrackpad: Architecture & Technical Design Document

**Document Version:** 1.0.0  
**Target Architecture:** Apple Silicon Mac (macOS 13+ through 26/27+)  
**Language:** Swift 6.x (Modern Swift Concurrency, Sendable protocols, Value types)  

---

## 1. System Philosophy & Design Principles

AirTrackpad is built from first principles as a **deterministic, low-latency virtual input system**. It is explicitly engineered to avoid common pitfalls in AI webcam mice:

1. **Strict Separation of Concerns:** Computer vision outputs normalized geometry; the gesture state machine processes pure temporal metrics; an action router dispatches abstract events to a replaceable OS backend.
2. **Zero Direct Coupling to CGEvent in Recognition:** The gesture engine has zero dependency on CoreGraphics or macOS event loops. It produces pure, platform-independent `AbstractGestureEvent` values.
3. **Deterministic Testability:** The entire gesture engine can run headless against recorded JSON landmark streams in unit tests.
4. **Safety as a First-Class Invariant:** Synthetic mouse-down states are guarded by a fail-safe supervisor (`SafetyController`) that guarantees `.leftMouseUp` dispatch under all error, disconnect, or timeout conditions.
5. **Adaptive Signal Filtering:** Dual-pipeline filtering—using the **One Euro Filter** for cursor stability and minimal-latency unfiltered or light EMA metrics for gesture kinematics.

---

## 2. End-to-End Data Pipeline

```
┌─────────────────────────┐
│     AVCaptureSession    │  60 FPS / 1280x720 video feed
└────────────┬────────────┘
             │ (CMSampleBuffer)
             ▼
┌─────────────────────────┐
│      CameraManager      │  Queue: com.airtrackpad.camera (.userInteractive)
│  (discards late frames) │  Strict freshness: drops stale frames if busy
└────────────┬────────────┘
             │ (CVPixelBuffer)
             ▼
┌─────────────────────────┐
│  HandTrackingProvider   │  Protocol: HandTrackingProvider
│   (VisionHandTracker)   │  Executes VNDetectHumanHandPoseRequest on ANE/Metal
└────────────┬────────────┘
             │ (HandObservation / 21 Landmarks)
             ▼
┌─────────────────────────┐
│ Landmark Normalization  │  Mirrors X, converts to normalized space [0, 1]
│   & Hand Scale Normal   │  Calculates palm scale S_hand = dist(wrist, middleMCP)
└────────────┬────────────┘
             │ (NormalizedHandFrame)
             ▼
┌─────────────────────────┐
│   Signal Filter Layer   │  Cursor: OneEuroFilter (minCutoff=1.0Hz, beta=0.007)
│   (Dual Filter Path)    │  Gestures: Minimal smoothing / direct kinematics
└────────────┬────────────┘
             │ (FilteredHandFrame)
             ▼
┌─────────────────────────┐
│ Finger Classifier &     │  Rotation-invariant 3D joint vector angles &
│ Geometric Analysis      │  distance ratios (Extended, Folded, Uncertain)
└────────────┬────────────┘
             │ (FingerStates, ExtCount, Centroid, Spread, PinchDist)
             ▼
┌─────────────────────────┐
│  Gesture State Machine  │  Deterministic temporal state machine with
│  & Priority Resolver    │  hysteresis, timers, and priority preemption
└────────────┬────────────┘
             │ (AbstractGestureEvent stream)
             ▼
┌─────────────────────────┐
│  ActionRouter & Safety  │  SafetyController watchdog for stuck mouse buttons,
│     Controller          │  Emergency stop (ESC), permission checking
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│   macOS Input Backend   │  Protocol: InputBackendProtocol
│  (CGEventInputBackend)  │  CGWarpMouseCursorPosition, CGEvent mouse/keyboard
└─────────────────────────┘
```

---

## 3. Module Decomposition

### Module 1: `Core/Models`
Pure Swift value types representing hand landmarks, frames, metrics, and abstract events.
- `struct Landmark`: Normalized coordinates $(x, y, z)$ and confidence score $\in [0, 1]$.
- `enum JointName`: 21 human hand joints (Wrist, Thumb, Index, Middle, Ring, Little joints).
- `enum Chirality`: `.left`, `.right`, `.unknown`.
- `struct HandObservation`: Chirality, 21 joints, timestamp, confidence.
- `struct HandMetrics`:
  - `extendedFingerCount`: $0 \dots 5$.
  - `fingerStates`: `[Finger: FingerState]`.
  - `pinchDistance`: Normalized distance between active fingertips.
  - `centroid`: Centroid of active fingertips.
  - `spread`: Average distance of fingertips from centroid divided by $S_{hand}$.
  - `handScale`: Palm size in normalized units.
- `enum AbstractGestureEvent`:
  - `.cursorMoved(to: CGPoint)`
  - `.leftClick(at: CGPoint)`
  - `.leftMouseDown(at: CGPoint)`
  - `.leftMouseDragged(to: CGPoint)`
  - `.leftMouseUp(at: CGPoint)`
  - `.switchSpace(direction: SwipeDirection)`
  - `.triggerMissionControl`
  - `.trackingPaused`
  - `.trackingResumed`

### Module 2: `HandTracking`
- `protocol HandTrackingProvider: Sendable`:
  ```swift
  protocol HandTrackingProvider: AnyObject {
      func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async throws -> [HandObservation]
      func reset()
  }
  ```
- `class VisionHandTracker: HandTrackingProvider`:
  Implements hand pose detection using Apple's `VNDetectHumanHandPoseRequest`.
- `class MediaPipeHandTracker: HandTrackingProvider`:
  Stub/benchmark provider for future evaluation.

### Module 3: `Filtering`
- `protocol SignalFilter`:
  ```swift
  protocol SignalFilter {
      mutating func filter(point: CGPoint, timestamp: TimeInterval) -> CGPoint
      mutating func reset()
  }
  ```
- `struct OneEuroFilter: SignalFilter`:
  Casiez et al. 1€ filter with configurable `minCutoff`, `beta`, and `dCutoff`.
- `struct ExponentialMovingAverageFilter: SignalFilter`:
  Lightweight EMA filter.
- `struct KalmanFilter2D: SignalFilter`:
  2D constant-velocity state-space filter for comparative benchmarking.

### Module 4: `FingerClassification`
- `struct FingerClassifier`:
  Pure mathematical module. Evaluates joint vectors:
  $$\vec{u} = P_{\text{pip}} - P_{\text{mcp}}, \quad \vec{v} = P_{\text{tip}} - P_{\text{pip}}$$
  Computes extension metrics and angle invariants. Returns `FingerState` for each finger without relying on screen $Y$ coordinates.

### Module 5: `GestureEngine`
- `class GestureStateMachine`:
  Implements the state machine defined in `docs/GESTURES.md`.
  - Tracks state durations, velocity vectors, and hysteresis thresholds.
  - Preempts cursor tracking whenever $N_{\text{ext}} \ge 2$.
  - Dispatches `AbstractGestureEvent` to registered listeners.

### Module 6: `InputBackend`
- `protocol InputBackendProtocol: AnyObject`:
  ```swift
  protocol InputBackendProtocol {
      func moveCursor(to screenPoint: CGPoint)
      func mouseClick(at screenPoint: CGPoint)
      func mouseDown(at screenPoint: CGPoint)
      func mouseDragged(to screenPoint: CGPoint)
      func mouseUp(at screenPoint: CGPoint)
      func switchSpace(direction: SwipeDirection)
      func triggerMissionControl()
  }
  ```
- `class CGEventInputBackend: InputBackendProtocol`:
  Standard macOS implementation using `CGWarpMouseCursorPosition`, `CGEvent`, and `NSWorkspace`.
- `class MockInputBackend: InputBackendProtocol`:
  In-memory recording backend for automated unit tests.

### Module 7: `SafetyController`
- Supervises all synthetic mouse button states.
- Ensures that if `mouseDown` is active and any of the following occur:
  1. Hand tracking lost for $> 4$ frames (~70ms),
  2. Camera disconnected,
  3. App termination or deactivation,
  4. Emergency Stop key (`ESC`) pressed,
  a synthetic `.leftMouseUp` is dispatched immediately.

### Module 8: `CoordinateMapping & Calibration`
- `struct ScreenMapper`:
  Maps normalized camera interaction box $[\text{minX}, \text{maxX}] \times [\text{minY}, \text{maxY}]$ to macOS multi-monitor screen bounds (`NSScreen` / `CGDirectDisplayID`).
  Handles display resolution, Retina scaling, and mirror transform.

### Module 9: `Recorder & Replay`
- `class GestureRecorder`:
  Records timestamped `[HandObservation]` streams to formatted JSON files in `recordings/`.
- `class GestureReplayEngine`:
  Reads JSON recording files and feeds frames into the `GestureStateMachine` at exact historical or configurable speeds, enabling deterministic algorithmic verification without a live camera.

### Module 10: `UI & Developer Tooling`
- `AirTrackpadApp`: Menu bar extra application (`NSStatusItem` / SwiftUI `MenuBarExtra`).
- `DebugHUDView`: Floating HUD window showing live camera feed, joint skeleton, finger states, gesture state badge, velocity graphs, FPS, and latency metrics.
- `SettingsView`: Full configuration panel for sensitivities, thresholds, camera selection, and calibration wizard.

---

## 4. Testing & Verification Strategy

The modular design enables 100% deterministic testing without physical hardware:

1. **Unit Tests (`AirTrackpadTests`):**
   - **Math & Geometry:** Test distance calculation, scale normalization, centroid, and spread formulas.
   - **Finger Classifier:** Test hand configurations (flat palm, fist, index pointing, peace sign, rotation by 45°/90°).
   - **Filter Accuracy:** Benchmark OneEuro vs EMA for step response and jitter reduction.
   - **State Machine Transitions:** Feed synthetic sequences to verify:
     - 1-finger cursor -> 2-finger freeze -> pinch -> release (click).
     - Pinch hold > 350ms -> drag start -> drag motion -> drag release.
     - 4-finger fast swipe -> space switch (left/right).
     - 5-finger convergence -> pinch lock -> divergence -> Mission Control.
     - Priority preemption (5-finger interrupts cursor).
   - **Safety Invariant:** Feed hand disappearance during drag and assert that `mouseUp` was dispatched.
2. **Replay Tests:**
   - Execute saved gesture JSON recordings through `GestureReplayEngine` and assert expected action events.

---

## 5. Implementation Roadmap (Phases 1 – 12)

- **Phase 1: Project Skeleton & Foundation**
  - Swift package / Xcode project structure, Swift 6 concurrency, camera capture, Vision hand pose wrapper, basic debug skeleton view.
- **Phase 2: One-Finger Cursor Navigation**
  - Index fingertip tracking, coordinate mapping, One Euro filtering, dead-zone, sensitivity & acceleration.
- **Phase 3: Multi-Finger Detection & Cursor Freeze**
  - Finger classification, 2-finger detection, instant cursor pause on multi-touch.
- **Phase 4: Two-Finger Pinch Click**
  - Normalized pinch distance, hysteresis thresholds, quick-pinch timing, debounced single left click.
- **Phase 5: Pinch-and-Hold Drag & Safety Controller**
  - Drag delay timer, mouse down, drag coordinates, mouse up, safety timeout watchdog.
- **Phase 6: Four-Finger Fast Swipe & Spaces Switching**
  - 4-finger kinematic velocity, horizontal dominance check, Spaces navigation dispatch (`Control + Arrows`).
- **Phase 7: Five-Finger Pinch ➔ Open Palm ➔ Mission Control**
  - Spread calculation, 5-stage temporal state sequence, armed lock, Mission Control dispatch.
- **Phase 8: Filtering & Coordinate Optimization**
  - Calibration wizard, interaction area cropping, Retina multi-monitor coordinate math.
- **Phase 9: Gesture Recording & Deterministic Replay Engine**
  - JSON serialization of landmark streams, mock replay runner, automated validation tests.
- **Phase 10: Settings & User Preferences**
  - Persistent user preferences via `UserDefaults`, threshold sliders, shortcut bindings.
- **Phase 11: Developer Debug HUD & Diagnostics**
  - Live skeleton rendering, real-time FPS counter, pipeline latency metrics, state overlay.
- **Phase 12: Menu Bar Packaging, Permissions & Polish**
  - Menu bar extra integration, Camera/Accessibility permission request UI, Emergency Stop hotkey (`ESC`).
