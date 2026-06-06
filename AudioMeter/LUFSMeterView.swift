import SwiftUI

// MARK: - Vertical bar LUFS meter (right-side panel)

struct LUFSBarMeterView: View {
    let lufsM: Float
    let lufsS: Float
    let lufsMPeak: Float
    let lufsSPeak: Float

    private let rangeMax: Float =   0
    private let rangeMin: Float = -50

    private let marks: [(label: String, lufs: Float)] = [
        ("0",   0),
        ("6",  -6),
        ("12", -12),
        ("24", -24),
        ("36", -36),
        ("50", -50),
    ]

    var body: some View {
        GeometryReader { geo in
            let padV: CGFloat = 12
            let usableH = geo.size.height - padV * 2

            HStack(alignment: .top, spacing: 0) {

                // ── Scale: numbers + ticks ────────────────────────────────
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(marks, id: \.label) { label, lufs in
                        HStack(spacing: 4) {
                            Text(label)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                                .frame(width: 22, alignment: .trailing)
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 6, height: 0.5)
                        }
                        .frame(height: 10)
                        .offset(y: yOffset(lufs: lufs, usableH: usableH) + padV - 5)
                    }
                }
                .frame(width: 36)

                // ── Bars ──────────────────────────────────────────────────
                HStack(spacing: 5) {
                    BarStrip(value: lufsM, peak: lufsMPeak,
                             rangeMin: rangeMin, rangeMax: rangeMax,
                             color: Color(white: 0.80))

                    BarStrip(value: lufsS, peak: lufsSPeak,
                             rangeMin: rangeMin, rangeMax: rangeMax,
                             color: Color(white: 0.35))
                }
                .padding(.vertical, padV)
                .frame(width: 38)

                // ── Readout ───────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()

                    // Momentary
                    readoutRow(value: lufsM,
                               label: "M",
                               color: Color(white: 0.95),
                               fontSize: 20)

                    Spacer().frame(height: 10)

                    // Short-Term
                    readoutRow(value: lufsS,
                               label: "S",
                               color: Color(white: 0.50),
                               fontSize: 15)

                    Spacer().frame(height: 6)

                    Text("LUFS")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.25))
                        .tracking(1.5)

                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }

    // MARK: Helpers

    private func yOffset(lufs: Float, usableH: CGFloat) -> CGFloat {
        CGFloat((rangeMax - lufs) / (rangeMax - rangeMin)) * usableH
    }

    @ViewBuilder
    private func readoutRow(value: Float, label: String, color: Color, fontSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value <= -140 ? "-∞" : String(format: "%.1f", value))
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(color.opacity(0.5))
        }
    }
}

// MARK: - Single vertical bar strip (Canvas-based — murah, redraw hanya saat data berubah)
// Kehalusan didapat dari rate data yang lebih tinggi (lihat AudioCaptureEngine),
// BUKAN dari animasi SwiftUI 60fps yang bikin loop render kedua (mahal).

struct BarStrip: View {
    let value:    Float
    let peak:     Float
    let rangeMin: Float
    let rangeMax: Float
    let color:    Color

    private func frac(_ v: Float) -> CGFloat {
        guard v > -140 else { return 0 }
        return CGFloat((max(rangeMin, min(rangeMax, v)) - rangeMin) / (rangeMax - rangeMin))
    }

    var body: some View {
        Canvas { ctx, size in
            let h    = size.height
            let fill = frac(value)
            let pkF  = frac(peak)

            // Track
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: h),
                          cornerRadius: 2),
                     with: .color(.white.opacity(0.06)))

            // Fill bar — rises from bottom
            if fill > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: h * (1 - fill),
                                                   width: size.width, height: h * fill),
                              cornerRadius: 2),
                         with: .color(color))
            }

            // Peak hold line
            if peak > -140 && pkF > 0 {
                ctx.fill(Path(CGRect(x: 0, y: h * (1 - pkF) - 1,
                                     width: size.width, height: 2)),
                         with: .color(color))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 0) {
        Rectangle()
            .fill(Color.black.opacity(0.6))
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 1)
        LUFSBarMeterView(lufsM: -9.3, lufsS: -11.1, lufsMPeak: -7.2, lufsSPeak: -8.5)
            .frame(width: 160)
    }
    .frame(width: 680, height: 260)
    .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    .preferredColorScheme(.dark)
}
