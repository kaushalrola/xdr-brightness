import MetalKit

/// Renders nothing but a clear colour. When the hosting layer is composited
/// with a "multiply" filter, that colour multiplies everything beneath it.
///
/// The drawable is deliberately 1x1 and stretched: the clear colour *is* the
/// frame, so a full-resolution drawable would be pure waste.
final class MetalOverlayView: MTKView, MTKViewDelegate {

    private var commandQueue: MTLCommandQueue?
    private var didRenderFirstFrame = false
    var onFirstFrame: (() -> Void)?

    private(set) var submitted: UInt64 = 0
    private(set) var completed: UInt64 = 0
    private(set) var failed: UInt64 = 0

    init?(frame: CGRect, multiply: Bool, gain: Double) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log("MetalOverlayView: no Metal device")
            return nil
        }
        super.init(frame: frame, device: device)

        guard let queue = device.makeCommandQueue() else {
            log("MetalOverlayView: could not create command queue")
            return nil
        }
        commandQueue = queue

        // A float pixel format is required to express values above 1.0.
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 5
        delegate = self

        if let metalLayer = layer as? CAMetalLayer {
            // This is what makes macOS unlock the extra brightness range.
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.isOpaque = false
            if multiply {
                // ...and this is what applies it to everything beneath.
                metalLayer.compositingFilter = "multiply"
            }
        }

        setGain(gain)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    func setGain(_ gain: Double) {
        clearColor = MTLClearColorMake(gain, gain, gain, 1.0)
        draw()
    }

    func draw(in view: MTKView) {
        guard let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        submitted += 1
        // No geometry: the clear colour is the entire frame.
        encoder.endEncoding()
        buffer.present(drawable)

        buffer.addCompletedHandler { [weak self] cmd in
            let ok = cmd.status == .completed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ok {
                        self.completed += 1
                        if !self.didRenderFirstFrame {
                            self.didRenderFirstFrame = true
                            self.onFirstFrame?()
                            self.onFirstFrame = nil
                        }
                    } else {
                        self.failed += 1
                    }
                }
            }
        }
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    var stats: String { "submitted \(submitted), completed \(completed), failed \(failed)" }
}
