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
        if let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite {
            return CGSize(width: width, height: height)
        }
        if let width = proposal.width, width > 0, width.isFinite {
            return CGSize(width: width, height: width * 9 / 16)
        }
        return nil
    }
}

// MARK: - NativeVideoContainerView

/// Custom AppKit container hosting the `AVPlayerLayer`.
final class NativeVideoContainerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var pipController: AVPictureInPictureController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.masksToBounds = true
        self.playerLayer.videoGravity = .resizeAspect
        self.playerLayer.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(self.playerLayer)
        self.setupPiP()
        self.attach(player: NativeVideoPlayer.shared.player)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handlePlayerNotification(_:)),
            name: .nativeVideoPlayerChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        guard self.playerLayer.player !== player else { return }
        self.playerLayer.player = player
        self.setupPiP()
    }

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              self.pipController == nil
        else { return }

        self.pipController = AVPictureInPictureController(playerLayer: self.playerLayer)
    }

    func togglePictureInPicture() {
        guard let pip = self.pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.playerLayer.frame = self.bounds
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.playerLayer.frame = self.bounds
        CATransaction.commit()
    }
}
