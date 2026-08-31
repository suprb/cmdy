import XCTest
@testable import CmdyKit

final class AppUpdateTests: XCTestCase {
    func testNewVersionDiscoveryNotifiesExactlyOncePerVersion() {
        XCTAssertTrue(AppUpdateMonitor.shouldNotifyAvailableVersion(
            "1.4.0", previouslyNotified: nil))
        XCTAssertTrue(AppUpdateMonitor.shouldNotifyAvailableVersion(
            "1.4.0", previouslyNotified: "1.3.0"))
        XCTAssertFalse(AppUpdateMonitor.shouldNotifyAvailableVersion(
            "1.4.0", previouslyNotified: "1.4.0"))
    }

    func testApplyPersistsAndPostsAvailabilityExactlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-update-notification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var notifications: [(title: String, body: String)] = []
        Notifier.postObserverForTesting = { title, body in
            notifications.append((title, body))
        }
        defer { Notifier.postObserverForTesting = nil }

        let stateURL = directory.appendingPathComponent("app-update-state.json")
        let release = AppReleaseUpdate(
            version: "1.4.0",
            name: "cmdy 1.4",
            releaseURL: URL(
                string: "https://github.com/suprb/cmdy/releases/tag/v1.4.0")!,
            assetURL: nil,
            assetName: nil,
            checksumURL: nil,
            notes: "")

