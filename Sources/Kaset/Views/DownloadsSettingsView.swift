import AppKit
import SwiftUI

// MARK: - DownloadsSettingsView

/// Settings view for configuring YouTube Music offline downloads, audio quality, and dependencies.
struct DownloadsSettingsView: View {
    @State private var settings = SettingsManager.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var isShowingDeleteConfirmation = false
    @State private var showsCustomYtdlpSheet = false
    @State private var showsCustomFfmpegSheet = false

    var body: some View {
        Form {
            // MARK: - Audio Quality Section

            Section {
                Picker(String(localized: "Audio Format"), selection: self.$settings.downloadAudioFormat) {
                    ForEach(SettingsManager.DownloadAudioFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .help(String(localized: "Audio format and quality used when downloading songs"))

                Text(self.formatDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "Audio Quality"))
            }

            // MARK: - Download Location Section

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Location"))
                                .font(.body)
                            Text(self.settings.downloadDirectoryPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button(String(localized: "Change…")) {
                            self.selectCustomDirectory()
                        }
                    }

                    HStack(spacing: 12) {
                        Button(String(localized: "Open in Finder")) {
                            NSWorkspace.shared.open(self.settings.resolvedDownloadDirectory)
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)

                        Button(String(localized: "Reset to Default")) {
                            self.settings.downloadDirectoryPath = SettingsManager.defaultDownloadDirectory.path
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .disabled(self.settings.downloadDirectoryPath == SettingsManager.defaultDownloadDirectory.path)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(String(localized: "Download Location"))
            }

            // MARK: - Concurrency & Storage Section

            Section {
                Stepper(
                    value: self.$settings.maxConcurrentDownloads,
                    in: 1 ... 5
                ) {
                    HStack {
                        Text(String(localized: "Concurrent Downloads"))
                        Spacer()
                        Text("\(self.settings.maxConcurrentDownloads)")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(String(localized: "Downloaded Tracks"))
                    Spacer()
                    Text("\(self.downloadManager.downloadedSongs.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(String(localized: "Storage Used"))
                    Spacer()
                    Text(self.totalStorageFormatted)
                        .foregroundStyle(.secondary)
                }

                if !self.downloadManager.downloadedSongs.isEmpty {
                    Button(role: .destructive) {
                        self.isShowingDeleteConfirmation = true
                    } label: {
                        Text(String(localized: "Delete All Downloads"))
                            .foregroundStyle(.red)
                    }
                    .confirmationDialog(
                        String(localized: "Delete All Downloads?"),
                        isPresented: self.$isShowingDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Delete Everything"), role: .destructive) {
                            self.downloadManager.removeAllDownloads()
                        }
                        Button(String(localized: "Cancel"), role: .cancel) {}
                    } message: {
                        Text(String(localized: "This will remove all downloaded audio files and album artwork from disk."))
                    }
                }
            } header: {
                Text(String(localized: "Storage & Queue"))
            }

            // MARK: - Tool Dependencies Section

            Section {
                self.dependencyRow(
                    name: "yt-dlp",
                    path: self.downloadManager.ytdlpPath,
                    isAvailable: self.downloadManager.isYtdlpAvailable,
                    installHint: "brew install yt-dlp",
                    customPath: self.$settings.customYtdlpPath
                )

                self.dependencyRow(
                    name: "ffmpeg",
                    path: self.downloadManager.ffmpegPath,
                    isAvailable: self.downloadManager.isFfmpegAvailable,
                    installHint: "brew install ffmpeg",
                    customPath: self.$settings.customFfmpegPath
                )
            } header: {
                Text(String(localized: "Dependencies"))
            } footer: {
                Text(String(localized: "Downloads require yt-dlp and ffmpeg for audio stream extraction and thumbnail embedding."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 380)
        .localizedNavigationTitle("Downloads")
    }

    // MARK: - Subviews

    private func dependencyRow(
        name: String,
        path: String?,
        isAvailable: Bool,
        installHint: String,
        customPath: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isAvailable ? .green : .yellow)

                Text(name)
                    .fontWeight(.medium)

                Spacer()

                if let path, !path.isEmpty {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                } else {
                    Text(String(localized: "Not Found"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !isAvailable {
                HStack(spacing: 8) {
                    Text(installHint)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        }

                    Spacer()

                    Button(String(localized: "Locate…")) {
                        self.selectCustomBinary(customPath: customPath)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Computed Properties

    private var formatDescription: String {
        switch self.settings.downloadAudioFormat {
        case .bestAudio:
            String(localized: "Extracts original M4A/AAC audio stream without re-encoding.")
        case .mp3_320:
            String(localized: "Converts audio to high-bitrate 320 kbps MP3 with embedded album art.")
        case .opus:
            String(localized: "Extracts high-fidelity Opus audio stream.")
        }
    }

    private var totalStorageFormatted: String {
        let totalBytes = self.downloadManager.downloadedSongs.compactMap(\.fileSize).reduce(0, +)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }

    // MARK: - Actions

    private func selectCustomDirectory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Download Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.level = .modalPanel

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            self.settings.downloadDirectoryPath = url.path
        }
    }

    private func selectCustomBinary(customPath: Binding<String>) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate Binary")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.level = .modalPanel

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            customPath.wrappedValue = url.path
        }
    }
}
