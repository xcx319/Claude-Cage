import CoreGraphics

// 系统合成平面会报告整屏边界；鼠标指针也出现在窗口列表中。
// 仅排除实机确认的 Apple 签名、层级和几何组合，交互窗口仍参与遮挡检查。
func macMaintenanceCompositorSurface(bundle: String, appleSigned: Bool, layer: Int,
                                     bounds: CGRect, display: CGRect, systemMajor: Int) -> Bool {
    guard [15, 26, 27].contains(systemMajor), appleSigned, !display.isEmpty,
          !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else { return false }
    if bundle == "com.apple.WindowServer" {
        return layer == Int(CGWindowLevelForKey(.cursorWindow)) &&
            bounds.width <= 128 && bounds.height <= 128 && display.contains(bounds)
    }
    guard bounds == display else { return false }
    return bundle == "com.apple.dock" && layer == 20 ||
        bundle == "com.apple.notificationcenterui" && layer == (systemMajor == 26 ? 21 : 23)
}
