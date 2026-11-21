import Foundation

/// Shared navigation helpers for standard InnerTube browse and continuation envelopes.
enum InnerTubeEnvelope {
    /// Extracts `contents.singleColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer`.
    static func singleColumnSectionList(in data: [String: Any]) -> [String: Any]? {
        guard let contents = data["contents"] as? [String: Any],
              let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = singleColumn["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionListRenderer = tabContent["sectionListRenderer"] as? [String: Any]
        else {
            return nil
        }
        return sectionListRenderer
    }

    /// Extracts the section array from `singleColumnSectionList(in:)`.
    static func singleColumnSections(in data: [String: Any]) -> [[String: Any]]? {
        self.singleColumnSectionList(in: data)?["contents"] as? [[String: Any]]
    }

    /// Extracts the `nextContinuationData.continuation` token from a renderer's `continuations` array.
    static func continuationToken(from container: [String: Any]) -> String? {
        guard let continuations = container["continuations"] as? [[String: Any]],
              let firstContinuation = continuations.first,
              let nextContinuationData = firstContinuation["nextContinuationData"] as? [String: Any],
              let token = nextContinuationData["continuation"] as? String
        else {
            return nil
        }
        return token
    }

    /// Extracts the continuation token from a `singleColumnBrowseResultsRenderer` response.
    static func singleColumnContinuationToken(in data: [String: Any]) -> String? {
        guard let sectionListRenderer = self.singleColumnSectionList(in: data) else {
            return nil
        }
        return self.continuationToken(from: sectionListRenderer)
    }

    /// Extracts the continuation token from a `continuationContents` response.
    static func continuationToken(inContinuationData data: [String: Any]) -> String? {
        guard let continuationContents = data["continuationContents"] as? [String: Any] else {
            return nil
        }

        if let sectionListContinuation = continuationContents["sectionListContinuation"] as? [String: Any],
           let token = self.continuationToken(from: sectionListContinuation)
        {
            return token
        }

        if let shelfContinuation = continuationContents["musicShelfContinuation"] as? [String: Any],
           let token = self.continuationToken(from: shelfContinuation)
        {
            return token
        }

        return nil
    }
}
