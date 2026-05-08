import Foundation

public struct OpenPetsClaudeCodeQuotaWindow: Codable, Equatable, Sendable {
    public var label: String
    public var usedPercentage: Int
    public var resetDate: Date
    public var durationMinutes: Int

    public init(
        label: String,
        usedPercentage: Int,
        resetDate: Date,
        durationMinutes: Int
    ) {
        self.label = label
        self.usedPercentage = usedPercentage
        self.resetDate = resetDate
        self.durationMinutes = durationMinutes
    }
}

public struct OpenPetsClaudeCodeQuotaSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: OpenPetsClaudeCodeQuotaWindow
    public var sevenDay: OpenPetsClaudeCodeQuotaWindow

    public init(
        fiveHour: OpenPetsClaudeCodeQuotaWindow,
        sevenDay: OpenPetsClaudeCodeQuotaWindow
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public enum OpenPetsClaudeCodeQuotaCache {
    public static var defaultCacheFileURL: URL {
        OpenPetsPaths.defaultConfigurationDirectory
            .appendingPathComponent("claude-code-quota.json")
    }

    public static func snapshot(
        fromStatusLineJSON data: Data
    ) -> OpenPetsClaudeCodeQuotaSnapshot? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rateLimits = root["rate_limits"] as? [String: Any],
            let fiveHour = rateLimits["five_hour"] as? [String: Any],
            let sevenDay = rateLimits["seven_day"] as? [String: Any],
            let fiveHourUsed = percentage(fiveHour["used_percentage"]),
            let sevenDayUsed = percentage(sevenDay["used_percentage"]),
            let fiveHourResetDate = resetDate(fiveHour["resets_at"]),
            let sevenDayResetDate = resetDate(sevenDay["resets_at"])
        else {
            return nil
        }

        return OpenPetsClaudeCodeQuotaSnapshot(
            fiveHour: OpenPetsClaudeCodeQuotaWindow(
                label: "5h",
                usedPercentage: fiveHourUsed,
                resetDate: fiveHourResetDate,
                durationMinutes: 5 * 60
            ),
            sevenDay: OpenPetsClaudeCodeQuotaWindow(
                label: "7d",
                usedPercentage: sevenDayUsed,
                resetDate: sevenDayResetDate,
                durationMinutes: 7 * 24 * 60
            )
        )
    }

    public static func load(
        from url: URL = defaultCacheFileURL,
        now: Date = Date()
    ) -> OpenPetsClaudeCodeQuotaSnapshot? {
        guard
            let data = try? Data(contentsOf: url),
            let snapshot = try? decoder().decode(OpenPetsClaudeCodeQuotaSnapshot.self, from: data),
            snapshot.fiveHour.resetDate > now,
            snapshot.sevenDay.resetDate > now
        else {
            return nil
        }
        return snapshot
    }

    public static func save(
        _ snapshot: OpenPetsClaudeCodeQuotaSnapshot,
        to url: URL = defaultCacheFileURL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private static func percentage(_ value: Any?) -> Int? {
        let percentage: Int?
        switch value {
        case let int as Int:
            percentage = int
        case let double as Double:
            percentage = Int(double.rounded(.down))
        case let string as String:
            percentage = Int(string)
        default:
            percentage = nil
        }
        guard let percentage, (0...100).contains(percentage) else {
            return nil
        }
        return percentage
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func resetDate(_ value: Any?) -> Date? {
        switch value {
        case let int as Int:
            return Date(timeIntervalSince1970: TimeInterval(int))
        case let double as Double:
            return Date(timeIntervalSince1970: double)
        case let string as String:
            if let epoch = Double(string) {
                return Date(timeIntervalSince1970: epoch)
            }
            return ISO8601DateFormatter().date(from: string)
        default:
            return nil
        }
    }
}
