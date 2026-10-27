import Foundation
import SystemConfiguration

/// Everything outside the capture that a filename pattern can read: the clock, the time zone,
/// the locale used for named date parts, the user and machine names and environment variables.
///
/// The default value describes the running process. Tests pass fixed values.
public struct FilenameEnvironment: Sendable {
    /// The value of `${now}`.
    public var now: Date
    /// Time zone for every date placeholder.
    public var timeZone: TimeZone
    /// Locale for month and day names and the standard `d` formats such as `D` and `T`.
    public var locale: Locale
    /// The value of `${user}` (the login name).
    public var userName: String
    /// The value of `${hostname}`.
    public var hostName: String
    /// Environment variables, consulted only for names that are not built-in placeholders.
    public var variables: [String: String]

    public init(now: Date = Date(),
                timeZone: TimeZone = .current,
                locale: Locale = .current,
                userName: String = NSUserName(),
                hostName: String = FilenameEnvironment.localHostName(),
                variables: [String: String] = ProcessInfo.processInfo.environment) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.userName = userName
        self.hostName = hostName
        self.variables = variables
    }

    /// The process environment at this moment.
    public static var current: FilenameEnvironment { FilenameEnvironment() }

    /// The Bonjour name of this Mac (for example "Tonys-MacBook-Pro"), without DNS lookups.
    public static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "Mac" }
        let full = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return full.split(separator: ".").first.map(String.init) ?? "Mac"
    }
}
