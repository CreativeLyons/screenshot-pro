import Foundation
import ScreenshotProCore

/// A pattern split into literal text and `${...}` placeholders.
enum PatternToken: Equatable {
    case literal(String)
    /// `body` is the text between `${` and `}`; `raw` is the whole placeholder as written.
    case placeholder(body: String, raw: String)
}

/// Options after the colon in `${name:options}`, separated by `;`.
struct PlaceholderOptions: Equatable {
    /// Negative width pads on the left, positive on the right.
    var pad: (width: Int, character: Character)?
    var dateFormat: String?
    var substring: (start: Int, length: Int?)?
    var replacements: [(old: String, new: String)] = []
    var lowercase = false
    var uppercase = false

    static func == (a: PlaceholderOptions, b: PlaceholderOptions) -> Bool {
        a.pad?.width == b.pad?.width && a.pad?.character == b.pad?.character
            && a.dateFormat == b.dateFormat
            && a.substring?.start == b.substring?.start && a.substring?.length == b.substring?.length
            && a.replacements.map(\.old) == b.replacements.map(\.old)
            && a.replacements.map(\.new) == b.replacements.map(\.new)
            && a.lowercase == b.lowercase && a.uppercase == b.uppercase
    }
}

/// The filename pattern engine behind `FilenamePattern`.
enum PatternExpander {
    static let fallbackPattern = "Screenshot ${capturetime}"
    static let maxLength = 200
    static let maxComponentBytes = 200
    static let maxTitleLength = 80
    static let defaultDateFormat = "yyyy-MM-dd HH-mm-ss"

    // MARK: Tokenizing

    static func tokenize(_ pattern: String) -> [PatternToken] {
        let chars = Array(pattern)
        var tokens: [PatternToken] = []
        var literal = ""
        var i = 0
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while i < chars.count {
            guard chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{" else {
                literal.append(chars[i])
                i += 1
                continue
            }
            // Find the closing brace; a brace inside double quotes does not close.
            var j = i + 2
            var inQuotes = false
            while j < chars.count {
                if chars[j] == "\"" { inQuotes.toggle() } else if chars[j] == "}" && !inQuotes { break }
                j += 1
            }
            guard j < chars.count else {
                literal.append(contentsOf: chars[i...])
                break
            }
            flush()
            tokens.append(.placeholder(body: String(chars[(i + 2)..<j]), raw: String(chars[i...j])))
            i = j + 1
        }
        flush()
        return tokens
    }

    /// Splits a placeholder body into its name and option list.
    static func split(body: String) -> (name: String, options: PlaceholderOptions) {
        guard let colon = body.firstIndex(of: ":") else {
            return (body.trimmingCharacters(in: .whitespaces), PlaceholderOptions())
        }
        let name = body[..<colon].trimmingCharacters(in: .whitespaces)
        return (name, parseOptions(String(body[body.index(after: colon)...])))
    }

    static func parseOptions(_ text: String) -> PlaceholderOptions {
        var options = PlaceholderOptions()
        for part in splitOutsideQuotes(text, separator: ";") {
            guard let kind = part.first else { continue }
            let argument = String(part.dropFirst())
            switch kind {
            case "p":
                let (w, c) = splitPair(argument)
                if let width = Int(w.trimmingCharacters(in: .whitespaces)) {
                    let char = c.map(unquoted)?.first ?? " "
                    options.pad = (width, char)
                }
            case "d":
                options.dateFormat = unquoted(argument)
            case "s":
                let (a, b) = splitPair(argument)
                if let start = Int(a.trimmingCharacters(in: .whitespaces)) {
                    let length = b.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if b == nil || length != nil { options.substring = (start, length) }
                }
            case "r":
                let (old, new) = splitPair(argument)
                let o = unquoted(old)
                if !o.isEmpty { options.replacements.append((o, unquoted(new ?? ""))) }
            case "l":
                options.lowercase = true
            case "u":
                options.uppercase = true
            default:
                continue
            }
        }
        return options
    }

