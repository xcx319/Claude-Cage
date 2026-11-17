import Foundation
import CoreGraphics

// Fix the crop for one layout transaction. AX resizing can temporarily move
// Electron's title-bar buttons; only the post-capture check can revise it.
struct MacCanvasFixedCropLayout {
    let crop: CGFloat
    let outerSize: CGSize
    init(crop: CGFloat, content: CGSize, display: CGSize) {
        self.crop = crop
        outerSize = CGSize(width: min(content.width, display.width), height: min(content.height + crop, display.height))
    }
}

// Observe bounds only. A stable constrained size remains supported; callers
// retain the existing resizable=false result if the requested size is refused.
struct MacCanvasLayoutSettlement {
    enum Decision: Equatable { case wait, settled }
    enum Problem: Error { case unstable }
    private var previous: CGRect?
    private var remaining = 12

    mutating func observe(bounds: CGRect) throws -> Decision {
        guard remaining > 0 else { throw Problem.unstable }
        remaining -= 1
        if previous == bounds { return .settled }
        previous = bounds
        return .wait
    }
}

// Each fresh layout owns its asynchronous work and one successful crop check.
// A superseded transaction cannot mutate the window or validate a newer cache.
struct MacCanvasLayoutTransactions {
    enum Problem: Error { case stale, cropChanged }
    private(set) var current = UUID()
    private var cropValidated = false

    mutating func begin() -> UUID {
        current = UUID()
        cropValidated = false
        return current
    }
    func isCurrent(_ generation: UUID) -> Bool { generation == current }
    mutating func invalidate(_ generation: UUID) -> Bool {
        guard isCurrent(generation) else { return false }
        _ = begin()
        return true
    }
    mutating func validateCrop(_ generation: UUID, probe: () -> Bool?) throws {
        guard isCurrent(generation) else { throw Problem.stale }
        if cropValidated { return }
        // nil means background/unavailable AX, not successful validation.
        guard let matches = probe() else { return }
        guard matches else { throw Problem.cropChanged }
        cropValidated = true
    }
}

// Only a verified crop transition may retry unpublished frame preparation.
// No input operation or generic window/identity failure enters this loop.
struct MacCanvasCropChanged: Error {
    let recoveryGeneration: UUID
    let window: UInt32
    let pid: Int32
    let observedCrop: CGFloat

    func matches(window: UInt32, pid: Int32) -> Bool { self.window == window && self.pid == pid }
}

@MainActor
enum MacCanvasFrameConvergence {
    enum Problem: Error { case unstable }
    static func run<Output>(timeout: Duration = .seconds(8),
                            attempt: (MacCanvasCropChanged?) async throws -> Output) async throws -> Output {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var recovery: MacCanvasCropChanged?
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Problem.unstable }
            do {
                let result = try await attempt(recovery)
                try Task.checkCancellation()
                guard clock.now < deadline else { throw Problem.unstable }
                return result
            } catch let changed as MacCanvasCropChanged {
                recovery = changed
            }
        }
        throw Problem.unstable
    }
}

#if !CAGE_CANVAS_LAYOUT_TEST
// A geometry token describes only the signed Claude window actually captured.
// All coordinates used for presentation and input are measured in guest points.
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct ClaudeCanvas {
    let generation: UUID
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let cropTop: CGFloat
    let scale: CGFloat
    let resizable: Bool
    var content: CGSize { CGSize(width: frame.width, height: frame.height - cropTop) }

    func matches(_ other: ClaudeCanvas) -> Bool {
        id == other.id && pid == other.pid && frame == other.frame && cropTop == other.cropTop && scale == other.scale
    }
}

private func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func axRect(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = axAttribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: pos, size: size)
}

private func liveBounds(_ id: CGWindowID, _ pid: pid_t) throws -> CGRect {
    let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String:Any]]
    guard let info = windows?.first, info[kCGWindowOwnerPID as String] as? Int32 == pid,
          info[kCGWindowIsOnscreen as String] as? Bool == true,
          let box = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: box), !rect.isEmpty else { throw Failure(7, "window_changed") }
    return rect
}

// AXIsProcessTrusted asks tccd, which re-validates this helper's signature.
// Input and layout ask on every event; a one-second answer is current enough.
final class AccessibilityTrust: @unchecked Sendable {
    static let shared = AccessibilityTrust()
    private let lock = NSLock()
    private var checked = Date.distantPast, trusted = false
    var current: Bool {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(checked) >= 1 { trusted = AXIsProcessTrusted(); checked = Date() }
        return trusted
    }
}