        let firstMonitor = AppUpdateMonitor(stateURL: stateURL)
        firstMonitor.apply(release, currentVersion: "1.3.0")
        firstMonitor.apply(release, currentVersion: "1.3.0")
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.title, "New cmdy update available")

        // A fresh monitor proves the suppression lives in the persisted file,
        // not merely in the first instance's `availableUpdate` property.
        let relaunchedMonitor = AppUpdateMonitor(stateURL: stateURL)
        relaunchedMonitor.apply(release, currentVersion: "1.3.0")
        XCTAssertEqual(notifications.count, 1)

        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)) as? [String: Any]
        XCTAssertEqual(persisted?["notifiedAvailableVersion"] as? String, "1.4.0")

        let nextRelease = AppReleaseUpdate(
            version: "1.5.0",
            name: "cmdy 1.5",
            releaseURL: URL(
                string: "https://github.com/suprb/cmdy/releases/tag/v1.5.0")!,
            assetURL: nil,
            assetName: nil,
            checksumURL: nil,
            notes: "")
        relaunchedMonitor.apply(nextRelease, currentVersion: "1.3.0")
        XCTAssertEqual(notifications.count, 2)
    }

    func testDiscoveryNotificationExplainsAutomaticDownload() {
        let release = AppReleaseUpdate(
            version: "1.4.0",
            name: "cmdy 1.4",
            releaseURL: URL(string: "https://github.com/suprb/cmdy/releases/tag/v1.4.0")!,
            assetURL: URL(string: "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy.zip")!,
            assetName: "cmdy-1.4.0-macOS-arm64.zip",
            checksumURL: URL(string: "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy.zip.sha256")!,
            notes: "")

        XCTAssertEqual(
            AppUpdateMonitor.availabilityNotificationBody(for: release),
            "Version 1.4.0 is downloading and being verified. "
                + "Open Check for Updates for details.")
        XCTAssertEqual(
            AppUpdateMonitor.availabilityNotificationTitle,
            "New cmdy update available")
    }

    func testNumericVersionsOnlyReportNewerStableBuilds() {
        XCTAssertTrue(AppUpdateMonitor.isVersion("1.10.0", newerThan: "1.9.9"))
        XCTAssertTrue(AppUpdateMonitor.isVersion("2.0", newerThan: "1.99.99"))
        XCTAssertFalse(AppUpdateMonitor.isVersion("1.2.0", newerThan: "1.2"))
        XCTAssertFalse(AppUpdateMonitor.isVersion("1.1.9", newerThan: "1.2.0"))
        XCTAssertFalse(AppUpdateMonitor.isVersion("nightly", newerThan: "1.2.0"))
    }

    func testLatestReleaseSelectsTheNotarizedMacOSArchive() throws {
        let data = Data(#"""
        {
          "tag_name": "v1.4.0",
          "name": "cmdy 1.4",
          "html_url": "https://github.com/suprb/cmdy/releases/tag/v1.4.0",
          "body": "A focused release.",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "cmdy-1.4.0-browser-2.1.0-macOS-arm64.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-browser.zip"
            },
            {
              "name": "cmdy-1.4.0-browser-2.1.0-macOS-arm64.zip.sha256",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-browser.zip.sha256"
            },
            {
              "name": "cmdy-1.4.0-macOS-arm64.zip.sha256",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-1.4.0-macOS-arm64.zip.sha256"
            },
            {
              "name": "cmdy-1.4.0-macOS-arm64.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy.zip"
            }
          ]
        }
        """#.utf8)

        let release = try XCTUnwrap(AppUpdateMonitor.decodeRelease(data))
        XCTAssertEqual(release.version, "1.4.0")
        XCTAssertEqual(release.name, "cmdy 1.4")
        XCTAssertEqual(release.notes, "A focused release.")
        XCTAssertEqual(release.downloadURL.lastPathComponent, "cmdy.zip")
        XCTAssertEqual(release.assetName, "cmdy-1.4.0-macOS-arm64.zip")
        XCTAssertEqual(
            release.checksumURL?.lastPathComponent,
            "cmdy-1.4.0-macOS-arm64.zip.sha256")
        XCTAssertTrue(release.canDownloadAutomatically)
    }

    func testLatestReleasePreservesTheInstalledBrowserEdition() throws {
        let data = Data(#"""
        {
          "tag_name": "v1.4.0",
          "name": "cmdy 1.4",
          "html_url": "https://github.com/suprb/cmdy/releases/tag/v1.4.0",
          "body": "Both editions.",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "cmdy-1.4.0-macOS-arm64.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy.zip"
            },
            {
              "name": "cmdy-1.4.0-macOS-arm64.zip.sha256",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy.zip.sha256"
            },
            {
              "name": "cmdy-1.4.0-browser-2.1.0-macOS-arm64.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-browser.zip"
            },
            {
              "name": "cmdy-1.4.0-browser-2.1.0-macOS-arm64.zip.sha256",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-browser.zip.sha256"
            }
          ]
        }
        """#.utf8)

        let browser = try XCTUnwrap(AppUpdateMonitor.decodeRelease(
            data, prefersBrowserEdition: true))
        XCTAssertEqual(
            browser.assetName,
            "cmdy-1.4.0-browser-2.1.0-macOS-arm64.zip")
        XCTAssertEqual(
            browser.checksumURL?.lastPathComponent,
            "cmdy-browser.zip.sha256")
        XCTAssertTrue(browser.canDownloadAutomatically)

        let lean = try XCTUnwrap(AppUpdateMonitor.decodeRelease(
            data, prefersBrowserEdition: false))
        XCTAssertEqual(lean.assetName, "cmdy-1.4.0-macOS-arm64.zip")
    }

    func testBrowserEditionNeverFallsBackToLeanArchive() throws {
        let data = Data(#"""
        {
          "tag_name": "v1.4.0",
          "name": "cmdy 1.4",
          "html_url": "https://github.com/suprb/cmdy/releases/tag/v1.4.0",
          "body": "Lean only.",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "cmdy-1.4.0-macOS-arm64.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy.zip"
            }
          ]
        }
        """#.utf8)

        let release = try XCTUnwrap(AppUpdateMonitor.decodeRelease(
            data, prefersBrowserEdition: true))
        XCTAssertNil(release.assetURL)
        XCTAssertFalse(release.canDownloadAutomatically)
    }

    func testRehearsalArchivesAreNeverSelectedForAutomaticUpdates() throws {
        let data = Data(#"""
        {
          "tag_name": "v1.4.0",
          "name": "cmdy 1.4",
          "html_url": "https://github.com/suprb/cmdy/releases/tag/v1.4.0",
          "body": "Rehearsal files must be ignored.",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "cmdy-1.4.0-macOS-arm64-rehearsal.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-rehearsal.zip"
            },
            {
              "name": "cmdy-1.4.0-browser-2.1.0-macOS-arm64-rehearsal.zip",
              "browser_download_url": "https://github.com/suprb/cmdy/releases/download/v1.4.0/cmdy-browser-rehearsal.zip"
            }
          ]
        }
        """#.utf8)

        let lean = try XCTUnwrap(AppUpdateMonitor.decodeRelease(data))
        XCTAssertNil(lean.assetURL)
        XCTAssertFalse(lean.canDownloadAutomatically)

        let browser = try XCTUnwrap(AppUpdateMonitor.decodeRelease(
            data, prefersBrowserEdition: true))
        XCTAssertNil(browser.assetURL)
        XCTAssertFalse(browser.canDownloadAutomatically)
    }

    func testReleaseArchiveNamesAreExact() {
        XCTAssertTrue(AppUpdateMonitor.isReleaseArchiveName(
            "cmdy-1.4.0-macOS-arm64.zip",
            version: "1.4.0",
            browserEdition: false))
        XCTAssertTrue(AppUpdateMonitor.isReleaseArchiveName(
            "cmdy-1.4.0-browser-2.1.0-macOS-arm64.zip",
            version: "1.4.0",
            browserEdition: true))
        XCTAssertFalse(AppUpdateMonitor.isReleaseArchiveName(
            "cmdy-1.4.0-macOS-arm64-rehearsal.zip",
            version: "1.4.0",
            browserEdition: false))
        XCTAssertFalse(AppUpdateMonitor.isReleaseArchiveName(
            "cmdy-1.4.0-extra-macOS-arm64.zip",
            version: "1.4.0",
            browserEdition: false))
        XCTAssertFalse(AppUpdateMonitor.isReleaseArchiveName(
            "cmdy-1.4.0-browser-2.1-macOS-arm64.zip",
            version: "1.4.0",
            browserEdition: true))
        XCTAssertFalse(AppUpdateMonitor.isReleaseArchiveName(
            "cmdy-9.9.9-macOS-arm64.zip",
            version: "1.4.0",
            browserEdition: false))
    }

    func testDraftsAndPrereleasesNeverBecomeUpdates() throws {
        for field in ["draft", "prerelease"] {
            let data = Data("""
            {
              "tag_name": "v9.0.0",
              "name": "Unstable",
              "html_url": "https://github.com/suprb/cmdy/releases/tag/v9.0.0",
              "body": "",
              "draft": \(field == "draft" ? "true" : "false"),
              "prerelease": \(field == "prerelease" ? "true" : "false"),
              "assets": []
            }
            """.utf8)
            XCTAssertNil(try AppUpdateMonitor.decodeRelease(data))
        }
    }

    func testChecksumMustMatchTheSelectedArchiveName() {
        let digest = String(repeating: "a", count: 64)
        let valid = Data("\(digest)  dist/cmdy-1.4.0-macOS-arm64.zip\n".utf8)
        XCTAssertEqual(
            AppUpdateMonitor.expectedChecksum(
                from: valid, assetName: "cmdy-1.4.0-macOS-arm64.zip"),
            digest)

        let wrong = Data("\(digest)  dist/another-product.zip\n".utf8)
        XCTAssertNil(AppUpdateMonitor.expectedChecksum(
            from: wrong, assetName: "cmdy-1.4.0-macOS-arm64.zip"))
    }

    func testUnsafeAssetNamesAreRejected() {
        XCTAssertTrue(AppUpdateMonitor.safeAssetName("cmdy-1.4.0-macOS-arm64.zip"))
        XCTAssertFalse(AppUpdateMonitor.safeAssetName("../cmdy.zip"))
        XCTAssertFalse(AppUpdateMonitor.safeAssetName("nested/cmdy.zip"))
        XCTAssertFalse(AppUpdateMonitor.safeAssetName(""))
    }

    func testSHA256StreamsTheDownloadedArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdy-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("archive.zip")
        try Data("cmdy update".utf8).write(to: file)
        XCTAssertEqual(
            try AppUpdateMonitor.sha256(of: file),
            "87bde56208538e6711e8537ff50e3b5c054294ad4f204a72da124aa9d4486598")
    }

    func testReleaseAssetsMustComeFromTheConfiguredGitHubRepository() throws {
        let data = Data(#"""
        {
          "tag_name": "v1.4.0",
          "name": "cmdy 1.4",
          "html_url": "https://github.com/suprb/cmdy/releases/tag/v1.4.0",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "cmdy-1.4.0-macOS-arm64.zip",
              "browser_download_url": "https://example.com/cmdy.zip"
            }
          ]
        }
        """#.utf8)

        let release = try XCTUnwrap(AppUpdateMonitor.decodeRelease(data))
        XCTAssertNil(release.assetURL)
        XCTAssertFalse(release.canDownloadAutomatically)
    }
}
