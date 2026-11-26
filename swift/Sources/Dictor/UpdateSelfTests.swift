// Самотесты проверки обновлений: манифест канала, разбор ответа и состояние
// проверки (когда показывать, когда молчать).

import Foundation

#if DEBUG
extension DictorSelfTest {
    static func testUpdate() throws {
        try testUpdateCheckParsing()
        try testUpdateCheckState()
        try testDirectUpdateManifest()
        try testUpdateDownload()
        try testUpdateHelperScript()
        try testDirectUpdateReplacement()
        try testUpdateProgressState()
    }

    private static func testDirectUpdateManifest() throws {
        let checksum = String(repeating: "a", count: 64)
        let validData = Data("{\"version\":\"9.8.7\",\"sha256\":\"\(checksum)\"}".utf8)
        try expect(
            try DictorUpdateInstaller.parseManifest(validData,
                                                           expectedVersion: "9.8.7"),
            equals: DictorUpdateManifest(version: "9.8.7", sha256: checksum),
            "direct update manifest should parse a canonical version and SHA-256"
        )

        do {
            _ = try DictorUpdateInstaller.parseManifest(validData,
                                                               expectedVersion: "9.8.8")
            throw SelfTestFailure.failed("direct update manifest should reject version disagreement")
        } catch let error as DictorUpdateInstallerError {
            try expect(error,
                       equals: .manifestVersionMismatch(expected: "9.8.8", actual: "9.8.7"),
                       "direct update manifest should describe version disagreement")
        }

        let invalidChecksum = Data(#"{"version":"9.8.7","sha256":"not-a-checksum"}"#.utf8)
        do {
            _ = try DictorUpdateInstaller.parseManifest(invalidChecksum,
                                                               expectedVersion: "9.8.7")
            throw SelfTestFailure.failed("direct update manifest should reject malformed checksums")
        } catch let error as DictorUpdateInstallerError {
            try expect(error, equals: .invalidManifest,
                       "direct update manifest should reject malformed checksums")
        }
    }

    private static func testUpdateCheckParsing() throws {
        let ok = HTTPURLResponse(url: UPDATE_MANIFEST_URL,
                                 statusCode: 200,
                                 httpVersion: nil,
                                 headerFields: nil)!
        let notFound = HTTPURLResponse(url: UPDATE_MANIFEST_URL,
                                       statusCode: 404,
                                       httpVersion: nil,
                                       headerFields: nil)!
        let releaseData = Data(
            #"{"version":"9.8.7","sha256":"deadbeef","notes":"Notes"}"#.utf8
        )

        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: ok),
            equals: .success(DictorRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "Notes",
                                           htmlURL: UPDATE_CHANNEL_PAGE.absoluteString)),
            "update parsing should decode the channel manifest"
        )
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: notFound),
            equals: .failure(.httpStatus(404)),
            "update parsing should reject non-2xx HTTP responses with the status code"
        )
        let rateLimited = HTTPURLResponse(url: UPDATE_MANIFEST_URL,
                                          statusCode: 403,
                                          httpVersion: nil,
                                          headerFields: nil)!
        try expect(
            UpdateCheck.parseLatest(data: releaseData, response: rateLimited),
            equals: .failure(.httpStatus(403)),
            "update parsing should surface HTTP 403 distinctly"
        )
        let oversizedReleaseData = Data(
            """
            {"version":"9.8.7","notes":"\(String(repeating: "x", count: UpdateCheck.maxReleaseResponseBytes))"}
            """.utf8
        )
        try expect(
            oversizedReleaseData.count > UpdateCheck.maxReleaseResponseBytes,
            equals: true,
            "oversized release response fixture should exceed the parser limit"
        )
        try expect(
            UpdateCheck.parseLatest(data: oversizedReleaseData, response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized release responses before decoding"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"version":""}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject empty release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"version":"latest"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-version release tags"
        )
        try expect(
            UpdateCheck.parseLatest(data: Data(#"{"version":"v01.2.3"}"#.utf8), response: ok),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject non-normal semver tags"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"version":"v999999999999999999999999.2.3"}"#.utf8),
                response: ok
            ),
            equals: .failure(.unexpectedResponse),
            "update parsing should reject oversized numeric version parts"
        )
        try expect(
            parseSemver("999999999999999999999999.2.3"),
            equals: [Int.max, 2, 3],
            "tolerant version parsing should not overflow on oversized components"
        )
        try expect(
            normalizedSkippedUpdateVersions([
                "junk",
                "v1.2.3",
                "1.2.3",
                " V2.0.0\n",
                "01.2.3",
                "3.999999999999999999999999.0"
            ]),
            equals: ["1.2.3", "2.0.0"],
            "skipped update versions should normalize valid versions and discard malformed entries"
        )
        try expect(
            normalizedSkippedUpdateVersions((0..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" }),
            equals: (3..<(MAX_SKIPPED_UPDATE_VERSIONS + 3)).map { "1.0.\($0)" },
            "skipped update versions should keep only the most recent bounded entries"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"version":"v9.8.7"}"#.utf8),
                response: ok
            ),
            equals: .success(DictorRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: UPDATE_CHANNEL_PAGE.absoluteString)),
            "update parsing should accept a v-prefixed version and empty notes"
        )
        try expect(
            UpdateCheck.parseLatest(
                data: Data(#"{"version":"9.8.7","sha256":"deadbeef","channel":"stable"}"#.utf8),
                response: ok
            ),
            equals: .success(DictorRelease(tagName: "v9.8.7",
                                           version: "9.8.7",
                                           body: "",
                                           htmlURL: UPDATE_CHANNEL_PAGE.absoluteString)),
            "update parsing should ignore unknown manifest fields"
        )
        // Manual-check alert copy: each failure kind gets its own
        // explanation instead of blaming the network for everything.
        try expect(
            manualUpdateCheckFailureText(.network).contains("internet connection"),
            equals: true,
            "network failure text should point at connectivity"
        )
        // Про «rate limiting» здесь больше нет речи: это была особенность
        // GitHub API, а канал теперь свой.
        try expect(
            manualUpdateCheckFailureText(.httpStatus(403)).contains("HTTP 403"),
            equals: true,
            "HTTP 403 failure text should include the status code"
        )
        try expect(
            manualUpdateCheckFailureText(.httpStatus(500)).contains("HTTP 500"),
            equals: true,
            "HTTP failure text should include the status code"
        )
        try expect(
            manualUpdateCheckFailureText(.unexpectedResponse).contains("couldn't read"),
            equals: true,
            "unexpected-response failure text should describe an unreadable response"
        )
        try expect(
            UpdateCheck.normalizedReleaseVersion(from: " V1.2.3\n"),
            equals: "1.2.3",
            "release version normalization should allow one leading v"
        )
        try expect(
            normalizedStoredAppVersion(" v2.3.4\n"),
            equals: "2.3.4",
            "stored app version normalization should canonicalize release-style versions"
        )
        try expect(
            normalizedStoredAppVersion("2.3"),
            equals: nil,
            "stored app version normalization should reject incomplete versions"
        )
        try expect(
            normalizedStoredAppVersion("v999999999999999999999999.2.3"),
            equals: nil,
            "stored app version normalization should reject oversized numeric components"
        )
        // Манифест лежит на нашем сервере, но это всё равно внешний ввод.
        // Настоящая защита не в санитайзере ссылок (его больше нет — продакшн
        // его и не вызывал), а в том, что ссылка «что нового» вообще не
        // читается из манифеста: какие бы поля там ни лежали, htmlURL — это
        // страница канала, зашитая в приложение.
        let hostileManifest = Data(
            #"{"version":"9.9.9","notes":"x","url":"https://evil.example/pwn","page":"https://evil.example/pwn"}"#
                .utf8)
        guard let hostileOK = HTTPURLResponse(url: UPDATE_MANIFEST_URL,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil) else {
            throw SelfTestFailure.failed("could not build a stub HTTP response")
        }
        try expect(
            (try? UpdateCheck.parseLatest(data: hostileManifest, response: hostileOK).get())?.htmlURL,
            equals: UPDATE_CHANNEL_PAGE.absoluteString,
            "the what's-new link must come from the app, not from the manifest"
        )
    }

    private static func testUpdateCheckState() throws {
        let release = DictorRelease(tagName: "v1.2.4",
                                    version: "1.2.4",
                                    body: "",
                                    htmlURL: UPDATE_CHANNEL_PAGE.absoluteString)
        try expect(
            updateCheckResult(for: nil, currentVersion: "1.2.3", skippedVersions: []),
            equals: .failed,
            "nil update checks should be recorded as failed or unavailable"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.4", skippedVersions: []),
            equals: .upToDate,
            "equal release versions should be recorded as up to date"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: []),
            equals: .available,
            "newer releases should be recorded as available"
        )
        try expect(
            updateCheckResult(for: release, currentVersion: "1.2.3", skippedVersions: ["1.2.4"]),
            equals: .skipped,
            "skipped newer releases should be recorded distinctly"
        )

        let now = Date(timeIntervalSince1970: 1_000)
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: true,
            "active reminders should suppress the matching update version"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.5",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(60),
                                            now: now),
            equals: false,
            "reminders should not suppress newer versions"
        )
        try expect(
            shouldSuppressUpdateForReminder(version: "1.2.4",
                                            reminderVersion: "1.2.4",
                                            reminderUntil: now.addingTimeInterval(-1),
                                            now: now),
            equals: false,
            "expired reminders should not suppress updates"
        )
        try expect(
            updateCheckDiagnosticText(checkedAt: nil,
                                      source: nil,
                                      result: nil,
                                      releaseVersion: ""),
            equals: "never",
            "missing update-check metadata should render as never"
        )

        // Stale-pause clearing: equal version (expired pause about to
        // be re-shown) and a newer superseding release both clear; an
        // older fetched version or no pause leaves things alone.
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: "1.2.4"),
            equals: true,
            "a fetched release matching the paused version should clear the pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.5", pausedVersion: "1.2.4"),
            equals: true,
            "a newer fetched release should clear a stale pause for the superseded version"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.3", pausedVersion: "1.2.4"),
            equals: false,
            "an older fetched release should keep the existing pause"
        )
        try expect(
            shouldClearUpdateReminderPause(fetchedVersion: "1.2.4", pausedVersion: nil),
            equals: false,
            "no pause means nothing to clear"
        )

        // Persisted pause expiry validation, mirroring the
        // lastUpdateCheck* pattern: corrupt → nil, in-range round-trip,
        // cleared/missing → nil.
        let pauseNow = Date(timeIntervalSince1970: 2_000)
        let validPauseUntil = pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS)
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: validPauseUntil, now: pauseNow),
            equals: validPauseUntil,
            "a stored pause expiry inside the pause window should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: pauseNow.addingTimeInterval(-60), now: pauseNow),
            equals: pauseNow.addingTimeInterval(-60),
            "an already-expired stored pause expiry is legitimate state and should round-trip"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: "not a date", now: pauseNow),
            equals: nil,
            "a corrupt (non-Date) stored pause expiry should degrade to nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(storedValue: nil, now: pauseNow),
            equals: nil,
            "a cleared pause expiry should read back as nil"
        )
        try expect(
            normalizedUpdateReminderPauseExpiry(
                storedValue: pauseNow.addingTimeInterval(UPDATE_REMIND_LATER_SECONDS + 60),
                now: pauseNow
            ),
            equals: nil,
            "an out-of-range future pause expiry should degrade to nil instead of suppressing indefinitely"
        )
        // The paused-version half persists through the same validated
        // app-version normalization tested in testUpdateCheckParsing
        // (normalizedStoredAppVersion: corrupt → nil, round-trip).

        try expect(
            UpdateCheckSource(rawValue: "settings_toggle"),
            equals: .settingsToggle,
            "settings-toggle update checks should round-trip through their persisted raw value"
        )
        try expect(
            UpdateCheckSource.settingsToggle.diagnosticLabel,
            equals: "settings toggle",
            "settings-toggle update checks should label themselves distinctly in diagnostics"
        )
    }
}
#endif
