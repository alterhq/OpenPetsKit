import AppKit
import CoreGraphics
import Foundation
@testable import OpenPetsKit
import XCTest

final class OpenPetsCloudSurfaceTests: XCTestCase {
    func testDecodesCloudSurfaceUpdateWithClickDetail() throws {
        let update = try decodeSurfaceUpdate(
            """
            {
              "type": "surface.update",
              "surfaceID": "battery.badge",
              "slotPreference": ["hotspot.topTrailing"],
              "priority": 40,
              "icon": "battery.75",
              "value": "62%",
              "label": "Battery",
              "tone": "normal",
              "detail": {
                "title": "Battery",
                "rows": [
                  {
                    "label": "Charge",
                    "value": "62%",
                    "tone": "normal"
                  },
                  {
                    "label": "State",
                    "value": "Battery"
                  }
                ],
                "ttlSeconds": 8
              }
            }
            """
        )

        XCTAssertEqual(update.surfaceID, "battery.badge")
        XCTAssertEqual(update.slotPreference, [.hotspotTopTrailing])
        XCTAssertEqual(update.priority, 40)
        XCTAssertEqual(update.icon, "battery.75")
        XCTAssertEqual(update.value, "62%")
        XCTAssertEqual(update.label, "Battery")
        XCTAssertEqual(update.tone, .normal)
        XCTAssertEqual(update.detail?.title, "Battery")
        XCTAssertEqual(update.detail?.rows.first?.label, "Charge")
        XCTAssertEqual(update.detail?.ttlSeconds, 8)
    }

    func testCloudSurfaceUpdateRoundTrips() throws {
        let update = OpenPetsSurfaceUpdate(
            surfaceID: "claude.5h",
            slotPreference: [.hotspotTopLeading],
            priority: 80,
            icon: OpenPetsSurfaceIcons.sparkles,
            value: "42%",
            label: "Claude 5h",
            tone: .warning,
            detail: OpenPetsSurfaceDetailData(title: "Claude", rows: [
                OpenPetsSurfaceDetailRow(label: "5h", value: "42%", tone: .warning)
            ], ttlSeconds: 8)
        )

        let data = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(OpenPetsSurfaceUpdate.self, from: data)

        XCTAssertEqual(decoded, update)
    }

    func testExampleCloudSurfaceIconsAreSFSymbolNames() {
        XCTAssertTrue(OpenPetsSurfaceIcons.examples.contains("battery.75"))
        XCTAssertTrue(OpenPetsSurfaceIcons.examples.contains("bolt.fill"))
        XCTAssertTrue(OpenPetsSurfaceIcons.examples.contains("gauge"))
        XCTAssertEqual(Set(OpenPetsSurfaceIcons.examples).count, OpenPetsSurfaceIcons.examples.count)
    }

    func testDecodesPetReactionUpdateWithTTL() throws {
        let data = Data(
            """
            {
              "type": "pet.reaction",
              "reactionID": "battery.low-energy",
              "kind": "low-energy",
              "priority": 90,
              "ttlSeconds": 4
            }
            """.utf8
        )

        let update = try JSONDecoder().decode(OpenPetsPetReactionUpdate.self, from: data)

        XCTAssertEqual(update.reactionID, "battery.low-energy")
        XCTAssertEqual(update.kind, .lowEnergy)
        XCTAssertEqual(update.priority, 90)
        XCTAssertEqual(update.ttlSeconds, 4)
    }

    func testPlacementResolverAssignsCloudSlotsByPriorityAndCollapsesOverflow() {
        let resolver = OpenPetsSurfacePlacementResolver(slotOrder: [.hotspotTopTrailing, .hotspotLeft])
        let highPriority = cloudUpdate(surfaceID: "claude.5h", priority: 90)
        let mediumPriority = cloudUpdate(surfaceID: "codex.usage", priority: 40)
        let lowPriority = cloudUpdate(surfaceID: "battery.percent", priority: 10)

        let resolved = resolver.resolve([lowPriority, highPriority, mediumPriority])

        XCTAssertEqual(resolved.map(\.update.surfaceID), ["battery.percent", "claude.5h", "codex.usage"])
        XCTAssertEqual(resolved[1].placement, .placed(.hotspotTopTrailing))
        XCTAssertEqual(resolved[2].placement, .placed(.hotspotLeft))
        XCTAssertEqual(resolved[0].placement, .hidden(reason: "No compatible slot available"))
    }

