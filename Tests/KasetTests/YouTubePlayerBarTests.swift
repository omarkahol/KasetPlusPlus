import AppKit
import Foundation
import SwiftUI
import Testing
@testable import KasetPlus

@Suite("YouTube player bar", .tags(.model))
@MainActor
struct YouTubePlayerBarTests {
    @Test("Chapter segments resolve explicit, next-chapter, and duration end times")
    func chapterSegmentsResolveEndTimes() throws {
        let chapters = [
            self.chapter(title: "Opening", start: 0, end: 45),
            self.chapter(title: "Main topic", start: 60),
            self.chapter(title: "Closing", start: 180),
        ]

        let segments = YouTubePlayerBar.chapterProgressSegments(chapters: chapters, duration: 300)
        #expect(segments.count == 3)

        let opening = try #require(segments.first)
        #expect(opening.start == 0)
        #expect(abs(opening.end - 0.15) < 0.000_001)
        #expect(opening.title == "Opening")
        #expect(opening.itemLabel == String(localized: "Chapter"))
        #expect(opening.rangeText == "0:00 – 0:45")

        let mainTopic = segments[1]
        #expect(abs(mainTopic.start - 0.2) < 0.000_001)
        #expect(abs(mainTopic.end - 0.6) < 0.000_001)
        #expect(mainTopic.title == "Main topic")
        #expect(mainTopic.itemLabel == String(localized: "Chapter"))
        #expect(mainTopic.rangeText == "1:00 – 3:00")

        let closing = try #require(segments.last)
        #expect(abs(closing.start - 0.6) < 0.000_001)
        #expect(closing.end == 1)
        #expect(closing.title == "Closing")
        #expect(closing.itemLabel == String(localized: "Chapter"))
        #expect(closing.rangeText == "3:00 – 5:00")

        #expect(segments.map(\.index) == [0, 1, 2])
        #expect(segments.allSatisfy { $0.count == 3 })
    }

    @Test("Explicit chapter ends are capped by the next chapter and video duration")
    func explicitEndsAreCapped() throws {
        let chapters = [
            self.chapter(title: "Overlaps next", start: 0, end: 180),
            self.chapter(title: "Past duration", start: 100, end: 500),
        ]

        let segments = YouTubePlayerBar.chapterProgressSegments(chapters: chapters, duration: 240)
        #expect(segments.count == 2)

        let first = try #require(segments.first)
        #expect(first.start == 0)
        #expect(abs(first.end - (100.0 / 240.0)) < 0.000_001)
        #expect(first.rangeText == "0:00 – 1:40")

        let second = try #require(segments.last)
        #expect(abs(second.start - (100.0 / 240.0)) < 0.000_001)
        #expect(second.end == 1)
        #expect(second.rangeText == "1:40 – 4:00")
    }

    @Test("Invalid starts and duplicate boundaries are omitted and valid spans are reindexed")
    func invalidChaptersAreOmittedAndSegmentsAreReindexed() {
        let chapters = [
            self.chapter(title: "Intro", start: 0, end: 80),
            self.chapter(title: "Recovered end", start: 80, end: 80),
            self.chapter(title: "Final", start: 180),
            self.chapter(title: "Final", start: 180),
            self.chapter(title: "Negative", start: -1, end: 20),
            self.chapter(title: "Not a number", start: .nan, end: 20),
            self.chapter(title: "Infinite", start: .infinity, end: nil),
            self.chapter(title: "At duration", start: 300, end: nil),
            self.chapter(title: "Past duration", start: 450, end: nil),
        ]

        let segments = YouTubePlayerBar.chapterProgressSegments(chapters: chapters, duration: 300)

        #expect(segments.count == 3)
        #expect(segments.map(\.index) == [0, 1, 2])
        #expect(segments.allSatisfy { $0.count == 3 })
        #expect(segments.map(\.title) == ["Intro", "Recovered end", "Final"])

        #expect(segments[0].start == 0)
        #expect(abs(segments[0].end - (80.0 / 300.0)) < 0.000_001)
        #expect(abs(segments[1].start - (80.0 / 300.0)) < 0.000_001)
        #expect(abs(segments[1].end - (180.0 / 300.0)) < 0.000_001)
        #expect(segments[1].rangeText == "1:20 – 3:00")
        #expect(abs(segments[2].start - (180.0 / 300.0)) < 0.000_001)
        #expect(segments[2].end == 1)
    }

