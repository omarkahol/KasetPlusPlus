import Foundation
import Testing
@testable import KasetPlus

// MARK: - ChannelPageParserTests

@Suite("ChannelPageParser", .tags(.parser))
struct ChannelPageParserTests {
    @Test("Parses channel metadata and landing videos from a captured browse response")
    func parsesChannelPage() throws {
        let data = try loadYouTubeFixture("youtube_channel")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        #expect(detail.channel.channelId == "UC_x5XG1OV2P6uZZ5FSM9Ttw")
        #expect(detail.channel.name == "Google for Developers")
        #expect(detail.channel.thumbnailURL != nil)
        #expect(detail.channel.descriptionSnippet?.isEmpty == false)
        #expect(!detail.videos.isEmpty)
    }
}

// MARK: - YouTubePlaylistPageParserTests

@Suite("YouTubePlaylistPageParser", .tags(.parser))
struct YouTubePlaylistPageParserTests {
    @Test("Parses playlist title and videos from a captured browse response")
    func parsesPlaylistPage() throws {
        let data = try loadYouTubeFixture("youtube_playlist")

        let detail = YouTubePlaylistPageParser.parse(data, playlistId: "PLsyeobzWxl7poL9JTVyndKe62ieoN-MZ3")

        #expect(detail.playlist.playlistId == "PLsyeobzWxl7poL9JTVyndKe62ieoN-MZ3")
        #expect(detail.playlist.title == "Python for Beginners (Full Course) | Programming Tutorial")
        #expect(!detail.videos.isEmpty)
        #expect(detail.playlist.firstVideoId == detail.videos.first?.videoId)
    }
}

// MARK: - YouTubeCommentsParserTests

@Suite("YouTubeCommentsParser", .tags(.parser))
struct YouTubeCommentsParserTests {
    @Test("Watch-next fixture exposes the comments continuation")
    func watchNextHasCommentsContinuation() throws {
        let data = try loadYouTubeFixture("youtube_watch_next")
        #expect(WatchNextParser.commentsContinuation(of: data) != nil)
    }

