import Foundation
import AVFoundation
import CoreVideo

public final class CameraManager: NSObject, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let processingQueue = DispatchQueue(label: "com.airtrackpad.camera", qos: .userInteractive)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var isProcessing = false
    
    public var targetFPS: Int32 = 60
    public var onFrame: (@Sendable (CVPixelBuffer, TimeInterval) -> Void)?
    
    public override init() {
        super.init()
    }
    
    public func start() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.configureSession()
                self.captureSession.startRunning()
            }
        }
    }
    
    public func stop() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }
    
    public func updateFPS(_ fps: Int32) {
        targetFPS = fps
        processingQueue.async { [weak self] in
            guard let self = self,
                  let output = self.videoOutput,
                  let connection = output.connection(with: .video) else { return }
            
            let frameDuration = CMTime(value: 1, timescale: fps)
            if connection.isVideoMinFrameDurationSupported {
                connection.videoMinFrameDuration = frameDuration
            }
            if connection.isVideoMaxFrameDurationSupported {
                connection.videoMaxFrameDuration = frameDuration
            }
        }
    }
    
    private func configureSession() {
        guard captureSession.inputs.isEmpty else { return }
        
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720
        
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            captureSession.commitConfiguration()
            return
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: processingQueue)
        
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }
        self.videoOutput = output
        
        if let connection = output.connection(with: .video) {
            let frameDuration = CMTime(value: 1, timescale: targetFPS)
            if connection.isVideoMinFrameDurationSupported {
                connection.videoMinFrameDuration = frameDuration
            }
            if connection.isVideoMaxFrameDurationSupported {
                connection.videoMaxFrameDuration = frameDuration
            }
        }
        
        captureSession.commitConfiguration()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Discard frame immediately if previous frame is still being processed
        guard !isProcessing else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        
        isProcessing = true
        onFrame?(pixelBuffer, timestamp)
        isProcessing = false
    }
}
