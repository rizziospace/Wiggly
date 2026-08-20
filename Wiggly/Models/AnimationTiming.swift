import Foundation

nonisolated enum AnimationTiming {
    /// One complete canvas animation cycle.
    static let canvasLoopDuration = 1.0

    static func phase(at elapsedTime: TimeInterval) -> Double {
        let duration = canvasLoopDuration
        return elapsedTime.truncatingRemainder(dividingBy: duration) / duration
    }
}