    @Test("Parses comments from entity payload mutations")
    func parsesEntityPayloads() throws {
        let data: [String: Any] = [
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [
                        [
                            "payload": [
                                "commentEntityPayload": [
                                    "properties": [
                                        "commentId": "c1",
                                        "content": ["content": "Nice video"],
                                        "publishedTime": "2 days ago",
                                    ],
                                    "author": [
                                        "displayName": "@someone",
                                        "avatarThumbnailUrl": "https://example.com/a.jpg",
                                    ],
                                    "toolbar": ["likeCountNotliked": "42"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "onResponseReceivedEndpoints": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "continuationItemRenderer": [
                                    "continuationEndpoint": [
                                        "continuationCommand": ["token": "next-page"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let page = YouTubeCommentsParser.parse(data)

        let comment = try #require(page.comments.first)
        #expect(comment.id == "c1")
        #expect(comment.author == "@someone")
        #expect(comment.text == "Nice video")
        #expect(comment.publishedText == "2 days ago")
        #expect(comment.likeCountText == "42")
        #expect(page.continuation == "next-page")
    }

    @Test("Links view models to entity payloads, surfaces, and replies")
    func linksViewModels() throws {
        let data: [String: Any] = [
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [
                        [
                            "entityKey": "key-c1",
                            "payload": [
                                "commentEntityPayload": [
                                    "properties": [
                                        "commentId": "c1",
                                        "content": ["content": "Threaded"],
                                    ],
                                    "author": [
                                        "displayName": "@author",
                                        "channelId": "UCauthor",
                                    ],
                                ],
                            ],
                        ],
                        [
                            "entityKey": "key-s1",
                            "payload": [
                                "engagementToolbarSurfaceEntityPayload": [
                                    "likeCommand": [
                                        "innertubeCommand": [
                                            "performCommentActionEndpoint": ["action": "like-token"],
                                        ],
                                    ],
                                    "unlikeCommand": [
                                        "innertubeCommand": [
                                            "performCommentActionEndpoint": ["action": "unlike-token"],
                                        ],
                                    ],
                                    "dislikeCommand": [
                                        "innertubeCommand": [
                                            "performCommentActionEndpoint": ["action": "dislike-token"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "onResponseReceivedEndpoints": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "commentThreadRenderer": [
                                    "commentViewModel": [
                                        "commentViewModel": [
                                            "commentId": "c1",
                                            "commentKey": "key-c1",
                                            "toolbarSurfaceKey": "key-s1",
                                        ],
                                    ],
                                    "replies": [
                                        "commentRepliesRenderer": [
                                            "contents": [
                                                [
                                                    "continuationItemRenderer": [
                                                        "continuationEndpoint": [
                                                            "continuationCommand": ["token": "replies-token"],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let page = YouTubeCommentsParser.parse(data)

        let comment = try #require(page.comments.first)
        #expect(comment.id == "c1")
        #expect(comment.authorChannelId == "UCauthor")
        #expect(comment.likeAction == "like-token")
        #expect(comment.unlikeAction == "unlike-token")
        #expect(comment.dislikeAction == "dislike-token")
        #expect(comment.repliesContinuation == "replies-token")
    }

    @Test("Parses legacy commentRenderer responses and create params")
    func parsesLegacyRenderers() throws {
        let data: [String: Any] = [
            "onResponseReceivedEndpoints": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "commentThreadRenderer": [
                                    "comment": [
                                        "commentRenderer": [
                                            "commentId": "legacy1",
                                            "contentText": ["runs": [["text": "Old style"]]],
                                            "authorText": ["simpleText": "@old"],
                                            "publishedTimeText": ["runs": [["text": "1 year ago"]]],
                                            "voteCount": ["simpleText": "7"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "header": [
                "commentsHeaderRenderer": [
                    "createRenderer": [
                        "commentSimpleboxRenderer": [
                            "submitButton": [
                                "buttonRenderer": [
                                    "serviceEndpoint": [
                                        "createCommentEndpoint": [
                                            "createCommentParams": "create-params-token",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let page = YouTubeCommentsParser.parse(data)

        let comment = try #require(page.comments.first)
        #expect(comment.id == "legacy1")
        #expect(comment.author == "@old")
        #expect(comment.text == "Old style")
        #expect(page.createCommentParams == "create-params-token")
    }
}

// MARK: - WatchNextParserHeatmapTests

@Suite("WatchNextParser heatmap")
struct WatchNextParserHeatmapTests {
    /// Builds the minimal `next` shape carrying a MARKER_TYPE_HEATMAP entity.
    private func response(videoId: String, markers: [[String: Any]]) -> [String: Any] {
        [
            "currentVideoEndpoint": ["watchEndpoint": ["videoId": videoId]],
            "frameworkUpdates": ["entityBatchUpdate": ["mutations": [
                ["payload": ["macroMarkersListEntity": [
                    "externalVideoId": videoId,
                    "markersList": [
                        "markerType": "MARKER_TYPE_HEATMAP",
                        "markers": markers,
                    ],
                ]]],
            ]]],
        ]
    }

    @Test("Normalizes heatmap samples to fraction/intensity spanning the video")
    func parsesHeatmap() {
        let markers: [[String: Any]] = [
            ["startMillis": "0", "durationMillis": "1000", "intensityScoreNormalized": 1.0],
            ["startMillis": "1000", "durationMillis": "1000", "intensityScoreNormalized": 0.5],
            ["startMillis": "2000", "durationMillis": "2000", "intensityScoreNormalized": 0.0],
        ]
        let heatmap = WatchNextParser.heatmap(of: self.response(videoId: "abc", markers: markers))

        #expect(heatmap.count == 3)
        // Span = last.start(2000) + last.duration(2000) = 4000.
        #expect(heatmap[0].fraction == 0)
        #expect(heatmap[1].fraction == 0.25)
        #expect(heatmap[2].fraction == 0.5)
        #expect(heatmap[0].intensity == 1.0)
        #expect(heatmap[2].intensity == 0.0)
    }

    @Test("Ignores a heatmap entity for a different video")
    func skipsMismatchedVideo() {
        let markers: [[String: Any]] = [
            ["startMillis": "0", "durationMillis": "1000", "intensityScoreNormalized": 1.0],
            ["startMillis": "1000", "durationMillis": "1000", "intensityScoreNormalized": 0.2],
        ]
        var data = self.response(videoId: "other", markers: markers)
        // Current video is "abc" but the entity belongs to "other".
        data["currentVideoEndpoint"] = ["watchEndpoint": ["videoId": "abc"]]

        #expect(WatchNextParser.heatmap(of: data).isEmpty)
    }
}

// MARK: - LiveChatParserTests

@Suite("LiveChatParser")
struct LiveChatParserTests {
    @Test("Parses text messages, roles, emoji, and the next poll token")
    func parsesLiveChat() {
        let data: [String: Any] = [
            "continuationContents": ["liveChatContinuation": [
                "actions": [
                    ["addChatItemAction": ["item": ["liveChatTextMessageRenderer": [
                        "id": "msg-1",
                        "authorName": ["simpleText": "@Alice"],
                        "authorExternalChannelId": "UC123",
                        "message": ["runs": [
                            ["text": "hello "],
                            ["emoji": ["emojiId": "😀", "isCustomEmoji": false]],
                        ]],
                        "authorBadges": [
                            ["liveChatAuthorBadgeRenderer": ["icon": ["iconType": "MODERATOR"]]],
                        ],
                    ]]]],
                ],
                "continuations": [
                    ["invalidationContinuationData": ["continuation": "next-token", "timeoutMs": 8000]],
                ],
            ]],
        ]
        let page = LiveChatParser.parse(data)
        #expect(page.messages.count == 1)
        #expect(page.messages.first?.author == "@Alice")
        #expect(page.messages.first?.message == "hello 😀")
        #expect(page.messages.first?.isModerator == true)
        #expect(page.messages.first?.authorChannelId == "UC123")
        #expect(page.continuation == "next-token")
        #expect(page.timeoutMs == 8000)
    }
}
