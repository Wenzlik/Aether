#if os(tvOS)
import SwiftUI
import UIKit

extension View {
    /// tvOS: detect **re-selection of the already-active** top tab — which
    /// SwiftUI's `TabView(selection:)` binding can't observe (it only fires on a
    /// *change*) — by hooking the underlying `UITabBarController`'s delegate and
    /// forwarding every other call to SwiftUI's own delegate. The closure is
    /// called with the re-selected tab's index. If the controller can't be found
    /// (SwiftUI not UIKit-backed, etc.) this **no-ops** — no regression. (#266)
    func tvOSTabReselect(_ onReselect: @escaping (Int) -> Void) -> some View {
        background(TabReselectDetector(onReselect: onReselect))
    }
}

private struct TabReselectDetector: UIViewRepresentable {
    let onReselect: (Int) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onReselect = onReselect
        // Defer to the next runloop tick so the view is in the hierarchy and the
        // enclosing tab-bar controller exists.
        DispatchQueue.main.async {
            guard let tabController = uiView.aetherEnclosingTabBarController() else { return }
            let coordinator = context.coordinator
            // Install our delegate once (and re-install if SwiftUI took it back),
            // capturing SwiftUI's delegate to forward to.
            if (tabController.delegate as? TabReselectDetector.Coordinator) !== coordinator {
                coordinator.original = tabController.delegate
                tabController.delegate = coordinator
            }
            coordinator.lastIndex = tabController.selectedIndex
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onReselect: onReselect) }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var onReselect: (Int) -> Void
        weak var original: UITabBarControllerDelegate?
        var lastIndex: Int = 0

        init(onReselect: @escaping (Int) -> Void) { self.onReselect = onReselect }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            let index = tabBarController.selectedIndex
            // Same index as before this select == a re-tap of the active tab.
            if index == lastIndex { onReselect(index) }
            lastIndex = index
            original?.tabBarController?(tabBarController, didSelect: viewController)
        }

        // Forward all other delegate calls to SwiftUI's original delegate so its
        // own selection handling is untouched.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

private extension UIView {
    /// Walk the responder chain to the enclosing `UITabBarController`, if any.
    func aetherEnclosingTabBarController() -> UITabBarController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UITabBarController { return controller }
            if let viewController = current as? UIViewController,
               let controller = viewController.tabBarController {
                return controller
            }
            responder = current.next
        }
        return nil
    }
}
#endif