    func testPlacementResolverUsesHotspotSlotsByDefault() {
        let resolver = OpenPetsSurfacePlacementResolver()
        let update = cloudUpdate(surfaceID: "battery.badge", priority: 10)

        let resolved = resolver.resolve([update])

        XCTAssertEqual(resolved.first?.placement, .placed(.hotspotTopTrailing))
    }

    func testPlacementResolverRejectsDuplicateSurfaceIDsWithoutOccupyingSlots() {
        let resolver = OpenPetsSurfacePlacementResolver()
        let duplicateA = cloudUpdate(surfaceID: "claude.5h", priority: 90)
        let duplicateB = cloudUpdate(surfaceID: "claude.5h", priority: 80)
        let unrelated = cloudUpdate(surfaceID: "codex.usage", priority: 10)

        let resolved = resolver.resolve([duplicateA, unrelated, duplicateB])

        XCTAssertEqual(resolved.map(\.update.surfaceID), ["claude.5h", "codex.usage", "claude.5h"])
        XCTAssertEqual(resolved[0].placement, .rejected(.duplicateSurfaceID("claude.5h")))
        XCTAssertEqual(resolved[1].placement, .placed(.hotspotTopTrailing))
        XCTAssertEqual(resolved[2].placement, .rejected(.duplicateSurfaceID("claude.5h")))
    }

    func testPlacementResolverRejectsUnsupportedMessageType() {
        let resolver = OpenPetsSurfacePlacementResolver()
        let update = OpenPetsSurfaceUpdate(
            type: "surface.future",
            surfaceID: "battery.badge",
            icon: OpenPetsSurfaceIcons.battery75,
            value: "68%"
        )

        let resolved = resolver.resolve([update])

        XCTAssertEqual(resolved.first?.placement, .rejected(.unsupportedMessageType("surface.future")))
    }

