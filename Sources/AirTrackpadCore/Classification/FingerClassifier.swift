import Foundation

/// Analyzes 21 joints of a hand observation to classify finger extension states in a rotation-invariant manner.
public enum FingerClassifier {

    public static func classifyFingers(in hand: HandObservation) -> [Finger: FingerState] {
        var states: [Finger: FingerState] = [:]

        guard let wrist = hand.landmark(.wrist) else {
            for f in Finger.allCases { states[f] = .uncertain }
            return states
        }

        let scale = hand.robustScale

        // 1. Thumb
        states[.thumb] = classifyThumb(hand: hand, wrist: wrist, palmScale: scale)

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
        if distTipWrist > distPipWrist * 1.08 && distTipMcp > distPipMcp * 1.15 && alignment > 0.15 {
            return .extended
        } else if distTipWrist < distPipWrist * 1.02 || alignment < -0.10 {
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
        for (_, state) in fingerStates where state == .extended {
            extendedCount += 1
        }

        let scale = hand.robustScale

        // Palm center: averaging five well-tracked joints cuts landmark noise by ~√5 and is
        // unaffected by what the fingers are doing.
        let palmCenter = hand.weightedCenter([
            (.wrist, 1.0), (.indexMCP, 1.0), (.middleMCP, 1.0), (.ringMCP, 1.0), (.littleMCP, 1.0)
        ]) ?? hand.landmark(.middleMCP) ?? hand.landmark(.wrist) ?? Landmark(x: 0.5, y: 0.5, confidence: 0)

        // Cursor anchor: mostly the index + middle knuckles, with a little of the index PIP
        // (after Ultraleap TouchFree's "index stable" point). Knuckles don't move when the
        // fingertip curls into a pinch or uncurls out of a fist, so clicks and clutching
        // don't drag the pointer.
        let cursorAnchor = hand.weightedCenter([
            (.indexMCP, 0.50), (.middleMCP, 0.35), (.indexPIP, 0.15)
        ]) ?? palmCenter

        let allTips: [Landmark] = [
            hand.landmark(.thumbTip),
            hand.landmark(.indexTip),
            hand.landmark(.middleTip),
            hand.landmark(.ringTip),
            hand.landmark(.littleTip)
        ].compactMap { $0 }

        let spread: Double = allTips.count >= 4 ? Geometry.spread(of: allTips, palmScale: scale) : 0.0

        // Pinch distances are thumb-based only. (Index↔middle proximity is the ✌️ scroll pose,
        // not a click.) Only observed fingertips count: an extrapolated or low-confidence tip
        // (typically the index tip hidden behind the thumb mid-pinch) would read as "open".
        let thumbTip = hand.observed(.thumbTip)
        var pinchDist = 1.0
        var pinchTracked = false
        if let thumbTip, let indexTip = hand.observed(.indexTip) {
            pinchDist = Geometry.normalizedDistance(indexTip, thumbTip, palmScale: scale)
            pinchTracked = true
        }
        var middlePinchDist = 1.0
        var middlePinchTracked = false
        if let thumbTip, let middleTip = hand.observed(.middleTip) {
            middlePinchDist = Geometry.normalizedDistance(middleTip, thumbTip, palmScale: scale)
            middlePinchTracked = true
        }

        var reach: [Finger: Double] = [:]
        let reachPairs: [(Finger, JointName, JointName)] = [
            (.thumb, .thumbTip, .indexMCP),
            (.index, .indexTip, .indexMCP),
            (.middle, .middleTip, .middleMCP),
            (.ring, .ringTip, .ringMCP),
            (.little, .littleTip, .littleMCP)
        ]
        for (finger, tipJoint, baseJoint) in reachPairs {
            if let tip = hand.trusted(tipJoint), let base = hand.trusted(baseJoint) {
                reach[finger] = Geometry.normalizedDistance(tip, base, palmScale: scale)
            } else {
                reach[finger] = HandMetrics.estimatedReach(for: fingerStates[finger] ?? .uncertain)
            }
        }

        return HandMetrics(
            timestamp: hand.timestamp,
            extendedFingerCount: extendedCount,
            fingerStates: fingerStates,
            centroid: palmCenter,
            spread: spread,
            pinchDistance: pinchDist,
            handScale: scale,
            middlePinchDistance: middlePinchDist,
            cursorAnchor: cursorAnchor,
            fingerReach: reach,
            pinchTracked: pinchTracked,
            middlePinchTracked: middlePinchTracked
        )
    }
}
