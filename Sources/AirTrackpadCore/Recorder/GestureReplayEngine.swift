import Foundation

public final class GestureReplayEngine: @unchecked Sendable {
    public init() {}
    
    /// Replays a recorded gesture sequence deterministically against a state machine and action router.
    /// Returns the list of all abstract events emitted during the replay.
    @discardableResult
    public func replayInstantaneous(
        recording: GestureRecording,
        stateMachine: GestureStateMachine,
        actionRouter: ActionRouter? = nil
    ) -> [AbstractGestureEvent] {
        stateMachine.reset()
        var allEvents: [AbstractGestureEvent] = []
        
        for frame in recording.frames {
            let events = stateMachine.process(
                hand: frame.observation,
                metrics: frame.metrics,
                timestamp: frame.timestamp
            )
            for e in events {
                allEvents.append(e)
                actionRouter?.handle(event: e)
            }
        }
        
        return allEvents
    }
}
