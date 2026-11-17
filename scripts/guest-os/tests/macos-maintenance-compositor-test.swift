import CoreGraphics

@main
struct MaintenanceCompositorTests {
    static func main() {
        let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        func accepted(_ bundle: String, _ layer: Int, _ bounds: CGRect,
                      signed: Bool = true, major: Int = 15) -> Bool {
            macMaintenanceCompositorSurface(bundle: bundle, appleSigned: signed,
                                            layer: layer, bounds: bounds, display: display, systemMajor: major)
        }
        precondition(accepted("com.apple.dock", 20, display))
        precondition(accepted("com.apple.notificationcenterui", 23, display))
        precondition(!accepted("com.apple.dock", 20, display, signed: false))
        precondition(!accepted("com.apple.notificationcenterui", 23, display, signed: false))
        precondition(!accepted("com.example.notificationcenterui", 23, display))
        precondition(!accepted("com.apple.dock", 0, display))
        precondition(!accepted("com.apple.notificationcenterui", 0, display))
        precondition(!accepted("com.apple.dock", 20, CGRect(x: 0, y: 700, width: 1600, height: 300)))
        precondition(!accepted("com.apple.notificationcenterui", 23, display.offsetBy(dx: 1, dy: 0)))
        precondition(accepted("com.apple.dock", 20, display, major: 26))
        precondition(accepted("com.apple.notificationcenterui", 21, display, major: 26))
        precondition(!accepted("com.apple.notificationcenterui", 23, display, major: 26))
        precondition(!accepted("com.apple.notificationcenterui", 21, display))
        precondition(!accepted("com.apple.UserNotificationCenter", 21, display, major: 26))
        precondition(accepted("com.apple.dock", 20, display, major: 27))
        precondition(accepted("com.apple.notificationcenterui", 23, display, major: 27))
        precondition(!accepted("com.apple.notificationcenterui", 23, display, signed: false, major: 27))
        precondition(!accepted("com.apple.notificationcenterui", 21, display, major: 27))
        precondition(!accepted("com.apple.dock", 20, display, major: 28))
        precondition(!accepted("com.apple.notificationcenterui", 21,
                              CGRect(x: 1200, y: 40, width: 360, height: 180), major: 26))
        let cursor = CGRect(x: 794, y: 307, width: 23, height: 22)
        let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
        precondition(accepted("com.apple.WindowServer", cursorLayer, cursor, major: 26))
        precondition(!accepted("com.apple.WindowServer", cursorLayer, cursor, signed: false, major: 26))
        precondition(!accepted("com.example.WindowServer", cursorLayer, cursor, major: 26))
        precondition(!accepted("com.apple.WindowServer", 24, cursor, major: 26))
        precondition(!accepted("com.apple.WindowServer", cursorLayer, display, major: 26))
        precondition(!accepted("com.apple.WindowServer", cursorLayer,
                              CGRect(x: 0, y: 0, width: 129, height: 22), major: 26))
        precondition(!accepted("com.apple.WindowServer", cursorLayer,
                              cursor.offsetBy(dx: -1600, dy: 0), major: 26))
        precondition(!accepted("com.apple.WindowServer", cursorLayer, .zero, major: 26))
        print("macOS maintenance compositor checks passed")
    }
}
