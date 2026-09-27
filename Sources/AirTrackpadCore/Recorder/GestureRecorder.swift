import Foundation

public final class GestureRecorder: @unchecked Sendable {
    public private(set) var isRecording: Bool = false
    public private(set) var recordingName: String = ""
    private var frames: [RecordedFrame] = []
    private let lock = NSLock()
    
    public init() {}
    
    public func startRecording(name: String) {
        lock.lock()
        defer { lock.unlock() }
        recordingName = name
        frames.removeAll()
        isRecording = true
    }
    
    public func recordFrame(
        observation: HandObservation?,
        metrics: HandMetrics?,
        gestureState: String,
        timestamp: TimeInterval
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        
        let frame = RecordedFrame(
            timestamp: timestamp,
            observation: observation,
            metrics: metrics,
            gestureState: gestureState
        )
        frames.append(frame)
    }
    
    public func stopRecording() -> GestureRecording {
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        return GestureRecording(name: recordingName, frames: frames)
    }
    
    public static func save(recording: GestureRecording, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recording)
        try data.write(to: fileURL, options: .atomic)
    }
    
    public static func load(from fileURL: URL) throws -> GestureRecording {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(GestureRecording.self, from: data)
    }
}