func owningAXWindow(_ pid: pid_t, _ frame: CGRect) -> AXUIElement? {
    guard AccessibilityTrust.shared.current, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let raw = axAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    let window = raw as! AXUIElement
    guard let actual = axRect(window), abs(actual.minX-frame.minX)<1, abs(actual.minY-frame.minY)<1,
          abs(actual.width-frame.width)<1, abs(actual.height-frame.height)<1 else { return nil }
    return window
}

func macApplicationWindowBounds(_ pid: pid_t) -> [CGRect] {
    guard AccessibilityTrust.shared.current,
          let windows = axAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    return windows.compactMap(axRect)
}

private func canSet(_ window: AXUIElement, _ name: String) -> Bool {
    var result = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(window, name as CFString, &result) == .success && result.boolValue
}

private func titleBarHeight(_ window: AXUIElement, _ frame: CGRect) -> CGFloat {
    var bottom: CGFloat = 0
    for name in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
        guard let raw = axAttribute(window, name), CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let button = axRect(raw as! AXUIElement), button.width > 2, button.height > 2,
              frame.contains(button), button.minX-frame.minX < 100, button.maxY-frame.minY < 70 else { continue }
        let margin = min(8, max(2, button.minY - frame.minY))
        bottom = max(bottom, ceil(button.maxY - frame.minY + margin))
    }
    return bottom < frame.height / 3 ? bottom : 0
}

// JPEG has no alpha. A window's rounded corners are filled with the colour
// just inside its bottom edge instead of the encoder's black.
private func windowEdgeColor(_ image: CGImage) -> CGColor? {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return nil
    default: break
    }
    guard image.width > 40, image.height > 40,
          let pixel = image.cropping(to: CGRect(x: 16, y: image.height - 17, width: 1, height: 1)),
          let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let data = context.data else { return nil }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    guard bytes[3] == 255 else { return nil }
    return CGColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
}

// ImageIO compresses the whole window on the CPU. Callers run this off the
// main actor, which also delivers input to the same window. The window is
// sent as JPEG: it encodes and decodes several times faster than PNG and is
// the same kind of image a Linux guest sends, at that display's quality.
private func encodedWindowFrame(_ content: CGImage, phoneJPEG: Bool, motionBurst: Bool = false) throws -> (data: Data, mime: String) {
    if phoneJPEG { return (try phoneDesktopJPEG(content), "image/jpeg") }
    let edge = windowEdgeColor(content)
    var data = Data()
    // Lower JPEG quality slightly during high-resolution motion bursts, then send
    // a full-quality frame once pixels settle so idle text remains crisp.
    let qualities: [Double] = motionBurst && content.width * content.height > 900_000 ? [0.80, 0.72] : [0.92, 0.84]
    for quality in qualities {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let edge { properties[kCGImageDestinationBackgroundColor] = edge }
        data = try encodedImage(content, type: .jpeg, properties: properties as CFDictionary)
        if data.count < 8<<20 { break }
    }
    guard data.count < 8<<20 else { throw Failure(8, "frame_limit") }
    return (data, "image/jpeg")
}

@MainActor
final class ClaudeCanvasSession {
    static let shared = ClaudeCanvasSession()
    static let browser = ClaudeCanvasSession(browser: true)
    private let browser: Bool
    let stream: MacWindowStream
    init(browser: Bool = false) {
        self.browser = browser
        self.stream = browser ? MacWindowStream() : .shared
    }

    private func owns(_ pid: pid_t) throws -> Bool {
        if browser { return MacChromeWindow.shared.owns(pid) }
        return try claudePIDs().contains(pid)
    }

    private func cropHeight(_ ax: AXUIElement, _ rect: CGRect) -> CGFloat {
        browser ? 0 : titleBarHeight(ax, rect)
    }

    private var transactions = MacCanvasLayoutTransactions()
    private var last: ClaudeCanvas?
    private var token = ""
    private var lastEncodedAt: TimeInterval = 0
    private var lastSettled = true

    // Finding the window (ScreenCaptureKit enumeration) and laying it out
    // (Accessibility queries) dominate a frame on a virtual Mac. While the
    // window keeps its bounds and the view keeps its size, reuse them for a
    // short time; capture still verifies bounds and ownership on every frame.
    private struct Target {
        let window: SCWindow, filter: SCContentFilter, layout: ClaudeCanvas
        let width: Int, height: Int, scale: Double, time: Date
        var inputValidatedAt: Date
    }
    private var target: Target?
    private static let targetLifetime: TimeInterval = 2

