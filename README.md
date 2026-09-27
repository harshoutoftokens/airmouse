# AirTrackpad

> **Camera-Based Gesture Control System for macOS (Apple Silicon)**  
> Low-latency, deterministic virtual gesture input with Apple Vision, Adaptive One Euro Filtering, and a formal Temporal Gesture State Machine.

---

## Overview

**AirTrackpad** turns your Mac's built-in FaceTime HD camera or external webcam into a responsive trackpad. It tracks 21 anatomical hand landmarks and transforms hand kinematics into native macOS pointer navigation, clicks, window dragging, virtual desktop (Spaces) switching, and Mission Control.

Built **from scratch** in Swift 6 for Apple Silicon Macs, AirTrackpad is designed as an input device—prioritizing low latency, jitter suppression, and deterministic behavior.

---

## Core Gesture Language

| Gesture | Movement | Action | State Machine Transition |
| :--- | :--- | :--- | :--- |
| **1-Finger Cursor** | ☝ Point with Index finger | Cursor follows fingertip with One Euro filtering & acceleration | `IDLE ➔ ONE_FINGER_CURSOR` |
| **Multi-Finger Pause**| ☝☝ Show 2 or more fingers | **Cursor instantly freezes** in place | `ONE_FINGER ➔ TWO_FINGER_PAUSED` |
| **2-Finger Quick Pinch**| 🤏 Quick pinch & release ($< 350\text{ ms}$) | **Left Click** (with hysteresis & debounce) | `PINCH_CANDIDATE ➔ LEFT_CLICK` |
| **2-Finger Pinch & Hold**| ✊ Pinch and hold ($\ge 350\text{ ms}$) | **Mouse Down & Drag** (window/file drag) | `PINCH_CANDIDATE ➔ DRAGGING` |
| **4-Finger Fast Swipe**| 🖐 Rapid horizontal swipe (← / →) | **Switch Spaces / Virtual Desktops** | `FOUR_FINGER_SWIPE ➔ SPACE_NEXT / PREV` |
| **5-Finger Pinch ➔ Open**| 🖐 ➔ 🤏 ➔ 🖐 (Pinch then Open Palm) | **Mission Control** | `OPEN ➔ PINCH_ARMED ➔ EXPAND ➔ MISSION_CONTROL` |

---

## Architecture & Data Pipeline

```
[AVCaptureSession (60 FPS)]
         │
         ▼
[CameraManager (Always discards late frames)]
         │
         ▼ (CVPixelBuffer)
[HandTrackingProvider (VisionHandTracker - Apple Silicon Neural Engine)]
         │
         ▼ (Raw Normalized 21 Landmarks)
[LandmarkNormalizer & Inversion Layer]
         │
         ▼ (NormalizedHandFrame)
[SignalFilterLayer (OneEuroFilter for Cursor / Direct Kinematics for Gestures)]
         │
         ▼ (FilteredHandFrame)
[FingerClassifier (Rotation-invariant vector angles & joint ratios)]
         │
         ▼ (ExtendedFingerCount, FingerStates, Centroid, Spread)
[GestureStateMachine (Temporal State Machine with Hysteresis & Priority)]
         │
         ▼ (AbstractGestureEvent stream)
[ActionRouter & SafetyController Watchdog (Emergency Stop ESC / Auto MouseUp)]
         │
         ▼
[macOSInputBackend (CGWarpMouseCursorPosition, Quartz CGEvent, NSWorkspace)]
```

---

## Technical Highlights

- **Hardware-Accelerated Tracking:** Powered by Apple Vision `VNDetectHumanHandPoseRequest`, executing on Apple Silicon Neural Engine / Metal in ~3–7 ms per frame at 60 FPS.
- **Adaptive One Euro Filtering:** Eliminates micro-tremor jitter when holding still while preserving instantaneous response during rapid movements.
- **Fail-Safe Safety Supervisor:** `ActionRouter` and `SafetyController` guarantee synthetic mouse buttons are never left stuck down if hand tracking drops or the app terminates. Emergency Stop is bound to the `ESC` key.
- **Deterministic Headless Replay Engine:** Test and iterate on gesture recognition algorithms offline using serialized JSON recordings in `recordings/` without requiring a physical camera.
- **Menu Bar Application & Live Debug HUD:** Floating real-time HUD displaying camera feed, color-coded skeleton overlay, active gesture state, FPS, and latency metrics.

---

## Building and Running

### Prerequisites
- macOS 13.0+ on Apple Silicon (M1/M2/M3/M4)
- Xcode 16+ or Command Line Tools with Swift 6.0+

### Build & Package App Bundle
```bash
make bundle
```
This compiles the executable and creates the standalone `AirTrackpad.app` bundle with required `Info.plist` entitlements.

### Run Unit Tests
```bash
make test
```
Executes all 24 unit tests covering vector geometry, rotation-invariant finger classification, One Euro filtering, coordinate mapping, gesture state transitions, and deterministic JSON replay.

### Launch Application
```bash
make run
```
Launches `AirTrackpad.app`. Access the app from the macOS Menu Bar (🖐 icon) or press `⌘D` to open the Live Debug HUD and `⌘,` for Settings.

---

## Documentation

- [docs/RESEARCH.md](file:///Users/harshrathod/Desktop/airmouse/docs/RESEARCH.md): Technical research, API comparisons (Vision vs MediaPipe), Quartz event services, and open-source analysis.
- [docs/GESTURES.md](file:///Users/harshrathod/Desktop/airmouse/docs/GESTURES.md): Mathematical formulations for palm scale normalization, spread metrics, and temporal state transitions.
- [docs/ARCHITECTURE.md](file:///Users/harshrathod/Desktop/airmouse/docs/ARCHITECTURE.md): Comprehensive system architecture, module boundaries, and design specifications.
