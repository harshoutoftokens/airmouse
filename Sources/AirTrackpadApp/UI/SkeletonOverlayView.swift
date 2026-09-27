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
        
        ForEach(0..<fingerChains.count, id: \.self) { idx in
            let chain = fingerChains[idx]
            let finger = fingers[idx]
            let isExtended = states[finger] == .extended
            let strokeColor = isExtended ? Color.green : Color.orange.opacity(0.8)
            
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
            .stroke(strokeColor, lineWidth: isExtended ? 3.0 : 2.0)
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
                
                Circle()
                    .fill(isTip ? Color.yellow : Color.white)
                    .frame(width: isTip ? 8 : 5, height: isTip ? 8 : 5)
                    .position(x: sx, y: sy)
                    .shadow(color: isTip ? Color.yellow.opacity(0.8) : Color.clear, radius: 4)
            }
        }
    }
}
