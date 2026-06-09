import SwiftUI

// MARK: - Meter panel (right-side)
// Kiri: Peak Meter stereo (L/R, dBFS) — respons cepat seperti waveform, garis
//       peak-hold oranye. Kanan: Short-term LUFS (1 bar) + angka.
// Angka hanya ditampilkan untuk Short.

struct LUFSBarMeterView: View {
    let peakL:     Float   // dBFS
    let peakR:     Float
    let peakHoldL: Float
    let peakHoldR: Float
    let lufsS:     Float   // LUFS
    let lufsSPeak: Float

    private let rangeMax: Float =   0
    private let rangeMin: Float = -50

    private let peakColor  = Color(red: 0.74, green: 0.78, blue: 0.92)
    private let holdColor  = Color(red: 0.97, green: 0.62, blue: 0.20)
    private let shortColor = Color(red: 0.62, green: 0.66, blue: 0.82)

    private let marks: [(label: String, db: Float)] = [
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
                    ForEach(marks, id: \.label) { label, db in
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
                        .offset(y: yOffset(db: db, usableH: usableH) + padV - 5)
                    }
                }
                .frame(width: 36)

                // ── Bars: [L peak][R peak]   [S LUFS] ─────────────────────
                HStack(alignment: .center, spacing: 0) {
                    // Peak meter stereo
                    HStack(spacing: 3) {
                        BarStrip(value: peakL, peak: peakHoldL,
                                 rangeMin: rangeMin, rangeMax: rangeMax,
                                 color: peakColor, peakColor: holdColor)
                        BarStrip(value: peakR, peak: peakHoldR,
                                 rangeMin: rangeMin, rangeMax: rangeMax,
                                 color: peakColor, peakColor: holdColor)
                    }
                    .frame(width: 22)

                    Spacer().frame(width: 7)

                    // Short-term LUFS
                    BarStrip(value: lufsS, peak: lufsSPeak,
                             rangeMin: rangeMin, rangeMax: rangeMax,
                             color: shortColor, peakColor: shortColor)
                        .frame(width: 13)
                }
                .padding(.vertical, padV)

                // ── Readout — Short only ──────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(lufsS <= -140 ? "-∞" : String(format: "%.1f", lufsS))
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("LUFS")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.45))
                    }
                    Text("SHORT-TERM")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.25))
                        .tracking(1.5)
                        .padding(.top, 3)
                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }

    // MARK: Helpers

    private func yOffset(db: Float, usableH: CGFloat) -> CGFloat {
        CGFloat((rangeMax - db) / (rangeMax - rangeMin)) * usableH
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
    var peakColor: Color = .orange   // warna garis peak-hold

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
                         with: .color(peakColor))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 0) {
        Rectangle().fill(Color.black.opacity(0.6))
        Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
        LUFSBarMeterView(peakL: -8, peakR: -5, peakHoldL: -3, peakHoldR: -2,
                         lufsS: -12.6, lufsSPeak: -10.5)
            .frame(width: 160)
    }
    .frame(width: 680, height: 260)
    .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    .preferredColorScheme(.dark)
}
