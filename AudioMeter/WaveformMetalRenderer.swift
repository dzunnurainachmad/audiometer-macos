import Metal
import MetalKit
import simd

private struct WaveParams {
    var resolution: SIMD2<Float>
    var nBars:      Int32
    var writeBar:   Int32
    var scrollFrac: Float
    var barW:       Float
}

private let kShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct WaveParams {
    float2 resolution;
    int    nBars;
    int    writeBar;
    float  scrollFrac;
    float  barW;
};

vertex VertexOut waveVert(uint vid [[vertex_id]]) {
    const float2 pos[4] = {
        float2(-1, 1), float2(1, 1), float2(-1,-1), float2(1,-1)
    };
    const float2 uv[4] = {
        float2(0,0), float2(1,0), float2(0,1), float2(1,1)
    };
    VertexOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = uv[vid];
    return out;
}

fragment float4 waveFrag(VertexOut        in   [[stage_in]],
                          constant float  *amps [[buffer(0)]],
                          constant WaveParams &p [[buffer(1)]]) {
    float4 bg = float4(0.04, 0.04, 0.06, 1.0);
    float x = in.uv.x * p.resolution.x;
    float y = in.uv.y;

    if (abs(y - 0.5) * p.resolution.y < 0.5) return float4(1,1,1,0.07);

    bool  isL = y < 0.5;
    float cy  = isL ? y * 2.0 : (y - 0.5) * 2.0;

    float adjX = x + p.scrollFrac * p.barW;
    int   win  = int(adjX / p.barW);
    int   vis  = int(p.resolution.x / p.barW) + 2;
    int   idx  = ((p.writeBar - vis + win) % p.nBars + 2 * p.nBars) % p.nBars;

    // DAW-style: buffer layout [minL, maxL, minR, maxR] per bar
    float minVal = isL ? amps[idx * 4 + 0] : amps[idx * 4 + 2];
    float maxVal = isL ? amps[idx * 4 + 1] : amps[idx * 4 + 3];

    float barTop    = 0.5 - maxVal * 0.495;
    float barBottom = 0.5 - minVal * 0.495;

    if (cy >= barTop && cy <= barBottom) {
        return isL ? float4(0.25, 0.85, 0.50, 0.88)
                   : float4(0.20, 0.65, 0.95, 0.88);
    }
    return bg;
}
"""

final class WaveformMetalRenderer: NSObject, MTKViewDelegate {

    static let nBars      = 2048
    static let barsPerSec = 48_000.0 / 1024.0

    let device: MTLDevice
    private let commandQueue:    MTLCommandQueue
    private var pipelineState:   MTLRenderPipelineState?
    // [minL, maxL, minR, maxR] × nBars
    private let amplitudeBuffer: MTLBuffer

    private var envMinL: Float = 0, envMaxL: Float = 0
    private var envMinR: Float = 0, envMaxR: Float = 0
    private let releaseAlpha: Float = 0.55

    private var barAccum     = Double(0)
    private let barsPerFrame = 48_000.0 / (1024.0 * 60.0)
    private var writeBar     = Int(0)

    private var pendingLock  = os_unfair_lock()
    // Simpan sebagai flat array [minL, maxL, minR, maxR, ...] — satu array saja
    private var pending:     [Float] = []

    private var drawableSize = CGSize(width: 800, height: 300)
    private var barW: Float  = 4.0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue

        let sz = Self.nBars * 4 * MemoryLayout<Float>.size
        guard let buf = device.makeBuffer(length: sz, options: .storageModeShared) else {
            return nil
        }
        amplitudeBuffer = buf
        memset(buf.contents(), 0, sz)

        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        do {
            let lib  = try device.makeLibrary(source: kShaderSource, options: nil)
            let vert = lib.makeFunction(name: "waveVert")!
            let frag = lib.makeFunction(name: "waveFrag")!
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction   = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[Metal] Pipeline error: \(error)")
        }
    }

    // MARK: Audio interface

    /// Simpan sebagai flat array [minL0, maxL0, minR0, maxR0, minL1, ...]
    func pushBars(minL: [Float], maxL: [Float], minR: [Float], maxR: [Float]) {
        let maxPending = 50 * 4   // 50 bars × 4 values
        os_unfair_lock_lock(&pendingLock)
        for i in 0..<minL.count {
            pending.append(minL[i]); pending.append(maxL[i])
            pending.append(minR[i]); pending.append(maxR[i])
        }
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }
        os_unfair_lock_unlock(&pendingLock)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        barW = 2.0 * Float(view.window?.backingScaleFactor ?? 2.0)
    }

    func draw(in view: MTKView) {
        barAccum += barsPerFrame
        let toAdd = Int(barAccum)
        barAccum -= Double(toAdd)

        if toAdd > 0 {
            os_unfair_lock_lock(&pendingLock)
            let available = pending.count / 4
            let n = min(toAdd, available)
            if n > 0 {
                let slice = Array(pending.prefix(n * 4))
                pending.removeFirst(n * 4)
                os_unfair_lock_unlock(&pendingLock)
                for i in 0..<n {
                    writeBarData(minL: slice[i*4],   maxL: slice[i*4+1],
                                 minR: slice[i*4+2], maxR: slice[i*4+3])
                }
            } else {
                os_unfair_lock_unlock(&pendingLock)
            }
        }

        guard let ps = pipelineState,
              let cb = commandQueue.makeCommandBuffer(),
              let rpd = view.currentRenderPassDescriptor,
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd),
              let drawable = view.currentDrawable
        else { return }

        var params = WaveParams(
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            nBars:      Int32(Self.nBars),
            writeBar:   Int32(writeBar),
            scrollFrac: Float(barAccum),
            barW:       barW
        )

        enc.setRenderPipelineState(ps)
        enc.setFragmentBuffer(amplitudeBuffer, offset: 0, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<WaveParams>.size, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func writeBarData(minL: Float, maxL: Float, minR: Float, maxR: Float) {
        envMaxL = maxL > envMaxL ? maxL : envMaxL * releaseAlpha + maxL * (1 - releaseAlpha)
        envMinL = minL < envMinL ? minL : envMinL * releaseAlpha + minL * (1 - releaseAlpha)
        envMaxR = maxR > envMaxR ? maxR : envMaxR * releaseAlpha + maxR * (1 - releaseAlpha)
        envMinR = minR < envMinR ? minR : envMinR * releaseAlpha + minR * (1 - releaseAlpha)

        let ptr = amplitudeBuffer.contents().bindMemory(to: Float.self,
                                                         capacity: Self.nBars * 4)
        ptr[writeBar * 4 + 0] = envMinL
        ptr[writeBar * 4 + 1] = envMaxL
        ptr[writeBar * 4 + 2] = envMinR
        ptr[writeBar * 4 + 3] = envMaxR
        writeBar = (writeBar + 1) % Self.nBars
    }
}
