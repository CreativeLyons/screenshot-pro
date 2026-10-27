import ScreenshotProCore
import XCTest
@testable import ScreenshotProOutput

/// Shared fixtures: 2026-10-25 10:11:12 UTC, a fixed user, host and environment.
enum Fixture {
    static let utc = TimeZone(identifier: "UTC")!
    static let date: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 25; c.hour = 10; c.minute = 11; c.second = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: c)!
    }()
    /// `${now}` is one hour and one second after the capture.
    static let now = date.addingTimeInterval(3601)

    static func environment(timeZone: TimeZone = utc, variables: [String: String] = [:]) -> FilenameEnvironment {
        FilenameEnvironment(now: now, timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"),
                            userName: "tony", hostName: "Studio", variables: variables)
    }

    static func details(title: String? = "Safari Window", app: String? = "Safari") -> CaptureDetails {
        CaptureDetails(mode: .window, date: date, title: title, appName: app, scale: 2)
    }

    static func expand(_ pattern: String, title: String? = "Safari Window", app: String? = "Safari",
                       counter: Int = 1, timeZone: TimeZone = utc, variables: [String: String] = [:]) -> String {
        FilenamePattern.expand(pattern, details: details(title: title, app: app), counter: counter,
                               environment: environment(timeZone: timeZone, variables: variables))
    }
}

final class FilenamePatternTests: XCTestCase {
    private func expand(_ pattern: String, title: String? = "Safari Window", app: String? = "Safari",
                        counter: Int = 1, timeZone: TimeZone = Fixture.utc,
                        variables: [String: String] = [:]) -> String {
        Fixture.expand(pattern, title: title, app: app, counter: counter, timeZone: timeZone, variables: variables)
    }

    // MARK: Built-in placeholders

    func testDefaultSettingsPattern() {
        XCTAssertEqual(expand(ScreenshotProSettings().filenamePattern), "Screenshot 2026-10-25 10.11.12")
    }

    func testDatePartPlaceholders() {
        XCTAssertEqual(expand("${YYYY}|${MM}|${DD}|${hh}|${mm}|${ss}"), "2026|10|25|10|11|12")
    }

