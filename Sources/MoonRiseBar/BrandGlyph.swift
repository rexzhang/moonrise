import AppKit

/// 菜单栏品牌字形：双屏叠放剪影（前屏左下在前、后屏右上在后）。
/// 模板图标——系统自动按菜单栏深/浅模式反色。
/// 异常态：在字形中央叠加警示盘（透明圆）+ 实心黑色惊叹号，需要用户介入。
enum BrandGlyph {
    private static let size = NSSize(width: 18, height: 18)

    /// 正常态字形
    static func normal() -> NSImage {
        glyph(withBadge: false)
    }

    /// 异常态字形（中央警示盘 + 惊叹号）
    static func problem() -> NSImage {
        glyph(withBadge: true)
    }

    // MARK: - 私有

    private static func glyph(withBadge badge: Bool) -> NSImage {
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // 后屏（右上，横长方形）
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.addPath(roundedRect(CGRect(x: 7, y: 7, width: 10.5, height: 9), radius: 1.5))
            ctx.fillPath()
            // 前屏（左下，横长方形）：先以透明描边出 1px 分隔线，再填充——两屏之间 1px 分隔线
            ctx.setBlendMode(.clear)
            ctx.addPath(roundedRect(CGRect(x: 0.5, y: 0.5, width: 13, height: 10), radius: 1.8))
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.addPath(roundedRect(CGRect(x: 0.5, y: 0.5, width: 13, height: 10), radius: 1.8))
            ctx.fillPath()
            if badge {
                drawBadge(ctx)
            }
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 中央警示盘（透明圆）+ 实心惊叹号（竖条 + 圆点）
    private static func drawBadge(_ ctx: CGContext) {
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: 9 - 3.4, y: 9 - 3.4, width: 6.8, height: 6.8))
        ctx.setBlendMode(.normal)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.addPath(roundedRect(CGRect(x: 8.25, y: 9.0, width: 1.5, height: 3.2), radius: 0.75))
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: 9 - 0.95, y: 7.6 - 0.95, width: 1.9, height: 1.9))
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
