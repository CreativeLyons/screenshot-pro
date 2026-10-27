import ScreenshotProCore
import XCTest
@testable import ScreenshotProOutput

final class UniqueURLTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotProOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func url(_ pattern: String, format: ImageFormat = .png, avoidOverwrite: Bool = true,
                     counter: Int = 1) -> URL {
        FilenamePattern.uniqueURL(folder: folder, pattern: pattern, details: Fixture.details(), format: format,
                                  avoidOverwrite: avoidOverwrite, counter: counter,
                                  environment: Fixture.environment())
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    func testFreeNameIsUsedAsIs() {
        let u = url("Screenshot ${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss}")
        XCTAssertEqual(u.lastPathComponent, "Screenshot 2026-10-25 10.11.12.png")
        XCTAssertEqual(u.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
    }

    func testExtensionFollowsFormat() {
        XCTAssertEqual(url("shot", format: .jpg).lastPathComponent, "shot.jpg")
        XCTAssertEqual(url("shot", format: .heic).lastPathComponent, "shot.heic")
        XCTAssertEqual(url("shot", format: .tiff).lastPathComponent, "shot.tiff")
        XCTAssertEqual(url("shot", format: .pdf).lastPathComponent, "shot.pdf")
    }

    func testDotsInNameDoNotConfuseTheExtension() {
        XCTAssertEqual(url("Screenshot 10.11.12").lastPathComponent, "Screenshot 10.11.12.png")
    }

    func testCollisionsAppendNumbers() throws {
        let first = url("shot")
        XCTAssertEqual(first.lastPathComponent, "shot.png")
        try touch(first)
        let second = url("shot")
        XCTAssertEqual(second.lastPathComponent, "shot (2).png")
        try touch(second)
        XCTAssertEqual(url("shot").lastPathComponent, "shot (3).png")
    }

    func testGapsAreFilledFromTwo() throws {
        try touch(folder.appendingPathComponent("shot.png"))
        try touch(folder.appendingPathComponent("shot (3).png"))
        XCTAssertEqual(url("shot").lastPathComponent, "shot (2).png")
    }

    func testOtherExtensionsDoNotCollide() throws {
        try touch(folder.appendingPathComponent("shot.jpg"))
        XCTAssertEqual(url("shot").lastPathComponent, "shot.png")
    }

    func testDirectoryWithSameNameCollides() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("shot.png"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(url("shot").lastPathComponent, "shot (2).png")
    }

    func testOverwriteAllowedReturnsExistingName() throws {
        try touch(folder.appendingPathComponent("shot.png"))
        XCTAssertEqual(url("shot", avoidOverwrite: false).lastPathComponent, "shot.png")
    }

    func testSubfoldersFromPattern() throws {
        let u = url("${YYYY}/${MM}/shot")
        XCTAssertEqual(u.path, folder.appendingPathComponent("2026/10/shot.png").path)
        try touch(u)
        XCTAssertEqual(url("${YYYY}/${MM}/shot").path, folder.appendingPathComponent("2026/10/shot (2).png").path)
    }

    func testCounterIsExpanded() {
        XCTAssertEqual(url("shot ${NUM}", counter: 12).lastPathComponent, "shot 000012.png")
    }

    func testContractOverloadUsesCounterOne() {
        let u = FilenamePattern.uniqueURL(folder: folder, pattern: "n${NUM}", details: Fixture.details(),
                                          format: .png, avoidOverwrite: true)
        XCTAssertEqual(u.lastPathComponent, "n000001.png")
    }

    func testAvailableURLWithoutExtension() throws {
        let plain = folder.appendingPathComponent("README")
        try touch(plain)
        XCTAssertEqual(FilenamePattern.availableURL(for: plain).lastPathComponent, "README (2)")
    }

    // MARK: Temporary files

    func testTemporaryFolderIsNamedAfterTheApp() {
        XCTAssertEqual(TemporaryFiles.directory.lastPathComponent, "Screenshot Pro")
        XCTAssertEqual(TemporaryFiles.directory.deletingLastPathComponent().standardizedFileURL,
                       FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    func testTemporaryURLIsSafeAndUnique() throws {
        let a = try TemporaryFiles.makeURL(name: "a/b: c", fileExtension: "png", in: folder)
        XCTAssertEqual(a.lastPathComponent, "a_b_ c.png")
        try touch(a)
        XCTAssertEqual(try TemporaryFiles.makeURL(name: "a/b: c", fileExtension: "png", in: folder).lastPathComponent,
                       "a_b_ c (2).png")
    }

    func testPurgeRemovesOnlyStaleFiles() throws {
        let old = folder.appendingPathComponent("old.png")
        let fresh = folder.appendingPathComponent("fresh.png")
        try touch(old)
        try touch(fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)],
                                              ofItemAtPath: old.path)
        XCTAssertEqual(TemporaryFiles.purgeStale(olderThan: 86_400, in: folder), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
