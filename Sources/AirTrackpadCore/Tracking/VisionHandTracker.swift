import Foundation
import CoreVideo
import Vision

public final class VisionHandTracker: HandTrackingProvider, @unchecked Sendable {
    public var maximumHandCount: Int
    public var mirrorsHorizontal: Bool
    
    private let lock = NSLock()
    
    public init(maximumHandCount: Int = 2, mirrorsHorizontal: Bool = true) {
        self.maximumHandCount = maximumHandCount
        self.mirrorsHorizontal = mirrorsHorizontal
    }
    
    public func reset() {
        // Stateless between frames; lock ensures no race during reconfiguration
    }
    
    public func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [HandObservation] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = maximumHandCount
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        
        guard let observations = request.results, !observations.isEmpty else {
            return []
        }
        
        var handObservations: [HandObservation] = []
        
        for obs in observations {
            let chirality: Chirality
            switch obs.chirality {
            case .left:
                chirality = mirrorsHorizontal ? .right : .left
            case .right:
                chirality = mirrorsHorizontal ? .left : .right
            default:
                chirality = .unknown
            }
            
            var joints: [JointName: Landmark] = [:]
            
            let mapping: [(JointName, VNHumanHandPoseObservation.JointName)] = [
                (.wrist, .wrist),
                (.thumbCMC, .thumbCMC),
                (.thumbMP, .thumbMP),
                (.thumbIP, .thumbIP),
                (.thumbTip, .thumbTip),
                (.indexMCP, .indexMCP),
                (.indexPIP, .indexPIP),
                (.indexDIP, .indexDIP),
                (.indexTip, .indexTip),
                (.middleMCP, .middleMCP),
                (.middlePIP, .middlePIP),
                (.middleDIP, .middleDIP),
                (.middleTip, .middleTip),
                (.ringMCP, .ringMCP),
                (.ringPIP, .ringPIP),
                (.ringDIP, .ringDIP),
                (.ringTip, .ringTip),
                (.littleMCP, .littleMCP),
                (.littlePIP, .littlePIP),
                (.littleDIP, .littleDIP),
                (.littleTip, .littleTip)
            ]
            
            for (jointName, vnJoint) in mapping {
                if let pt = try? obs.recognizedPoint(vnJoint) {
                    let rawX = Double(pt.location.x)
                    let finalX = mirrorsHorizontal ? (1.0 - rawX) : rawX
                    let finalY = Double(pt.location.y)
                    
                    joints[jointName] = Landmark(
                        x: finalX,
                        y: finalY,
                        z: 0.0,
                        confidence: pt.confidence
                    )
                }
            }
            
            let hand = HandObservation(
                timestamp: timestamp,
                chirality: chirality,
                confidence: obs.confidence,
                joints: joints
            )
            handObservations.append(hand)
        }
        
        return handObservations
    }
}
