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

    init() {
        handle = mpv_create()
    }

    /// Configure options and initialize. `vo=libmpv` selects the embeddable
    /// render API (the video surface is driven by `MpvVideoView`).
    func start() {
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
            // C callback (arbitrary thread): pass the pointer as a Sendable bit
            // pattern across the hop, resolve the instance on the main actor.
            let bits = UInt(bitPattern: raw)
            Task { @MainActor in
                guard let p = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                Unmanaged<MpvClient>.fromOpaque(p).takeUnretainedValue().drainEvents()
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

    // MARK: Teardown

    func destroy() {
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
        self.handle = nil
    }

    deinit { destroy() }
}
