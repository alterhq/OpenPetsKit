import CoreGraphics
import Foundation
import ImageIO

public struct OpenPetsPetAssetPreloadRequest: Sendable {
    public var petDirectoryURL: URL
    public var display: OpenPetsDisplayConfiguration

    public init(petDirectoryURL: URL, display: OpenPetsDisplayConfiguration) {
        self.petDirectoryURL = petDirectoryURL
        self.display = display
    }
}

public actor OpenPetsPetAssetCache {
    public static let shared = OpenPetsPetAssetCache()

    private var assetsByKey: [PetHostAssetCacheKey: PetHostAssets] = [:]

    public init() {}

    public func preloadPet(at petDirectoryURL: URL, display: OpenPetsDisplayConfiguration) {
        _ = try? assets(for: petDirectoryURL, display: display)
    }

    public func preloadPets(_ requests: [OpenPetsPetAssetPreloadRequest]) {
        for request in requests {
            preloadPet(at: request.petDirectoryURL, display: request.display)
        }
    }

    func cachedPetCount() -> Int {
        assetsByKey.count
    }

    public func invalidatePet(at petDirectoryURL: URL) {
        let directoryPath = petDirectoryURL.standardizedFileURL.path
        assetsByKey = assetsByKey.filter { key, _ in
            key.directoryPath != directoryPath
        }
    }

    func assets(for petDirectoryURL: URL, display: OpenPetsDisplayConfiguration) throws -> PetHostAssets {
        let petBundle = try PetBundle.load(from: petDirectoryURL)
        let key = try PetHostAssetCacheKey(petBundle: petBundle, displayScale: display.scale)
        if let assets = assetsByKey[key] {
            return assets
        }

        let assets = try PetHostAssets.load(from: petBundle, displayScale: display.scale)
        assetsByKey = assetsByKey.filter { existingKey, _ in
            existingKey.directoryPath != key.directoryPath
        }
        assetsByKey[key] = assets
        return assets
    }
}

struct PetHostAssetCacheKey: Hashable, Sendable {
    var directoryPath: String
    var manifestPath: String
    var manifestFileSize: UInt64
    var manifestModifiedAt: TimeInterval
    var spritesheetPath: String
    var spritesheetFileSize: UInt64
    var spritesheetModifiedAt: TimeInterval
    var displayScale: Double

    init(petBundle: PetBundle, displayScale: CGFloat) throws {
        let manifestURL = petBundle.directoryURL.appendingPathComponent("pet.json")
        let manifestSignature = try Self.fileSignature(for: manifestURL)
        let spritesheetSignature = try Self.fileSignature(for: petBundle.spritesheetURL)

        directoryPath = petBundle.directoryURL.standardizedFileURL.path
        manifestPath = manifestURL.standardizedFileURL.path
        manifestFileSize = manifestSignature.size
        manifestModifiedAt = manifestSignature.modifiedAt
        spritesheetPath = petBundle.spritesheetURL.standardizedFileURL.path
        spritesheetFileSize = spritesheetSignature.size
        spritesheetModifiedAt = spritesheetSignature.modifiedAt
        self.displayScale = Double(displayScale)
    }

    private static func fileSignature(for url: URL) throws -> (size: UInt64, modifiedAt: TimeInterval) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (
            UInt64(max(0, values.fileSize ?? 0)),
            values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }
}

final class PetHostAssets: @unchecked Sendable {
    let petBundle: PetBundle
    let frames: [PetAnimation: [CGImage]]
    let surfacePalette: OpenPetsPetSurfacePalette
    let reactionFrames: [OpenPetsPetReactionKind: [CGImage]]
    let reactionFrameDurations: [OpenPetsPetReactionKind: [Int]]
    let stableSpriteBounds: CGRect