    func testDatePartsArePadded() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixture.utc
        let early = calendar.date(from: DateComponents(year: 987, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
        let details = CaptureDetails(mode: .region, date: early)
        let result = FilenamePattern.expand("${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss}", details: details, counter: 1,
                                            environment: Fixture.environment())
        XCTAssertEqual(result, "0987-01-02 03.04.05")
    }

    func testMonthAndMinuteAreCaseSensitive() {
        XCTAssertEqual(expand("${MM}-${mm}"), "10-11")
    }

    func testTimeZoneIsHonored() {
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(expand("${hh}", timeZone: newYork), "06")
        XCTAssertEqual(expand("${capturetime}", timeZone: newYork), "2026-10-25 06-11-12")
    }

    func testCaptureTimeDefaultFormat() {
        XCTAssertEqual(expand("${capturetime}"), "2026-10-25 10-11-12")
    }

    func testNowUsesTheEnvironmentClock() {
        XCTAssertEqual(expand("${now}"), "2026-10-25 11-11-13")
        XCTAssertEqual(expand("${now:d\"HH.mm.ss\"}"), "11.11.13")
    }

    func testNamedPlaceholdersAreCaseInsensitive() {
        XCTAssertEqual(expand("${CAPTURETIME}"), "2026-10-25 10-11-12")
        XCTAssertEqual(expand("${Title}"), "Safari Window")
        XCTAssertEqual(expand("${num}", counter: 3), "000003")
        XCTAssertEqual(expand("${USER}@${HostName}"), "tony@Studio")
    }

    func testCounterIsSixDigitsByDefault() {
        XCTAssertEqual(expand("${NUM}", counter: 42), "000042")
        XCTAssertEqual(expand("${NUM}", counter: 1_234_567), "1234567")
    }

    func testCounterWithPadOptionUsesRawNumber() {
        XCTAssertEqual(expand("${NUM:p-2,0}", counter: 7), "07")
        XCTAssertEqual(expand("${NUM:p-2,0}", counter: 123), "123")
        XCTAssertEqual(expand("${NUM:p-4,0}", counter: 42), "0042")
    }

    func testTitle() {
        XCTAssertEqual(expand("${title}"), "Safari Window")
        XCTAssertEqual(expand("${title}", title: "  padded  "), "padded")
    }

    func testTitleFallsBackToScreenshot() {
        XCTAssertEqual(expand("${title}", title: nil), "Screenshot")
        XCTAssertEqual(expand("${title}", title: ""), "Screenshot")
        XCTAssertEqual(expand("${title}", title: " \n "), "Screenshot")
    }

    func testTitleIsTruncatedTo80Characters() {
        let long = String(repeating: "x", count: 120)
        XCTAssertEqual(expand("${title}", title: long).count, 80)
        XCTAssertEqual(expand("${title}!", title: long), String(repeating: "x", count: 80) + "!")
    }

    func testAppUserHostname() {
        XCTAssertEqual(expand("${app} ${user} ${hostname}"), "Safari tony Studio")
        XCTAssertEqual(expand("[${app}]", app: nil), "[]")
    }

    func testRandomPlaceholders() {
        let alphabet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        for count in [1, 4, 12] {
            let value = expand("${" + String(repeating: "R", count: count) + "}")
            XCTAssertEqual(value.count, count)
            XCTAssertTrue(value.allSatisfy(alphabet.contains), value)
        }
        // 12 random characters colliding twice in a row is practically impossible.
        XCTAssertNotEqual(expand("${RRRRRRRRRRRR}"), expand("${RRRRRRRRRRRR}"))
    }

    func testLowercaseRIsNotRandom() {
        XCTAssertEqual(expand("${rrr}"), "${rrr}")
    }

    // MARK: Unknown names and environment variables

    func testUnknownPlaceholderStaysLiteral() {
        XCTAssertEqual(expand("a ${unknown} b"), "a ${unknown} b")
        XCTAssertEqual(expand("${}"), "${}")
        XCTAssertEqual(expand("${unknown:p-9,0}"), "${unknown_p-9,0}")
    }

    func testUnknownPlaceholderIsStillFileSafe() {
        XCTAssertEqual(expand("${a/b}"), "${a_b}")
    }

    func testUnterminatedPlaceholderIsLiteral() {
        XCTAssertEqual(expand("shot ${YYYY"), "shot ${YYYY")
        XCTAssertEqual(expand("$YYYY {MM}"), "$YYYY {MM}")
    }

    func testEnvironmentVariableFallback() {
        XCTAssertEqual(expand("${PROJECT}", variables: ["PROJECT": "Atlas"]), "Atlas")
        XCTAssertEqual(expand("${PROJECT:u}", variables: ["PROJECT": "Atlas"]), "ATLAS")
    }

    func testEnvironmentVariablesNeverShadowBuiltIns() {
        let env = ["YYYY": "1999", "title": "from env", "USER": "root", "NUM": "x", "R": "env"]
        XCTAssertEqual(expand("${YYYY} ${title} ${USER} ${NUM}", counter: 5, variables: env),
                       "2026 Safari Window tony 000005")
        XCTAssertEqual(expand("${R}", variables: env).count, 1)
        XCTAssertNotEqual(expand("${RRRRRRRRRR}", variables: ["RRRRRRRRRR": "fixedvalue"]), "fixedvalue")
    }

    func testEnvironmentValuesAreFileSafe() {
        XCTAssertEqual(expand("${P}", variables: ["P": "/Users/tony:x"]), "_Users_tony_x")
    }

    // MARK: Options

    func testPadLeftAndRight() {
        XCTAssertEqual(expand("${app:p-8}"), "Safari", "leading spaces are trimmed at the start of the name")
        XCTAssertEqual(expand("[${app:p-8}]"), "[  Safari]")
        XCTAssertEqual(expand("[${app:p8}]"), "[Safari  ]")
        XCTAssertEqual(expand("[${app:p8,*}]"), "[Safari**]")
        XCTAssertEqual(expand("[${app:p-8,\"0\"}]"), "[00Safari]")
        XCTAssertEqual(expand("[${app:p3,*}]"), "[Safari]", "never truncates")
    }

    func testMalformedPadIsIgnored() {
        XCTAssertEqual(expand("${app:pX}"), "Safari")
    }

    func testSubstring() {
        XCTAssertEqual(expand("${title:s0,6}"), "Safari")
        XCTAssertEqual(expand("${title:s7}"), "Window")
        XCTAssertEqual(expand("${title:s-6}"), "Window")
        XCTAssertEqual(expand("${title:s-6,3}"), "Win")
        XCTAssertEqual(expand("${title:s0,-7}"), "Safari", "negative length drops characters from the end")
        XCTAssertEqual(expand("${title:s7,-3}"), "Win")
    }

    func testSubstringOutOfRangeLeavesValueUnchanged() {
        XCTAssertEqual(expand("${title:s99}"), "Safari Window")
        XCTAssertEqual(expand("${title:s-99}"), "Safari Window")
        XCTAssertEqual(expand("${title:s1,99}"), "Safari Window")
        XCTAssertEqual(expand("${title:s0,-99}"), "Safari Window")
        XCTAssertEqual(expand("${title:sX}"), "Safari Window")
    }

    func testReplace() {
        XCTAssertEqual(expand("${title:r ,_}"), "Safari_Window")
        XCTAssertEqual(expand("${title:ra,4;ri,1}"), "S4f4r1 W1ndow")
        XCTAssertEqual(expand("${title:r\"Safari \",\"\"}"), "Window")
        XCTAssertEqual(expand("${title:rWindow}"), "Safari", "missing new value removes")
    }

    func testReplaceCanFixDateSeparators() {
        XCTAssertEqual(expand("${capturetime:d\"HH:mm\";r:,h}"), "10h11")
    }

    func testCaseOptions() {
        XCTAssertEqual(expand("${title:l}"), "safari window")
        XCTAssertEqual(expand("${title:u}"), "SAFARI WINDOW")
    }

    func testOptionsApplyInOrderPadSubstringReplace() {
        // 7 -> "0007" (pad) -> "007" (substring) -> "oo7" (replace) -> "OO7" (upper)
        XCTAssertEqual(expand("${NUM:p-4,0;s1;r0,o;u}", counter: 7), "OO7")
    }

    func testUnknownOptionsAreIgnored() {
        XCTAssertEqual(expand("${title:x;;z}"), "Safari Window")
    }

    func testSemicolonInsideQuotesDoesNotSplitOptions() {
        XCTAssertEqual(expand("${capturetime:d\"HH;mm\"}"), "10;11")
    }

    func testBraceInsideQuotesDoesNotClose() {
        XCTAssertEqual(expand("${capturetime:d\"{HH}\"}"), "{10}")
    }

    // MARK: Date format option

    func testDateFormatOption() {
        XCTAssertEqual(expand("${capturetime:d\"yyyy-MM-dd HH_mm_ss\"}"), "2026-10-25 10_11_12")
        XCTAssertEqual(expand("${capturetime:dyyyyMMdd}"), "20261025")
        XCTAssertEqual(expand("${capturetime:d\"yyyy-MM-dd HH_mm_ss\"}-${title}"),
                       "2026-10-25 10_11_12-Safari Window")
    }

    func testDateFormatColonsAreMadeSafe() {
        XCTAssertEqual(expand("${capturetime:d\"HH:mm:ss\"}"), "10_11_12")
        XCTAssertEqual(expand("${capturetime:d\"dd/MM/yyyy\"}"), "25_10_2026", "a slash from a value never makes folders")
    }

    func testStandardDateFormats() {
        XCTAssertEqual(expand("${capturetime:dD}"), "Sunday, October 25, 2026")
        XCTAssertEqual(expand("${capturetime:ds}"), "2026-10-25T10_11_12")
        XCTAssertEqual(expand("${capturetime:du}"), "2026-10-25 10_11_12Z")
    }

    // MARK: File-name safety

    func testSlashAndColonInValuesAreReplaced() {
        XCTAssertEqual(expand("${title}", title: "a/b: c"), "a_b_ c")
    }

    func testControlCharactersAreReplaced() {
        XCTAssertEqual(expand("${title}", title: "a\tb\nc\u{0}d\u{7F}e\u{2028}f"), "a_b_c_d_e_f")
        XCTAssertEqual(expand("x\ty"), "x_y", "control characters in the pattern too")
    }

    func testColonInLiteralIsReplaced() {
        XCTAssertEqual(expand("Shot 10:30"), "Shot 10_30")
    }

    func testEmojiAndJoinersSurvive() {
        XCTAssertEqual(expand("${title}", title: "Team 👩‍👩‍👧 notes"), "Team 👩‍👩‍👧 notes")
    }

    func testResultIsTrimmed() {
        XCTAssertEqual(expand("  ${title}  "), "Safari Window")
        XCTAssertEqual(expand("${title}", title: "\tTabbed"), "Tabbed", "the title is trimmed before sanitizing")
        XCTAssertEqual(expand("${app}", app: "\u{1}Odd"), "_Odd")
    }

    func testLengthIsCappedAt200() {
        let result = expand(String(repeating: "a", count: 300))
        XCTAssertEqual(result.count, 200)
    }

    func testCapDoesNotLeaveTrailingSpace() {
        let pattern = String(repeating: "a", count: 199) + " bcd"
        XCTAssertEqual(expand(pattern), String(repeating: "a", count: 199))
    }

    func testComponentByteLengthIsCapped() {
        let result = expand(String(repeating: "😀", count: 100))
        XCTAssertLessThanOrEqual(result.utf8.count, 200)
        XCTAssertEqual(result, String(repeating: "😀", count: 50))
    }

    func testEmptyPatternUsesFallback() {
        XCTAssertEqual(expand(""), "Screenshot 2026-10-25 10-11-12")
        XCTAssertEqual(expand("   "), "Screenshot 2026-10-25 10-11-12")
    }

    func testEmptyResultBecomesScreenshot() {
        XCTAssertEqual(expand("${app}", app: nil), "Screenshot")
        XCTAssertEqual(expand("/ /"), "Screenshot")
    }

    // MARK: Subfolders

    func testLiteralSlashCreatesSubfolders() {
        XCTAssertEqual(expand("${YYYY}/${MM}/shot ${DD}"), "2026/10/shot 25")
    }

    func testSubfolderComponentsAreNormalized() {
        XCTAssertEqual(expand("/a//b/"), "a/b")
        XCTAssertEqual(expand(" a / b "), "a/b")
        XCTAssertEqual(expand("../x/./y"), "_/x/_/y")
    }

    func testSlashFromValueStaysInOneComponent() {
        XCTAssertEqual(expand("${YYYY}/${title}", title: "../../etc"), "2026/.._.._etc")
    }

    // MARK: Counter detection and text expansion

    func testUsesCounter() {
        XCTAssertTrue(FilenamePattern.usesCounter("shot ${NUM}"))
        XCTAssertTrue(FilenamePattern.usesCounter("${num:p-2,0}"))
        XCTAssertFalse(FilenamePattern.usesCounter("NUM ${NUMBER} $NUM"))
        XCTAssertFalse(FilenamePattern.usesCounter(ScreenshotProSettings().filenamePattern))
    }

    func testExpandTextKeepsUnsafeCharacters() {
        let text = FilenamePattern.expandText("${capturetime:d\"HH:mm\"} - ${title}", details: Fixture.details(title: "a/b"),
                                              environment: Fixture.environment())
        XCTAssertEqual(text, "10:11 - a/b")
    }

    func testContractExpandUsesCurrentEnvironment() {
        let details = Fixture.details()
        XCTAssertEqual(FilenamePattern.expand("${title} ${NUM}", details: details, counter: 9), "Safari Window 000009")
        XCTAssertEqual(FilenamePattern.expand("${user}", details: details), PatternExpander.safeValue(NSUserName()))
    }
}
