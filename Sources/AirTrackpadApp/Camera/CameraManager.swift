import Foundation
import AVFoundation
import CoreVideo

public struct CameraDescriptor: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
}

public final class CameraManager: NSObject, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let processingQueue = DispatchQueue(label: "com.airtrackpad.camera", qos: .userInteractive)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentInput: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []
    private var wantsRunning = false

    /// nil = automatic (built-in camera first).
    public var preferredDeviceID: String?
    public var onFrame: (@Sendable (CVPixelBuffer, TimeInterval) -> Void)?
    /// Reports "<camera name> · <fps> fps" whenever the active camera changes.
    public var onCameraChanged: (@Sendable (String) -> Void)?

    public override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: nil) { [weak self] _ in
            self?.scheduleRecovery()
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let manager = self, let device = note.object as? AVCaptureDevice else { return }
            let id = device.uniqueID
            // `currentInput` belongs to the processing queue.
            manager.processingQueue.async { [weak manager] in
                guard let manager, id == manager.currentInput?.device.uniqueID else { return }
                manager.scheduleRecovery()
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Runs `work` on the frame-processing queue (serialized with frame delivery).
    public func perform(_ work: @escaping @Sendable () -> Void) {
        processingQueue.async(execute: work)
    }

    public static func availableCameras() -> [CameraDescriptor] {
        discoverySession().devices.map { CameraDescriptor(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .continuityCamera])
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    }

    public func start() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.configureSession()
            if !self.captureSession.isRunning && !self.captureSession.inputs.isEmpty {
                self.captureSession.startRunning()
            }
        }
    }

    public func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    /// Switches camera, restarting capture if it was running.
    public func selectDevice(_ id: String?) {
        processingQueue.async { [weak self] in
            guard let self, self.preferredDeviceID != id else { return }
            self.preferredDeviceID = id
            self.rebuildInput()
        }
    }

    private func scheduleRecovery() {
        processingQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.wantsRunning else { return }
            self.rebuildInput()
        }
    }

    private func rebuildInput() {
        let wasRunning = captureSession.isRunning || wantsRunning
        if captureSession.isRunning { captureSession.stopRunning() }
        captureSession.beginConfiguration()
        if let input = currentInput {
            captureSession.removeInput(input)
            currentInput = nil
        }
        captureSession.commitConfiguration()
        configureSession()
        if wasRunning && !captureSession.inputs.isEmpty {
            captureSession.startRunning()
        }
    }

    private func chooseDevice() -> AVCaptureDevice? {
        let devices = CameraManager.discoverySession().devices
        if let id = preferredDeviceID, let match = devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        // Automatic: the built-in camera. Continuity Camera appears and disappears with the
        // phone and its Center Stage crop moves the image, so never pick it implicitly.
        if let builtIn = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtIn
        }
        return devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func configureSession() {
        guard currentInput == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        guard let camera = chooseDevice(), let input = try? AVCaptureDeviceInput(device: camera) else { return }

        captureSession.beginConfiguration()
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            currentInput = input
        }

        if videoOutput == nil {
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            // The camera's native YUV format: Vision consumes it directly, no BGRA conversion.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            output.setSampleBufferDelegate(self, queue: processingQueue)
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
            videoOutput = output
        }

        let fps = applyBestFormat(to: camera)
        captureSession.commitConfiguration()

        print("🎥 CameraManager: \(camera.localizedName) @ \(Int(fps)) fps")
        onCameraChanged?("\(camera.localizedName) · \(Int(fps)) fps")
    }

    /// Picks ~720p at 30 fps and pins the frame rate. All gesture timing (debounce frames,
    /// confirmation frames) is tuned at 30 fps, and pinning keeps it consistent in low light.
    /// Returns the frame rate in use.
    private func applyBestFormat(to device: AVCaptureDevice) -> Double {
        let target = 30.0
        func supportsTarget(_ format: AVCaptureDevice.Format) -> Bool {
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= target + 0.01 && $0.maxFrameRate >= target - 0.1 }
        }
        func score(_ format: AVCaptureDevice.Format) -> (Int, Double) {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let sizePenalty = abs(Double(dims.width) - 1280) + abs(Double(dims.height) - 720)
            return (supportsTarget(format) ? 1 : 0, -sizePenalty)
        }
        let candidates = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width >= 640 && dims.width <= 1920 && dims.width >= dims.height
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return 30 }
        
        // A duration outside every supported range raises an Objective-C exception, so only use
        // values a range actually contains.
        let ranges = best.videoSupportedFrameRateRanges
        let duration: CMTime
        if ranges.contains(where: { $0.minFrameRate <= target && target <= $0.maxFrameRate }) {
            duration = CMTime(value: 1, timescale: 30)
        } else if let near = ranges.first(where: { abs($0.maxFrameRate - target) < 0.1 }) {
            duration = near.minFrameDuration // e.g. 29.97 fps
        } else if let fastest = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            duration = fastest.minFrameDuration
        } else {
            return 30
        }
        let fps = 1.0 / max(duration.seconds, 1e-3)

        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            captureSession.sessionPreset = .hd1280x720
        }

        // Center Stage re-crops the image to follow the user's face, which drags the cursor.
        if #available(macOS 12.3, *), device.formats.contains(where: { $0.isCenterStageSupported }) {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }
        return fps
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(pixelBuffer, timestamp)
    }
}
