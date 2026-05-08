import Foundation

public struct OpenPetsPetReactionKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let lowEnergy: Self = "low-energy"
    public static let charging: Self = "charging"
    public static let alert: Self = "alert"
    public static let celebrate: Self = "celebrate"
    public static let working: Self = "working"
    public static let resting: Self = "resting"
}

public struct OpenPetsPetReactionUpdate: Codable, Equatable, Sendable {
    public var type: String
    public var reactionID: String
    public var kind: OpenPetsPetReactionKind
    public var priority: Int
    public var ttlSeconds: Double?

    public init(
        type: String = "pet.reaction",
        reactionID: String,
        kind: OpenPetsPetReactionKind,
        priority: Int = 0,
        ttlSeconds: Double? = nil
    ) {
        self.type = type
        self.reactionID = reactionID
        self.kind = kind
        self.priority = priority
        self.ttlSeconds = ttlSeconds
    }
}

public struct OpenPetsPetReactionAnimation: Codable, Equatable, Sendable {
    public var kind: OpenPetsPetReactionKind
    public var animation: PetAnimation?
    public var spritesheetPath: String?
    public var row: Int?
    public var frameCount: Int?
    public var frameDurationsMilliseconds: [Int]?

    public init(
        kind: OpenPetsPetReactionKind,
        animation: PetAnimation? = nil,
        spritesheetPath: String? = nil,
        row: Int? = nil,
        frameCount: Int? = nil,
        frameDurationsMilliseconds: [Int]? = nil
    ) {
        self.kind = kind
        self.animation = animation
        self.spritesheetPath = spritesheetPath
        self.row = row
        self.frameCount = frameCount
        self.frameDurationsMilliseconds = frameDurationsMilliseconds
    }
}
