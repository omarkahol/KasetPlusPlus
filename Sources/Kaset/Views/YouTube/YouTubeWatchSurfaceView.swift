import SwiftUI
import WebKit

// MARK: - YouTubeWatchSurfaceView

/// Hosts the YouTube video surface (either the hardware-accelerated
/// native AVPlayerLayer or the fallback watch WebView) inside a native view.
/// Used by both the inline WatchView, Shorts pager, and the floating window.
struct YouTubeWatchSurfaceView: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    let expectedVideoId: String?

    init(expectedVideoId: String? = nil) {
        self.expectedVideoId = expectedVideoId
    }

    var body: some View {
        if self.youtubePlayer.isPlayingNativeVideo {
            NativeVideoSurfaceView()
        } else {
            YouTubeWatchLegacySurfaceView(expectedVideoId: self.expectedVideoId)
        }
    }
}

// MARK: - YouTubeWatchLegacySurfaceView

/// Legacy WebKit fallback container for the watch WebView.
struct YouTubeWatchLegacySurfaceView: NSViewRepresentable {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    let expectedVideoId: String?

    init(expectedVideoId: String? = nil) {
        self.expectedVideoId = expectedVideoId
    }

    func makeNSView(context _: Context) -> YouTubeWatchContainerView {
        let container = YouTubeWatchContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ nsView: YouTubeWatchContainerView, context _: Context) {
        YouTubeWatchWebView.shared.ensureInHierarchy(
            container: nsView,
            expectedVideoId: self.expectedVideoId,
            selectedVideoId: self.youtubePlayer.currentVideo?.videoId
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: YouTubeWatchContainerView, context _: Context) -> CGSize? {
        if let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite {
            return CGSize(width: width, height: height)
        }
        if let width = proposal.width, width > 0, width.isFinite {
            return CGSize(width: width, height: width * 9 / 16)
        }
        return nil
    }
}

// MARK: - YouTubeWatchSurfaceAttachment

@MainActor
enum YouTubeWatchSurfaceAttachment {
    @discardableResult
    static func claim(
        surface: NSView,
        in container: NSView,
        expectedVideoId: String?,
        currentVideoId: String?
    ) -> Bool {
        if let expectedVideoId, expectedVideoId != currentVideoId {
            return false
        }
        guard surface.superview !== container else { return true }
        surface.removeFromSuperview()
        container.addSubview(surface)
        return true
    }
}

// MARK: - YouTubeWatchContainerView

/// Custom NSView that keeps the WebView sized with the container.
final class YouTubeWatchContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        self.wantsLayer = true
        self.layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.syncWebViewFrame()
    }

    override func layout() {
        super.layout()
        self.syncWebViewFrame()
    }

    private func syncWebViewFrame() {
        // Overscan the WebView slightly: fractional-point rounding between
        // SwiftUI's aspect-fitted frame and the page's 100vw video leaves
        // hairline black slivers at the edges otherwise. The container's
        // layer clips the overflow.
        for subview in self.subviews where subview is WKWebView {
            subview.frame = self.bounds.insetBy(dx: -1.5, dy: -1.5)
        }
    }
}
