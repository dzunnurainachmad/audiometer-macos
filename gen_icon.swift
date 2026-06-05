#!/usr/bin/swift
import AppKit

func makeIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // ── Background rounded rect ──────────────────────────────────────────
    let radius = s * 0.22
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bg); ctx.clip()
    ctx.setFillColor(CGColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // ── Subtle inner glow at top ─────────────────────────────────────────
    let glowColors = [CGColor(red: 0.25, green: 0.85, blue: 0.50, alpha: 0.12),
                      CGColor(red: 0.25, green: 0.85, blue: 0.50, alpha: 0.00)] as CFArray
    let glowLocs: [CGFloat] = [0, 1]
    let gSpace = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: gSpace, colors: glowColors, locations: glowLocs) {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: s/2, y: s),
            end:   CGPoint(x: s/2, y: s * 0.4),
            options: [])
    }

    // ── Audio bars ───────────────────────────────────────────────────────
    // Waveform-like heights (low → peak → low)
    let amps: [CGFloat] = [0.18, 0.28, 0.45, 0.62, 0.78, 0.92, 1.00, 0.88, 0.72, 0.55, 0.35, 0.22, 0.13]
    let n = amps.count
    let maxH  = s * 0.62
    let barW  = s * 0.042
    let gap   = s * 0.022
    let totalW = CGFloat(n) * barW + CGFloat(n - 1) * gap
    let startX = (s - totalW) / 2
    let midY   = s * 0.50

    for i in 0..<n {
        let t   = CGFloat(i) / CGFloat(n - 1)
        // Green (#40D97F) → Blue (#33A6F2)
        let r = CGFloat(0.25 + 0.08 * t)
        let g = CGFloat(0.85 - 0.20 * t)
        let b = CGFloat(0.50 + 0.45 * t)
        let alpha: CGFloat = 0.92

        let h = amps[i] * maxH
        let x = startX + CGFloat(i) * (barW + gap)
        let y = midY - h / 2

        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: alpha))
        let barR = s < 64 ? barW * 0.35 : barW * 0.40
        let bar = CGPath(roundedRect: CGRect(x: x, y: y, width: barW, height: h),
                         cornerWidth: barR, cornerHeight: barR, transform: nil)
        ctx.addPath(bar)
        ctx.fillPath()
    }

    // ── Fine top-edge specular line ──────────────────────────────────────
    if size >= 64 {
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
        ctx.setLineWidth(max(1, s * 0.005))
        let line = CGMutablePath()
        line.move(to:    CGPoint(x: radius, y: s - 1))
        line.addLine(to: CGPoint(x: s - radius, y: s - 1))
        ctx.addPath(line); ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS AppIcon sizes
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

for sz in sizes {
    let data = makeIcon(size: sz)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(sz).png")
    try! data.write(to: url)
    print("✓ icon_\(sz).png")
}
