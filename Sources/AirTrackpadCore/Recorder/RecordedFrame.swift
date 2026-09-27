import Foundation

/// A single timestamped frame containing raw observation and geometric metrics for recording and replay.
public struct RecordedFrame: Codable, Sendable {
    public var timestamp: TimeInterval
    public var observation: HandObservation?
    public var metrics: HandMetrics?
    public var gestureState: String
    
    public init(
        timestamp: TimeInterval,
        observation: HandObservation?,
        metrics: HandMetrics?,
        gestureState: String
    ) {
        self.timestamp = timestamp
        self.observation = observation
        self.metrics = metrics
        self.gestureState = gestureState
    }
}

/// A serialized sequence of recorded gesture frames.
public struct GestureRecording: Codable, Sendable {
    public var name: String
    public var recordedAt: Date
    public var targetFPS: Double
    public var frames: [RecordedFrame]
    
    public init(
        name: String,
        recordedAt: Date = Date(),
        targetFPS: Double = 60.0,
        frames: [RecordedFrame]
    ) {
        self.name = name
        self.recordedAt = recordedAt
        self.targetFPS = targetFPS
        self.frames = frames
    }
}
