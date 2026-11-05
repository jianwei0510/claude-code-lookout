// App 的 logo（只有 Dock 圖示；視窗標題列不放任何標記）。
//
// 放射狀的等寬長條＋中心一個方塊：一個方框看著四面八方的工作。
// 顏色用 app 自己的「需要你」琥珀色（Mono Sharp 的 warning token），不借任何其他產品的品牌色。

import AppKit

private let amber = NSColor(srgbRed: 0.9577, green: 0.7636, blue: 0.3199, alpha: 1) // Mono Sharp warning（深色主題）
private let ivory = NSColor(srgbRed: 0.941, green: 0.933, blue: 0.902, alpha: 1)   // 象牙白
private let ink = NSColor(srgbRed: 0.098, green: 0.094, blue: 0.090, alpha: 1)     // 偏暖的近黑

/// 一圈放射狀長條。所有長度都以「畫布邊長」的比例給，任何尺寸都同一個形狀。
private func rays(center c: NSPoint, side: CGFloat, count: Int,
                  inner: CGFloat, long: CGFloat, short: CGFloat, width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<count {
        let outer = (i % 2 == 0 ? long : short) * side
        let bar = NSBezierPath(rect: NSRect(x: inner * side, y: -width * side / 2,
                                            width: outer - inner * side, height: width * side))
        var t = AffineTransform(translationByX: c.x, byY: c.y)
        // 從正上方開始，讓長條對稱地落在上下左右
        t.rotate(byRadians: CGFloat(i) * 2 * .pi / CGFloat(count) + .pi / 2)
        bar.transform(using: t)
        path.append(bar)
    }
    return path
}

private func coreSquare(center c: NSPoint, side: CGFloat, size: CGFloat) -> NSBezierPath {
    let s = size * side
    return NSBezierPath(rect: NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
}

/// Dock 圖示，1024×1024。外框照 macOS 圖示的慣例（四周留邊、大圓角）。
func appIcon() -> NSImage {
    NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
        let body = rect.insetBy(dx: 100, dy: 100)
        ink.setFill()
        NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()

        let c = NSPoint(x: rect.midX, y: rect.midY)
        let side = body.width
        amber.setFill()
        rays(center: c, side: side, count: 12, inner: 0.15, long: 0.40, short: 0.31, width: 0.08).fill()
        ivory.setFill()
        coreSquare(center: c, side: side, size: 0.16).fill()
        return true
    }
}
