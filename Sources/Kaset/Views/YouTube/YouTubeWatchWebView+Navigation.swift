import os
import SwiftUI
import WebKit

extension YouTubeWatchWebView {
    // MARK: - User Scripts

    func beginBlankDocumentNavigation() -> URL? {
        self.documentNavigations.removeAll()
        self.cancelledDocumentNavigations.removeAll()
        self.continuationGenerationsAwaitingStart.removeAll()
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.cancelledPendingSeekGenerations.removeAll()
        self.directSeekGenerations.removeAll()
        self.pendingSeekRetryCounts.removeAll()
        let generation = self.documentGeneration.beginBlankNavigation()
        return WebPlaybackDocumentGeneration.blankURL(generation: generation)
    }

    func recordAcceptedMainFrameResponse(_ response: URLResponse) {
        guard let currentVideoId = self.currentVideoId else { return }
        _ = self.documentGeneration.recordSuccessfulPlaybackResponse(
            url: response.url,
            host: "www.youtube.com",
            videoID: currentVideoId
        )
    }

    func refreshDocumentUserScripts(on webView: WKWebView) {
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        let scriptGeneration = self.documentGeneration.userScriptGeneration
        let pendingSeek: Double? = if self.documentGeneration.pendingGeneration != nil
            || self.documentGeneration.inFlightGeneration != nil
        {
            self.pendingSeek
        } else {
            nil
        }
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume,
            documentGeneration: scriptGeneration,
            pendingSeek: pendingSeek,
            pendingSeekVideoId: pendingSeek == nil ? nil : self.currentVideoId,
            pendingSeekAttemptID: pendingSeek == nil
                ? nil
                : self.pendingSeekAttemptIDsByGeneration[scriptGeneration]
        )
    }

    func startDocumentNavigation(
        on webView: WKWebView,
        request: URLRequest,
        generation: UInt64,
        pendingSeek: Double?,
        url: URL
    ) {
        guard webView === self.webView else {
            if self.documentGeneration.pendingGeneration == generation {
                self.handlePendingDocumentNavigationFailure(webView: webView)
            }
            return
        }
        guard self.documentGeneration.startNavigation(generation) else {
            self.logger.debug("YouTube load superseded before navigation; skipping stale \(url.absoluteString)")
            return
        }
        if WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
            webView.url,
            host: "www.youtube.com"
        ) {
            webView.evaluateJavaScript(
                WebPlaybackDocumentGeneration.locationReplacementScript(for: url)
            ) { [weak self, weak webView] _, error in
                guard let self,
                      let webView,
                      webView === self.webView,
                      self.documentGeneration.inFlightGeneration == generation,
                      self.documentGeneration.pendingGeneration == nil
                else { return }
                guard error == nil
                    || WebPlaybackDocumentGeneration.generation(from: webView.url) == generation
                else {
                    self.handleCurrentDocumentNavigationFailure(
                        generation,
                        webView: webView,
                        resumeAtOverride: pendingSeek
                    )
                    return
                }
            }
            return
        }
        guard let navigation = webView.load(request) else {
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
            return
        }
        self.documentNavigations[navigation] = WebPlaybackTrackedNavigation(
            generation: generation,
            pendingSeek: self.pendingSeeksByGeneration[generation] ?? pendingSeek
        )
    }

    func startBoundNavigationContinuation(
        on webView: WKWebView,
        request: URLRequest,
        generation: UInt64
    ) {
        guard webView === self.webView,
              self.documentGeneration.inFlightGeneration == generation,
              self.documentGeneration.pendingGeneration == nil
        else {
            self.continuationGenerationsAwaitingStart.remove(generation)
            return
        }
        guard let navigation = webView.load(request) else {
            self.continuationGenerationsAwaitingStart.remove(generation)
            self.handleCurrentDocumentNavigationFailure(generation, webView: webView)
            return
        }
        self.documentNavigations[navigation] = WebPlaybackTrackedNavigation(
            generation: generation,
            pendingSeek: self.pendingSeeksByGeneration[generation]
        )
        self.continuationGenerationsAwaitingStart.remove(generation)
    }

    func cancelActiveDocumentNavigation(on webView: WKWebView) {
        guard let generation = self.documentGeneration.inFlightGeneration else { return }
        for (identifier, navigation) in self.documentNavigations
            where navigation.generation == generation
        {
            self.cancelledDocumentNavigations[identifier] = WebPlaybackCancelledNavigation(
                generation: generation,
                shouldReportFailure: false
            )
        }
        self.documentNavigations = self.documentNavigations.filter {
            $0.value.generation != generation
        }
        self.pendingSeeksByGeneration.removeValue(forKey: generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
        self.directSeekGenerations.remove(generation)
        self.pendingSeekRetryCounts.removeValue(forKey: generation)
        _ = self.documentGeneration.cancelInFlightNavigation(generation)
        self.continuationGenerationsAwaitingStart.remove(generation)
        webView.stopLoading()
    }

    func trackDocumentNavigationStart(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView,
              let navigation,
              self.documentNavigations[navigation] == nil,
              let generation = WebPlaybackDocumentGeneration.generation(from: webView.url)
              ?? (self.documentGeneration.committedIntermediaryGeneration
                  == self.documentGeneration.inFlightGeneration
                  && WebPlaybackDocumentGeneration.isAllowedPlaybackNavigationURL(
                      webView.url,
                      playbackHost: "www.youtube.com"
                  ) ? self.documentGeneration.inFlightGeneration : nil),
              generation == self.documentGeneration.inFlightGeneration
        else { return }
        self.documentNavigations[navigation] = WebPlaybackTrackedNavigation(
            generation: generation,
            pendingSeek: self.pendingSeeksByGeneration[generation]
        )
    }

    func handleDocumentNavigationRedirect(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations[navigation],
              trackedNavigation.generation == self.documentGeneration.inFlightGeneration,
              self.documentGeneration.pendingGeneration == nil
        else { return }
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        self.installUserScripts(
            on: webView.configuration.userContentController,
            targetVolume: targetVolume,
            documentGeneration: trackedNavigation.generation,
            pendingSeek: trackedNavigation.pendingSeek,
            pendingSeekVideoId: self.pendingSeekVideoIdsByGeneration[trackedNavigation.generation],
            pendingSeekAttemptID: self.pendingSeekAttemptIDsByGeneration[trackedNavigation.generation]
        )
    }

    func commitDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        guard webView === self.webView else { return }
        if let navigation,
           let cancelledNavigation = self.cancelledDocumentNavigations[navigation]
        {
            if WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
                cancelledGeneration: cancelledNavigation.generation,
                committedURL: webView.url,
                pendingGeneration: self.documentGeneration.pendingGeneration,
                inFlightGeneration: self.documentGeneration.inFlightGeneration,
                currentGeneration: self.documentGeneration.currentGeneration
            ) {
                let replacementGeneration = self.documentGeneration.pendingGeneration
                    ?? self.documentGeneration.inFlightGeneration
                if let replacementGeneration,
                   replacementGeneration != cancelledNavigation.generation
                {
                    self.suppressSurvivingDocumentMedia(webView)
                } else {
                    self.pauseSurvivingDocument(webView)
                }
            }
            return
        }
        if WebPlaybackDocumentGeneration.isInternalBlankNavigation(webView.url) {
            guard self.documentGeneration.ownsBlankNavigation(webView.url) else {
                self.handleUnexpectedBlankDocumentCommit(navigation, webView: webView)
                return
            }
            return
        }
        guard let navigation,
              var trackedNavigation = self.documentNavigations[navigation]
        else { return }
        trackedNavigation.didCommit = true
        if let currentVideoId = self.currentVideoId,
           WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
               webView.url,
               host: "www.youtube.com",
               videoID: currentVideoId
           )
        {
            guard self.documentGeneration.commitNavigation(
                trackedNavigation.generation,
                expectedVideoID: currentVideoId
            ) else { return }
            trackedNavigation.didActivatePlaybackOrigin = true
        } else if WebPlaybackDocumentGeneration.isTrustedIntermediaryURL(webView.url) {
            guard self.documentGeneration.commitIntermediaryNavigation(
                trackedNavigation.generation
            ) else { return }
        }
        self.documentNavigations[navigation] = trackedNavigation
        if trackedNavigation.didActivatePlaybackOrigin {
            if self.cancelledPendingSeekGenerations.remove(trackedNavigation.generation) != nil {
                webView.evaluateJavaScript(
                    Self.pendingSeekCancellationScript(
                        documentGeneration: trackedNavigation.generation
                    ),
                    completionHandler: nil
                )
            } else {
                self.injectPendingSeekIfNeeded(
                    generation: trackedNavigation.generation,
                    webView: webView
                )
            }
        }
    }

    func consumeCancelledDocumentNavigation(
        _ navigation: WKNavigation?
    ) -> WebPlaybackCancelledNavigation? {
        guard let navigation else { return nil }
        return self.cancelledDocumentNavigations.removeValue(
            forKey: navigation
        )
    }

    func finishDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        if WebPlaybackDocumentGeneration.isInternalBlankNavigation(webView.url) {
            guard self.documentGeneration.ownsBlankNavigation(webView.url) else {
                self.handleUnexpectedBlankDocumentCommit(navigation, webView: webView)
                return false
            }
            return true
        }
        guard let navigation,
              let trackedNavigation = self.documentNavigations.removeValue(
                  forKey: navigation
              )
        else { return false }
        guard trackedNavigation.didCommit else {
            self.handleCurrentDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView
            )
            return false
        }
        if !trackedNavigation.didActivatePlaybackOrigin {
            return WebPlaybackDocumentGeneration.isAllowedPlaybackNavigationURL(
                webView.url,
                playbackHost: "www.youtube.com"
            ) && trackedNavigation.generation == self.documentGeneration.inFlightGeneration
        }
        guard self.documentGeneration.canFinishNavigation(
            trackedNavigation.generation
        ) else { return false }
        if trackedNavigation.pendingSeek == nil {
            self.pendingSeeksByGeneration.removeValue(forKey: trackedNavigation.generation)
            self.pendingSeekVideoIdsByGeneration.removeValue(forKey: trackedNavigation.generation)
            self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: trackedNavigation.generation)
            self.pendingSeekRetryCounts.removeValue(forKey: trackedNavigation.generation)
            self.directSeekGenerations.remove(trackedNavigation.generation)
        }
        return true
    }

    private func handleUnexpectedBlankDocumentCommit(
        _ navigation: WKNavigation?,
        webView: WKWebView
    ) {
        guard webView === self.webView else { return }
        if let navigation,
           self.documentNavigations[navigation] != nil
        {
            self.failDocumentNavigation(navigation, webView: webView)
            return
        }
        if let generation = self.documentGeneration.inFlightGeneration {
            let resumeAt = self.pendingSeeksByGeneration[generation]
            self.documentNavigations = self.documentNavigations.filter {
                $0.value.generation != generation
            }
            self.continuationGenerationsAwaitingStart.remove(generation)
            self.handleCurrentDocumentNavigationFailure(
                generation,
                webView: webView,
                resumeAtOverride: resumeAt
            )
        } else if self.documentGeneration.pendingGeneration != nil {
            self.handlePendingDocumentNavigationFailure(webView: webView)
        } else if self.currentVideoId != nil {
            self.handleCommittedDocumentNavigationFailure(
                self.documentGeneration.currentGeneration,
                webView: webView,
                resumeAtOverride: self.pendingSeek
            )
        }
    }

    private func failDocumentNavigation(_ navigation: WKNavigation?, webView: WKWebView) {
        if let navigation {
            self.cancelledDocumentNavigations.removeValue(forKey: navigation)
        }
        guard webView === self.webView,
              let navigation,
              let trackedNavigation = self.documentNavigations.removeValue(
                  forKey: navigation
              )
        else { return }
        let resumeAt = trackedNavigation.pendingSeek
        self.pendingSeeksByGeneration.removeValue(forKey: trackedNavigation.generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: trackedNavigation.generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: trackedNavigation.generation)
        self.pendingSeekRetryCounts.removeValue(forKey: trackedNavigation.generation)
        self.directSeekGenerations.remove(trackedNavigation.generation)
        if trackedNavigation.didActivatePlaybackOrigin {
            self.handleCommittedDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView,
                resumeAtOverride: resumeAt
            )
        } else {
            self.handleCurrentDocumentNavigationFailure(
                trackedNavigation.generation,
                webView: webView,
                resumeAtOverride: resumeAt
            )
        }
    }

    private func handleCurrentDocumentNavigationFailure(
        _ generation: UInt64,
        webView: WKWebView,
        resumeAtOverride: Double? = nil
    ) {
        guard self.documentGeneration.cancelInFlightNavigation(generation) else { return }
        self.pendingSeeksByGeneration.removeValue(forKey: generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
        self.pendingSeekRetryCounts.removeValue(forKey: generation)
        self.directSeekGenerations.remove(generation)
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.handleWebNavigationFailure(
            resumeAtOverride: resumeAtOverride
        )
        self.refreshDocumentUserScripts(on: webView)
    }

    func handlePendingDocumentNavigationFailure(webView: WKWebView) {
        let resumeAt = self.pendingSeek
            ?? self.documentGeneration.pendingGeneration.flatMap { self.pendingSeeksByGeneration[$0] }
        self.documentGeneration.cancelPendingNavigation()
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.cancelledPendingSeekGenerations.removeAll()
        self.directSeekGenerations.removeAll()
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.handleWebNavigationFailure(resumeAtOverride: resumeAt)
        self.refreshDocumentUserScripts(on: webView)
    }

    private func handleCommittedDocumentNavigationFailure(
        _ generation: UInt64,
        webView: WKWebView,
        resumeAtOverride: Double? = nil
    ) {
        guard self.documentGeneration.currentGeneration == generation,
              self.documentGeneration.pendingGeneration == nil,
              self.documentGeneration.inFlightGeneration == nil
        else { return }
        self.pauseSurvivingDocument(webView)
        self.currentVideoId = nil
        self.documentGeneration.invalidate()
        self.coordinator?.playerService.handleWebNavigationFailure(
            resumeAtOverride: resumeAtOverride
        )
        self.refreshDocumentUserScripts(on: webView)
    }

    func handleDocumentNavigationFailure(
        _ navigation: WKNavigation?,
        webView: WKWebView,
        error: Error
    ) {
        if WebPlaybackNavigationFailure.isRetryableCancellation(error) {
            guard let navigation,
                  let trackedNavigation = self.documentNavigations[navigation]
            else {
                if let navigation,
                   let cancelledNavigation = self.cancelledDocumentNavigations.removeValue(
                       forKey: navigation
                   )
                {
                    if cancelledNavigation.shouldReportFailure {
                        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                    }
                    return
                }
                self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
            let hasSameGenerationSuccessor = self.documentNavigations.contains { key, candidate in
                key !== navigation
                    && candidate.generation == trackedNavigation.generation
            }
            if !trackedNavigation.didActivatePlaybackOrigin,
               hasSameGenerationSuccessor
               || self.continuationGenerationsAwaitingStart.contains(trackedNavigation.generation)
            {
                self.documentNavigations.removeValue(forKey: navigation)
                self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
        }
        self.failDocumentNavigation(navigation, webView: webView)
        self.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
    }

    func pauseSurvivingDocument(_ webView: WKWebView) {
        webView.stopLoading()
        self.suppressSurvivingDocumentMedia(webView)
    }

    private func suppressSurvivingDocumentMedia(_ webView: WKWebView) {
        webView.evaluateJavaScript(
            WebPlaybackDocumentGeneration.mediaSuppressionScript,
            completionHandler: nil
        )
    }

    func beginContentProcessRecovery(webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        self.documentNavigations.removeAll()
        self.cancelledDocumentNavigations.removeAll()
        self.documentGeneration.invalidate()
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.directSeekGenerations.removeAll()
        self.pendingSeekRetryCounts.removeAll()
        self.currentVideoId = nil
        return true
    }

    func installUserScripts(
        on contentController: WKUserContentController,
        targetVolume: Double,
        documentGeneration: UInt64,
        pendingSeek: Double? = nil,
        pendingSeekVideoId: String? = nil,
        pendingSeekAttemptID: UInt64? = nil,
        isShort: Bool = false
    ) {
        contentController.removeAllUserScripts()

        let sbSettings = SettingsManager.shared
        let bootstrap = WKUserScript(
            source: Self.pageBootstrapScript(
                targetVolume: targetVolume,
                documentGeneration: documentGeneration,
                pendingSeek: pendingSeek,
                pendingSeekVideoId: pendingSeekVideoId,
                pendingSeekAttemptID: pendingSeekAttemptID,
                sponsorBlockEnabled: sbSettings.sponsorBlockEnabled,
                sponsorBlockCategories: sbSettings.sponsorBlockCategories
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(bootstrap)

        // Black from first paint — no YouTube layout flash before extraction.
        let blackout = WKUserScript(
            source: Self.blackoutScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(blackout)

        let observer = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(observer)

        let extraction = WKUserScript(
            source: Self.extractionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(extraction)

        let sponsorBlock = WKUserScript(
            source: Self.sponsorBlockScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(sponsorBlock)

        // Ad-block: json-prune + skip. MUST run at document-start so
        // JSON.parse is overridden before YouTube's JS loads ad data.
        // Skipped for Shorts: they carry no ads, and the JSON.parse override
        // adds needless overhead to the (already slow) watch-page load.
        if !isShort, SettingsManager.shared.adBlockEnabled {
            let adBlock = WKUserScript(
                source: AdBlockService.adBlockScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            contentController.addUserScript(adBlock)
        }
    }
}
