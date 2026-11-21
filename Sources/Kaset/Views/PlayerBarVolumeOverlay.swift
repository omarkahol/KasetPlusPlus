import SwiftUI

// MARK: - PlayerBarVolumeOverlay

/// Shared floating volume capsule presented above the volume button in both
/// `PlayerBar` and `YouTubePlayerBar`.
struct PlayerBarVolumeOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var value: Double
    @Binding var isAdjusting: Bool
    let volumeIcon: String
    let accent: Color
    var accessibilityIdentifier: String?
    let onSetVolume: (Double) -> Void

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)

                PlayerBarVerticalSlider(
                    value: self.$value,
                    accent: self.accent,
                    accessibilityIdentifier: self.accessibilityIdentifier,
                    accessibilityLabel: String(localized: "Volume"),
                    onEditingChanged: { editing in
                        self.isAdjusting = editing
                        if !editing {
                            self.onSetVolume(self.value)
                        }
                    },
                    onValueChanged: { oldValue, newValue in
                        if self.isAdjusting {
                            if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                                HapticService.sliderBoundary()
                            }
                            self.onSetVolume(newValue)
                        }
                    }
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 16)
            .frame(width: 46, height: 168)
            .background {
                Capsule()
                    .fill(self.volumeOverlayFill)
            }
            .compatGlass(interactive: true, tint: self.volumeOverlayTint, in: .capsule)
            .shadow(color: self.volumeOverlayShadow, radius: 14, y: 5)
        }
    }

    private var volumeOverlayFill: Color {
        self.colorScheme == .dark ? .black.opacity(0.22) : .white.opacity(0.72)
    }

    private var volumeOverlayTint: Color {
        self.colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    private var volumeOverlayShadow: Color {
        self.colorScheme == .dark ? .black.opacity(0.36) : .black.opacity(0.18)
    }
}
