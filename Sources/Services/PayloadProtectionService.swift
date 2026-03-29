import Foundation

enum PayloadProtectionService {
    private static var supportDirectoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var patternsFilePath: String {
        supportDirectoryURL.appendingPathComponent("payload-patterns.tsv").path
    }

    static var permanentAllowlistPath: String {
        supportDirectoryURL.appendingPathComponent("payload-allowlist.txt").path
    }

    static var sessionAllowlistPath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("focusshield-payload-session-allowlist.txt").path
    }

    static func syncRuntimeConfiguration(enabled: Bool, patterns: [PayloadPattern]) {
        let activePatterns = enabled ? patterns.filter(\.isEnabled) : []
        let lines = activePatterns.map { pattern in
            "\(escapeField(pattern.name))\t\(escapeField(pattern.regex))"
        }
        let payload = lines.joined(separator: "\n")
        try? payload.write(toFile: patternsFilePath, atomically: true, encoding: .utf8)

        if !FileManager.default.fileExists(atPath: permanentAllowlistPath) {
            try? "".write(toFile: permanentAllowlistPath, atomically: true, encoding: .utf8)
        }
    }

    static func isValidRegex(_ regex: String) -> Bool {
        (try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])) != nil
    }

    private static func escapeField(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
