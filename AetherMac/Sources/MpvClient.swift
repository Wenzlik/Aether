import Foundation
import Cmpv

/// Thin Swift wrapper over a single `mpv_handle` — the control plane for one
/// player window (load, transport, properties, track selection). Rendering is
/// handled separately by `MpvVideoView`, which builds an `mpv_render_context`
/// on this same handle.
///
/// Events are delivered via mpv's **wakeup callback** (fired on an arbitrary
/// thread): we hop to the main actor and drain `mpv_wait_event(0)` non-blocking,
/// forwarding each observed property change to `onPropertyChange`. This avoids a
/// dedicated blocking event thread and keeps all observable state on main.
final class MpvClient {
    /// The raw handle, exposed so the render view can create its render context
    /// on the same player.
    private(set) var handle: OpaquePointer?

    /// Called on the main actor when an observed property changes (name only —
    /// the model re-reads the value it cares about). Set before `start()`.
    var onPropertyChange: (@MainActor (String) -> Void)?
    /// Called on the main actor when playback reaches end-of-file.
    var onEndFile: (@MainActor () -> Void)?

    /// Create **and fully initialize** mpv up front. Initialization must finish
    /// before `MpvVideoView` creates its render context (`mpv_render_context_create`
    /// requires an initialized handle) — and in SwiftUI the view's `prepareOpenGL`
    /// can fire before `.onAppear`, so we can't defer this to a later `start()`.
    init() {
        handle = mpv_create()
        configure()
    }

    /// Configure options and initialize. `vo=libmpv` selects the embeddable
    /// render API (the video surface is driven by `MpvVideoView`).
    private func configure() {
        guard let handle else { return }
        // Use the render API for video output; hardware-decode via VideoToolbox.
        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        // Keep the player alive at end-of-file so we can read final state and
        // the window controls don't blank out; we tear down explicitly.
        mpv_set_option_string(handle, "keep-open", "yes")
        // Reasonable OSD/seek behaviour for a GUI front-end.
        mpv_set_option_string(handle, "force-seekable", "yes")

        mpv_initialize(handle)

        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("track-list/count", MPV_FORMAT_INT64)
        observe("aid", MPV_FORMAT_INT64)
        observe("sid", MPV_FORMAT_INT64)

        // Wakeup → drain on main.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { raw in
            // C callback on an mpv thread (a raw pthread). Bridge to main via GCD,
            // NOT `Task { @MainActor }` — enqueuing a Task from a non-cooperative
            // thread trips a Swift-concurrency executor assertion (SIGTRAP). Pass
            // the pointer as a Sendable bit pattern across the hop.
            let bits = UInt(bitPattern: raw)
            DispatchQueue.main.async {
                guard let p = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                MainActor.assumeIsolated {
                    Unmanaged<MpvClient>.fromOpaque(p).takeUnretainedValue().drainEvents()
                }
            }
        }, ctx)
    }

    private func observe(_ name: String, _ format: mpv_format) {
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    // MARK: Commands

    func loadFile(_ url: URL) {
        command(["loadfile", url.isFileURL ? url.path : url.absoluteString])
    }

    /// Run an mpv command from a string argument list (NULL-terminated for C).
    func command(_ args: [String]) {
        guard let handle else { return }
        let dup = args.map { strdup($0) }              // [UnsafeMutablePointer<CChar>?]
        defer { dup.forEach { free($0) } }
        var cargs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) } + [nil]
        cargs.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command(handle, buf.baseAddress)
        }
    }

    func setProperty(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    func setFlag(_ name: String, _ value: Bool) {
        setProperty(name, value ? "yes" : "no")
    }

    // MARK: Property reads

    func doubleProperty(_ name: String) -> Double {
        guard let handle else { return 0 }
        var value: Double = 0
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    func boolProperty(_ name: String) -> Bool {
        guard let handle else { return false }
        var flag: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &flag)
        return flag != 0
    }

    func intProperty(_ name: String) -> Int64 {
        guard let handle else { return 0 }
        var value: Int64 = 0
        mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        return value
    }

    func stringProperty(_ name: String) -> String? {
        guard let handle, let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    // MARK: Events

    @MainActor
    private func drainEvents() {
        guard let handle else { return }
        while true {
            guard let evPtr = mpv_wait_event(handle, 0) else { break }
            let event = evPtr.pointee
            switch event.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.data {
                    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    if let name = prop.name { onPropertyChange?(String(cString: name)) }
                }
            case MPV_EVENT_END_FILE:
                onEndFile?()
            default:
                break
            }
        }
    }

    // MARK: Render context (owned here for deterministic teardown ordering)

    /// The OpenGL render context, created by `MpvVideoView` once its GL context
    /// is current. Owned by the client so `destroy()` can free it **before**
    /// terminating the handle — freeing it after would crash (it references the
    /// core), and splitting ownership across the view made the order racy.
    @ObservationIgnored private(set) var renderContext: OpaquePointer?

    /// Create the OpenGL render context on the **current** GL context.
    /// `updateCtx` is passed to the (non-isolated) update callback — the view,
    /// which it asks to redraw.
    func createRenderContext(updateCtx: UnsafeMutableRawPointer) {
        guard let handle, renderContext == nil else { return }
        var glInit = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress, get_proc_address_ctx: nil)
        withUnsafeMutablePointer(to: &glInit) { initPtr in
            MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_create(&renderContext, handle, &params)
            }
        }
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, mpvRenderUpdate, updateCtx)
        }
    }

    /// Render the current frame into the default framebuffer (call with the GL
    /// context current, on the main thread).
    func render(width: Int32, height: Int32) {
        guard let renderContext else { return }
        var fbo = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
    }

    // MARK: Teardown

    /// Ordered, idempotent teardown: free the render context **first**, then
    /// terminate the handle. Safe to call more than once (stop() + deinit).
    func destroy() {
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
    }

    deinit { destroy() }
}

/// libmpv GL symbol resolver — file-scope, non-isolated (called from mpv).
/// RTLD_DEFAULT (= -2 on Darwin) resolves from the linked OpenGL.framework.
private func mpvGetProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}
