import Foundation

public enum OpenPetsSurfaceTone: String, Codable, Equatable, Sendable {
    case normal
    case success
    case warning
    case critical
    case muted
}

public enum OpenPetsSurfaceIcons {
    public static let battery25 = "battery.25"
    public static let battery50 = "battery.50"
    public static let battery75 = "battery.75"
    public static let battery100 = "battery.100"
    public static let batteryCharging = "bolt.fill"
    public static let quota = "gauge"
    public static let database = "cylinder.split.1x2.fill"
    public static let api = "link"
    public static let clock = "clock.fill"
    public static let timer = "timer"
    public static let chart = "chart.bar.fill"
    public static let warning = "exclamationmark.triangle.fill"
    public static let success = "checkmark.circle.fill"
    public static let info = "info.circle.fill"
    public static let sparkles = "sparkles"
    public static let cpu = "cpu"
    public static let memory = "memorychip.fill"
    public static let network = "network"

    public static let examples: [String] = [
        battery25,
        battery50,
        battery75,
        battery100,
        batteryCharging,
        quota,
        database,
        api,
        clock,
        timer,
        chart,
        warning,
        success,
        info,
        sparkles,
        cpu,
        memory,
        network
    ]
}

public struct OpenPetsSurfaceSlot: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let hotspotTopLeading: Self = "hotspot.topLeading"
    public static let hotspotTopTrailing: Self = "hotspot.topTrailing"
    public static let hotspotRight: Self = "hotspot.right"
    public static let hotspotBottomTrailing: Self = "hotspot.bottomTrailing"
    public static let hotspotBottomLeading: Self = "hotspot.bottomLeading"
    public static let hotspotLeft: Self = "hotspot.left"
}

public enum OpenPetsSurfaceSlots {
    public static let defaultOrder: [OpenPetsSurfaceSlot] = [
        .hotspotTopTrailing,
        .hotspotTopLeading,
        .hotspotRight,
        .hotspotBottomTrailing,
        .hotspotBottomLeading,
        .hotspotLeft
    ]
}

public struct OpenPetsSurfaceDetailRow: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public var tone: OpenPetsSurfaceTone?

    public init(label: String, value: String, tone: OpenPetsSurfaceTone? = nil) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

public struct OpenPetsSurfaceDetailData: Codable, Equatable, Sendable {
    public var title: String
    public var rows: [OpenPetsSurfaceDetailRow]
    public var actionURL: String?
    public var actionLabel: String?
    public var ttlSeconds: Double?

    public init(
        title: String,
        rows: [OpenPetsSurfaceDetailRow],
        actionURL: String? = nil,
        actionLabel: String? = nil,
        ttlSeconds: Double? = nil
    ) {
        self.title = title
        self.rows = rows
        self.actionURL = actionURL
        self.actionLabel = actionLabel
        self.ttlSeconds = ttlSeconds
    }
}

public struct OpenPetsSurfaceUpdate: Codable, Equatable, Sendable {
    public var type: String
    public var surfaceID: String
    public var slotPreference: [OpenPetsSurfaceSlot]
    public var priority: Int
    public var icon: String
    public var value: String
    public var label: String?
    public var tone: OpenPetsSurfaceTone
    public var detail: OpenPetsSurfaceDetailData?

    public init(
        type: String = "surface.update",
        surfaceID: String,
        slotPreference: [OpenPetsSurfaceSlot] = [],
        priority: Int = 0,
        icon: String,
        value: String,
        label: String? = nil,
        tone: OpenPetsSurfaceTone = .normal,
        detail: OpenPetsSurfaceDetailData? = nil
    ) {
        self.type = type
        self.surfaceID = surfaceID
        self.slotPreference = slotPreference
        self.priority = priority
        self.icon = icon
        self.value = value
        self.label = label
        self.tone = tone
        self.detail = detail
    }
}