    func cachedTarget(width: Int, height: Int, scale: Double) -> (SCWindow, SCContentFilter, ClaudeCanvas)? {
        guard let cached = target, transactions.isCurrent(cached.layout.generation), cached.width == width, cached.height == height, cached.scale == scale,
              Date().timeIntervalSince(cached.time) < Self.targetLifetime,
              (try? liveBounds(cached.layout.id, cached.layout.pid)) == cached.layout.frame else {
            target = nil
            return nil
        }
        return (cached.window, cached.filter, cached.layout)
    }

    func requirePublishedLayout(_ layout: ClaudeCanvas, geometry: String?) throws {
        guard transactions.isCurrent(layout.generation), let geometry, token == geometry,
              last?.matches(layout) == true else {
            GuestDiagnostic.record("window", "capture_publication_superseded")
            throw Failure(7, "window_changed")
        }
    }

    func remember(_ window: SCWindow, filter: SCContentFilter, layout: ClaudeCanvas, width: Int, height: Int, scale: Double, geometry: String?) {
        guard transactions.isCurrent(layout.generation), let geometry, token == geometry, last?.matches(layout) == true else { return }
        let now = Date()
        target = Target(window: window, filter: filter, layout: layout, width: width, height: height, scale: scale, time: now, inputValidatedAt: now)
    }

    // A fully validated frame refreshes input reuse, not the enumeration TTL.
    // A request suspended during capture must not renew a replacement target.
    func validatedInputTarget(_ window: SCWindow, layout: ClaudeCanvas, geometry: String?) {
        guard transactions.isCurrent(layout.generation), let geometry, token == geometry, last?.matches(layout) == true,
              var cached = target, cached.window === window, cached.layout.matches(layout) else { return }
        cached.inputValidatedAt = Date()
        target = cached
    }

    func forgetTarget(ifMatching layout: ClaudeCanvas) {
        guard transactions.isCurrent(layout.generation), target?.layout.generation == layout.generation else { return }
        target = nil
    }

    private func requireCurrentLayout(_ generation: UUID) throws {
        guard transactions.isCurrent(generation) else { throw Failure(7, "window_changed") }
    }

    private func invalidateLayout(_ generation: UUID) {
        if transactions.invalidate(generation) { measured = nil; target = nil }
    }

    // Input reuses the window the frame stream already verified only while
    // its captured bounds match the layout. Input checks geometry and focus
    // again before every delivery, including the SCWindow's original bounds.
    func cachedWindow() -> SCWindow? {
        guard let cached = target, transactions.isCurrent(cached.layout.generation), Date().timeIntervalSince(cached.inputValidatedAt) < Self.targetLifetime,
              abs(cached.window.frame.minX - cached.layout.frame.minX) < 1,
              abs(cached.window.frame.minY - cached.layout.frame.minY) < 1,
              abs(cached.window.frame.width - cached.layout.frame.width) < 1,
              abs(cached.window.frame.height - cached.layout.frame.height) < 1,
              (try? liveBounds(cached.layout.id, cached.layout.pid)) == cached.layout.frame else { return nil }
        return cached.window
    }
    private var requested: (id: CGWindowID, pid: pid_t, size: CGSize, observed: CGSize, time: Date)?
    // Each accessibility query is a round trip into the application. What they
    // report follows the window's geometry, which every frame reads anyway.
    private var measured: (id: CGWindowID, pid: pid_t, bounds: CGRect, width: Int, height: Int, crop: CGFloat, resized: Bool, time: Date)?

