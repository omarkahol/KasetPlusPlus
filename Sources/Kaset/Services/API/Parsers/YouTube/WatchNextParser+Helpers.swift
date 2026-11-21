import Foundation

extension WatchNextParser {
    static func findRepeatChapterCommand(in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let command = dict["repeatChapterCommand"] as? [String: Any] {
                return command
            }

            for nested in dict.values {
                if let command = self.findRepeatChapterCommand(in: nested) {
                    return command
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let command = self.findRepeatChapterCommand(in: element) {
                    return command
                }
            }
        }

        return nil
    }

    static func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let double as Double:
            Int(double)
        case let number as NSNumber:
            Int(number.int64Value)
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    static func deduplicateChapters(_ chapters: [YouTubeChapter]) -> [YouTubeChapter] {
        var indexByKey: [String: Int] = [:]
        var result: [YouTubeChapter] = []

        for chapter in chapters {
            let key = self.chapterKey(chapter)
            if let index = indexByKey[key] {
                if result[index].endTime == nil, chapter.endTime != nil {
                    result[index] = self.mergingEndTime(in: result[index], from: chapter)
                }
                continue
            }
            indexByKey[key] = result.count
            result.append(chapter)
        }

        return result.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            return lhs.title < rhs.title
        }
    }

    static func mergingEndTimes(
        in chapters: [YouTubeChapter],
        from boundedChapters: [YouTubeChapter]
    ) -> [YouTubeChapter] {
        let boundsByKey = Dictionary(uniqueKeysWithValues: boundedChapters.map {
            (self.chapterKey($0), $0)
        })
        return chapters.map { chapter in
            guard chapter.endTime == nil, let boundedChapter = boundsByKey[self.chapterKey(chapter)] else {
                return chapter
            }
            return self.mergingEndTime(in: chapter, from: boundedChapter)
        }
    }

    private static func mergingEndTime(
        in chapter: YouTubeChapter,
        from boundedChapter: YouTubeChapter
    ) -> YouTubeChapter {
        YouTubeChapter(
            videoId: chapter.videoId,
            title: chapter.title,
            startTime: chapter.startTime,
            endTime: boundedChapter.endTime,
            timeText: chapter.timeText,
            thumbnailURL: chapter.thumbnailURL
        )
    }

    private static func chapterKey(_ chapter: YouTubeChapter) -> String {
        "\(chapter.videoId ?? "")|\(Int((chapter.startTime * 1000).rounded()))|\(chapter.title)"
    }

    // MARK: - Private

    static func channel(fromVideoOwner owner: [String: Any]) -> YouTubeChannel? {
        let browseEndpoint = (owner["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
            as? [String: Any]
        guard let name = YouTubeItemParser.text(from: owner["title"]),
              let channelId = browseEndpoint?["browseId"] as? String
        else {
            return nil
        }

        return YouTubeChannel(
            channelId: channelId,
            name: name,
            handle: (browseEndpoint?["canonicalBaseUrl"] as? String)?
                .split(separator: "/").last.map(String.init),
            subscriberCountText: YouTubeItemParser.text(from: owner["subscriberCountText"]),
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: owner["thumbnail"])
        )
    }
}
