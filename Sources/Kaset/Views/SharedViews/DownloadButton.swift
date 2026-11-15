import SwiftUI

// MARK: - DownloadButton

/// Trailing download button for a track row.
///
/// States:
/// - Not Downloaded: Outline download icon (visible on hover)
/// - Downloading: Circular progress ring showing download completion
/// - Downloaded: Solid checkmark icon in green
struct DownloadButton: View {
    let song: Song
    let isRowHovered: Bool

    private var downloadManager = DownloadManager.shared
    @State private var isHoveringButton = false

    init(song: Song, isRowHovered: Bool = true) {
        self.song = song
        self.isRowHovered = isRowHovered
    }

    var body: some View {
        let status = self.downloadManager.status(for: self.song.videoId)
        let isDownloaded = self.downloadManager.isDownloaded(videoId: self.song.videoId)

        Group {
            if isDownloaded {
                Menu {
                    Button(String(localized: "Show in Finder")) {
                        if let fileURL = self.downloadManager.fileURL(for: self.song.videoId) {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        self.downloadManager.removeDownload(videoId: self.song.videoId)
                    } label: {
                        Label(String(localized: "Remove Download"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .help(String(localized: "Downloaded"))
            } else if let status, status.isDownloading {
                Button {
                    self.downloadManager.cancel(videoId: self.song.videoId)
                } label: {
                    ZStack {
                        if self.isHoveringButton {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView(value: max(0.05, status.progress))
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onHover { self.isHoveringButton = $0 }
                .help(self.downloadingHelpText(for: status))
            } else {
                Button {
                    self.downloadManager.download(song: self.song)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .opacity(self.isRowHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: self.isRowHovered)
                .help(String(localized: "Download for Offline Playback"))
            }
        }
    }

    func downloadingHelpText(for status: DownloadManager.DownloadStatus) -> String {
        switch status {
        case .queued:
            String(localized: "Download Queued — Click to cancel")
        case .preparing:
            String(localized: "Preparing Download… — Click to cancel")
        case let .downloading(progress, speed):
            if !speed.isEmpty {
                "\(Int(progress * 100))% (\(speed)) — " + String(localized: "Click to cancel")
            } else {
                "\(Int(progress * 100))% — " + String(localized: "Click to cancel")
            }
        default:
            String(localized: "Click to cancel")
        }
    }
}
