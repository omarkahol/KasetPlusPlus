import AVKit
import SwiftUI

// MARK: - NativeVideoSurfaceView

/// Hosts the hardware-accelerated native `AVPlayerLayer` video surface.
/// Supports standard aspect ratios, window resizing, zero overscan distortion,
/// and native macOS Picture-in-Picture.
struct NativeVideoSurfaceView: NSViewRepresentable {
    func makeNSView(context _: Context) -> NativeVideoContainerView {
        let container = NativeVideoContainerView()
        container.attach(player: NativeVideoPlayer.shared.player)
        return container
    }

    func updateNSView(_ nsView: NativeVideoContainerView, context _: Context) {
        nsView.attach(player: NativeVideoPlayer.shared.player)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NativeVideoContainerView, context _: Context) -> CGSize? {
        if let width = proposal.width, width > 0 {
            return CGSize(width: width, height: width * 9 / 16)
        }
        return nil
    }
}

// MARK: - NativeVideoContainerView

/// Custom AppKit container hosting the `AVPlayerLayer`.
final class NativeVideoContainerView: NSView {
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        self.layer = layer
        self.playerLayer = layer
        self.setupPiP()
        self.attach(player: NativeVideoPlayer.shared.player)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handlePlayerNotification(_:)),
            name: .nativeVideoPlayerChanged,
            object: nil
        )
    }

    @objc private func handlePlayerNotification(_ notification: Notification) {
        let player = notification.object as? AVPlayer
        self.attach(player: player)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(player: AVPlayer?) {
        guard self.playerLayer?.player !== player else { return }
        self.playerLayer?.player = player
        self.setupPiP()
    }

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer = self.playerLayer,
              self.pipController == nil
        else { return }

        self.pipController = AVPictureInPictureController(playerLayer: playerLayer)
    }

    func togglePictureInPicture() {
        guard let pip = self.pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.playerLayer?.frame = self.bounds
        CATransaction.commit()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.playerLayer?.frame = self.bounds
        CATransaction.commit()
    }
}
