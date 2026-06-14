import SwiftUI
import Cmpv
import OpenGL.GL

/// mpv render-update callback. **File-scope and non-isolated on purpose** —
/// mpv calls it from its `vo` thread, so it must not carry `@MainActor`
/// isolation (a closure inside the @MainActor `MpvGLView` would, and the Swift
/// runtime would trap on the isolation check the moment mpv invoked it). Here we
/// just hop to the main thread and ask the view to redraw. Internal (not
/// private) so `MpvClient.createRenderContext` can install it.
func mpvRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    let bits = UInt(bitPattern: ctx)
    DispatchQueue.main.async {
        guard let p = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        MainActor.assumeIsolated {
            Unmanaged<MpvGLView>.fromOpaque(p).takeUnretainedValue().setNeedsRedraw()
        }
    }
}

/// The video surface for libmpv. An `NSOpenGLView` whose GL context backs the
/// client's `mpv_render_context`; mpv renders into the view's default
/// framebuffer. The render context's lifetime is owned by `MpvClient` (so it's
/// torn down in the right order); this view just creates it (GL current) and
/// drives `render` on draw.
struct MpvVideoView: NSViewRepresentable {
    let client: MpvClient

    func makeNSView(context: Context) -> MpvGLView { MpvGLView(client: client) }
    func updateNSView(_ nsView: MpvGLView, context: Context) {}
}

final class MpvGLView: NSOpenGLView {
    private weak var client: MpvClient?

    init(client: MpvClient) {
        self.client = client
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attrs)
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        // Create the render context on the now-current GL context. mpv's update
        // callback gets *this view* as its context, so it can ask for a redraw.
        client?.createRenderContext(updateCtx: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Request a redraw on the main thread (called from the render-update hop).
    fileprivate func setNeedsRedraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let openGLContext else { return }
        openGLContext.makeCurrentContext()
        let scale = window?.backingScaleFactor ?? 1
        client?.render(width: Int32(bounds.width * scale), height: Int32(bounds.height * scale))
        openGLContext.flushBuffer()
    }
}
