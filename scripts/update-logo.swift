// update-logo.swift — Logo 更新管线：
//   swift scripts/update-logo.swift <source.png>
// 流程：alpha 边界裁剪 → 左右各留 10px、以此宽度为正方形、内容垂直居中 → 重出 logo masters（默认含 iconset）
// 完成后运行 bash scripts/install-app.sh 重编译 .icns 并重装。

import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers
import CoreText
import CoreImage

guard CommandLine.arguments.count >= 2 else {
    print("用法：swift scripts/update-logo.swift <source.png> [--logo-only]")
    print("  默认：新标准裁剪后全量输出（logo masters + iconset）")
    print("  --logo-only：仅输出 assets/brand/logo/（供查看，不动 iconset）")
    exit(64)
}
var srcPath = CommandLine.arguments[1]
var logoOnly = false
var appBg = false
if CommandLine.arguments.contains("--logo-only") { logoOnly = true }
if CommandLine.arguments.contains("--app-bg") { appBg = true }
if CommandLine.arguments.count >= 3, !CommandLine.arguments[2].hasPrefix("--") {
    srcPath = CommandLine.arguments[2]
}
let repoRoot = "/Users/rex/p/moonrise"
let outDir = repoRoot + "/assets/brand"

func loadCGImage(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let cond = [kCGImageSourceShouldCache: false] as CFDictionary
    return CGImageSourceCreateImageAtIndex(src, 0, cond)!
}

func makeContext(_ w: Int, _ h: Int, opaque: Bool = false) -> CGContext {
    let info = (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedLast).rawValue
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: info)!
}

