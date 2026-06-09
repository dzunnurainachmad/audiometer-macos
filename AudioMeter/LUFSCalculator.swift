import Foundation
import Accelerate

// MARK: - Single-channel K-weighting + sliding-window mean-square
// Biquad filter pakai vDSP.Biquad (SIMD, 4-8× lebih cepat)
// Ring buffer update tetap scalar — simple, predictable, no hidden allocations

final class ChannelLUFSProcessor {

    // ── vDSP biquad (SIMD-accelerated) ───────────────────────────────────
    private var biquad: vDSP.Biquad<Float>

    // ── Sliding windows ───────────────────────────────────────────────────
    private var momentaryBuf: [Double]
    private var shortTermBuf: [Double]
    private var mPos = 0, sPos = 0
    private var mSum: Double = 0, sSum: Double = 0

    private var samplesSinceRecompute = 0
    private let recomputeInterval: Int

    init(sampleRate: Double = 48_000) {
        // K-weighting BS.1770-4 dihitung untuk sample rate aktual (adaptive).
        // Di 48 kHz hasilnya identik dengan koefisien standar ITU.
        let coeffs = Self.kWeightingCoefficients(sampleRate: sampleRate)
        biquad = vDSP.Biquad(coefficients: coeffs,
                              channelCount: 1,
                              sectionCount: 2,
                              ofType: Float.self)!

        momentaryBuf = Array(repeating: 0, count: Int(sampleRate * 0.4))
        shortTermBuf = Array(repeating: 0, count: Int(sampleRate * 3.0))
        recomputeInterval = Int(sampleRate * 0.1)
    }

    // BS.1770-4 K-weighting via bilinear transform — berlaku untuk fs apa pun
    // (44.1k, 48k, 88.2k, 96k, dst). Stage 1: high-shelf, Stage 2: high-pass.
    private static func kWeightingCoefficients(sampleRate fs: Double) -> [Double] {
        // Stage 1 — high-shelf
        let f0s = 1681.974450955533
        let Gs  = 3.999843853973347      // dB
        let Qs  = 0.7071752369554196
        let K1  = tan(Double.pi * f0s / fs)
        let Vh  = pow(10.0, Gs / 20.0)
        let Vb  = pow(Vh, 0.4996667741545416)
        let a0s = 1 + K1 / Qs + K1 * K1
        let b0_1 = (Vh + Vb * K1 / Qs + K1 * K1) / a0s
        let b1_1 = 2 * (K1 * K1 - Vh) / a0s
        let b2_1 = (Vh - Vb * K1 / Qs + K1 * K1) / a0s
        let a1_1 = 2 * (K1 * K1 - 1) / a0s
        let a2_1 = (1 - K1 / Qs + K1 * K1) / a0s

        // Stage 2 — high-pass (numerator [1,-2,1] sesuai konvensi ITU)
        let f0h = 38.13547087602444
        let Qh  = 0.5003270373238773
        let K2  = tan(Double.pi * f0h / fs)
        let a0h = 1 + K2 / Qh + K2 * K2
        let b0_2 =  1.0
        let b1_2 = -2.0
        let b2_2 =  1.0
        let a1_2 = 2 * (K2 * K2 - 1) / a0h
        let a2_2 = (1 - K2 / Qh + K2 * K2) / a0h

        return [b0_1, b1_1, b2_1, a1_1, a2_1,
                b0_2, b1_2, b2_2, a1_2, a2_2]
    }

    func process(_ samples: [Float]) -> (mMeanSq: Double, sMeanSq: Double) {
        // 1. SIMD biquad filter — proses semua samples sekaligus
        let filtered = biquad.apply(input: samples)

        // 2. Update ring buffers — scalar (simple, no hidden allocations)
        for f in filtered {
            let sq = Double(f) * Double(f)

            mSum -= momentaryBuf[mPos]
            momentaryBuf[mPos] = sq
            mSum += sq
            mPos = (mPos + 1) % momentaryBuf.count

            sSum -= shortTermBuf[sPos]
            shortTermBuf[sPos] = sq
            sSum += sq
            sPos = (sPos + 1) % shortTermBuf.count
        }

        // 3. Periodic recompute pakai vDSP untuk cegah FP drift
        samplesSinceRecompute += filtered.count
        if samplesSinceRecompute >= recomputeInterval {
            mSum = momentaryBuf.withUnsafeBufferPointer {
                var s = Double(0)
                vDSP_sveD($0.baseAddress!, 1, &s, vDSP_Length($0.count))
                return s
            }
            sSum = shortTermBuf.withUnsafeBufferPointer {
                var s = Double(0)
                vDSP_sveD($0.baseAddress!, 1, &s, vDSP_Length($0.count))
                return s
            }
            samplesSinceRecompute = 0
        }

        let mMean = max(mSum, 0) / Double(momentaryBuf.count)
        let sMean = max(sSum, 0) / Double(shortTermBuf.count)
        return (mMean, sMean)
    }
}

// MARK: - Stereo LUFS (BS.1770-4)

final class StereoLUFSCalculator {
    private let left:  ChannelLUFSProcessor
    private let right: ChannelLUFSProcessor

    init(sampleRate: Double = 48_000) {
        left  = ChannelLUFSProcessor(sampleRate: sampleRate)
        right = ChannelLUFSProcessor(sampleRate: sampleRate)
    }

    func process(left l: [Float], right r: [Float]) -> (lufsM: Float, lufsS: Float) {
        let lv = left.process(l)
        let rv = right.process(r)
        let mSum = lv.mMeanSq + rv.mMeanSq
        let sSum = lv.sMeanSq + rv.sMeanSq
        let lufsM = mSum > 1e-10 ? Float(-0.691 + 10 * log10(mSum)) : -144.0
        let lufsS = sSum > 1e-10 ? Float(-0.691 + 10 * log10(sSum)) : -144.0
        return (lufsM, lufsS)
    }
}