    /// Splits on `separator` except inside double quotes.
    static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle() }
            if c == separator && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    /// "a,b" -> ("a", "b"); "a" -> ("a", nil). A comma inside quotes does not split.
    static func splitPair(_ text: String) -> (String, String?) {
        let parts = splitOutsideQuotes(text, separator: ",")
        guard parts.count > 1 else { return (text, nil) }
        return (parts[0], parts.dropFirst().joined(separator: ","))
    }

    /// Removes one pair of surrounding double quotes.
    static func unquoted(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: Expansion

    /// Expands `pattern`. With `safe`, placeholder values are made file-name safe and the result
    /// is normalized into a relative path (see `normalizePath`). Without it the plain text is
    /// returned, for print footers and previews of text.
    static func expand(_ pattern: String, details: CaptureDetails, counter: Int,
                       environment: FilenameEnvironment, safe: Bool) -> String {
        let source = pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackPattern : pattern
        var out = ""
        for token in tokenize(source) {
            switch token {
            case .literal(let text):
                out += safe ? safeLiteral(text) : text
            case .placeholder(let body, let raw):
                let (name, options) = split(body: body)
                if let value = resolve(name: name, options: options, details: details,
                                       counter: counter, environment: environment) {
                    out += safe ? safeValue(apply(options, to: value)) : apply(options, to: value)
                } else {
                    out += safe ? safeValue(raw) : raw
                }
            }
        }
        return safe ? normalizePath(out) : out
    }

    /// True when the pattern contains a `${NUM}` placeholder (any options, any case).
    static func usesCounter(_ pattern: String) -> Bool {
        tokenize(pattern).contains { token in
            if case .placeholder(let body, _) = token { return split(body: body).name.lowercased() == "num" }
            return false
        }
    }

    /// The raw value of a placeholder before options, or nil when the name is unknown.
    static func resolve(name: String, options: PlaceholderOptions, details: CaptureDetails, counter: Int,
                        environment env: FilenameEnvironment) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = env.timeZone
        func part(_ component: Calendar.Component, _ digits: Int) -> String {
            zeroPadded(calendar.component(component, from: details.date), digits)
        }
        // Case-sensitive names first: ${MM} is the month and ${mm} the minute.
        switch name {
        case "YYYY": return part(.year, 4)
        case "MM": return part(.month, 2)
        case "DD": return part(.day, 2)
        case "hh": return part(.hour, 2)
        case "mm": return part(.minute, 2)
        case "ss": return part(.second, 2)
        default: break
        }
        switch name.lowercased() {
        case "capturetime":
            return DateFormatting.format(details.date, dotNetFormat: options.dateFormat,
                                         timeZone: env.timeZone, locale: env.locale)
        case "now":
            return DateFormatting.format(env.now, dotNetFormat: options.dateFormat,
                                         timeZone: env.timeZone, locale: env.locale)
        case "num":
            return options.pad == nil ? zeroPadded(counter, 6) : String(counter)
        case "title":
            let title = (details.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Screenshot" : String(title.prefix(maxTitleLength))
        case "app":
            return (details.appName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case "user":
            return env.userName
        case "hostname":
            return env.hostName
        default:
            break
        }
        if !name.isEmpty, name.allSatisfy({ $0 == "R" }) {
            return randomAlphanumerics(count: name.count)
        }
        return env.variables[name]
    }

    /// Applies padding, substring, replacements and case, in that order.
    static func apply(_ options: PlaceholderOptions, to value: String) -> String {
        var s = value
        if let pad = options.pad {
            let missing = abs(pad.width) - s.count
            if missing > 0 {
                let fill = String(repeating: pad.character, count: missing)
                s = pad.width < 0 ? fill + s : s + fill
            }
        }
        if let sub = options.substring {
            s = substring(s, start: sub.start, length: sub.length)
        }
        for r in options.replacements {
            s = s.replacingOccurrences(of: r.old, with: r.new)
        }
        if options.lowercase { s = s.lowercased() }
        if options.uppercase { s = s.uppercased() }
        return s
    }

    /// Negative `start` counts from the end. A negative `length` drops that many characters from
    /// the end. Out-of-range values leave the string unchanged.
    static func substring(_ s: String, start: Int, length: Int?) -> String {
        let chars = Array(s)
        let from = start < 0 ? chars.count + start : start
        guard from >= 0, from <= chars.count else { return s }
        let remaining = chars.count - from
        let count: Int
        if let length {
            count = length < 0 ? remaining + length : length
        } else {
            count = remaining
        }
        guard count >= 0, count <= remaining else { return s }
        return String(chars[from..<(from + count)])
    }

    static func zeroPadded(_ value: Int, _ digits: Int) -> String {
        let s = String(abs(value))
        let padded = s.count < digits ? String(repeating: "0", count: digits - s.count) + s : s
        return value < 0 ? "-" + padded : padded
    }

    static let alphanumerics = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func randomAlphanumerics(count: Int) -> String {
        String((0..<count).map { _ in alphanumerics.randomElement()! })
    }

    // MARK: File-name safety

    static func isUnsafe(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                || scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }

    /// Placeholder values: `/`, `:` and control characters become `_`.
    static func safeValue(_ text: String) -> String {
        String(text.map { c in (c == "/" || c == ":" || isUnsafe(c)) ? "_" : c })
    }

    /// Literal pattern text keeps `/` (it creates subfolders); `:` and control characters become `_`.
    static func safeLiteral(_ text: String) -> String {
        String(text.map { c in (c == ":" || isUnsafe(c)) ? "_" : c })
    }

    /// Trims every path component, drops empty ones, neutralizes "." and "..", caps the whole
    /// name at `maxLength` characters and each component at `maxComponentBytes` UTF-8 bytes.
    /// Never returns an empty string.
    static func normalizePath(_ text: String) -> String {
        var components = text.split(separator: "/", omittingEmptySubsequences: false).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed == "." || trimmed == ".." { return "_" }
            return capBytes(trimmed, maxComponentBytes)
        }
        var joined = components.joined(separator: "/")
        if joined.count > maxLength {
            joined = String(joined.prefix(maxLength))
            components = joined.split(separator: "/").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            joined = components.joined(separator: "/")
        }
        return joined.isEmpty ? "Screenshot" : joined
    }

    /// Truncates on a character boundary so the UTF-8 form fits in `limit` bytes.
    static func capBytes(_ s: String, _ limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var result = ""
        var bytes = 0
        for c in s {
            let n = String(c).utf8.count
            if bytes + n > limit { break }
            result.append(c)
            bytes += n
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
