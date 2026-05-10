import CoreGraphics
import Foundation

public struct OpenPetsConfiguration: Codable, Equatable, Sendable {
    public var display: OpenPetsDisplayConfiguration
    public var socketPath: String
    public var mcpHost: String
    public var mcpPort: Int
    public var mcpEndpoint: String
    public var activePetID: String
    public var petScalesByID: [String: CGFloat]
    public var enabledPluginIDs: [String]
    public var disabledPluginIDs: [String]
    public var surfaceSlotOverridesByID: [String: OpenPetsSurfaceSlot]

    public init(
        display: OpenPetsDisplayConfiguration = .default,
        socketPath: String = OpenPetsPaths.defaultSocketPath,
        mcpHost: String = "127.0.0.1",
        mcpPort: Int = 3001,
        mcpEndpoint: String = "/mcp",
        activePetID: String = OpenPetsBundledPets.starcornID,
        petScalesByID: [String: CGFloat] = [:],
        enabledPluginIDs: [String] = [],
        disabledPluginIDs: [String] = [],
        surfaceSlotOverridesByID: [String: OpenPetsSurfaceSlot] = [:]
    ) {
        self.display = display
        self.socketPath = socketPath
        self.mcpHost = mcpHost
        self.mcpPort = mcpPort
        self.mcpEndpoint = mcpEndpoint
        self.activePetID = activePetID
        self.petScalesByID = petScalesByID
        self.enabledPluginIDs = enabledPluginIDs
        self.disabledPluginIDs = disabledPluginIDs
        self.surfaceSlotOverridesByID = surfaceSlotOverridesByID
    }

    private enum CodingKeys: String, CodingKey {
        case display
        case socketPath
        case mcpHost
        case mcpPort
        case mcpEndpoint
        case activePetID
        case petScalesByID
        case enabledPluginIDs
        case disabledPluginIDs
        case surfaceSlotOverridesByID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try container.decodeIfPresent(OpenPetsDisplayConfiguration.self, forKey: .display) ?? .default
        socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath) ?? OpenPetsPaths.defaultSocketPath
        mcpHost = try container.decodeIfPresent(String.self, forKey: .mcpHost) ?? "127.0.0.1"
        mcpPort = try container.decodeIfPresent(Int.self, forKey: .mcpPort) ?? 3001
        mcpEndpoint = try container.decodeIfPresent(String.self, forKey: .mcpEndpoint) ?? "/mcp"
        activePetID = try container.decodeIfPresent(String.self, forKey: .activePetID) ?? OpenPetsBundledPets.starcornID
        petScalesByID = try container.decodeIfPresent([String: CGFloat].self, forKey: .petScalesByID) ?? [:]
        enabledPluginIDs = try container.decodeIfPresent([String].self, forKey: .enabledPluginIDs) ?? []
        disabledPluginIDs = try container.decodeIfPresent([String].self, forKey: .disabledPluginIDs) ?? []
        surfaceSlotOverridesByID = try container.decodeIfPresent(
            [String: OpenPetsSurfaceSlot].self,
            forKey: .surfaceSlotOverridesByID
        ) ?? [:]
    }

    public func scale(forPetID petID: String) -> CGFloat {
        petScalesByID[petID] ?? display.scale
    }

    public func display(forPetID petID: String) -> OpenPetsDisplayConfiguration {
        var petDisplay = display
        petDisplay.scale = scale(forPetID: petID)
        return petDisplay
    }

    public mutating func setScale(_ scale: CGFloat, forPetID petID: String) {
        petScalesByID[petID] = scale
    }

    public static func load(
        from url: URL = OpenPetsPaths.defaultConfigurationFileURL
    ) throws -> OpenPetsConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return OpenPetsConfiguration()
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OpenPetsConfiguration.self, from: data)
    }

    @discardableResult
    public static func loadOrCreateDefault(
        at url: URL = OpenPetsPaths.defaultConfigurationFileURL
    ) throws -> OpenPetsConfiguration {
        if FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }

        let configuration = OpenPetsConfiguration()
        try configuration.save(to: url)
        return configuration
    }

    public func save(to url: URL = OpenPetsPaths.defaultConfigurationFileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