    private init(
        petBundle: PetBundle,
        frames: [PetAnimation: [CGImage]],
        surfacePalette: OpenPetsPetSurfacePalette,
        reactionFrames: [OpenPetsPetReactionKind: [CGImage]],
        reactionFrameDurations: [OpenPetsPetReactionKind: [Int]],
        stableSpriteBounds: CGRect
    ) {
        self.petBundle = petBundle
        self.frames = frames
        self.surfacePalette = surfacePalette
        self.reactionFrames = reactionFrames
        self.reactionFrameDurations = reactionFrameDurations
        self.stableSpriteBounds = stableSpriteBounds
    }

    static func load(from petBundle: PetBundle, displayScale: CGFloat) throws -> PetHostAssets {
        let frames = try loadFrames(from: petBundle)
        let spriteSize = CGSize(
            width: CGFloat(petBundle.atlas.cellWidth) * displayScale,
            height: CGFloat(petBundle.atlas.cellHeight) * displayScale
        )
        let reactionAssets = try loadReactionFrames(from: petBundle)
        return PetHostAssets(
            petBundle: petBundle,
            frames: frames,
            surfacePalette: OpenPetsPetSurfacePalette.extract(from: frames),
            reactionFrames: reactionAssets.frames,
            reactionFrameDurations: reactionAssets.durations,
            stableSpriteBounds: PetSpriteVisibility.stableVisibleBounds(in: frames, spriteSize: spriteSize)
        )
    }

    private static func loadFrames(from petBundle: PetBundle) throws -> [PetAnimation: [CGImage]] {
        guard
            let source = CGImageSourceCreateWithURL(petBundle.spritesheetURL as CFURL, nil),
            let spritesheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OpenPetsError.invalidSpritesheet(petBundle.spritesheetURL)
        }

        var frames: [PetAnimation: [CGImage]] = [:]
        for animation in PetAnimation.allCases {
            let row = animation.row
            frames[animation] = (0..<animation.frameCount).compactMap { column in
                let rect = CGRect(
                    x: column * petBundle.atlas.cellWidth,
                    y: row * petBundle.atlas.cellHeight,
                    width: petBundle.atlas.cellWidth,
                    height: petBundle.atlas.cellHeight
                )
                return spritesheet.cropping(to: rect)
            }
        }

        return frames
    }

    private static func loadReactionFrames(
        from petBundle: PetBundle
    ) throws -> (frames: [OpenPetsPetReactionKind: [CGImage]], durations: [OpenPetsPetReactionKind: [Int]]) {
        var framesByReaction: [OpenPetsPetReactionKind: [CGImage]] = [:]
        var durationsByReaction: [OpenPetsPetReactionKind: [Int]] = [:]

        for reaction in petBundle.manifest.reactionAnimations {
            guard
                let spritesheetPath = reaction.spritesheetPath,
                let row = reaction.row,
                let frameCount = reaction.frameCount,
                frameCount > 0
            else {
                continue
            }

            let spritesheetURL = petBundle.directoryURL.appendingPathComponent(spritesheetPath)
            guard
                let source = CGImageSourceCreateWithURL(spritesheetURL as CFURL, nil),
                let spritesheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                continue
            }

            guard
                spritesheet.width % petBundle.atlas.cellWidth == 0,
                spritesheet.height % petBundle.atlas.cellHeight == 0,
                row >= 0,
                (row + 1) * petBundle.atlas.cellHeight <= spritesheet.height,
                frameCount * petBundle.atlas.cellWidth <= spritesheet.width
            else {
                continue
            }

            let images = (0..<frameCount).compactMap { column in
                spritesheet.cropping(to: CGRect(
                    x: column * petBundle.atlas.cellWidth,
                    y: row * petBundle.atlas.cellHeight,
                    width: petBundle.atlas.cellWidth,
                    height: petBundle.atlas.cellHeight
                ))
            }
            guard !images.isEmpty else { continue }
            framesByReaction[reaction.kind] = images
            if let durations = reaction.frameDurationsMilliseconds, !durations.isEmpty {
                durationsByReaction[reaction.kind] = durations
            } else {
                durationsByReaction[reaction.kind] = Array(repeating: 150, count: images.count)
            }
        }

        return (framesByReaction, durationsByReaction)
    }
}
