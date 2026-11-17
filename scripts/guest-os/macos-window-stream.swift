import Foundation

// Main-actor state shared by frame entry/exit, idle expiry and stream teardown.
// Cancellation alone cannot revoke an expiry whose sleep already completed.
struct MacWindowStreamLifetime {
    struct Lease: Equatable { let id: UUID; let generation: String }
    private(set) var generation = UUID().uuidString
    private(set) var inFlight = 0
    private var lease: Lease?

    mutating func beginFrame() { inFlight += 1; lease = nil }
    mutating func finishFrame() -> Bool {
        precondition(inFlight > 0)
        inFlight -= 1
        return inFlight == 0
    }
    mutating func renewIdle() -> Lease? {
        lease = nil
        guard inFlight == 0 else { return nil }
        let next = Lease(id: UUID(), generation: generation)
        lease = next
        return next
    }
    mutating func consumeIdle(_ expected: Lease, cancelled: Bool) -> Bool {
        guard !cancelled, inFlight == 0, lease == expected, generation == expected.generation else { return false }
        lease = nil
        return true
    }
    // Revoke synchronously before awaiting the old SCStream's teardown.
    // The returned reservation must still be current before installing a stream.
    mutating func replaceStream(expected: String) -> String? {
        guard generation == expected else { return nil }
        lease = nil
        generation = UUID().uuidString
        return generation
    }
    func ownsStream(_ expected: String) -> Bool { generation == expected }
}

#if !CAGE_WINDOW_STREAM_TEST
import AppKit
import CoreImage
import ScreenCaptureKit

@MainActor
final class MacWindowStream: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = MacWindowStream()
    private var stream: SCStream?
    private var key = ""
    private var lifetime = MacWindowStreamLifetime()
    private var generation: String { lifetime.generation }
    private var number: UInt64 = 0
    private var sequence: String { generation + "-" + String(number) }
    private var buffer: CVPixelBuffer?
    private var expiry: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let images = CIContext()

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return }
        let pixels = sample.isValid ? sample.imageBuffer : nil
        let changed = (attachments.first?[.dirtyRects] as? [Any])?.isEmpty != true
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            if status == SCFrameStatus.complete.rawValue, let pixels {
                if self.buffer != nil && !changed { return }
                self.buffer = pixels
                self.number += 1
            } else if status != SCFrameStatus.idle.rawValue {
                self.buffer = nil
                self.number += 1
            }
            self.wake()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            _ = self.lifetime.replaceStream(expected: self.generation)
            self.expiry?.cancel()
            self.expiry = nil
            self.stream = nil
            self.buffer = nil
            self.key = ""
            self.wake()
        }
    }

    private func stop(ifGeneration expected: String, idleLease: MacWindowStreamLifetime.Lease? = nil) async -> String? {
        // Validate expiry at the destructive operation, not before an await.
        if let idleLease, !lifetime.consumeIdle(idleLease, cancelled: Task.isCancelled) { return nil }
        guard let reservation = lifetime.replaceStream(expected: expected) else { return nil }
        if idleLease == nil { expiry?.cancel() }
        expiry = nil
        let previous = stream
        stream = nil
        buffer = nil
        key = ""
        wake()
        try? await previous?.stopCapture()
        return reservation
    }

    private func wake() {
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func waitForFrame(after expected: String, seconds: Double) async throws {
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.waiters.removeValue(forKey: id)?.resume()
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || stream == nil || expected != sequence { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
        }
        try Task.checkCancellation()
    }

    private func renew() {
        expiry?.cancel()
        expiry = nil
        guard stream != nil, let lease = lifetime.renewIdle() else { return }
        expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await self.stop(ifGeneration: lease.generation, idleLease: lease)
        }
    }

    func unchanged(after: String?) -> Bool {
        guard stream != nil, buffer != nil, after == sequence else { return false }
        renew()
        return true
    }

    func frame(filter: SCContentFilter, configuration: SCStreamConfiguration, identity: String, after: String?, wait: Bool = false, waitSeconds: Double = 2, forceSettled: Bool = false) async throws -> (CGImage?, String) {
        lifetime.beginFrame()
        expiry?.cancel()
        expiry = nil
        defer { if lifetime.finishFrame() { renew() } }
        if stream == nil || key != identity {
            guard let reservation = await stop(ifGeneration: generation),
                  lifetime.ownsStream(reservation), stream == nil else {
                GuestDiagnostic.record("window", "stream_start_superseded")
                throw Failure(7, "window_changed")
            }
            try Task.checkCancellation()
            number = 0
            key = identity
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let next = SCStream(filter: filter, configuration: configuration, delegate: self)
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cage.window.frames"))
            stream = next
            do { try await next.startCapture() }
            catch { _ = await stop(ifGeneration: reservation); throw error }
            guard lifetime.ownsStream(reservation), stream === next else {
                GuestDiagnostic.record("window", "stream_start_superseded")
                throw Failure(7, "window_changed")
            }
        }
        let frameGeneration = generation
        // Only the first frame of a newly configured stream needs to wait.
        let deadline = Date().addingTimeInterval(5)
        while buffer == nil && stream != nil && Date() < deadline {
            try await waitForFrame(after: sequence, seconds: max(0, deadline.timeIntervalSinceNow))
            guard lifetime.ownsStream(frameGeneration), key == identity else {
                GuestDiagnostic.record("window", "stream_wait_superseded")
                throw Failure(7, "window_changed")
            }
        }
        if wait, buffer != nil, after == sequence {
            // Revalidate window ownership and the console session at least every
            // two seconds even when ScreenCaptureKit reports no changed pixels.
            try await waitForFrame(after: sequence, seconds: waitSeconds)
        }
        guard lifetime.ownsStream(frameGeneration), key == identity else { throw Failure(7, "window_changed") }
        guard let buffer else { _ = await stop(ifGeneration: frameGeneration); throw Failure(8, "capture_no_frame") }
        let sequence = self.sequence
        if sequence == after && !forceSettled { return (nil, sequence) }
        let image = CIImage(cvPixelBuffer: buffer)
        // Reading the surface back copies the whole frame. It runs off the main
        // actor so that input and other requests are not held behind it.
        let context = images
        let converted = await Task.detached(priority: .userInitiated) {
            context.createCGImage(image, from: image.extent)
        }.value
        guard let output = converted else { throw Failure(8, "capture_conversion_failed") }
        return (output, sequence)
    }
}

#endif
