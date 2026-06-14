import SwiftUI
import Cmpv
import OpenGL.GL

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
            mpv_render_context_set_update_callback(renderContext, { raw in
                // Fires on mpv's `vo` thread (a raw pthread). Bridge to main via
                // GCD — NOT `Task { @MainActor }`, which trips a Swift-concurrency
                // executor assertion when enqueued from a non-cooperative thread
                // (it crashed the vo thread). Pass the pointer as a Sendable
                // bit pattern across the boundary.
                let bits = UInt(bitPattern: raw)
                DispatchQueue.main.async {
                    guard let p = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                    MainActor.assumeIsolated {
                        Unmanaged<MpvGLView>.fromOpaque(p).takeUnretainedValue().needsDisplay = true
                    }
                }
            }, ctx)
        }
    }

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
