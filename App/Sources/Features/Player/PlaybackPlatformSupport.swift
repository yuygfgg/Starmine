import SwiftUI

#if os(macOS)
    import AppKit

    struct WindowToolbarFullscreenBehavior: ViewModifier {
        let isVideoFullscreen: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 15.0, *) {
                content.windowToolbarFullScreenVisibility(
                    isVideoFullscreen ? .onHover : .visible
                )
            } else {
                content
            }
        }
    }

    struct PlaybackShortcutMonitor: NSViewRepresentable {
        let onTogglePause: () -> Void
        let onToggleDanmaku: () -> Void
        let onCaptureScreenshot: () -> Void
        let onToggleFullscreen: () -> Void
        let onSeekBackward: () -> Void
        let onSeekForward: () -> Void
        let onWindowWillClose: () -> Void

        func makeNSView(context: Context) -> PlaybackShortcutMonitorView {
            let view = PlaybackShortcutMonitorView()
            view.onTogglePause = onTogglePause
            view.onToggleDanmaku = onToggleDanmaku
            view.onCaptureScreenshot = onCaptureScreenshot
            view.onToggleFullscreen = onToggleFullscreen
            view.onSeekBackward = onSeekBackward
            view.onSeekForward = onSeekForward
            view.onWindowWillClose = onWindowWillClose
            return view
        }

        func updateNSView(
            _ nsView: PlaybackShortcutMonitorView,
            context: Context
        ) {
            nsView.onTogglePause = onTogglePause
            nsView.onToggleDanmaku = onToggleDanmaku
            nsView.onCaptureScreenshot = onCaptureScreenshot
            nsView.onToggleFullscreen = onToggleFullscreen
            nsView.onSeekBackward = onSeekBackward
            nsView.onSeekForward = onSeekForward
            nsView.onWindowWillClose = onWindowWillClose
        }
    }

    final class PlaybackShortcutMonitorView: NSView {
        var onTogglePause: (() -> Void)?
        var onToggleDanmaku: (() -> Void)?
        var onCaptureScreenshot: (() -> Void)?
        var onToggleFullscreen: (() -> Void)?
        var onSeekBackward: (() -> Void)?
        var onSeekForward: (() -> Void)?
        var onWindowWillClose: (() -> Void)?
        private var localMonitor: Any?
        private var willCloseObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
            installWindowObserverIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                tearDownWindowObserver()
                tearDownMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        deinit {
            tearDownWindowObserver()
            tearDownMonitor()
        }

        private func installMonitorIfNeeded() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
            { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func tearDownMonitor() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            localMonitor = nil
        }

        private func installWindowObserverIfNeeded() {
            guard willCloseObserver == nil, let window else { return }
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowWillClose?()
            }
        }

        private func tearDownWindowObserver() {
            if let willCloseObserver {
                NotificationCenter.default.removeObserver(willCloseObserver)
            }
            willCloseObserver = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard window?.isKeyWindow == true else { return event }
            guard window?.firstResponder is NSTextView == false else {
                return event
            }
            let blockedModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option,
            ]
            guard event.modifierFlags.intersection(blockedModifiers).isEmpty
            else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ":
                onTogglePause?()
                return nil
            case "d":
                onToggleDanmaku?()
                return nil
            case "s":
                onCaptureScreenshot?()
                return nil
            case "f":
                onToggleFullscreen?()
                return nil
            default:
                switch event.keyCode {
                case 123:
                    onSeekBackward?()
                    return nil
                case 124:
                    onSeekForward?()
                    return nil
                default:
                    return event
                }
            }
        }
    }
#elseif canImport(UIKit)
    import UIKit

    struct PlaybackTouchGestureSurface: UIViewRepresentable {
        let onSingleTap: () -> Void
        let onDoubleTap: (_ isLeadingHalf: Bool) -> Void
        let onHorizontalPanBegan: () -> Void
        let onHorizontalPanChanged:
            (_ translationX: CGFloat, _ width: CGFloat)
                -> Void
        let onHorizontalPanEnded:
            (_ translationX: CGFloat, _ width: CGFloat)
                -> Void
        let onLongPressBegan: () -> Void
        let onLongPressEnded: () -> Void

        func makeUIView(context: Context) -> PlaybackTouchGestureSurfaceView {
            let view = PlaybackTouchGestureSurfaceView()
            updateCallbacks(on: view)
            return view
        }

        func updateUIView(
            _ uiView: PlaybackTouchGestureSurfaceView,
            context: Context
        ) {
            updateCallbacks(on: uiView)
        }

        private func updateCallbacks(on view: PlaybackTouchGestureSurfaceView) {
            view.onSingleTap = onSingleTap
            view.onDoubleTap = onDoubleTap
            view.onHorizontalPanBegan = onHorizontalPanBegan
            view.onHorizontalPanChanged = onHorizontalPanChanged
            view.onHorizontalPanEnded = onHorizontalPanEnded
            view.onLongPressBegan = onLongPressBegan
            view.onLongPressEnded = onLongPressEnded
        }
    }

    final class PlaybackTouchGestureSurfaceView: UIView,
        UIGestureRecognizerDelegate
    {
        var onSingleTap: (() -> Void)?
        var onDoubleTap: ((_ isLeadingHalf: Bool) -> Void)?
        var onHorizontalPanBegan: (() -> Void)?
        var onHorizontalPanChanged:
            (
                (_ translationX: CGFloat, _ width: CGFloat)
                    -> Void
            )?
        var onHorizontalPanEnded:
            (
                (_ translationX: CGFloat, _ width: CGFloat)
                    -> Void
            )?
        var onLongPressBegan: (() -> Void)?
        var onLongPressEnded: (() -> Void)?

        private lazy var singleTapRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSingleTap(_:))
        )
        private lazy var doubleTapRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        private lazy var panRecognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        private lazy var longPressRecognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            installRecognizers()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func installRecognizers() {
            singleTapRecognizer.numberOfTapsRequired = 1
            doubleTapRecognizer.numberOfTapsRequired = 2
            singleTapRecognizer.require(toFail: doubleTapRecognizer)

            panRecognizer.minimumNumberOfTouches = 1
            panRecognizer.maximumNumberOfTouches = 1

            longPressRecognizer.minimumPressDuration = 0.35
            longPressRecognizer.allowableMovement = 12

            panRecognizer.delegate = self
            longPressRecognizer.delegate = self

            addGestureRecognizer(singleTapRecognizer)
            addGestureRecognizer(doubleTapRecognizer)
            addGestureRecognizer(panRecognizer)
            addGestureRecognizer(longPressRecognizer)
        }

        override func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard
                let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer
            else {
                return true
            }

            let velocity = panRecognizer.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y) && bounds.width > 1
        }

        @objc
        private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleTap?()
        }

        @objc
        private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onDoubleTap?(recognizer.location(in: self).x < bounds.midX)
        }

        @objc
        private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translationX = recognizer.translation(in: self).x
            let width = bounds.width

            switch recognizer.state {
            case .began:
                onHorizontalPanBegan?()
                onHorizontalPanChanged?(translationX, width)
            case .changed:
                onHorizontalPanChanged?(translationX, width)
            case .ended, .cancelled, .failed:
                onHorizontalPanEnded?(translationX, width)
            default:
                break
            }
        }

        @objc
        private func handleLongPress(_ recognizer: UILongPressGestureRecognizer)
        {
            switch recognizer.state {
            case .began:
                onLongPressBegan?()
            case .ended, .cancelled, .failed:
                onLongPressEnded?()
            default:
                break
            }
        }
    }
#endif