func writePNG(_ cg: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// 1) 定稿裁剪区域（2026-11-06 用户确认）：x123 y135 1044×865（含月屏上方柔光带）
let useX = 123, useY = 135, useBoxW = 1044, useBoxH = 865
let source = loadCGImage(srcPath)

// 2) 裁切标准：内容左右各留 10px 空白，以此宽度为正方形边长，内容垂直居中（上下留白相等）
let side = useBoxW + 20
let canvas = makeContext(side, side)
// CG 位图上下文数据第 0 行 = 图像顶部行，扫描坐标即顶部原点坐标，直接裁剪
let cropped = source.cropping(to: CGRect(x: useX, y: useY, width: useBoxW, height: useBoxH))!
canvas.draw(cropped, in: CGRect(x: 10, y: CGFloat((side - useBoxH) / 2), width: CGFloat(useBoxW), height: CGFloat(useBoxH)))
let master = canvas.makeImage()!
let out = side

let masterPath = outDir + "/logo/moonrise-icon-master.png"
// 写前备份上一版 master（ buggy 输出绝不覆盖唯一输入源）
let backupPath = outDir + "/logo/.previous-master.png"
if FileManager.default.fileExists(atPath: masterPath) {
    try? FileManager.default.copyItem(atPath: masterPath, toPath: backupPath)
}
writePNG(master, masterPath)
writePNG(master, outDir + "/logo/moonrise-icon-1024.png")

// --bg-variants：背景色候选矩阵（平涂 + Joplin 式左上→右下对角光照）
let diagLight: (CGFloat, CGFloat) = (0.12, 0.16)   // 白 .12（左上）→ 黑 .16（右下）
let bgVariants: [(String, UInt32, String)] = [
    ("ink",    0x101318, "深墨 · 高反差（暗）"),
    ("white",  0xF5F5F7, "纯白 · 高反差（亮）"),
    ("joplin", 0x20669E, "经典蓝 · 中高反差（Joplin 致敬）"),
    ("purple", 0x3B2A66, "暗紫 · 中反差"),
    ("cream",  0xF1EDE4, "暖米 · 高反差（亮·暖调）"),
    ("navy",   0x16294F, "藏青 · 低反差对照组（与月屏同族）"),
]

func renderAppBg(baseHex: UInt32, withDiagonalLight: Bool, box: CGFloat = 758) -> CGImage {
    let c = makeContext(1024, 1024, opaque: true)
    c.saveGState()
    let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.addPath(squircle)
    c.clip()
    c.setFillColor(rgba(baseHex))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    if withDiagonalLight {
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [rgba(0xFFFFFF, diagLight.0), rgba(0xFFFFFF, 0), rgba(0x000000, diagLight.1)] as CFArray,
                               locations: [0, 0.5, 1])!
        c.drawLinearGradient(light, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    }
    let box: CGFloat = 758
    let s = box / CGFloat(master.width)
    let dw = CGFloat(master.width) * s
    let dh = CGFloat(master.height) * s
    c.draw(master, in: CGRect(x: (1024 - dw) / 2, y: (1024 - dh) / 2, width: dw, height: dh))
    c.restoreGState()
    return c.makeImage()!
}

if CommandLine.arguments.contains("--bg-variants") {
    func caption(_ c: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, x: CGFloat, y: CGFloat) {
        let attr = NSAttributedString(string: s,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, c)
    }
    let vdir = repoRoot + "/docs/logos/variants"
    try? FileManager.default.createDirectory(atPath: vdir, withIntermediateDirectories: true)
    var previews: [(String, CGImage)] = []
    for (name, hex, _) in bgVariants {
        let img = renderAppBg(baseHex: hex, withDiagonalLight: true)
        writePNG(img, vdir + "/variant-\(name)-1024.png")
        let small = makeContext(256, 256, opaque: true)
        small.draw(img, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        writePNG(small.makeImage()!, vdir + "/variant-\(name)-256.png")
        previews.append((name, small.makeImage()!))
        print("✓ variant-\(name)")
    }
    // 变体总览：3×2 网格
    let cw = 340, ch = 460, mg = 70
    let w = mg * 2 + cw * 3, h = mg + 150 + ch * 2 + mg
    let c = makeContext(w, h, opaque: true)
    c.setFillColor(rgba(0x0B1220))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    caption(c, "背景色候选 — 平涂 × 对角光照（左上→右下）", size: 46, weight: .bold,
            color: rgba(0xE8EEF9), x: CGFloat(mg), y: CGFloat(h - mg - 70))
    for (i, pv) in previews.enumerated() {
        let col: CGFloat = CGFloat(i % 3), row: CGFloat = CGFloat(i / 3)
        let x: CGFloat = CGFloat(mg) + col * CGFloat(cw)
        let y: CGFloat = CGFloat(h) - CGFloat(mg) - CGFloat(ch) - row * CGFloat(ch + 30) - 130
        c.draw(pv.1, in: CGRect(x: x, y: y, width: 256, height: 256))
        caption(c, bgVariants[i].2, size: 19, weight: .regular,
                color: rgba(0xE8EEF9), x: x, y: y - 34)
    }
    writePNG(c.makeImage()!, vdir + "/variants-overview.png")
    print("完成：docs/logos/variants/variants-overview.png")
    exit(0)
}

// --bg-final：初选色 × 三档边缘留白（按内容垂直留白真实拉开档位）
func renderAppBgSized(baseHex: UInt32, contentHeight: CGFloat) -> CGImage {
    let c = makeContext(1024, 1024, opaque: true)
    c.saveGState()
    let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.addPath(squircle)
    c.clip()
    c.setFillColor(rgba(baseHex))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [rgba(0xFFFFFF, 0.12), rgba(0xFFFFFF, 0), rgba(0x000000, 0.16)] as CFArray,
                           locations: [0, 0.5, 1])!
    c.drawLinearGradient(light, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // master 内容高占比 772/1274：按目标内容高等比放大（越界部分由 squircle 裁掉）
    let mSize = contentHeight / (772.0 / 1274.0)
    let dw = mSize, dh = mSize
    c.draw(master, in: CGRect(x: (1024 - dw) / 2, y: (1024 - dh) / 2, width: dw, height: dh))
    c.restoreGState()
    return c.makeImage()!
}

if CommandLine.arguments.contains("--bg-final") {
    func caption(_ c: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, x: CGFloat, y: CGFloat) {
        let attr = NSAttributedString(string: s,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, c)
    }
    let fdir = repoRoot + "/docs/logos/variants/final"
    try? FileManager.default.createDirectory(atPath: fdir, withIntermediateDirectories: true)
    let combos: [(String, UInt32, CGFloat, String)] = [
        ("white-mid", 0xF5F5F7, 554, "纯白 · 中间档"),
        ("navy-mid",  0x16294F, 554, "藏青 · 中间档"),
    ]
    var previews: [(String, String, CGImage)] = []
    for (name, hex, contentH, label) in combos {
        let img = renderAppBgSized(baseHex: hex, contentHeight: contentH)
        writePNG(img, fdir + "/final-\(name)-1024.png")
        let small = makeContext(256, 256, opaque: true)
        small.draw(img, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        writePNG(small.makeImage()!, fdir + "/final-\(name)-256.png")
        previews.append((name, label, small.makeImage()!))
        print("✓ final-\(name)")
    }
    let cw = 340, ch = 300, mg = 70
    let w = mg * 2 + cw * 3, h = mg + 150 + ch * 2 + mg
    let c = makeContext(w, h, opaque: true)
    c.setFillColor(rgba(0x0B1220))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    caption(c, "初选定稿 — 纯白 / 藏青 × 三档边缘留白", size: 46, weight: .bold,
            color: rgba(0xE8EEF9), x: CGFloat(mg), y: CGFloat(h - mg - 70))
    for (i, pv) in previews.enumerated() {
        let col: CGFloat = CGFloat(i % 3), row: CGFloat = CGFloat(i / 3)
        let x: CGFloat = CGFloat(mg) + col * CGFloat(cw)
        let y: CGFloat = CGFloat(h) - CGFloat(mg) - CGFloat(ch) - row * CGFloat(ch + 30) - 130
        c.draw(pv.2, in: CGRect(x: x, y: y, width: 256, height: 256))
        caption(c, pv.1, size: 19, weight: .regular, color: rgba(0xE8EEF9), x: x, y: y - 34)
    }
    writePNG(c.makeImage()!, fdir + "/final-overview.png")
    print("完成：docs/logos/variants/final/final-overview.png")
    exit(0)
}

// --bg-fit：垂直留白的三种结构性方案 × 纯白/藏青
if CommandLine.arguments.contains("--bg-fit") {
    func caption(_ c: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, x: CGFloat, y: CGFloat) {
        let attr = NSAttributedString(string: s,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, c)
    }
    // 不透明铺底图（base 色 + master 等比放大居中）——供模糊延展使用
    func coverTile(_ baseHex: UInt32) -> CGImage {
        let c = makeContext(1024, 1024, opaque: true)
        c.setFillColor(rgba(baseHex))
        c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let s = max(1024 / CGFloat(master.width), 1024 / CGFloat(master.height))
        let dw = CGFloat(master.width) * s, dh = CGFloat(master.height) * s
        c.draw(master, in: CGRect(x: (1024 - dw) / 2, y: (1024 - dh) / 2, width: dw, height: dh))
        return c.makeImage()!
    }
    func blurred(_ img: CGImage) -> CGImage {
        let ci = CIImage(cgImage: img)
        let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: ci, kCIInputRadiusKey: 40])!
        let ctx = CIContext()
        return ctx.createCGImage(f.outputImage!, from: CGRect(x: 0, y: 0, width: 1024, height: 1024))!
    }
    let fdir = repoRoot + "/docs/logos/variants/fit"
    try? FileManager.default.createDirectory(atPath: fdir, withIntermediateDirectories: true)

    func renderFit(baseHex: UInt32, mode: String) -> CGImage {
        let c = makeContext(1024, 1024, opaque: true)
        c.saveGState()
        let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.addPath(squircle)
        c.clip()
        switch mode {
        case "blurfill":
            c.draw(blurred(coverTile(baseHex)), in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        case "glow":
            c.setFillColor(rgba(baseHex))
            c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [rgba(0xFFFFFF, 0.16), rgba(0xF2DFA2, 0.10), rgba(0x000000, 0)] as CFArray,
                                  locations: [0, 0.5, 1])!
            c.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                                 endCenter: CGPoint(x: 512, y: 512), endRadius: 520, options: [])
        case "vcrop":
            c.setFillColor(rgba(baseHex))
            c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            let s = 744.0 / CGFloat(master.height)
            let dw = CGFloat(master.width) * s
            c.draw(master, in: CGRect(x: (1024 - dw) / 2, y: 140, width: dw, height: 744))
        default: break
        }
        c.restoreGState()
        // 清晰内容（C 几何：内容盒 826）
        let s2 = 826.0 / CGFloat(master.width)
        let dw2 = CGFloat(master.width) * s2
        let dh2 = CGFloat(master.height) * s2
        c.draw(master, in: CGRect(x: (1024 - dw2) / 2, y: (1024 - dh2) / 2, width: dw2, height: dh2))
        return c.makeImage()!
    }

    let combos: [(String, UInt32, String, String)] = [
        ("white-blur",  0xF5F5F7, "blurfill", "纯白 · 模糊延展底"),
        ("navy-blur",   0x16294F, "blurfill", "藏青 · 模糊延展底"),
        ("white-glow",  0xF5F5F7, "glow",     "纯白 · 辉光填充"),
        ("navy-glow",   0x16294F, "glow",     "藏青 · 辉光填充"),
        ("white-vcrop", 0xF5F5F7, "vcrop",    "纯白 · 竖向满幅（左右裁~190）"),
        ("navy-vcrop",  0x16294F, "vcrop",    "藏青 · 竖向满幅（左右裁~190）"),
    ]
    let dir = repoRoot + "/docs/logos/variants/fit"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var previews: [(String, String, CGImage)] = []
    for (name, hex, mode, label) in combos {
        let img = renderFit(baseHex: hex, mode: mode)
        writePNG(img, dir + "/fit-\(name)-1024.png")
        let small = makeContext(256, 256, opaque: true)
        small.draw(img, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        writePNG(small.makeImage()!, dir + "/fit-\(name)-256.png")
        previews.append((name, label, small.makeImage()!))
        print("✓ fit-\(name)")
    }
    let cw = 340, ch = 300, mg = 70
    let w = mg * 2 + cw * 3, h = mg + 150 + ch * 2 + mg
    let c = makeContext(w, h, opaque: true)
    c.setFillColor(rgba(0x0B1220))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    caption(c, "垂直留白三方案 — 模糊延展 / 辉光 / 竖向满幅", size: 44, weight: .bold,
            color: rgba(0xE8EEF9), x: CGFloat(mg), y: CGFloat(h - mg - 70))
    for (i, pv) in previews.enumerated() {
        let col: CGFloat = CGFloat(i % 3), row: CGFloat = CGFloat(i / 3)
        let x: CGFloat = CGFloat(mg) + col * CGFloat(cw)
        let y: CGFloat = CGFloat(h) - CGFloat(mg) - CGFloat(ch) - row * CGFloat(ch + 30) - 130
        c.draw(pv.2, in: CGRect(x: x, y: y, width: 256, height: 256))
        caption(c, pv.1, size: 18, weight: .regular, color: rgba(0xE8EEF9), x: x, y: y - 34)
    }
    writePNG(c.makeImage()!, dir + "/fit-overview.png")
    print("完成：docs/logos/variants/fit/fit-overview.png")
    exit(0)
}

// --app-bg：macOS 生态风格应用图标背景（824 squircle，rx 185；渐变取自 logo 色彩世界）
if appBg {
    let c = makeContext(1024, 1024, opaque: true)
    c.saveGState()
    let squircle = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.addPath(squircle)
    c.clip()
    // Joplin 风格：纯色平涂、高反差（深墨底 × 暖橙/亮蓝双屏）
    c.setFillColor(rgba(0x101318))
    c.fillPath()
    // 左右留白减半：内容盒 664 → 758（等比缩放，垂直留白随动 211→182）
    let box: CGFloat = 758
    let s = box / CGFloat(master.width)
    let dw = CGFloat(master.width) * s
    let dh = CGFloat(master.height) * s
    c.draw(master, in: CGRect(x: (1024 - dw) / 2, y: (1024 - dh) / 2, width: dw, height: dh))
    c.restoreGState()
    writePNG(c.makeImage()!, outDir + "/logo/moonrise-icon-app-1024.png")
    let small = makeContext(256, 256, opaque: true)
    small.draw(c.makeImage()!, in: CGRect(x: 0, y: 0, width: 256, height: 256))
    writePNG(small.makeImage()!, outDir + "/logo/moonrise-icon-app-256.png")
    print("✓ app 风格背景已合成：logo/moonrise-icon-app-{1024,256}.png")
}

// 3) sips 重出其余尺寸（--logo-only 只出 logo 目录）
var derived: [(String, Int)] = [
    (outDir + "/logo/moonrise-icon-1024.png", 1024),
    (outDir + "/logo/moonrise-icon-512.png", 512),
    (outDir + "/logo/moonrise-icon-256.png", 256),
    (outDir + "/logo/moonrise-icon-128.png", 128),
]
if !logoOnly {
    derived += [
        (outDir + "/MoonRise.iconset/icon_16x16.png", 16),
        (outDir + "/MoonRise.iconset/icon_16x16@2x.png", 32),
        (outDir + "/MoonRise.iconset/icon_32x32.png", 32),
        (outDir + "/MoonRise.iconset/icon_32x32@2x.png", 64),
        (outDir + "/MoonRise.iconset/icon_128x128.png", 128),
        (outDir + "/MoonRise.iconset/icon_128x128@2x.png", 256),
        (outDir + "/MoonRise.iconset/icon_256x256.png", 256),
        (outDir + "/MoonRise.iconset/icon_256x256@2x.png", 512),
        (outDir + "/MoonRise.iconset/icon_512x512.png", 512),
        (outDir + "/MoonRise.iconset/icon_512x512@2x.png", 1024),
    ]
}
for (path, size) in derived {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", String(size), String(size), masterPath, "--out", path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    print("✓ \(path.replacingOccurrences(of: outDir + "/", with: "")) @\(size)")
}
print("完成：bash scripts/install-app.sh 重编译 .icns 并重装")
