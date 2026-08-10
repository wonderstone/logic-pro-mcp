import Foundation
import XCTest
@testable import LogicProMCP

final class AXDocumentIdentityTests: XCTestCase {
    func testAXDocumentResolvesEncodedExistingLogicxAndBindsDigest() throws {
        let package = try makeLogicPackage(name: "WCH-Main Theme__P5A-ACE-20260810.logicx")
        defer { try? FileManager.default.removeItem(at: package) }

        let document = URL(fileURLWithPath: package.path).absoluteString + "/"
        let title = "WCH-Main Theme__P5A-ACE-20260810.logicx - WCH-Main Theme__P5A-ACE-20260810 - Tracks"
        let resolved = try XCTUnwrap(
            AXDocumentProjectResolver.resolve(document: document, windowTitle: title)
        )

        XCTAssertTrue(document.contains("%20"))
        XCTAssertEqual(resolved.path, package.standardizedFileURL.path)
        XCTAssertEqual(resolved.digest, try ACEFileDigest.sha256(at: package.path))
        XCTAssertEqual(resolved.projectIdentity.source, "ax_document")
        XCTAssertEqual(resolved.projectIdentity.stability, .stable)
        XCTAssertEqual(resolved.projectIdentity.value, resolved.path)
        XCTAssertEqual(resolved.projectIdentity.digest, resolved.digest)
    }

    func testAXDocumentRejectsMissingMalformedNonFileAndNonLogicxPaths() throws {
        let package = try makeLogicPackage(name: "valid.logicx")
        defer { try? FileManager.default.removeItem(at: package) }
        let digestFailurePackage = try makeLogicPackage(name: "digest-failure.logicx")
        defer { try? FileManager.default.removeItem(at: digestFailurePackage) }
        try FileManager.default.createSymbolicLink(
            at: digestFailurePackage.appendingPathComponent("unsupported-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp/AXDocumentIdentity-missing-target")
        )

        XCTAssertNil(AXDocumentProjectResolver.resolve(document: nil))
        XCTAssertNil(AXDocumentProjectResolver.resolve(document: "file:///tmp/%ZZ.logicx"))
        XCTAssertNil(AXDocumentProjectResolver.resolve(document: "https://example.com/project.logicx"))
        XCTAssertNil(AXDocumentProjectResolver.resolve(document: "file:///tmp/not-a-project.txt"))
        XCTAssertNil(AXDocumentProjectResolver.resolve(document: "file:///tmp/missing.logicx"))
        XCTAssertNil(
            AXDocumentProjectResolver.resolve(
                document: URL(fileURLWithPath: digestFailurePackage.path).absoluteString
            )
        )
    }

    func testAXDocumentRejectsTitlePathMismatchAndAmbiguousCandidates() throws {
        let package = try makeLogicPackage(name: "Current.logicx")
        defer { try? FileManager.default.removeItem(at: package) }

        let document = URL(fileURLWithPath: package.path).absoluteString
        XCTAssertNil(
            AXDocumentProjectResolver.resolve(document: document, windowTitle: "Different.logicx - Different - Tracks")
        )
        XCTAssertNil(
            AXDocumentProjectResolver.resolve(documentCandidates: [document, document])
        )
        XCTAssertNotNil(
            AXDocumentProjectResolver.resolve(documentCandidates: [nil, document])
        )
    }

    func testProjectDigestParticipatesInIdentityAndCacheGeneration() async throws {
        let package = try makeLogicPackage(name: "generation.logicx")
        defer { try? FileManager.default.removeItem(at: package) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "b", count: 64)
        let firstIdentity = ProjectIdentity.stable(
            path: package.path,
            source: "ax_document",
            digest: firstDigest
        )
        let secondIdentity = ProjectIdentity.stable(
            path: package.path,
            source: "ax_document",
            digest: secondDigest
        )
        XCTAssertFalse(firstIdentity.matches(secondIdentity))

        let cache = StateCache()
        var firstProject = ProjectInfo(name: "generation", filePath: package.path, lastUpdated: now)
        firstProject.projectIdentity = firstIdentity
        await cache.updateProject(firstProject)
        let firstGeneration = await cache.getGeneration()
        await cache.updateTracks([TrackState(id: 0, name: "Visible", type: .audio)])
        let tracksAfterFirst = await cache.getTracks()
        let boundTrack = try XCTUnwrap(tracksAfterFirst.first)
        XCTAssertEqual(boundTrack.projectIdentity, firstIdentity)
        XCTAssertEqual(boundTrack.generation, firstGeneration)

        var secondProject = ProjectInfo(
            name: "generation",
            filePath: package.path,
            lastUpdated: now.addingTimeInterval(1)
        )
        secondProject.projectIdentity = secondIdentity
        await cache.updateProject(secondProject)

        let secondGeneration = await cache.getGeneration()
        let currentIdentity = await cache.getProjectIdentity()
        let tracksAfterSecond = await cache.getTracks()
        XCTAssertEqual(secondGeneration, firstGeneration + 1)
        XCTAssertEqual(currentIdentity, secondIdentity)
        XCTAssertTrue(tracksAfterSecond.isEmpty)
    }

    func testInstalledLogicIdentityUsesLogicProXProcessWithStableBundleID() {
        XCTAssertEqual(ServerConfig.logicProBundleID, "com.apple.logic10")
        XCTAssertEqual(ServerConfig.logicProProcessName, "Logic Pro X")
    }

    private func makeLogicPackage(name: String) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXDocumentIdentity-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("AXDocument test package".utf8)
            .write(to: package.appendingPathComponent("ProjectInformation.plist"), options: .atomic)
        return package
    }
}
