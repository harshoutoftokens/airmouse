import SwiftUI
import AirTrackpadCore

public struct SkeletonOverlayView: View {
    public var observations: [HandObservation]
    
    public init(observations: [HandObservation]) {
        self.observations = observations
    }
    
    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            ZStack {
                ForEach(observations, id: \.id) { hand in
                    // Draw finger bones
                    drawFingers(for: hand, width: w, height: h)
                    
                    // Draw palm base loop
                    drawPalm(for: hand, width: w, height: h)
                    
                    // Draw joint nodes
                    drawJointNodes(for: hand, width: w, height: h)
                    
                    // Draw finger identification badges and status markers
                    drawFingerLabels(for: hand, width: w, height: h)
                }
            }
        }
    }
    
    @ViewBuilder
    private func drawFingers(for hand: HandObservation, width: CGFloat, height: CGFloat) -> some View {
        let fingerChains: [[JointName]] = [
            [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
            [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
            [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
            [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
        ]
        
        let states = FingerClassifier.classifyFingers(in: hand)
        let fingers: [Finger] = [.thumb, .index, .middle, .ring, .little]
        let isScrollMode = PoseClassifier.classify(FingerClassifier.extractMetrics(from: hand)) == .scroll
        
        ForEach(0..<fingerChains.count, id: \.self) { idx in
            let chain = fingerChains[idx]
            let finger = fingers[idx]
            let isExtended = states[finger] == .extended
            
            let strokeColor: Color = {
                if isScrollMode && (finger == .index || finger == .middle) {
                    return Color.cyan
                }
                return isExtended ? Color.green : Color.orange.opacity(0.7)
            }()
            
            Path { path in
                var started = false
                for joint in chain {
                    if let pt = hand.landmark(joint), pt.confidence > 0.3 {
                        let sx = CGFloat(pt.x) * width
                        let sy = CGFloat(1.0 - pt.y) * height
                        if !started {
                            path.move(to: CGPoint(x: sx, y: sy))
                            started = true
                        } else {
                            path.addLine(to: CGPoint(x: sx, y: sy))
                        }
                    }
                }
            }
            .stroke(strokeColor, lineWidth: (isScrollMode && (finger == .index || finger == .middle)) ? 4.0 : (isExtended ? 3.0 : 2.0))
        }
    }
    
    @ViewBuilder
    private func drawPalm(for hand: HandObservation, width: CGFloat, height: CGFloat) -> some View {
        let palmJoints: [JointName] = [.thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        
        Path { path in
            var started = false
            for joint in palmJoints {
                if let pt = hand.landmark(joint), pt.confidence > 0.3 {
                    let sx = CGFloat(pt.x) * width
                    let sy = CGFloat(1.0 - pt.y) * height
                    if !started {
                        path.move(to: CGPoint(x: sx, y: sy))
                        started = true
                    } else {
                        path.addLine(to: CGPoint(x: sx, y: sy))
                    }
                }
            }
        }
        .stroke(Color.cyan.opacity(0.7), lineWidth: 2.0)
    }
    
    @ViewBuilder
    private func drawJointNodes(for hand: HandObservation, width: CGFloat, height: CGFloat) -> some View {
        ForEach(JointName.allCases, id: \.self) { joint in
            if let pt = hand.landmark(joint), pt.confidence > 0.3 {
                let sx = CGFloat(pt.x) * width
                let sy = CGFloat(1.0 - pt.y) * height
                let isTip = joint.rawValue.contains("Tip")
                
                let nodeColor: Color = {
                    guard isTip else { return Color.white }
                    switch joint {
                    case .thumbTip: return Color.yellow
                    case .indexTip: return Color.green
                    case .middleTip: return Color.cyan
                    case .ringTip: return Color.orange
                    case .littleTip: return Color.pink
                    default: return Color.yellow
                    }
                }()
                
                Circle()
                    .fill(nodeColor)
                    .frame(width: isTip ? 9 : 5, height: isTip ? 9 : 5)
                    .position(x: sx, y: sy)
                    .shadow(color: isTip ? nodeColor.opacity(0.8) : Color.clear, radius: 4)
            }
        }
    }
    
    @ViewBuilder
    private func drawFingerLabels(for hand: HandObservation, width: CGFloat, height: CGFloat) -> some View {
        let states = FingerClassifier.classifyFingers(in: hand)
        let fingerInfo: [(Finger, JointName, String, String, Color)] = [
            (.thumb, .thumbTip, "THUMB", "👍", Color.yellow),
            (.index, .indexTip, "INDEX", "☝️", Color.green),
            (.middle, .middleTip, "MIDDLE", "✌️", Color.cyan),
            (.ring, .ringTip, "RING", "💍", Color.orange),
            (.little, .littleTip, "PINKY", "🤙", Color.pink)
        ]
        
        let isScrollMode = PoseClassifier.classify(FingerClassifier.extractMetrics(from: hand)) == .scroll
        
        ForEach(fingerInfo, id: \.0) { finger, joint, name, emoji, baseColor in
            if let pt = hand.landmark(joint), pt.confidence > 0.3 {
                let sx = CGFloat(pt.x) * width
                let sy = CGFloat(1.0 - pt.y) * height
                let state = states[finger] ?? .uncertain
                let isExtended = state == .extended
                let isPartially = state == .partiallyExtended
                
                let badgeColor: Color = isExtended ? baseColor : (isPartially ? Color.yellow : Color.gray.opacity(0.7))
                let statusText: String = isExtended ? "UP" : (isPartially ? "HALF" : "DOWN")
                
                HStack(spacing: 3) {
                    Text(emoji)
                        .font(.system(size: 9))
                    Text("\(name) [\(statusText)]")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(badgeColor.opacity(isExtended ? 0.85 : 0.4))
                )
                .overlay(
                    Capsule()
                        .stroke(badgeColor, lineWidth: isExtended ? 1.5 : 0.8)
                )
                .shadow(color: isExtended ? badgeColor.opacity(0.6) : Color.clear, radius: 4)
                .position(x: sx, y: max(16, sy - 18))
            }
        }
        
        // Mode Banner if in 2-Finger Scroll mode
        if isScrollMode,
           let indexPt = hand.landmark(.indexTip),
           let middlePt = hand.landmark(.middleTip) {
            let midX = CGFloat((indexPt.x + middlePt.x) / 2.0) * width
            let midY = CGFloat(1.0 - (indexPt.y + middlePt.y) / 2.0) * height
            
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down.circle.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: 11))
                Text("2-FINGER SCROLL ACTIVE")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.4))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.cyan, lineWidth: 1.5)
            )
            .shadow(color: Color.cyan.opacity(0.8), radius: 6)
            .position(x: midX, y: max(22, midY - 42))
        }
    }
}
