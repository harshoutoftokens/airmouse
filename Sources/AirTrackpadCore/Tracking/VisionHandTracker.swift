import Foundation
import CoreVideo
import Vision

public final class VisionHandTracker: HandTrackingProvider, @unchecked Sendable {
    public var maximumHandCount: Int
    public var mirrorsHorizontal: Bool
    /// Hands Vision is less sure about than this produce unreliable landmarks; skip them.
    public var minimumHandConfidence: Float = 0.3
    
    private let lock = NSLock()
    /// Reused across frames (Vision recommends keeping requests alive).
    private let request = VNDetectHumanHandPoseRequest()
    
    public init(maximumHandCount: Int = 2, mirrorsHorizontal: Bool = true) {
        self.maximumHandCount = maximumHandCount
        self.mirrorsHorizontal = mirrorsHorizontal
    }
    
    public func reset() {
        // Stateless between frames.
    }
    
    public func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [HandObservation] {
        lock.lock()
        defer { lock.unlock() }
        request.maximumHandCount = maximumHandCount
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        
        guard let observations = request.results, !observations.isEmpty else {
            return []
        }
        
        var handObservations: [HandObservation] = []
        
        for obs in observations where obs.confidence >= minimumHandConfidence {
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
            
            let synthesized = synthesizeMissingTips(in: &joints)
            
            let hand = HandObservation(
                timestamp: timestamp,
                chirality: chirality,
                confidence: obs.confidence,
                joints: joints,
                synthesizedJoints: synthesized
            )
            handObservations.append(hand)
        }
        
        return handObservations
    }
    
    /// Extrapolates missing or occluded fingertips when fingers reach the top or edge of the camera frame
    @discardableResult
    private func synthesizeMissingTips(in joints: inout [JointName: Landmark]) -> Set<JointName> {
        var synthesized: Set<JointName> = []
        // 1. Index Tip
        let indexTipValid = (joints[.indexTip]?.confidence ?? 0.0) >= 0.35
        if !indexTipValid {
            if let dip = joints[.indexDIP], let pip = joints[.indexPIP],
               dip.confidence > 0.3, pip.confidence > 0.3 {
                let dx = dip.x - pip.x
                let dy = dip.y - pip.y
                let extTipX = dip.x + dx * 0.75
                let extTipY = dip.y + dy * 0.75
                let conf = min(dip.confidence, pip.confidence) * 0.85
                joints[.indexTip] = Landmark(x: extTipX, y: extTipY, z: 0.0, confidence: conf)
                synthesized.insert(.indexTip)
            } else if let pip = joints[.indexPIP], let mcp = joints[.indexMCP],
                      pip.confidence > 0.3, mcp.confidence > 0.3 {
                let dx = pip.x - mcp.x
                let dy = pip.y - mcp.y
                let extTipX = pip.x + dx * 1.2
                let extTipY = pip.y + dy * 1.2
                let conf = min(pip.confidence, mcp.confidence) * 0.75
                joints[.indexTip] = Landmark(x: extTipX, y: extTipY, z: 0.0, confidence: conf)
                synthesized.insert(.indexTip)
            }
        }
        
        // 2. Middle Tip
        let middleTipValid = (joints[.middleTip]?.confidence ?? 0.0) >= 0.35
        if !middleTipValid {
            if let dip = joints[.middleDIP], let pip = joints[.middlePIP],
               dip.confidence > 0.3, pip.confidence > 0.3 {
                let dx = dip.x - pip.x
                let dy = dip.y - pip.y
                let extTipX = dip.x + dx * 0.75
                let extTipY = dip.y + dy * 0.75
                let conf = min(dip.confidence, pip.confidence) * 0.85
                joints[.middleTip] = Landmark(x: extTipX, y: extTipY, z: 0.0, confidence: conf)
                synthesized.insert(.middleTip)
            } else if let pip = joints[.middlePIP], let mcp = joints[.middleMCP],
                      pip.confidence > 0.3, mcp.confidence > 0.3 {
                let dx = pip.x - mcp.x
                let dy = pip.y - mcp.y
                let extTipX = pip.x + dx * 1.2
                let extTipY = pip.y + dy * 1.2
                let conf = min(pip.confidence, mcp.confidence) * 0.75
                joints[.middleTip] = Landmark(x: extTipX, y: extTipY, z: 0.0, confidence: conf)
                synthesized.insert(.middleTip)
            }
        }
        
        // 3. Thumb Tip
        let thumbTipValid = (joints[.thumbTip]?.confidence ?? 0.0) >= 0.35
        if !thumbTipValid {
            if let ip = joints[.thumbIP], let mp = joints[.thumbMP],
               ip.confidence > 0.3, mp.confidence > 0.3 {
                let dx = ip.x - mp.x
                let dy = ip.y - mp.y
                let extTipX = ip.x + dx * 0.8
                let extTipY = ip.y + dy * 0.8
                let conf = min(ip.confidence, mp.confidence) * 0.85
                joints[.thumbTip] = Landmark(x: extTipX, y: extTipY, z: 0.0, confidence: conf)
                synthesized.insert(.thumbTip)
            }
        }
        return synthesized
    }
}
