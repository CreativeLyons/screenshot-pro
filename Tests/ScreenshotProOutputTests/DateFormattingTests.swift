import XCTest
@testable import ScreenshotProOutput

final class DateFormattingTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    private func format(_ dotNet: String?, timeZone: TimeZone = Fixture.utc) -> String {
        DateFormatting.format(Fixture.date, dotNetFormat: dotNet, timeZone: timeZone, locale: posix)
    }

    func testDefaultFormat() {
        XCTAssertEqual(format(nil), "2026-10-25 10-11-12")
        XCTAssertEqual(format(""), "2026-10-25 10-11-12")
    }

    func testPatternTranslation() {
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "yyyy-MM-dd HH_mm_ss"), "yyyy-MM-dd HH_mm_ss")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "ddd dddd"), "EEE EEEE")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "hh:mm tt"), "hh:mm a")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "fff"), "SSS")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "zzz K"), "xxx xxx")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "'at' HH"), "'at' HH")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "\"Q\"yyyy"), "'Q'yyyy")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "\\Wyyyy"), "'W'yyyy")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "%d"), "d")
        XCTAssertEqual(DateFormatting.unicodePattern(fromDotNet: "Week"), "'Week'")
    }

    func testUnmappedLettersAreLiteral() {
        XCTAssertEqual(format("yyyy Q E"), "2026 Q E")
        XCTAssertEqual(format("HH'h'mm"), "10h11")
    }

    func testSingleQuoteOutsideLettersIsEscaped() {
        XCTAssertEqual(format("\"it's\" yyyy"), "it's 2026")
    }

    func testCustomComponents() {
        XCTAssertEqual(format("d.M.yy"), "25.10.26")
        XCTAssertEqual(format("ddd, dd MMM yyyy"), "Sun, 25 Oct 2026")
        XCTAssertEqual(format("dddd MMMM"), "Sunday October")
        XCTAssertEqual(format("h:mm tt"), "10:11 AM")
        XCTAssertEqual(format("H.m.s"), "10.11.12")
        XCTAssertEqual(format("yyyy-MM-ddTHH"), "2026-10-25T10")
        XCTAssertEqual(format("%y"), "26", "a lone y is the standard year-month format")
        XCTAssertEqual(format("y"), "October 2026")
    }

    func testFractionsAndOffsets() {
        XCTAssertEqual(format("ss.fff"), "12.000")
        XCTAssertEqual(format("zzz", timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!), "+05:30")
    }

    func testStandardFormats() {
        XCTAssertEqual(format("D"), "Sunday, October 25, 2026")
        XCTAssertEqual(format("s"), "2026-10-25T10:11:12")
        XCTAssertEqual(format("u"), "2026-10-25 10:11:12Z")
        XCTAssertEqual(format("R"), "Sun, 25 Oct 2026 10:11:12 GMT")
        XCTAssertTrue(format("T").hasPrefix("10:11:12"), format("T"))
        XCTAssertTrue(format("t").hasPrefix("10:11"), format("t"))
    }

    func testUniversalFormatsIgnoreLocalTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(format("u", timeZone: tokyo), "2026-10-25 10:11:12Z")
        XCTAssertEqual(format("s", timeZone: tokyo), "2026-10-25T19:11:12")
    }

    func testSingleLetterThatIsNotStandardIsCustom() {
        XCTAssertEqual(format("H"), "10")
    }
}
