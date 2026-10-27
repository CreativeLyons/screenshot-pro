import Foundation

/// Formats dates for the `d` option of `${capturetime}` and `${now}`, which takes .NET custom date
/// format strings or a one-letter .NET standard format.
public enum DateFormatting {
    /// Formats `date`. `dotNetFormat` nil or empty uses `yyyy-MM-dd HH-mm-ss`.
    public static func format(_ date: Date, dotNetFormat: String?, timeZone: TimeZone, locale: Locale) -> String {
        let format = dotNetFormat ?? ""
        if format.isEmpty {
            return defaultFormat(date, timeZone: timeZone)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = locale
        if format.count == 1, applyStandard(format.first!, to: formatter) {
            return formatter.string(from: date)
        }
        formatter.dateFormat = unicodePattern(fromDotNet: format)
        return formatter.string(from: date)
    }

    /// `yyyy-MM-dd HH-mm-ss` built from calendar components, so digits are always ASCII.
    static func defaultFormat(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func p(_ v: Int?, _ n: Int) -> String { PatternExpander.zeroPadded(v ?? 0, n) }
        return "\(p(c.year, 4))-\(p(c.month, 2))-\(p(c.day, 2)) \(p(c.hour, 2))-\(p(c.minute, 2))-\(p(c.second, 2))"
    }

    /// Configures `formatter` for a .NET standard format letter; false when it is not one.
    static func applyStandard(_ letter: Character, to formatter: DateFormatter) -> Bool {
        let posix = Locale(identifier: "en_US_POSIX")
        let utc = TimeZone(identifier: "UTC")!
        switch letter {
        case "d": formatter.dateStyle = .short; formatter.timeStyle = .none
        case "D": formatter.dateStyle = .full; formatter.timeStyle = .none
        case "t": formatter.dateStyle = .none; formatter.timeStyle = .short
        case "T": formatter.dateStyle = .none; formatter.timeStyle = .medium
        case "f": formatter.dateStyle = .full; formatter.timeStyle = .short
        case "F": formatter.dateStyle = .full; formatter.timeStyle = .medium
        case "g": formatter.dateStyle = .short; formatter.timeStyle = .short
        case "G": formatter.dateStyle = .short; formatter.timeStyle = .medium
        case "M", "m": formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        case "Y", "y": formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        case "s":
            formatter.locale = posix
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        case "u":
            formatter.locale = posix
            formatter.timeZone = utc
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        case "O", "o":
            formatter.locale = posix
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSxxx"
        case "R", "r":
            formatter.locale = posix
            formatter.timeZone = utc
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        default:
            return false
        }
        return true
    }

    /// Translates a .NET custom date format into a Unicode (DateFormatter) pattern.
    ///
    /// Supported: `d dd ddd dddd`, `M MM MMM MMMM`, `y yy yyy yyyy`, `h hh H HH m mm s ss`,
    /// `f...` / `F...` (fractions), `t tt` (AM/PM), `g` (era), `z zz zzz` and `K` (offset),
    /// `'quoted'` and `"quoted"` literals, `\` escapes and the `%` prefix. Any other letter is
    /// literal in .NET, so it is quoted in the output.
    public static func unicodePattern(fromDotNet format: String) -> String {
        let chars = Array(format)
        var out = ""
        // Pending literal letters, emitted inside one pair of quotes.
        var quoted = ""
        func flushQuoted() {
            guard !quoted.isEmpty else { return }
            out += "'" + quoted + "'"
            quoted = ""
        }
        func emit(_ pattern: String) {
            flushQuoted()
            out += pattern
        }
        // Only ASCII letters are pattern characters in Unicode patterns; other characters are
        // literal as is, except the apostrophe, which is doubled inside the quoted run.
        func literal(_ c: Character) {
            if c == "'" {
                quoted += "''"
            } else if c.isASCII && c.isLetter {
                quoted.append(c)
            } else {
                flushQuoted()
                out.append(c)
            }
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += 1 }
                chars[(i + 1)..<min(j, chars.count)].forEach(literal)
                i = j + 1
                continue
            }
            if c == "\\" {
                if i + 1 < chars.count { literal(chars[i + 1]) }
                i += 2
                continue
            }
            if c == "%" {
                i += 1
                continue
            }
            guard c.isASCII, c.isLetter else {
                literal(c)
                i += 1
                continue
            }
            var n = 1
            while i + n < chars.count, chars[i + n] == c { n += 1 }
            switch c {
            case "d": emit(n == 1 ? "d" : n == 2 ? "dd" : n == 3 ? "EEE" : "EEEE")
            case "M": emit(String(repeating: "M", count: min(n, 4)))
            case "y": emit(n == 1 ? "yy" : String(repeating: "y", count: n))
            case "h": emit(n == 1 ? "h" : "hh")
            case "H": emit(n == 1 ? "H" : "HH")
            case "m": emit(n == 1 ? "m" : "mm")
            case "s": emit(n == 1 ? "s" : "ss")
            case "f", "F": emit(String(repeating: "S", count: min(n, 7)))
            case "t": emit("a")
            case "g": emit("G")
            case "z": emit(n < 3 ? "x" : "xxx")
            case "K": emit("xxx")
            default: for _ in 0..<n { literal(c) }
            }
            i += n
        }
        flushQuoted()
        return out
    }
}
