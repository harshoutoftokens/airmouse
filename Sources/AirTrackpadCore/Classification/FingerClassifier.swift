import Foundation

/// Analyzes 21 joints of a hand observation to classify finger extension states in a rotation-invariant manner.
public enum FingerClassifier {
    
    public static func classifyFingers(in hand: HandObservation) -> [Finger: FingerState] {
        var states: [Finger: FingerState] = [:]
        
        guard let wrist = hand.landmark(.wrist) else {
            for f in Finger.allCases { states[f] = .uncertain }
            return states
        }
        
        let palmScale = hand.palmScale
        
        // 1. Thumb
        states[.thumb] = classifyThumb(hand: hand, wrist: wrist, palmScale: palmScale)
        
        // 2. Index
        states[.index] = classifyFinger(
            tip: hand.landmark(.indexTip),
            pip: hand.landmark(.indexPIP),
            mcp: hand.landmark(.indexMCP),
            wrist: wrist
        )
        
        // 3. Middle
        states[.middle] = classifyFinger(
            tip: hand.landmark(.middleTip),
            pip: hand.landmark(.middlePIP),
            mcp: hand.landmark(.middleMCP),
            wrist: wrist
        )
        
        // 4. Ring
        states[.ring] = classifyFinger(
            tip: hand.landmark(.ringTip),
            pip: hand.landmark(.ringPIP),
            mcp: hand.landmark(.ringMCP),
            wrist: wrist
        )
        
        // 5. Little
        states[.little] = classifyFinger(
            tip: hand.landmark(.littleTip),
            pip: hand.landmark(.littlePIP),
            mcp: hand.landmark(.littleMCP),
            wrist: wrist
        )
        
        return states
    }
    
    private static func classifyFinger(
        tip: Landmark?,
        pip: Landmark?,
        mcp: Landmark?,
        wrist: Landmark
    ) -> FingerState {
        guard let tip = tip, let pip = pip, let mcp = mcp,
              tip.confidence > 0.3, pip.confidence > 0.3, mcp.confidence > 0.3 else {
            return .uncertain
        }
        
        // Metric 1: Distance from wrist
        let distTipWrist = Geometry.distance(tip, wrist)
        let distPipWrist = Geometry.distance(pip, wrist)
        
        let distTipMcp = Geometry.distance(tip, mcp)
        let distPipMcp = Geometry.distance(pip, mcp)
        
        // Metric 2: Joint alignment
        let vProx = Vector2D(from: mcp, to: pip)
        let vDist = Vector2D(from: pip, to: tip)
        let alignment = vProx.cosine(with: vDist)
        
        // An extended finger has Tip significantly further from wrist than PIP, and near-linear alignment
        if distTipWrist > distPipWrist * 1.25 && distTipMcp > distPipMcp * 1.5 && alignment > 0.40 {
            return .extended
        } else if distTipWrist < distPipWrist * 1.10 || alignment < 0.0 {
            return .folded
        } else {
            return .partiallyExtended
        }
    }
    
    private static func classifyThumb(
        hand: HandObservation,
        wrist: Landmark,
        palmScale: Double
    ) -> FingerState {
        guard let tip = hand.landmark(.thumbTip),
              let ip = hand.landmark(.thumbIP),
              let mp = hand.landmark(.thumbMP),
              tip.confidence > 0.3, ip.confidence > 0.3 else {
            return .uncertain
        }
        
        // Use distance from Pinky MCP to evaluate thumb opening
        let pinkyRef = hand.landmark(.littleMCP) ?? wrist
        let distToPinky = Geometry.distance(tip, pinkyRef)
        let normDist = distToPinky / max(palmScale, 0.02)
        
        let vProx = Vector2D(from: mp, to: ip)
        let vDist = Vector2D(from: ip, to: tip)
        let alignment = vProx.cosine(with: vDist)
        
        if normDist > 0.85 && alignment > 0.3 {
            return .extended
        } else if normDist < 0.65 {
            return .folded
        } else {
            return .partiallyExtended
        }
    }
    
    public static func extractMetrics(from hand: HandObservation) -> HandMetrics {
        let fingerStates = classifyFingers(in: hand)
        var extendedCount = 0
        var extendedTips: [Landmark] = []
        
        for (f, state) in fingerStates {
            if state == .extended {
                extendedCount += 1
                switch f {
                case .thumb: if let pt = hand.landmark(.thumbTip) { extendedTips.append(pt) }
                case .index: if let pt = hand.landmark(.indexTip) { extendedTips.append(pt) }
                case .middle: if let pt = hand.landmark(.middleTip) { extendedTips.append(pt) }
                case .ring: if let pt = hand.landmark(.ringTip) { extendedTips.append(pt) }
                case .little: if let pt = hand.landmark(.littleTip) { extendedTips.append(pt) }
                }
            }
        }
        
        let scale = hand.palmScale
        let palmCenter = hand.landmark(.middleMCP) ?? hand.landmark(.wrist) ?? Geometry.centroid(of: extendedTips)
        let centroid = palmCenter
        
        let allTips: [Landmark] = [
            hand.landmark(.thumbTip),
            hand.landmark(.indexTip),
            hand.landmark(.middleTip),
            hand.landmark(.ringTip),
            hand.landmark(.littleTip)
        ].compactMap { $0 }
        
        let spread: Double
        if allTips.count >= 4 {
            spread = Geometry.spread(of: allTips, palmScale: scale)
        } else if !extendedTips.isEmpty {
            spread = Geometry.spread(of: extendedTips, palmScale: scale)
        } else {
            spread = 0.0
        }
        
        // Pinch distance: evaluate both Index-to-Thumb and Index-to-Middle fingertips
        var pinchDist = 1.0
        if let indexTip = hand.landmark(.indexTip) {
            var distances: [Double] = []
            if let thumbTip = hand.landmark(.thumbTip), thumbTip.confidence > 0.3 {
                distances.append(Geometry.normalizedDistance(indexTip, thumbTip, palmScale: scale))
            }
            if let middleTip = hand.landmark(.middleTip), middleTip.confidence > 0.3 {
                distances.append(Geometry.normalizedDistance(indexTip, middleTip, palmScale: scale))
            }
            if let minD = distances.min() {
                pinchDist = minD
            }
        }
        
        return HandMetrics(
            timestamp: hand.timestamp,
            extendedFingerCount: extendedCount,
            fingerStates: fingerStates,
            centroid: centroid,
            spread: spread,
            pinchDistance: pinchDist,
            handScale: scale
        )
    }
}
