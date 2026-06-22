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
        // `videotoolbox-copy` is the correct hwdec mode for the SW render API
        // (`MPV_RENDER_API_TYPE_SW`): decoded frames are copied from GPU (IOSurface)
        // to a CPU buffer that `mpv_render_context_render` can hand back to us.
        // `videotoolbox` (non-copy) keeps frames as CVPixelBuffers on the GPU and
        // was never intended for the SW path — newer mpv 0.41+ is strict about this
        // and would stall instead of silently falling back to software decode.
        mpv_set_option_string(handle, "hwdec", "videotoolbox-copy")
        // Keep the player alive at end-of-file so we can read final state and
        // the window controls don't blank out; we tear down explicitly.
        mpv_set_option_string(handle, "keep-open", "yes")
        // Reasonable OSD/seek behaviour for a GUI front-end.
        mpv_set_option_string(handle, "force-seekable", "yes")
        // Allow the software volume slider to go up to 150% — movies are often
        // mastered at a lower level than streaming services; this extra headroom
        // lets users compensate without clipping (mpv applies soft-clipping above
        // 100). Default stays at 100 (unity gain).
        mpv_set_option_string(handle, "volume-max", "150")

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

    /// The mpv **software** render context, created by `MpvVideoView` (#19 —
    /// replaced the OpenGL path so the player no longer uses the deprecated
    /// `NSOpenGLView`). Owned by the client so `destroy()` can free it **before**
    /// terminating the handle — freeing it after would crash (it references the
    /// core), and splitting ownership across the view made the order racy.
    @ObservationIgnored private(set) var renderContext: OpaquePointer?

    /// The `passRetained` coordinator pointer handed to the update callback —
    /// released in `destroy()` once the callback is cleared, balancing the retain
    /// taken in `MpvVideoView`'s `attach`. Keeps the coordinator alive exactly as
    /// long as mpv can call back into it.
    @ObservationIgnored private var renderUpdateCtx: UnsafeMutableRawPointer?

    /// Create the software render context (`MPV_RENDER_API_TYPE_SW`). No GL/Metal
    /// init params — mpv renders into a CPU buffer we hand it per frame. `updateCtx`
    /// is passed to the (non-isolated) update callback — the Metal coordinator it
    /// asks to redraw.
    func createRenderContext(updateCtx: UnsafeMutableRawPointer) {
        guard let handle, renderContext == nil else { return }
        MPV_RENDER_API_TYPE_SW.withCString { apiType in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            mpv_render_context_create(&renderContext, handle, &params)
        }
        if let renderContext {
            renderUpdateCtx = updateCtx
            mpv_render_context_set_update_callback(renderContext, mpvRenderUpdate, updateCtx)
        }
    }

    /// Render the current frame into a CPU pixel buffer (BGRA bytes, ignored
    /// alpha → `"bgr0"`, matching Metal's `.bgra8Unorm`). The Metal coordinator
    /// then uploads it to a texture and blits it to the drawable. Call on the
    /// main thread (SW rendering has no thread-affinity requirement like GL did).
    func renderSW(into pointer: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        guard let renderContext else { return }
        var size: [CInt] = [CInt(width), CInt(height)]
        var swStride = stride                       // bridges to size_t
        "bgr0".withCString { fmt in
            size.withUnsafeMutableBufferPointer { sizeBuf in
                withUnsafeMutablePointer(to: &swStride) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizeBuf.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: fmt)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    mpv_render_context_render(renderContext, &params)
                }
            }
        }
    }

    // MARK: Teardown

    /// Ordered, idempotent teardown: free the render context **first** (on the
    /// caller's thread — main, where the GL context lives), then terminate the
    /// handle. Safe to call more than once (stop() + deinit).
    ///
    /// `mpv_terminate_destroy` joins every mpv thread, including a demux thread
    /// that may be blocked in a network read (Plex HLS over HTTPS) — so calling
    /// it on the main thread froze the UI on close/quit. We hand the handle to a
    /// background queue to terminate there; main never blocks.
    func destroy() {
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
            // Balance the `passRetained` coordinator from createRenderContext —
            // now that mpv can no longer call the update callback, drop the retain.
            if let renderUpdateCtx {
                Unmanaged<AnyObject>.fromOpaque(renderUpdateCtx).release()
                self.renderUpdateCtx = nil
            }
        }
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            self.handle = nil
            // Everything from here joins mpv threads (incl. a demux thread blocked
            // in a network read) — keep it entirely off the main thread. Pass the
            // handle as a Sendable bit pattern across the queue hop.
            let bits = UInt(bitPattern: UnsafeMutableRawPointer(handle))
            DispatchQueue.global(qos: .utility).async {
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                mpv_terminate_destroy(OpaquePointer(raw))
            }
        }
    }

    deinit { destroy() }
}