    func layout(_ window: SCWindow, filter: SCContentFilter, width: Int, height: Int, scale: Double, recovery: MacCanvasCropChanged? = nil) async throws -> ClaudeCanvas {
        guard let pid = window.owningApplication?.processID,
              (320...2560).contains(width), (240...1600).contains(height),
              scale.isFinite, (1...2).contains(scale) else { throw Failure(8, "invalid_input") }
        if let recovery {
            try requireCurrentLayout(recovery.recoveryGeneration)
            guard recovery.matches(window: window.windowID, pid: pid) else { throw Failure(7, "window_changed") }
        }
        let generation = transactions.begin()
        var completed = false
        defer { if !completed { invalidateLayout(generation) } }
        var bounds = try liveBounds(window.windowID, pid)
        let density = min(max(1,CGFloat(filter.pointPixelScale)), CGFloat(scale))
        if recovery == nil, let known = measured, known.id == window.windowID, known.pid == pid, known.bounds == bounds,
           known.width == width, known.height == height, Date().timeIntervalSince(known.time) < 1 {
            completed = true
            return ClaudeCanvas(generation: generation, id: window.windowID, pid: pid, frame: bounds, cropTop: known.crop,
                                scale: density, resizable: known.resized)
        }
        var crop: CGFloat = recovery?.observedCrop ?? 0, resized = false
        guard crop.isFinite, crop >= 0, crop < bounds.height / 3 else { throw Failure(7, "window_changed") }
        if let ax = owningAXWindow(pid, bounds) {
            if recovery == nil { crop = cropHeight(ax, bounds) }
            if canSet(ax, kAXSizeAttribute) {
                let display = CGDisplayBounds(CGMainDisplayID())
                let plan = MacCanvasFixedCropLayout(crop: crop, content: CGSize(width: width, height: height), display: display.size)
                let wanted = plan.outerSize
                let close = abs(bounds.width - wanted.width) < 2 && abs(bounds.height - wanted.height) < 2
                let recent = requested.map { $0.id == window.windowID && $0.pid == pid && $0.size == wanted &&
                    $0.observed == bounds.size && Date().timeIntervalSince($0.time) < 3 } ?? false
                if !close && !recent {
                    try requireCurrentLayout(generation)
                    var size = wanted
                    if let value = AXValueCreate(.cgSize, &size),
                       AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, value) == .success {
                        var settlement = MacCanvasLayoutSettlement()
                        settling: while true {
                            try await Task.sleep(nanoseconds: 70_000_000)
                            try requireCurrentLayout(generation)
                            try consoleUser()
                            guard try owns(pid) else { throw Failure(7, "window_changed") }
                            bounds = try liveBounds(window.windowID, pid)
                            guard let current = owningAXWindow(pid, bounds), CFEqual(current, ax) else {
                                throw Failure(7, "window_changed")
                            }
                            // Keep the same owned window on its display after resizing.
                            var origin = CGPoint(x: max(display.minX, min(bounds.minX, display.maxX-bounds.width)),
                                                 y: max(display.minY, min(bounds.minY, display.maxY-bounds.height)))
                            if origin != bounds.origin, canSet(current, kAXPositionAttribute),
                               let point = AXValueCreate(.cgPoint, &origin) {
                                try requireCurrentLayout(generation)
                                guard AXUIElementSetAttributeValue(current, kAXPositionAttribute as CFString, point) == .success else {
                                    throw Failure(7, "window_changed")
                                }
                                bounds = try liveBounds(window.windowID, pid)
                            }
                            let decision: MacCanvasLayoutSettlement.Decision
                            do { decision = try settlement.observe(bounds: bounds) }
                            catch { throw Failure(7, "window_changed") }
                            switch decision {
                            case .wait: continue
                            case .settled: break settling
                            }
                        }
                    }
                    requested = (window.windowID, pid, wanted, bounds.size, Date())
                }
                resized = abs(bounds.width-wanted.width) < 2 && abs(bounds.height-wanted.height) < 2
            }
        }
        measured = (window.windowID, pid, bounds, width, height, crop, resized, Date())
        completed = true
        return ClaudeCanvas(generation: generation, id: window.windowID, pid: pid, frame: bounds, cropTop: crop,
                            scale: density, resizable: resized)
    }

    func record(_ value: ClaudeCanvas) -> String {
        if last?.matches(value) != true { token = UUID().uuidString; last = value }
        return token
    }

    func inputGeometry(_ requested: String, window: SCWindow) throws -> ClaudeCanvas {
        guard let last, token == requested, last.id == window.windowID, last.pid == window.owningApplication?.processID,
              try liveBounds(last.id, last.pid) == last.frame,
              let ax = owningAXWindow(last.pid, last.frame), cropHeight(ax,last.frame) == last.cropTop else {
            throw Failure(7, "window_changed")
        }
        return last
    }

    func requireCropRecovery(_ changed: MacCanvasCropChanged, window: CGWindowID, pid: pid_t) throws {
        try requireCurrentLayout(changed.recoveryGeneration)
        guard changed.matches(window: window, pid: pid) else { throw Failure(7, "window_changed") }
        try requireCropRecoveryTarget(window: window, pid: pid)
    }

    func requireCropRecoveryTarget(window: CGWindowID, pid: pid_t) throws {
        try consoleUser()
        guard try owns(pid), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              owningAXWindow(pid, try liveBounds(window, pid)) != nil else {
            GuestDiagnostic.record("window", "crop_recovery_target_changed")
            throw Failure(7, "window_changed")
        }
    }

    private func validateCurrentCrop(_ layout: ClaudeCanvas, allowRecovery: Bool) throws {
        var observedCrop: CGFloat?
        do {
            try transactions.validateCrop(layout.generation) {
                guard let ax = owningAXWindow(layout.pid, layout.frame) else { return nil }
                let current = cropHeight(ax, layout.frame)
                observedCrop = current
                return current == layout.cropTop
            }
        } catch MacCanvasLayoutTransactions.Problem.cropChanged {
            invalidateLayout(layout.generation)
            GuestDiagnostic.record("window", "capture_crop_changed")
            if allowRecovery, let observedCrop {
                throw MacCanvasCropChanged(recoveryGeneration: transactions.current, window: layout.id, pid: layout.pid, observedCrop: observedCrop)
            }
            throw Failure(7, "window_changed")
        } catch {
            // A superseded capture must neither retry nor clear newer state.
            GuestDiagnostic.record("window", "capture_layout_superseded")
            throw Failure(7, "window_changed")
        }
    }

    func capture(_ window: SCWindow, filter: SCContentFilter, layout: ClaudeCanvas, after: String? = nil, wait: Bool = false, binary: Bool = false, phoneJPEG: Bool = false, allowCropRecovery: Bool = false) async throws -> [String:Any] {
        try requireCurrentLayout(layout.generation)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((layout.frame.width*layout.scale).rounded()))
        config.height = max(1, Int((layout.frame.height*layout.scale).rounded()))
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true; config.showsCursor = false
        if #available(macOS 14.2, *) { config.includeChildWindows = browser }
        let geometry = record(layout)
        // Timings let the host separate waiting for a new frame, encoding
        // in the guest and the transport. They contain no window content.
        let captureStarted = Date()
        let needSettle = !lastSettled && !phoneJPEG
        let (updated, sequence) = try await stream.frame(filter: filter, configuration: config, identity: geometry, after: after, wait: wait, waitSeconds: needSettle ? 0.25 : 2, forceSettled: needSettle)
        let captureMs = Date().timeIntervalSince(captureStarted) * 1000
        try requireCurrentLayout(layout.generation)
        guard try liveBounds(layout.id, layout.pid) == layout.frame,
              try owns(layout.pid) else { throw Failure(7, "window_changed") }
        guard let image = updated else {
            try validateCurrentCrop(layout, allowRecovery: allowCropRecovery)
            lastSettled = true
            return ["unchanged": true, "sequence": sequence, "geometry": geometry]
        }
        let top = Int((layout.cropTop * CGFloat(image.height) / layout.frame.height).rounded())
        guard top >= 0, top < image.height,
              let content = image.cropping(to: CGRect(x:0,y:top,width:image.width,height:image.height-top)) else {
            throw Failure(7, "window_changed")
        }
        let now = ProcessInfo.processInfo.systemUptime
        let motionBurst = !phoneJPEG && layout.scale > 1 && lastEncodedAt > 0 && now - lastEncodedAt < 0.18
        lastEncodedAt = now
        lastSettled = !motionBurst
        let encodeStarted = Date()
        let encoded = try await Task.detached(priority: .userInitiated) {
            try encodedWindowFrame(content, phoneJPEG: phoneJPEG, motionBurst: motionBurst)
        }.value
        let data = encoded.data, mime = encoded.mime
        try requireCurrentLayout(layout.generation)
        // The second ownership check covers the time spent encoding.
        guard try liveBounds(layout.id, layout.pid) == layout.frame,
              try owns(layout.pid) else { throw Failure(7, "window_changed") }
        try validateCurrentCrop(layout, allowRecovery: allowCropRecovery)
        var reply: [String:Any] = ["window":layout.id,"pid":layout.pid,"mime":mime,"sequence":sequence,
                "contentWidth":layout.content.width,"contentHeight":layout.content.height,
                "pixelWidth":content.width,"pixelHeight":content.height,"cropTop":layout.cropTop,
                "resizable":layout.resizable, "geometry":geometry,
                "captureMs":captureMs.rounded(), "encodeMs":(Date().timeIntervalSince(encodeStarted) * 1000).rounded()]
        if binary { reply["imageBytes"] = data }
        else { reply["image"] = data.base64EncodedString() }
        return reply
    }
}

#endif