    @Test("Options width accommodates all buttons in full and reduced tiers")
    func optionsWidthAccommodatesReducedButtons() {
        let reducedWidth = YouTubePlayerBar.youtubeOptionsWidth(tier: .reduced)
        // Four 28pt buttons + three 6pt gaps + 12pt trailing padding = 142pt minimum.
        #expect(reducedWidth >= 142)
        #expect(reducedWidth == 144)
        #expect(YouTubePlayerBar.youtubeOptionsWidth(tier: .full) == 246)
        // Eight buttons (with alternate audio track): 8*28 + 7*6 + 12 = 278pt.
        #expect(
            YouTubePlayerBar.youtubeOptionsWidth(
                tier: .full,
                hasPersonalAccount: true,
                isLive: false,
                hasAlternateAudio: true
            ) == 278
        )
    }

    @Test("Bar layout metrics keep scrubber uncrowded and prevent overflow across supported widths")
    func barLayoutMetricsPreventOverflowAcrossWidths() {
        let widths: [CGFloat] = [480, 512, 608, 680, 728, 737, 840, 1024]
        for width in widths {
            let metrics = YouTubePlayerBar.layoutMetrics(
                forBarWidth: width,
                hasPersonalAccount: true,
                isLive: false,
                hasAlternateAudio: true
            )
            let spacing: CGFloat = metrics.showsDetails ? 20 : 10
            let expectedLeadingPadding: CGFloat = metrics.showsDetails ? 0 : 14
            #expect(metrics.leadingPadding == expectedLeadingPadding)
            #expect(
                metrics.leadingPadding + metrics.detailsWidth + metrics.optionsWidth + spacing + metrics.progressWidth == width
            )
            #expect(metrics.progressWidth >= 248)
        }
    }

    @Test("Minimum detached video bar preserves 14pt leading inset and fits H:MM:SS timestamps")
    func minimumDetachedBarPreservesLeadingInset() {
        // Detached video window minimum content width = 512pt; outer horizontal padding = 32pt -> 480pt bar.
        let metrics = YouTubePlayerBar.layoutMetrics(
            forBarWidth: 480,
            hasPersonalAccount: true,
            isLive: false,
            hasAlternateAudio: true
        )
        #expect(!metrics.showsDetails)
        #expect(metrics.leadingPadding == 14)
        #expect(metrics.progressWidth == 312)

        let lane = PlayerBarProgressLane(
            fraction: 0.4,
            accent: .red,
            elapsedText: "1:23:45",
            remainingText: "-1:23:45",
            isLive: false,
            canSeek: true,
            isLoading: false,
            onScrub: { _ in },
            onCommit: {},
            inlineTimestamps: true
        )
        .padding(.leading, metrics.leadingPadding)
        .frame(width: metrics.leadingPadding + metrics.progressWidth, height: 52)

        let host = NSHostingView(rootView: lane)
        host.frame = NSRect(x: 0, y: 0, width: metrics.leadingPadding + metrics.progressWidth, height: 52)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width <= metrics.leadingPadding + metrics.progressWidth)
        #expect(host.frame.minX >= 0)
    }

    private func chapter(
        title: String,
        start: TimeInterval,
        end: TimeInterval? = nil
    ) -> YouTubeChapter {
        YouTubeChapter(
            videoId: "video-id",
            title: title,
            startTime: start,
            endTime: end,
            timeText: nil,
            thumbnailURL: nil
        )
    }
}