    @MainActor
    func testHostSessionResolvesSurfaceUpdatesWhenPetIsNotRunning() {
        let session = OpenPetsHostSession(configuration: OpenPetsHostConfiguration(
            petDirectoryURL: URL(fileURLWithPath: "/tmp/missing-openpets-pet")
        ))

        let resolved = session.setSurfaceUpdates([
            cloudUpdate(surfaceID: "claude.5h", priority: 50)
        ])

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.placement, .placed(.hotspotTopTrailing))
    }

    func testHotspotVisibilityProgressesWithDistance() {
        XCTAssertEqual(OpenPetsHotspotVisibility(distance: .infinity).opacity, 0.035, accuracy: 0.001)
        XCTAssertEqual(OpenPetsHotspotVisibility(distance: 120).compactProgress, 0, accuracy: 0.001)
        XCTAssertGreaterThan(OpenPetsHotspotVisibility(distance: 64).opacity, 0.035)
        XCTAssertGreaterThan(OpenPetsHotspotVisibility(distance: 80).compactProgress, 0)
        XCTAssertLessThan(OpenPetsHotspotVisibility(distance: 80).compactProgress, 1)
        XCTAssertEqual(OpenPetsHotspotVisibility(distance: 22).compactProgress, 1, accuracy: 0.001)
    }

    func testHotspotVisibilityCanRevealPositionWithoutCursorProximity() {
        let visibility = OpenPetsHotspotVisibility(distance: .infinity, positionRevealProgress: 0.75)

        XCTAssertEqual(visibility.opacity, 0.75875, accuracy: 0.001)
        XCTAssertEqual(visibility.compactProgress, 0.75, accuracy: 0.001)
    }

    func testSurfaceRevealPhaseStartsHoldsAndDissolves() {
        let start = OpenPetsSurfaceRevealPhase(progress: 0)
        XCTAssertEqual(start.beamProgress, 0, accuracy: 0.001)
        XCTAssertEqual(start.beamOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(start.targetRevealProgress, 0, accuracy: 0.001)

        let hold = OpenPetsSurfaceRevealPhase(progress: 0.5)
        XCTAssertEqual(hold.beamProgress, 1, accuracy: 0.001)
        XCTAssertEqual(hold.beamOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(hold.targetRevealProgress, 1, accuracy: 0.001)

        let lateHold = OpenPetsSurfaceRevealPhase(progress: 0.97)
        XCTAssertEqual(lateHold.beamOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(lateHold.targetRevealProgress, 1, accuracy: 0.001)

        let end = OpenPetsSurfaceRevealPhase(progress: 1)
        XCTAssertEqual(end.beamProgress, 1, accuracy: 0.001)
        XCTAssertEqual(end.beamOpacity, 0, accuracy: 0.001)
        XCTAssertEqual(end.targetRevealProgress, 0, accuracy: 0.001)
    }

    func testSurfaceRevealMakesTargetsReadableWithoutChangingNonTargets() {
        let phase = OpenPetsSurfaceRevealPhase(progress: 0.5)
        let targetVisibility = OpenPetsHotspotVisibility(
            distance: .infinity,
            positionRevealProgress: phase.targetRevealProgress
        )
        let nonTargetVisibility = OpenPetsHotspotVisibility(distance: .infinity)

        XCTAssertEqual(targetVisibility.compactProgress, 1, accuracy: 0.001)
        XCTAssertEqual(targetVisibility.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(nonTargetVisibility.compactProgress, 0, accuracy: 0.001)
        XCTAssertEqual(nonTargetVisibility.opacity, OpenPetsHotspotVisibility.defaultAlpha, accuracy: 0.001)
    }

    func testSurfaceRevealGeometrySendsBeamFromPetToTargetHotspots() {
        let petFrame = CGRect(x: 180, y: 180, width: 40, height: 40)
        let targetFrames = [
            "battery.badge": CGRect(x: 260, y: 280, width: 80, height: 30),
            "codex.primary": CGRect(x: 70, y: 285, width: 80, height: 30)
        ]

        let start = OpenPetsSurfaceRevealGeometry(progress: 0, petFrame: petFrame, targetFrames: targetFrames)
        XCTAssertEqual(start.origin.x, petFrame.midX, accuracy: 0.001)
        XCTAssertEqual(start.origin.y, petFrame.midY, accuracy: 0.001)
        for (surfaceID, target) in start.targetCenters {
            XCTAssertEqual(start.beamPoint(for: target, surfaceID: surfaceID).x, petFrame.midX, accuracy: 0.001)
            XCTAssertEqual(start.beamPoint(for: target, surfaceID: surfaceID).y, petFrame.midY, accuracy: 0.001)
        }

        let arrived = OpenPetsSurfaceRevealGeometry(progress: 0.12, petFrame: petFrame, targetFrames: targetFrames)
        XCTAssertTrue(arrived.isVisible)
        for (surfaceID, target) in arrived.targetCenters {
            XCTAssertEqual(arrived.beamPoint(for: target, surfaceID: surfaceID).x, target.x, accuracy: 0.001)
            XCTAssertEqual(arrived.beamPoint(for: target, surfaceID: surfaceID).y, target.y, accuracy: 0.001)
        }
    }

    func testSurfaceRevealStaggersMultipleTargetStartTimes() {
        let surfaceIDs: Set<String> = ["battery.badge", "claude.primary", "codex.usage"]
        let offsets = OpenPetsSurfaceRevealState.startOffsets(for: surfaceIDs)

        XCTAssertEqual(offsets.count, surfaceIDs.count)
        XCTAssertEqual(Set(offsets.values).count, surfaceIDs.count)
        XCTAssertEqual(offsets.values.min()!, 0, accuracy: 0.001)
        XCTAssertEqual(offsets.values.max()!, OpenPetsSurfaceRevealState.maximumStartOffset, accuracy: 0.001)

        let delayedSurfaceID = offsets.max { $0.value < $1.value }!.key
        let state = OpenPetsSurfaceRevealState(
            progress: OpenPetsSurfaceRevealState.maximumStartOffset / 2,
            targetSurfaceIDs: surfaceIDs,
            startOffsetsBySurfaceID: offsets
        )

        XCTAssertEqual(state.progress(for: delayedSurfaceID), 0, accuracy: 0.001)
    }

    func testHotspotHitFrameExpandsFromMinimalGlowToVisibleCloud() {
        let widgetFrame = CGRect(
            origin: CGPoint(x: 10, y: 20),
            size: OpenPetsSurfaceHotspotLayout.widgetSize
        )

        let hiddenHitFrame = OpenPetsSurfaceHotspotLayout.hitFrame(
            for: widgetFrame,
            visibility: OpenPetsHotspotVisibility(distance: .infinity)
        )
        let fullHitFrame = OpenPetsSurfaceHotspotLayout.hitFrame(
            for: widgetFrame,
            visibility: OpenPetsHotspotVisibility(distance: 0)
        )

        XCTAssertEqual(hiddenHitFrame.width, OpenPetsSurfaceHotspotLayout.minimalHitSize.width, accuracy: 0.001)
        XCTAssertEqual(hiddenHitFrame.height, OpenPetsSurfaceHotspotLayout.minimalHitSize.height, accuracy: 0.001)
        XCTAssertEqual(hiddenHitFrame.midX, widgetFrame.midX, accuracy: 0.001)
        XCTAssertEqual(hiddenHitFrame.midY, widgetFrame.midY, accuracy: 0.001)
        XCTAssertEqual(fullHitFrame.width, OpenPetsSurfaceHotspotLayout.revealedHitSize.width, accuracy: 0.001)
        XCTAssertEqual(fullHitFrame.height, OpenPetsSurfaceHotspotLayout.revealedHitSize.height, accuracy: 0.001)
        XCTAssertEqual(fullHitFrame.midX, widgetFrame.midX, accuracy: 0.001)
        XCTAssertEqual(fullHitFrame.midY, widgetFrame.midY, accuracy: 0.001)
    }

    func testHotspotLayoutClampsWidgetInsidePanel() {
        let frame = OpenPetsSurfaceHotspotLayout.frame(
            for: .hotspotTopTrailing,
            petFrame: CGRect(x: 80, y: 80, width: 20, height: 20),
            panelSize: CGSize(width: 220, height: 220)
        )

        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 220)
        XCTAssertLessThanOrEqual(frame.maxY, 220)
    }

    func testHotspotDistanceIsLocalToWidgetCenterNotWholePetFrame() {
        let petFrame = CGRect(x: 96, y: 96, width: 40, height: 40)
        let hotspotFrame = OpenPetsSurfaceHotspotLayout.frame(
            for: .hotspotTopTrailing,
            petFrame: petFrame,
            panelSize: CGSize(width: 360, height: 360)
        )
        let pointInsidePet = CGPoint(x: petFrame.midX, y: petFrame.midY)

        XCTAssertEqual(OpenPetsSurfaceHotspotLayout.distance(from: pointInsidePet, to: petFrame), 0, accuracy: 0.001)
        XCTAssertGreaterThan(OpenPetsSurfaceHotspotLayout.hotspotDistance(from: pointInsidePet, to: hotspotFrame), 22)
        XCTAssertEqual(
            OpenPetsHotspotVisibility(
                distance: OpenPetsSurfaceHotspotLayout.hotspotDistance(from: pointInsidePet, to: hotspotFrame)
            ).compactProgress,
            0,
            accuracy: 0.01
        )
    }

    func testPetSurfacePaletteExtractsFarVisibleColors() throws {
        let image = try makeImage(width: 8, height: 1, pixels: [
            (255, 210, 0, 255),
            (255, 210, 0, 255),
            (255, 210, 0, 255),
            (255, 210, 0, 255),
            (240, 190, 0, 255),
            (240, 190, 0, 255),
            (240, 190, 0, 255),
            (90, 30, 180, 255)
        ])

        let palette = try XCTUnwrap(OpenPetsPetSurfacePalette.extract(from: image))

        XCTAssertGreaterThan(palette.primary.red, 0.8)
        XCTAssertGreaterThan(palette.primary.green, 0.6)
        XCTAssertLessThan(palette.primary.blue, 0.2)
        XCTAssertGreaterThan(palette.accent.distance(to: palette.primary), 0.45)
        XCTAssertGreaterThan(palette.accent.blue, 0.45)
        XCTAssertLessThan(palette.accent.green, 0.35)
    }

    func testPetSurfacePalettePrefersComplementaryHueOverDominantDarkSameHue() throws {
        let image = try makeImage(width: 10, height: 1, pixels: [
            (255, 218, 18, 255),
            (255, 218, 18, 255),
            (255, 218, 18, 255),
            (255, 218, 18, 255),
            (190, 138, 0, 255),
            (190, 138, 0, 255),
            (190, 138, 0, 255),
            (190, 138, 0, 255),
            (116, 54, 205, 255),
            (116, 54, 205, 255)
        ])

        let palette = try XCTUnwrap(OpenPetsPetSurfacePalette.extract(from: image))

        XCTAssertGreaterThan(palette.primary.red, 0.70)
        XCTAssertGreaterThan(palette.primary.green, 0.50)
        XCTAssertLessThan(palette.primary.blue, 0.2)
        XCTAssertGreaterThan(palette.accent.blue, 0.5)
        XCTAssertGreaterThan(palette.accent.hueDistance(to: palette.primary), 0.22)
    }

    func testPetSurfacePaletteIgnoresTransparentPixels() throws {
        let image = try makeImage(width: 2, height: 1, pixels: [
            (255, 0, 0, 0),
            (0, 0, 255, 255)
        ])

        let palette = try XCTUnwrap(OpenPetsPetSurfacePalette.extract(from: image))

        XCTAssertLessThan(palette.primary.red, 0.2)
        XCTAssertLessThan(palette.primary.green, 0.2)
        XCTAssertGreaterThan(palette.primary.blue, 0.8)
    }

    func testPetSurfacePaletteFallsBackForTransparentFrames() throws {
        let image = try makeImage(width: 2, height: 1, pixels: [
            (255, 0, 0, 0),
            (0, 0, 255, 0)
        ])

        XCTAssertNil(OpenPetsPetSurfacePalette.extract(from: image))
        XCTAssertEqual(OpenPetsPetSurfacePalette.extract(from: [.idle: [image]]), .fallback)
    }

    @MainActor
    func testSurfacePanelDoesNotHitTestCloudHotspotsOrBackground() throws {
        let view = PetSurfacePanelView()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        let resolved = OpenPetsSurfacePlacementResolver().resolve([
            cloudUpdate(surfaceID: "battery.badge", slotPreference: [.hotspotTopTrailing])
        ])

        view.set(resolvedSurfaces: resolved)
        view.resizeWindow(aroundPetFrame: CGRect(x: 100, y: 200, width: 10, height: 10))

        XCTAssertTrue(view.hasVisibleSurfaces)
        XCTAssertGreaterThan(panel.frame.width, 10)
        XCTAssertGreaterThan(panel.frame.height, 10)
        XCTAssertEqual(panel.frame.midX, 105, accuracy: 0.5)
        XCTAssertEqual(panel.frame.midY, 205, accuracy: 0.5)
        XCTAssertNil(view.hitTest(CGPoint(x: 5, y: 5)))
        XCTAssertNil(view.hitTest(CGPoint(x: 101, y: 101)))
        XCTAssertNil(view.hitTest(CGPoint(x: 148, y: 88)))
    }

    @MainActor
    func testSurfacePanelDoesNotSelectHotspotFromPetFrame() throws {
        let view = PetSurfacePanelView()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        let resolved = OpenPetsSurfacePlacementResolver().resolve([
            cloudUpdate(surfaceID: "battery.badge", slotPreference: [.hotspotTopTrailing])
        ])
        var selectedSurfaceID: String?
        view.onSelectSurface = { selectedSurfaceID = $0.update.surfaceID }

        view.set(resolvedSurfaces: resolved)
        view.resizeWindow(aroundPetFrame: CGRect(x: 100, y: 200, width: 40, height: 40))

        XCTAssertFalse(view.selectSurface(atScreenPoint: CGPoint(x: 139, y: 218)))
        XCTAssertNil(selectedSurfaceID)
    }

    @MainActor
    func testSurfacePanelSelectsHotspotAtRenderedTopRightNotMirroredBottomRight() throws {
        let view = PetSurfacePanelView()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        let resolved = OpenPetsSurfacePlacementResolver().resolve([
            cloudUpdate(surfaceID: "battery.badge", slotPreference: [.hotspotTopTrailing])
        ])
        var selectedSurfaceID: String?
        view.onSelectSurface = { selectedSurfaceID = $0.update.surfaceID }

        view.set(resolvedSurfaces: resolved)
        view.resizeWindow(aroundPetFrame: CGRect(x: 100, y: 200, width: 100, height: 100))

        XCTAssertFalse(view.selectSurface(atScreenPoint: CGPoint(x: 273, y: 218)))
        XCTAssertNil(selectedSurfaceID)
        XCTAssertTrue(view.selectSurface(atScreenPoint: CGPoint(x: 273, y: 282)))
        XCTAssertEqual(selectedSurfaceID, "battery.badge")
    }

    @MainActor
    func testSurfacePanelShowsContextMenuForHotspotWithoutSelectingIt() throws {
        let view = PetSurfacePanelView()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        let resolved = OpenPetsSurfacePlacementResolver().resolve([
            cloudUpdate(surfaceID: "battery.badge", slotPreference: [.hotspotTopTrailing])
        ])
        var selectedSurfaceID: String?
        var contextSurfaceID: String?
        view.onSelectSurface = { selectedSurfaceID = $0.update.surfaceID }
        view.onContextMenuSurface = { surface, _ in contextSurfaceID = surface.update.surfaceID }

        view.set(resolvedSurfaces: resolved)
        view.resizeWindow(aroundPetFrame: CGRect(x: 100, y: 200, width: 100, height: 100))

        XCTAssertTrue(view.showContextMenu(atScreenPoint: CGPoint(x: 273, y: 282)))
        XCTAssertNil(selectedSurfaceID)
        XCTAssertEqual(contextSurfaceID, "battery.badge")
    }

    @MainActor
    func testSurfacePanelDoesNotShowContextMenuFromPetFrameOrEmptySpace() throws {
        let view = PetSurfacePanelView()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        defer { panel.close() }

        let resolved = OpenPetsSurfacePlacementResolver().resolve([
            cloudUpdate(surfaceID: "battery.badge", slotPreference: [.hotspotTopTrailing])
        ])
        var contextSurfaceID: String?
        view.onContextMenuSurface = { surface, _ in contextSurfaceID = surface.update.surfaceID }

        view.set(resolvedSurfaces: resolved)
        view.resizeWindow(aroundPetFrame: CGRect(x: 100, y: 200, width: 100, height: 100))

        XCTAssertFalse(view.showContextMenu(atScreenPoint: CGPoint(x: 139, y: 218)))
        XCTAssertFalse(view.showContextMenu(atScreenPoint: CGPoint(x: 80, y: 180)))
        XCTAssertNil(contextSurfaceID)
    }

    private func decodeSurfaceUpdate(_ json: String) throws -> OpenPetsSurfaceUpdate {
        try JSONDecoder().decode(OpenPetsSurfaceUpdate.self, from: Data(json.utf8))
    }

    private func cloudUpdate(
        surfaceID: String,
        slotPreference: [OpenPetsSurfaceSlot] = [],
        priority: Int = 0
    ) -> OpenPetsSurfaceUpdate {
        OpenPetsSurfaceUpdate(
            surfaceID: surfaceID,
            slotPreference: slotPreference,
            priority: priority,
            icon: OpenPetsSurfaceIcons.sparkles,
            value: "42%",
            label: "Usage"
        )
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixels: [(UInt8, UInt8, UInt8, UInt8)]
    ) throws -> CGImage {
        precondition(pixels.count == width * height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let data = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        guard
            let provider = CGDataProvider(data: Data(data) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw XCTSkip("Could not create test image")
        }
        return image
    }
}
