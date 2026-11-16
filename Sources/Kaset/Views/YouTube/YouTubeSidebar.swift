import SwiftUI

// MARK: - YouTubeSidebar

/// Sidebar navigation for the YouTube (video) experience.
///
/// Mirrors the music `Sidebar` structure so toggling sources feels native:
/// main items on top, a Discover section, and a Collection section, with the
/// shared footer (source toggle + profile) at the bottom.
struct YouTubeSidebar: View {
    @Binding var selection: YouTubeNavigationItem?
    var onReselect: ((YouTubeNavigationItem) -> Void)?
    @Environment(AuthService.self) private var authService
    @State private var settings = SettingsManager.shared

    var body: some View {
        List {
            // Main navigation
            Section {
                self.row(for: .search)
                self.row(for: .home)
                if self.hasPersonalAccount {
                    self.row(for: .subscriptions)
                }
            }

            // Discover section
            Section(String(localized: "Discover")) {
                self.row(for: .explore)
                self.row(for: .shorts)
            }

            // Collection section
            Section(String(localized: "Collection")) {
                if self.hasPersonalAccount {
                    self.row(for: .likedVideos)
                    self.row(for: .watchLater)
                    self.row(for: .playlists)
                    self.row(for: .history)
                }

                self.row(for: .downloads)
                self.offlineModeRow
            }
        }
        .listStyle(.sidebar)
        .compatTranslucentSidebar()
        .accessibilityIdentifier(AccessibilityID.YouTubeSidebar.container)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooterView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private var offlineModeRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.settings.isOfflineModeEnabled.toggle()
                if self.settings.isOfflineModeEnabled {
                    self.selection = .downloads
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.settings.isOfflineModeEnabled ? "antenna.radiowaves.left.and.right.slash" : "bolt.slash")
                    .foregroundStyle(self.settings.isOfflineModeEnabled ? self.settings.accentColor : .secondary)
                    .frame(width: 16)

                Text(String(localized: "Offline Mode"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { self.settings.isOfflineModeEnabled },
                    set: { isEnabled in
                        self.settings.isOfflineModeEnabled = isEnabled
                        if isEnabled {
                            self.selection = .downloads
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.YouTubeSidebar.offlineMode)
    }

    private func row(for item: YouTubeNavigationItem) -> some View {
        KasetSidebarRow(
            title: item.displayName,
            systemImage: item.icon,
            isSelected: self.selection == item
        ) {
            self.select(item)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeSidebar.item(for: item))
    }

    private func select(_ item: YouTubeNavigationItem) {
        if self.selection == item {
            self.onReselect?(item)
            HapticService.navigation()
            return
        }
        self.selection = item
        HapticService.navigation()
    }
}

// MARK: - AccessibilityID.YouTubeSidebar

extension AccessibilityID {
    enum YouTubeSidebar {
        static let container = "youtubeSidebar"

        static func item(for item: YouTubeNavigationItem) -> String {
            "youtubeSidebar.\(item.rawValue)"
        }

        static let offlineMode = "youtubeSidebar.offlineMode"
    }
}

#Preview {
    YouTubeSidebar(selection: .constant(.home))
        .frame(width: 220)
        .environment(AuthService())
}
