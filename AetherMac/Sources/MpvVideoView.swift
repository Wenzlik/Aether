import SwiftUI
import Cmpv
import OpenGL.GL

/// mpv render-update callback. **File-scope and non-isolated on purpose** —
/// mpv calls it from its `vo` thread, so it must not carry `@MainActor`
/// isolation (a closure inside the @MainActor `MpvGLView` would, and the Swift
/// runtime would trap on the isolation check the moment mpv invoked it). Here we
/// just hop to the main thread and ask the view to redraw.
private func mpvRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    let bits = UInt(bitPattern: ctx)
    DispatchQueue.main.async {
        guard let p = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        MainActor.assumeIsolated {
            Unmanaged<MpvGLView>.fromOpaque(p).takeUnretainedValue().setNeedsRedraw()
        }
    }
}

/// The video surface for libmpv. An `NSOpenGLView` whose GL context backs an
/// `mpv_render_context`; mpv renders into the view's default framebuffer. mpv's
/// update callback (any thread) flips `needsDisplay` on main, and `draw` issues
/// `mpv_render_context_render` on the GL thread (main, single-threaded GL).
struct MpvVideoView: NSViewRepresentable {
    let client: MpvClient

    func makeNSView(context: Context) -> MpvGLView {
        MpvGLView(client: client)
    }
    func updateNSView(_ nsView: MpvGLView, context: Context) {}

    static func dismantleNSView(_ nsView: MpvGLView, coordinator: ()) {
        nsView.teardown()
    }
}

final class MpvGLView: NSOpenGLView {
    private weak var client: MpvClient?
    private var renderContext: OpaquePointer?

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
        guard let mpv = client?.handle else { return }

        var glInit = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                // RTLD_DEFAULT (= -2 on Darwin) resolves GL symbols from the
                // already-linked OpenGL.framework.
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            },
            get_proc_address_ctx: nil
        )

        withUnsafeMutablePointer(to: &glInit) { initPtr in
            MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                _ = mpv_render_context_create(&renderContext, mpv, &params)
            }
        }

        if let renderContext {
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            // Must pass a **non-isolated** function: this fires on mpv's `vo`
            // thread, and a closure written here would inherit `prepareOpenGL`'s
            // `@MainActor` isolation (NSView is @MainActor), so the Swift runtime
            // would assert "not on main actor" the instant mpv calls it and trap
            // (dispatch_assert_queue). `mpvRenderUpdate` is a free function with
            // no isolation, so it's safe to invoke from any thread.
            mpv_render_context_set_update_callback(renderContext, mpvRenderUpdate, ctx)
        }
    }

    /// Request a redraw on the main thread (called from the render-update hop).
    fileprivate func setNeedsRedraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderContext, let openGLContext else { return }
        openGLContext.makeCurrentContext()

        let scale = window?.backingScaleFactor ?? 1
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(pixelSize.width), h: Int32(pixelSize.height), internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                _ = mpv_render_context_render(renderContext, &params)
            }
        }
        openGLContext.flushBuffer()
    }

    /// Free the render context before the handle is destroyed.
    func teardown() {
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
    }

    deinit { teardown() }
}
