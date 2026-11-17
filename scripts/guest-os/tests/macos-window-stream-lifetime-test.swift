import Foundation

@main
struct MacWindowStreamLifetimeTests {
    static func main() {
        var lifetime = MacWindowStreamLifetime()
        // The sleep completed, but its actor callback has not run yet.
        let oldExpiry = lifetime.renewIdle()!
        lifetime.beginFrame()
        precondition(!lifetime.consumeIdle(oldExpiry, cancelled: false), "A new frame revokes a wakeup even before cancellation is observed")
        precondition(!lifetime.consumeIdle(oldExpiry, cancelled: true))
        precondition(lifetime.inFlight == 1)

        // A second frame is in flight when the first frame's defer executes.
        lifetime.beginFrame()
        precondition(!lifetime.finishFrame())
        precondition(lifetime.renewIdle() == nil, "unchanged/old completion must not schedule expiry during capture")
        precondition(lifetime.inFlight == 1)
        precondition(lifetime.finishFrame())
        let currentExpiry = lifetime.renewIdle()!
        precondition(!lifetime.consumeIdle(currentExpiry, cancelled: true))
        precondition(lifetime.consumeIdle(currentExpiry, cancelled: false), "Normal idle expiry must still stop the stream")
        precondition(!lifetime.consumeIdle(currentExpiry, cancelled: false), "An expiry lease is consumed only once")

        // Teardown clears the old stream before awaiting it. Another start can
        // win during that await; the old completion must not install or stop it.
        let oldGeneration = lifetime.generation
        let pendingStart = lifetime.replaceStream(expected: oldGeneration)!
        let newerStart = lifetime.replaceStream(expected: pendingStart)!
        precondition(!lifetime.ownsStream(pendingStart))
        precondition(lifetime.ownsStream(newerStart))
        precondition(lifetime.replaceStream(expected: oldGeneration) == nil)
        precondition(lifetime.replaceStream(expected: pendingStart) == nil)
        precondition(lifetime.ownsStream(newerStart), "A stale start failure must not tear down the newer stream")
        let staleGenerationExpiry = lifetime.renewIdle()!
        _ = lifetime.replaceStream(expected: newerStart)
        precondition(!lifetime.consumeIdle(staleGenerationExpiry, cancelled: false))

        let replacedLease = lifetime.renewIdle()!
        let finalLease = lifetime.renewIdle()!
        precondition(!lifetime.consumeIdle(replacedLease, cancelled: false))
        precondition(lifetime.consumeIdle(finalLease, cancelled: false))
        print("Stream idle lease: late wakeup, cancellation, overlapping frames, unchanged, normal expiry, and stale teardown passed")
    }
}
