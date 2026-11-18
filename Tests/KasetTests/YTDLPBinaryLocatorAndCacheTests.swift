import Foundation
import Testing
@testable import KasetPlus

@Suite("YTDLPBinaryLocator & DearrowCache", .serialized, .tags(.service))
@MainActor
struct YTDLPBinaryLocatorAndCacheTests {
    @Test("DearrowCache evicts oldest entries beyond maxEntries")
    func dearrowCacheEvictsLRU() {
        let cache = DearrowCache.makeTestInstance(maxEntries: 3)

        _ = cache.displayTitle(for: "v1", original: "Title 1")
        _ = cache.displayTitle(for: "v2", original: "Title 2")
        _ = cache.displayTitle(for: "v3", original: "Title 3")
        #expect(cache.cachedEntryCount == 3)

        _ = cache.displayTitle(for: "v4", original: "Title 4")
        #expect(cache.cachedEntryCount == 3)
        #expect(cache.originalTitle(for: "v1") == nil)
        #expect(cache.originalTitle(for: "v4") == "Title 4")
    }

    @Test("YTDLPBinaryLocator invalidate resets lookup state cleanly")
    func locatorInvalidateDoesNotCrash() {
        YTDLPBinaryLocator.shared.invalidate()
        _ = YTDLPBinaryLocator.shared.ytdlpPath()
    }
}
