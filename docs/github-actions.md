# GitHub Actions & CI/CD Guide

Lessons and guardrails for keeping KasetPlusPlus workflows green across `lint.yml`, `tests.yml`, `dev-build.yml`, `api-explorer.yml`, `automerge.yml`, and `release.yml`.

## 1. Lint & Format (`lint.yml`)

- **Always run both tools locally before pushing:**
  ```bash
  swiftformat --lint .
  swiftlint lint --strict --quiet
  ```
- **`--strict` promotes every SwiftLint warning to an error.** Pay special attention to:
  - `file_length` (warning at 900, error at 1500), `type_body_length` (700/1000), `function_body_length` (100/150), and `cyclomatic_complexity` (15/25).
  - `superfluous_disable_command` — remove `swiftlint:disable` comments if you refactor a file/function below the threshold.
  - `inclusive_language` — avoid `master` in new identifiers (use `multivariant` for HLS playlists).
  - `legacy_swiftui_aspect_ratio`, `multiple_closures_with_trailing_closure`, `large_tuple` (max 2 members), `function_parameter_count` (max 5), and `no_foreground_color`.
  - `// MARK: - TypeName` is enforced by SwiftFormat (`markTypes`) before top-level types and extensions.
- **Check source-reading tests after splitting files:** Tests such as [YouTubeNavigationScriptOwnershipTests.swift](../Tests/KasetTests/YouTubeNavigationScriptOwnershipTests.swift) read `.swift` source files by path. If you extract methods into `+Extension.swift` files, update any corresponding source-path tests.
- **Homebrew on arm64 CI runners (`macos-26`):** Cache `~/Library/Caches/Homebrew` (not `/usr/local/Homebrew`), set `HOMEBREW_NO_AUTO_UPDATE=1`, and guard `brew install` with `command -v <tool> >/dev/null 2>&1 || brew install <tool>`.

## 2. Swift Toolchain & Runtime Compatibility (`tests.yml`, `release.yml`)

- **Avoid `isolated deinit` on `@MainActor` `NSObject` subclasses:**
  - `isolated deinit` on `@MainActor` Objective-C / `NSObject` subclasses (such as `WebKitManager` or `WKHTTPCookieStoreObserver` / `WKScriptMessageHandler` classes) can trap at runtime with **`SIGTRAP` (`signal 5`)** on Xcode 26.6 (`macos-15` and `macos-26` CI runners), even when it passes on newer local macOS/Swift toolchains.
  - Use a weak proxy object (e.g., `WeakCookieStoreObserver`, `WeakScriptMessageHandler`) plus explicit `tearDown()` cleanup instead.
- **Never hardcode Xcode bundle paths in workflows:**
  - Use [Scripts/select-xcode.sh](../Scripts/select-xcode.sh) to dynamically select the newest installed Xcode 26+ toolchain, because GitHub-hosted runner images rotate minor versions.
- **SPM caching:**
  - Cache only `~/Library/Caches/org.swift.swiftpm/spm-repositories` (never `.build` across Xcode updates) and run `rm -rf ~/Library/Caches/org.swift.swiftpm/artifacts` before building/testing.

## 3. Unit Tests & Localization Parity (`tests.yml`, `release.yml`)

- **Run the exact CI unit test command locally before pushing:**
  ```bash
  swift test -q --no-parallel --skip KasetUITests --disable-xctest
  ```
  - `--no-parallel` is required because suites share process-wide singletons and `UserDefaults.standard`.
  - `--disable-xctest` avoids `swiftpm-xctest-helper` crashes on macOS 15 + Xcode 26 during XCTest discovery.
- **Avoid tight `Task.sleep` polling windows:** GitHub-hosted macOS VMs can stall briefly under load; use generous timeouts (e.g., `>= 2–3s` total polling budget) rather than `500ms` caps.
- **Localization parity:**
  - `Sources/Kaset/Resources/Localizable.xcstrings` is the source of truth, and all 16 `*.lproj/Localizable.strings` files must stay in sync.
  - Run `python3 Scripts/sync-lproj.py` after editing `Localizable.xcstrings`, and verify both `LocalizationCatalogParityTests` and `AppLocalizationTests` pass (preserving the empty-string `"" = "";` key).
- **UI tests (`macos_ui_tests`):** Do not run `KasetUITests` locally without explicit user permission. Note that on headless CI runners, `CODE_SIGNING_ALLOWED=NO` and missing TCC Accessibility permissions can cause `xcodebuild test` to exit with code `65`.

## 4. Release & Automation Workflows (`release.yml`, `automerge.yml`)

- **Tagging & manual dispatch (`release.yml`):**
  - Releases trigger on `v*` tags (`git tag -a vX.Y.Z ...`). When using `workflow_dispatch`, always require an explicit `tag` input rather than falling back to `github.ref_name` (`main`).
  - Guard `git log` changelog generation in case the tag does not yet exist locally.
- **Sparkle & Homebrew Cask (`release.yml`):**
  - Locate Sparkle's signing binary via `*/Sparkle/bin/sign_update` (do not match `old_dsa_scripts/sign_update`).
  - Preserve existing `<item>` entries when updating `appcast.xml`, and keep Cask metadata aligned with `KasetPlusPlus` / `KasetPlusPlus.app`.
- **Dependabot automerge (`automerge.yml`):**
  - Use `pull_request_target` (not `pull_request`) so `GITHUB_TOKEN` has write permission on Dependabot PRs.
- **External tool downloads (`Scripts/build-app.sh`):**
  - Fetch `yt-dlp` with `curl -fsSL --retry 3 --retry-delay 2` to a temporary file and atomically move it into place.
