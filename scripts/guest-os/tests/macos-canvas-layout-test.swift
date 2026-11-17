import Foundation
import CoreGraphics

@main
struct MacCanvasLayoutSettlementTest {
    static func check(_ value: Bool) { precondition(value) }
    @MainActor
    static func main() async throws {
        let plan = MacCanvasFixedCropLayout(crop: 32, content: CGSize(width: 1240, height: 840), display: CGSize(width: 1920, height: 1200))
        let at872 = CGRect(origin: .zero, size: plan.outerSize)
        precondition(plan.outerSize.height == 872 && plan.crop == 32)
        var initial = MacCanvasLayoutSettlement()
        // AX buttons temporarily report 38 after resize; they cannot feed back
        // into bounds settlement or change the fixed crop/outer height.
        check(try initial.observe(bounds: at872) == .wait)
        check(try initial.observe(bounds: at872) == .settled)
        precondition(plan.outerSize.height - plan.crop == 840)

        var changing = MacCanvasLayoutSettlement()
        for n in 0..<12 {
            check(try changing.observe(bounds: at872.offsetBy(dx: CGFloat(n), dy: 0)) != .settled)
        }
        do {
            _ = try changing.observe(bounds: at872)
            fatalError("Unstable bounds must exhaust the observation budget")
        } catch MacCanvasLayoutSettlement.Problem.unstable {}

        var moving = MacCanvasLayoutSettlement()
        check(try moving.observe(bounds: at872) == .wait)
        let moved = at872.offsetBy(dx: 10, dy: 0)
        check(try moving.observe(bounds: moved) == .wait)
        check(try moving.observe(bounds: moved) == .settled)
        // A stable minimum-size constrained window retains actual-size semantics.
        var constrained = MacCanvasLayoutSettlement()
        let large = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        check(try constrained.observe(bounds: large) == .wait)
        check(try constrained.observe(bounds: large) == .settled)
        print("Fixed crop, bounded bounds settlement, origin and constrained-size behavior passed")
        var transactions = MacCanvasLayoutTransactions()
        let oldLayout = transactions.begin()
        precondition(transactions.isCurrent(oldLayout))
        // A second viewport wins while the first resize is suspended.
        let newLayout = transactions.begin()
        precondition(!transactions.isCurrent(oldLayout))
        precondition(transactions.isCurrent(newLayout))
        precondition(!transactions.invalidate(oldLayout), "Old failure must not invalidate new layout")
        var probes = 0
        do {
            try transactions.validateCrop(oldLayout) { probes += 1; return true }
            fatalError("An old capture completion must not validate the newer layout")
        } catch MacCanvasLayoutTransactions.Problem.stale {}
        precondition(probes == 0)
        // A background frame does not establish successful crop validation.
        try transactions.validateCrop(newLayout) { probes += 1; return nil }
        precondition(probes == 1)
        try transactions.validateCrop(newLayout) { probes += 1; return true }
        precondition(probes == 2)
        for _ in 0..<100 {
            try transactions.validateCrop(newLayout) { probes += 1; return false }
        }
        precondition(probes == 2, "Warm cached frames must perform no additional AX crop probe")
        let thirdLayout = transactions.begin()
        do {
            try transactions.validateCrop(thirdLayout) { probes += 1; return false }
            fatalError("An incorrect fresh crop must not be accepted")
        } catch MacCanvasLayoutTransactions.Problem.cropChanged {}
        precondition(transactions.invalidate(thirdLayout))
        precondition(!transactions.isCurrent(thirdLayout))
        precondition(!transactions.invalidate(oldLayout))
        print("Transaction interleaving, stale completion, background validation, and zero-probe warm frames passed")
        var attempts = 0
        for actualCrops: [CGFloat] in [[32], [38, 38], [38, 32, 32]] {
            attempts = 0
            var frameTransactions = MacCanvasLayoutTransactions()
            let published: (crop: CGFloat, content: CGFloat) = try await MacCanvasFrameConvergence.run { recovery in
                if let recovery {
                    precondition(frameTransactions.isCurrent(recovery.recoveryGeneration))
                    precondition(recovery.matches(window: 7, pid: 23))
                    precondition(!recovery.matches(window: 8, pid: 23) && !recovery.matches(window: 7, pid: 24))
                }
                let generation = frameTransactions.begin()
                let fixed = MacCanvasFixedCropLayout(crop: recovery?.observedCrop ?? 32,
                    content: CGSize(width: 1240, height: 840), display: CGSize(width: 1920, height: 1200))
                var settlement = MacCanvasLayoutSettlement()
                let bounds = CGRect(origin: .zero, size: fixed.outerSize)
                check(try settlement.observe(bounds: bounds) == .wait)
                check(try settlement.observe(bounds: bounds) == .settled)
                let capturedCrop = actualCrops[attempts]
                attempts += 1
                do {
                    try frameTransactions.validateCrop(generation) { fixed.crop == capturedCrop }
                } catch MacCanvasLayoutTransactions.Problem.cropChanged {
                    precondition(frameTransactions.invalidate(generation))
                    throw MacCanvasCropChanged(recoveryGeneration: frameTransactions.current, window: 7, pid: 23, observedCrop: capturedCrop)
                }
                return (fixed.crop, bounds.height - fixed.crop)
            }
            precondition(attempts == actualCrops.count && published.crop == actualCrops.last! && published.content == 840)
        }
        attempts = 0
        do {
            let _: Int = try await MacCanvasFrameConvergence.run { _ in
                attempts += 1
                throw MacCanvasCropChanged(recoveryGeneration: UUID(), window: 7, pid: 23, observedCrop: 38)
            }
            fatalError("Repeated capture crop changes must fail")
        } catch MacCanvasFrameConvergence.Problem.unstable {}
        precondition(attempts == 3)
        enum TargetFailure: Error { case changed }
        attempts = 0
        do {
            let _: Int = try await MacCanvasFrameConvergence.run { recovery in
                attempts += 1
                if recovery != nil { throw TargetFailure.changed }
                throw MacCanvasCropChanged(recoveryGeneration: UUID(), window: 7, pid: 23, observedCrop: 38)
            }
            fatalError("A changed window during recovery must not be retried")
        } catch TargetFailure.changed {}
        precondition(attempts == 2)
        attempts = 0
        do {
            let _: Int = try await MacCanvasFrameConvergence.run { _ in
                attempts += 1
                throw MacCanvasLayoutTransactions.Problem.stale
            }
            fatalError("Stale generations must never enter crop recovery")
        } catch MacCanvasLayoutTransactions.Problem.stale {}
        precondition(attempts == 1)
        print("Capture crop convergence, bounded failure, target replacement and stale-generation rejection passed")


    }
}
