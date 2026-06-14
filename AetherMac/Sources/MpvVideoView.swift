import SwiftUI
import MetalKit
import Cmpv

/// mpv render-update callback. **File-scope and non-isolated on purpose** — mpv
/// calls it from its render/`vo` thread, so it must not carry `@MainActor`
/// isolation (the Swift runtime would trap on the isolation check the moment mpv
/// invoked it). We hop to the main thread and ask the view's coordinator to
/// redraw. Internal (not private) so `MpvClient.createRenderContext` can install it.
func mpvRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    let bits = UInt(bitPattern: ctx)
    DispatchQueue.main.async {
        guard let p = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        MainActor.assumeIsolated {
            Unmanaged<MpvMetalCoordinator>.fromOpaque(p).takeUnretainedValue().setNeedsRedraw()
        }
    }
}

/// The video surface for libmpv on macOS — a **Metal** view (replacing the
/// deprecated `NSOpenGLView`, #19). libmpv has no native Metal render backend, so
/// we use its **software render API** (`MPV_RENDER_API_TYPE_SW`): mpv renders the
/// frame into a CPU buffer, which we upload to a `MTLTexture` and blit into the
/// `MTKView`'s drawable. Hardware decode (VideoToolbox) still applies; only the
/// final compositing path is CPU→Metal. The render context's lifetime is owned by
/// `MpvClient` (torn down in the right order); this view creates it and drives
/// `renderSW` on draw.
struct MpvVideoView: NSViewRepresentable {
    let client: MpvClient

    func makeCoordinator() -> MpvMetalCoordinator { MpvMetalCoordinator(client: client) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        // We blit into the drawable, so it can't be framebuffer-only.
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        // Draw on demand — mpv's update callback marks the view dirty when a new
        // frame is ready, instead of a free-running display-link.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.layer?.isOpaque = true
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: MpvMetalCoordinator) {
        coordinator.detach()
    }
}

/// Owns the Metal compositing for one player view: a reusable CPU buffer mpv
/// renders into, a matching `MTLTexture`, and a blit into the drawable each frame.
@MainActor
final class MpvMetalCoordinator: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let client: MpvClient
    private let commandQueue: MTLCommandQueue?
    private weak var view: MTKView?

    private var buffer: UnsafeMutableRawPointer?
    private var texture: MTLTexture?
    private var texW = 0
    private var texH = 0

    init(client: MpvClient) {
        self.client = client
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        super.init()
    }

    func attach(_ view: MTKView) {
        self.view = view
        // Create mpv's SW render context; its update callback (file-scope, called
        // off-thread) hops to main and pokes `setNeedsRedraw` on this coordinator.
        client.createRenderContext(updateCtx: Unmanaged.passUnretained(self).toOpaque())
    }

    func detach() {
        if let buffer { free(buffer) }
        buffer = nil
        texture = nil
    }

    /// Called from the render-update hop (main thread) — request a redraw.
    func setNeedsRedraw() { view?.needsDisplay = true }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let device,
            let commandQueue,
            let drawable = view.currentDrawable
        else { return }
        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return }

        ensureResources(device: device, width: width, height: height)
        guard let buffer, let texture else { return }

        // mpv paints the current frame into our CPU buffer (BGRA, ignored alpha).
        let stride = width * 4
        client.renderSW(into: buffer, width: width, height: height, stride: stride)

        // Upload → texture → blit into the drawable → present.
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: buffer,
            bytesPerRow: stride
        )
        guard
            let command = commandQueue.makeCommandBuffer(),
            let blit = command.makeBlitCommandEncoder()
        else { return }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// (Re)allocate the CPU buffer + texture when the drawable size changes.
    private func ensureResources(device: MTLDevice, width: Int, height: Int) {
        guard width != texW || height != texH || buffer == nil || texture == nil else { return }
        if let buffer { free(buffer) }
        buffer = malloc(width * height * 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: descriptor)
        texW = width
        texH = height
    }
}
