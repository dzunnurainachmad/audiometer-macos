import SwiftUI
import MetalKit

struct WaveformMetalView: NSViewRepresentable {
    let renderer: WaveformMetalRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate             = renderer
        view.colorPixelFormat     = .bgra8Unorm
        view.clearColor           = MTLClearColorMake(0.04, 0.04, 0.06, 1.0)
        view.framebufferOnly      = true
        view.isPaused             = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
