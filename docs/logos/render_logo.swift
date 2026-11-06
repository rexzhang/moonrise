// render_logo.swift — 渲染 docs/logos/render/ 下的四个候选标识。
// 运行：swift docs/logos/render_logo.swift
// 几何与 docs/logos/gallery.html 一一对应；选定候选后按同一几何转 .icns。

import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers
import CoreText

let outDir = URL(fileURLWithPath: "/Users/rex/p/moonrise/docs/logos")

// MARK: - 基础

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func makeContext(_ w: Int, _ h: Int, opaque: Bool = false) -> CGContext {
    let info = (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedLast).rawValue
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: info)!
}

func writePNG(_ cg: CGImage, _ relative: String) {
    let url = outDir.appendingPathComponent(relative)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("✓ \(relative)")
}

func rounded(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

let iconGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgba(0x1B2F55), rgba(0x0C1830)] as CFArray,
                              locations: [0, 1])!

/// 垂直渐变按同一用户空间坐标填充任意路径（用于月牙裁切处的"挖色还原"）
func fillGradient(_ c: CGContext, in rect: CGRect) {
    c.saveGState()
    c.addRect(rect)
    c.clip()
    c.drawLinearGradient(iconGradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
    c.restoreGState()
}

/// App 图标：1024 画布、圆角 228、夜空渐变；candidate 闭包在翻转后的 SVG 坐标系里作画
func renderIcon(_ candidate: (CGContext) -> Void) -> CGImage {
    let c = makeContext(1024, 1024, opaque: true)
    c.translateBy(x: 0, y: 1024)
    c.scaleBy(x: 1, y: -1)
    c.saveGState()
    c.addPath(rounded(CGRect(x: 0, y: 0, width: 1024, height: 1024), 228))
    c.clip()
    fillGradient(c, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    candidate(c)
    c.restoreGState()
    return c.makeImage()!
}

func star(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
    c.setFillColor(rgba(0xDCE6F8, a))
    c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// MARK: - 四个候选的图标绘制（SVG 坐标系）

func drawHorizon(_ c: CGContext) {
    star(c, 300, 292, 9, 0.85); star(c, 702, 236, 13, 0.6)
    star(c, 566, 168, 7, 0.75); star(c, 824, 420, 8, 0.5)
    c.setFillColor(rgba(0xF2DFA2, 0.1))
    c.fillEllipse(in: CGRect(x: 512 - 266, y: 560 - 266, width: 532, height: 532))
    c.saveGState()
    c.addRect(CGRect(x: 0, y: 0, width: 1024, height: 712))
    c.clip()
    c.setFillColor(rgba(0xF2DFA2))
    c.fillEllipse(in: CGRect(x: 512 - 212, y: 560 - 212, width: 424, height: 424))
    c.restoreGState()
    c.setFillColor(rgba(0xE8B84B))
    c.addPath(rounded(CGRect(x: 150, y: 712, width: 724, height: 12), 6))
    c.fillPath()
}

func drawScreenMoon(_ c: CGContext) {
    c.setFillColor(rgba(0x0A1428))
    c.addPath(rounded(CGRect(x: 212, y: 296, width: 600, height: 404), 38))
    c.fillPath()
    c.setStrokeColor(rgba(0xDCE6F8, 0.4))
    c.setLineWidth(10)
    c.addPath(rounded(CGRect(x: 212, y: 296, width: 600, height: 404), 38))
    c.strokePath()
    c.setFillColor(rgba(0xF2DFA2))
    c.fillEllipse(in: CGRect(x: 470 - 96, y: 500 - 96, width: 192, height: 192))
    c.setFillColor(rgba(0x0A1428))   // 屏内底色填充偏移圆 → 月牙
    c.fillEllipse(in: CGRect(x: 524 - 90, y: 468 - 90, width: 180, height: 180))
    c.setFillColor(rgba(0xDCE6F8, 0.35))
    c.addPath(rounded(CGRect(x: 462, y: 700, width: 100, height: 30), 12)); c.fillPath()
    c.addPath(rounded(CGRect(x: 392, y: 730, width: 240, height: 14), 7)); c.fillPath()
}

func drawOrbit(_ c: CGContext) {
    star(c, 806, 252, 9, 0.7); star(c, 248, 266, 7, 0.6)
    c.saveGState()
    c.translateBy(x: 512, y: 540)
    c.rotate(by: -16 * .pi / 180)
    c.setStrokeColor(rgba(0xE8B84B))
    c.setLineWidth(8)
    c.strokeEllipse(in: CGRect(x: -336, y: -128, width: 672, height: 256))
    c.restoreGState()
    c.setFillColor(rgba(0xDCE6F8))
    c.fillEllipse(in: CGRect(x: 820 - 16, y: 394 - 16, width: 32, height: 32))
    c.setFillColor(rgba(0xF2DFA2))
    c.fillEllipse(in: CGRect(x: 472 - 230, y: 560 - 230, width: 460, height: 460))
    c.saveGState()
    c.addPath(CGPath(ellipseIn: CGRect(x: 576 - 204, y: 478 - 204, width: 408, height: 408), transform: nil))
    c.clip()
    fillGradient(c, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    c.restoreGState()
}

func drawEclipse(_ c: CGContext) {
    star(c, 706, 238, 9, 0.7); star(c, 262, 248, 7, 0.55)
    c.setFillColor(rgba(0xF2C14E))
    c.fillEllipse(in: CGRect(x: 404 - 216, y: 512 - 216, width: 432, height: 432))
    c.setFillColor(rgba(0x101E3A))
    c.fillEllipse(in: CGRect(x: 600 - 216, y: 512 - 216, width: 432, height: 432))
    c.setStrokeColor(rgba(0xE8B84B))
    c.setLineWidth(8)
    c.strokeEllipse(in: CGRect(x: 600 - 216, y: 512 - 216, width: 432, height: 432))
}

// MARK: - 菜单栏模板字形（24 盒，单色；月牙裁切用 blend clear 保持透明）

func glyphHorizon(_ c: CGContext, _ color: CGColor) {
    c.setFillColor(color)
    c.fillEllipse(in: CGRect(x: 12 - 6.5, y: 10 - 6.5, width: 13, height: 13))
    c.addPath(rounded(CGRect(x: 3, y: 18.6, width: 18, height: 1.8), 0.9)); c.fillPath()
}

func glyphScreenMoon(_ c: CGContext, _ color: CGColor) {
    c.setStrokeColor(color); c.setLineWidth(1.7)
    c.addPath(rounded(CGRect(x: 3, y: 4.5, width: 18, height: 12.5), 2.2)); c.strokePath()
    c.setFillColor(color)
    c.fillEllipse(in: CGRect(x: 9.6 - 3.1, y: 10.6 - 3.1, width: 6.2, height: 6.2))
    c.addPath(rounded(CGRect(x: 9, y: 18.4, width: 6, height: 1.6), 0.8)); c.fillPath()
    c.addPath(rounded(CGRect(x: 6.5, y: 20.6, width: 11, height: 1.4), 0.7)); c.fillPath()
}

func glyphOrbit(_ c: CGContext, _ color: CGColor) {
    c.setFillColor(color)
    c.fillEllipse(in: CGRect(x: 10.5 - 7, y: 13 - 7, width: 14, height: 14))
    c.setBlendMode(.clear)
    c.fillEllipse(in: CGRect(x: 15.5 - 6.2, y: 9.5 - 6.2, width: 12.4, height: 12.4))
    c.setBlendMode(.normal)
    c.fillEllipse(in: CGRect(x: 19 - 1.8, y: 5.5 - 1.8, width: 3.6, height: 3.6))
}

func glyphEclipse(_ c: CGContext, _ color: CGColor) {
    c.setFillColor(color)
    c.fillEllipse(in: CGRect(x: 9.5 - 6, y: 12 - 6, width: 12, height: 12))
    c.setStrokeColor(color); c.setLineWidth(1.7)
    c.strokeEllipse(in: CGRect(x: 14.5 - 6, y: 12 - 6, width: 12, height: 12))
}

// MARK: - 菜单栏合成图（400×88：深色 / 浅色两条）

func renderBar(_ glyph: (CGContext, CGColor) -> Void, dark: Bool) -> CGImage {
    let w = 400, h = 88, barH = 64
    let c = makeContext(w, h)
    c.setFillColor(dark ? rgba(0x1C1C1E) : rgba(0xECECED))
    c.addPath(rounded(CGRect(x: 0, y: h - barH, width: w, height: barH), 14))
    c.fillPath()
    let fg = dark ? rgba(0xF5F5F7) : rgba(0x1D1D1F)
    let slot = dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22)
    // 字形：26px，位于左侧
    let g = makeContext(26, 26)
    g.translateBy(x: 0, y: 26)
    g.scaleBy(x: 1, y: -1)
    g.scaleBy(x: 26.0 / 24.0, y: 26.0 / 24.0)
    glyph(g, fg)
    c.draw(g.makeImage()!, in: CGRect(x: 18, y: h - barH + (barH - 26) / 2, width: 26, height: 26))
    // 占位图标 ×2 + 时钟
    c.setFillColor(slot)
    for i in 0..<2 {
        let slotX: CGFloat = 60 + CGFloat(i) * 36
        let slotY: CGFloat = CGFloat(h) - CGFloat(barH) + 19
        let slotPath = rounded(CGRect(x: slotX, y: slotY, width: 26, height: 26), 8)
        c.addPath(slotPath)
        c.fillPath()
    }
    let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
    let line = NSAttributedString(string: "23:41", attributes: attr)
    let size = line.size()
    let clockW: CGFloat = CGFloat(w) - size.width - 24
    let clockH: CGFloat = size.height + 4
    let clockY: CGFloat = CGFloat(h) - CGFloat(barH) + (CGFloat(barH) - size.height) / 2 - 2
    let clockRect = CGRect(x: clockW, y: clockY, width: size.width + 4, height: clockH)
    line.draw(in: clockRect)
    return c.makeImage()!
}

func renderGlyph(_ glyph: (CGContext, CGColor) -> Void, _ color: CGColor) -> CGImage {
    let c = makeContext(96, 96)
    c.translateBy(x: 0, y: 96)
    c.scaleBy(x: 1, y: -1)
    c.scaleBy(x: 4, y: 4)
    glyph(c, color)
    return c.makeImage()!
}

// MARK: - 总览拼图

func drawText(_ c: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, x: CGFloat, y: CGFloat) {
    let attr = NSAttributedString(string: s,
        attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attr)
    c.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, c)
}

func renderSheet(_ items: [(String, String, CGImage, CGImage, CGImage)]) -> CGImage {
    let margin = 60, cellW = 860, iconSize = 300, gap = 24
    let cellH = iconSize + 2 * (88 + 10) + 70
    let w = margin * 2 + cellW * 2 + gap
    let h = margin + 120 + cellH * 2 + gap
    let c = makeContext(w, h, opaque: true)
    c.setFillColor(rgba(0x0B1220))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    drawText(c, "MoonRise 标识候选 — App 图标 × 菜单栏", size: 44, weight: .bold,
             color: rgba(0xE8EEF9), x: CGFloat(margin), y: CGFloat(h - margin - 90))
    drawText(c, "docs/logos/render · 深色菜单栏为默认形态", size: 22, weight: .regular,
             color: rgba(0x97A5C0), x: CGFloat(margin), y: CGFloat(h - margin - 28))
    for (i, item) in items.enumerated() {
        let col: CGFloat = CGFloat(i % 2)
        let row: CGFloat = CGFloat(i / 2)
        let x: CGFloat = CGFloat(margin) + col * CGFloat(cellW + gap)
        let yTop: CGFloat = CGFloat(h) - 200 - CGFloat(cellH) - row * CGFloat(cellH + gap)
        let iconY: CGFloat = yTop + CGFloat(cellH) - CGFloat(iconSize)
        c.draw(item.2, in: CGRect(x: x, y: iconY, width: CGFloat(iconSize), height: CGFloat(iconSize)))
        let barX: CGFloat = x + CGFloat(iconSize) + 28
        let barW: CGFloat = CGFloat(cellW) - CGFloat(iconSize) - 28
        drawText(c, item.0, size: 28, weight: .semibold, color: rgba(0xE8B84B), x: barX, y: iconY + CGFloat(iconSize) - 20)
        drawText(c, item.1, size: 20, weight: .regular, color: rgba(0xE8EEF9), x: barX, y: iconY + CGFloat(iconSize) - 60)
        let bar1 = CGRect(x: barX, y: iconY + 150, width: barW, height: 88)
        let bar2 = CGRect(x: barX, y: iconY + 40, width: barW, height: 88)
        c.draw(item.3, in: bar1)
        c.draw(item.4, in: bar2)
    }
    return c.makeImage()!
}

// MARK: - 执行

let candidates: [(String, String, (CGContext) -> Void, (CGContext, CGColor) -> Void)] = [
    ("01-horizon", "月出", drawHorizon, glyphHorizon),
    ("02-screen-moon", "屏月", drawScreenMoon, glyphScreenMoon),
    ("03-orbit", "轨道", drawOrbit, glyphOrbit),
    ("04-eclipse", "日月", drawEclipse, glyphEclipse),
]

var sheetItems: [(String, String, CGImage, CGImage, CGImage)] = []
for (slug, name, iconDraw, glyphDraw) in candidates {
    let icon = renderIcon(iconDraw)
    let darkBar = renderBar(glyphDraw, dark: true)
    let lightBar = renderBar(glyphDraw, dark: false)
    writePNG(icon, "render/\(slug)/icon.png")
    writePNG(darkBar, "render/\(slug)/menubar-dark.png")
    writePNG(lightBar, "render/\(slug)/menubar-light.png")
    writePNG(renderGlyph(glyphDraw, rgba(0x000000)), "render/\(slug)/glyph-black.png")
    writePNG(renderGlyph(glyphDraw, rgba(0xFFFFFF)), "render/\(slug)/glyph-white.png")
    sheetItems.append((slug, name, icon, darkBar, lightBar))
}
writePNG(renderSheet(sheetItems), "render/overview.png")
print("完成：open docs/logos/render/overview.png")
