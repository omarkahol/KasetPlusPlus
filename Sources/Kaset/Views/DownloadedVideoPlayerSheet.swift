import AVKit
import SwiftUI

// MARK: - DownloadedVideoPlayerSheet

/// Native video player sheet for locally downloaded video files using AVPlayerView.
struct DownloadedVideoPlayerSheet: View {
    let title: String
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(self.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button {
                    NSWorkspace.shared.open(self.fileURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open in Default App"))

                Button {
                    self.player?.pause()
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Player View
            if let player = self.player {
                AVPlayerViewContainer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(.black)
        .onAppear {
            let player = AVPlayer(url: self.fileURL)
            self.player = player
            player.play()
        }
        .onDisappear {
            self.player?.pause()
            self.player = nil
        }
    }
}

// MARK: - AVPlayerViewContainer

private struct AVPlayerViewContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = self.player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context _: Context) {
        nsView.player = self.player
    }
}
