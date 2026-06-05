import Foundation
import Accelerate

// MARK: - Single-channel K-weighting + sliding-window mean-square
// Biquad filter pakai vDSP.Biquad (SIMD, 4-8× lebih cepat)
// Ring buffer update tetap scalar — simple, predictable, no hidden allocations

final class ChannelLUFSProcessor {

    // ── K-weighting coefficients (48 kHz) ─────────────────────────────────
    private let b0_1 =  1.53512485958697; private let b1_1 = -2.69169618940638
    private let b2_1 =  1.19839281085285; private let a1_1 = -1.69065929318241
    private let a2_1 =  0.73248077421585

    private let b0_2 =  1.0;              private let b1_2 = -2.0
    private let b2_2 =  1.0;             private let a1_2 = -1.99004745483398
    private let a2_2 =  0.99007225036621

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
        let coeffs: [Double] = [
            b0_1, b1_1, b2_1, a1_1, a2_1,
            b0_2, b1_2, b2_2, a1_2, a2_2
        ]
        biquad = vDSP.Biquad(coefficients: coeffs,
                              channelCount: 1,
                              sectionCount: 2,
                              ofType: Float.self)!

        momentaryBuf = Array(repeating: 0, count: Int(sampleRate * 0.4))
        shortTermBuf = Array(repeating: 0, count: Int(sampleRate * 3.0))
        recomputeInterval = Int(sampleRate * 0.1)
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
