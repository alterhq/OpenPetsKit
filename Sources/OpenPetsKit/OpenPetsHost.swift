import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

public struct OpenPetsHostConfiguration: Sendable {
    public var petDirectoryURL: URL
    public var socketPath: String
    public var display: OpenPetsDisplayConfiguration
    public var positionStoreURL: URL

    public var scale: CGFloat {
        get { display.scale }
        set { display.scale = newValue }
    }

    public init(
        petDirectoryURL: URL,
        socketPath: String = OpenPetsPaths.defaultSocketPath,
        display: OpenPetsDisplayConfiguration = .default,
        positionStoreURL: URL = OpenPetsPaths.defaultPositionStoreURL
    ) {
        self.petDirectoryURL = petDirectoryURL
        self.socketPath = socketPath
        self.display = display
        self.positionStoreURL = positionStoreURL
    }

    public init(
        petDirectoryURL: URL,
        socketPath: String = OpenPetsPaths.defaultSocketPath,
        scale: CGFloat,
        positionStoreURL: URL = OpenPetsPaths.defaultPositionStoreURL
    ) {
        self.init(
            petDirectoryURL: petDirectoryURL,
            socketPath: socketPath,
            display: OpenPetsDisplayConfiguration(scale: scale),
            positionStoreURL: positionStoreURL
        )
    }
}

public typealias OpenPetsSurfaceContextMenuProvider = @MainActor (OpenPetsResolvedSurface) -> NSMenu?

struct PetLaunchMotion {
    struct Step {
        var origin: CGPoint
        var velocity: CGVector
        var animation: PetAnimation
        var shouldStop: Bool
    }

    static let launchSpeedThreshold: CGFloat = 650
    static let stopSpeedThreshold: CGFloat = 45
    static let minimumHorizontalAnimationSpeed: CGFloat = 15
    static let frameInterval: TimeInterval = 1.0 / 60.0
    private static let decelerationRate: CGFloat = 3.8

    static func shouldLaunch(velocity: CGVector) -> Bool {
        speed(of: velocity) >= launchSpeedThreshold
    }

    static func animation(for velocity: CGVector, fallback: PetAnimation) -> PetAnimation {
        if velocity.dx > minimumHorizontalAnimationSpeed {
            return .runningRight
        }
        if velocity.dx < -minimumHorizontalAnimationSpeed {
            return .runningLeft
        }
        return fallback == .runningLeft ? .runningLeft : .runningRight
    }

    static func step(
        origin: CGPoint,
        velocity: CGVector,
        movingFrame: CGRect,
        visibleFrame: CGRect,
        fallbackAnimation: PetAnimation,
        deltaTime: TimeInterval
    ) -> Step {
        var nextOrigin = CGPoint(
            x: origin.x + velocity.dx * deltaTime,
            y: origin.y + velocity.dy * deltaTime
        )
        var nextVelocity = velocity
        let minimumOrigin = CGPoint(
            x: visibleFrame.minX - movingFrame.minX,
            y: visibleFrame.minY - movingFrame.minY
        )
        let maximumOrigin = CGPoint(
            x: visibleFrame.maxX - movingFrame.maxX,
            y: visibleFrame.maxY - movingFrame.maxY
        )

        if nextOrigin.x < minimumOrigin.x {
            nextOrigin.x = minimumOrigin.x
            if nextVelocity.dx < 0 {
                nextVelocity.dx = 0
            }
        } else if nextOrigin.x > maximumOrigin.x {
            nextOrigin.x = maximumOrigin.x
            if nextVelocity.dx > 0 {
                nextVelocity.dx = 0
            }
        }

        if nextOrigin.y < minimumOrigin.y {
            nextOrigin.y = minimumOrigin.y
            if nextVelocity.dy < 0 {
                nextVelocity.dy = 0
            }
        } else if nextOrigin.y > maximumOrigin.y {
            nextOrigin.y = maximumOrigin.y
            if nextVelocity.dy > 0 {
                nextVelocity.dy = 0
            }
        }

        let decay = exp(-decelerationRate * deltaTime)
        nextVelocity.dx *= decay
        nextVelocity.dy *= decay

        return Step(
            origin: nextOrigin,
            velocity: nextVelocity,
            animation: animation(for: nextVelocity, fallback: fallbackAnimation),
            shouldStop: speed(of: nextVelocity) < stopSpeedThreshold
        )
    }

    private static func speed(of velocity: CGVector) -> CGFloat {
        hypot(velocity.dx, velocity.dy)
    }
}

struct PetCallMotion {
    static let frameIntervalNanoseconds: UInt64 = 16_666_667
    private static let minimumDuration: TimeInterval = 0.28
    private static let maximumDuration: TimeInterval = 0.9
    private static let pointsPerSecond: CGFloat = 900

    static func duration(from origin: CGPoint, to targetOrigin: CGPoint) -> TimeInterval {
        let distance = hypot(targetOrigin.x - origin.x, targetOrigin.y - origin.y)
        return min(max(TimeInterval(distance / pointsPerSecond), minimumDuration), maximumDuration)
    }

    static func origin(from origin: CGPoint, to targetOrigin: CGPoint, progress: CGFloat) -> CGPoint {
        let progress = min(max(progress, 0), 1)
        let easedProgress = 1 - pow(1 - progress, 3)
        return CGPoint(
            x: origin.x + (targetOrigin.x - origin.x) * easedProgress,
            y: origin.y + (targetOrigin.y - origin.y) * easedProgress
        )
    }

    static func animation(from origin: CGPoint, to targetOrigin: CGPoint, fallback: PetAnimation) -> PetAnimation {
        let deltaX = targetOrigin.x - origin.x
        if deltaX > PetLaunchMotion.minimumHorizontalAnimationSpeed {
            return .runningRight
        }
        if deltaX < -PetLaunchMotion.minimumHorizontalAnimationSpeed {
            return .runningLeft
        }
        return fallback == .runningLeft ? .runningLeft : .runningRight
    }
}

public enum OpenPetsHost {
    @MainActor
    public static func run(configuration: OpenPetsHostConfiguration) throws {
        let session = OpenPetsHostSession(
            configuration: configuration,
            terminatesApplicationOnShutdown: true
        )
        try session.start()
        let app = NSApplication.shared
        let delegate = OpenPetsApplicationDelegate(session: session)
        OpenPetsRuntime.current = OpenPetsRuntime(delegate: delegate)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
public final class OpenPetsHostSession {
    public private(set) var configuration: OpenPetsHostConfiguration
    public let terminatesApplicationOnShutdown: Bool
    private let contextMenuProvider: (@MainActor () -> NSMenu?)?
    private let surfaceContextMenuProvider: OpenPetsSurfaceContextMenuProvider?
    private let petAssetCache: OpenPetsPetAssetCache
    private var controller: PetHostController?
    private var server: OpenPetsServer?
    private var surfaceUpdates: [OpenPetsSurfaceUpdate] = []
    private var petReactionUpdates: [OpenPetsPetReactionUpdate] = []

    public var isRunning: Bool {
        controller != nil
    }

    public var petManifest: PetManifest? {
        controller?.petManifest
    }

    public init(
        configuration: OpenPetsHostConfiguration,
        terminatesApplicationOnShutdown: Bool = false,
        contextMenuProvider: (@MainActor () -> NSMenu?)? = nil,
        surfaceContextMenuProvider: OpenPetsSurfaceContextMenuProvider? = nil,
        petAssetCache: OpenPetsPetAssetCache = .shared
    ) {
        self.configuration = configuration
        self.terminatesApplicationOnShutdown = terminatesApplicationOnShutdown
        self.contextMenuProvider = contextMenuProvider
        self.surfaceContextMenuProvider = surfaceContextMenuProvider
        self.petAssetCache = petAssetCache
    }

    public func start() throws {
        guard !isRunning else { return }

        let petBundle = try PetBundle.load(from: configuration.petDirectoryURL)
        let petAssets = try PetHostAssets.load(from: petBundle, displayScale: configuration.display.scale)
        try start(with: petAssets)
    }

    public func startUsingCachedAssets() async throws {
        guard !isRunning else { return }

        let petAssets = try await petAssetCache.assets(
            for: configuration.petDirectoryURL,
            display: configuration.display
        )
        try start(with: petAssets)
    }

    public func switchPet(to petDirectoryURL: URL, display: OpenPetsDisplayConfiguration) async throws {
        let petAssets = try await petAssetCache.assets(for: petDirectoryURL, display: display)

        if !isRunning {
            configuration.petDirectoryURL = petDirectoryURL
            configuration.display = display
            try start(with: petAssets)
            return
        }

        let oldController = controller
        let controller = try PetHostController(
            petAssets: petAssets,
            display: display,
            positionStore: PetPositionStore(url: configuration.positionStoreURL),
            contextMenuProvider: contextMenuProvider,
            surfaceContextMenuProvider: surfaceContextMenuProvider
        )
        configuration.petDirectoryURL = petDirectoryURL
        configuration.display = display
        self.controller = controller
        oldController?.savePosition()
        oldController?.close()
        controller.show()
        _ = controller.setSurfaceUpdates(surfaceUpdates)
        controller.setPetReactionUpdates(petReactionUpdates)
    }

    private func start(with petAssets: PetHostAssets) throws {
        let controller = try PetHostController(
            petAssets: petAssets,
            display: configuration.display,
            positionStore: PetPositionStore(url: configuration.positionStoreURL),
            contextMenuProvider: contextMenuProvider,
            surfaceContextMenuProvider: surfaceContextMenuProvider
        )
        let bridge = PetHostCommandBridge(session: self)
        let server = OpenPetsServer(socketPath: configuration.socketPath) { command in
            bridge.handle(command)
        }

        do {
            try server.start()
        } catch {
            controller.close()
            throw error
        }

        self.controller = controller
        self.server = server
        controller.show()
        _ = controller.setSurfaceUpdates(surfaceUpdates)
        controller.setPetReactionUpdates(petReactionUpdates)
    }

    public func stop() {
        server?.stop()
        server = nil
        controller?.savePosition()
        controller?.close()
        controller = nil
    }

    public func callPet() {
        controller?.callPet()
    }

    @discardableResult
    public func setSurfaceUpdates(_ updates: [OpenPetsSurfaceUpdate]) -> [OpenPetsResolvedSurface] {
        surfaceUpdates = updates
        return controller?.setSurfaceUpdates(updates) ?? OpenPetsSurfacePlacementResolver().resolve(updates)
    }

    public func clearSurfaceUpdates() {
        _ = setSurfaceUpdates([])
    }

    public func revealSurfacePositions(surfaceIDs: Set<String>? = nil, duration: TimeInterval = 6.2) {
        controller?.revealSurfacePositions(surfaceIDs: surfaceIDs, duration: duration)
    }

    @discardableResult
    public func showSurfaceDetail(forSurfaceID surfaceID: String) -> Bool {
        controller?.showSurfaceDetail(forSurfaceID: surfaceID) ?? false
    }

    public func setPetReactionUpdates(_ updates: [OpenPetsPetReactionUpdate]) {
        petReactionUpdates = updates
        controller?.setPetReactionUpdates(updates)
    }

    public func clearPetReactionUpdates() {
        setPetReactionUpdates([])
    }

    @discardableResult
    public func handle(_ command: PetCommand) -> PetResponse {
        switch command {
        case .ping:
            return PetResponse(ok: isRunning, message: isRunning ? "pong" : "pet is not running")
        case .shutdown:
            stop()
            if terminatesApplicationOnShutdown {
                NSApplication.shared.terminate(nil)
            }
            return PetResponse(ok: true, message: "shutting down")
        case .notify(let notification):
            guard let controller else {
                return PetResponse(ok: false, message: "pet is not running")
            }
            let resolvedNotification = notification.resolvingThreadId()
            controller.apply(.notify(resolvedNotification))
            return PetResponse(ok: true, threadId: resolvedNotification.threadId)
        default:
            guard let controller else {
                return PetResponse(ok: false, message: "pet is not running")
            }
            controller.apply(command)
            return PetResponse(ok: true)
        }
    }

    public func apply(_ command: PetCommand) -> PetResponse {
        handle(command)
    }
}

@MainActor
private final class OpenPetsRuntime {
    static var current: OpenPetsRuntime?
    let delegate: OpenPetsApplicationDelegate

    init(delegate: OpenPetsApplicationDelegate) {
        self.delegate = delegate
    }
}

@MainActor
private final class OpenPetsApplicationDelegate: NSObject, NSApplicationDelegate {
    let session: OpenPetsHostSession

    init(session: OpenPetsHostSession) {
        self.session = session
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }
}

private final class PetHostCommandBridge: @unchecked Sendable {
    @MainActor private let session: OpenPetsHostSession

    @MainActor
    init(session: OpenPetsHostSession) {
        self.session = session
    }

    func handle(_ command: PetCommand) -> PetResponse {
        let response: PetResponse
        switch command {
        case .ping:
            response = PetResponse(ok: true, message: "pong")
        case .shutdown:
            response = PetResponse(ok: true, message: "shutting down")
        case .notify(let notification):
            let resolvedNotification = notification.resolvingThreadId()
            response = PetResponse(ok: true, threadId: resolvedNotification.threadId)
            DispatchQueue.main.async { [self] in
                Task { @MainActor in
                    session.handle(.notify(resolvedNotification))
                }
            }
            return response
        default:
            response = PetResponse(ok: true)
        }

        DispatchQueue.main.async { [self] in
            Task { @MainActor in
                session.handle(command)
            }
        }
        return response
    }
}

@MainActor
struct PetWindowPositioning {
    static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)

    static func windowOrigin(preservingPetAnchor petAnchor: CGPoint, petFrame: CGRect) -> CGPoint {
        CGPoint(
            x: petAnchor.x - petFrame.minX,
            y: petAnchor.y - petFrame.minY
        )
    }

    static func legacyContentSize(spriteSize: CGSize, messageAreaHeight: CGFloat) -> CGSize {
        CGSize(
            width: max(316, spriteSize.width + 120),
            height: spriteSize.height + messageAreaHeight
        )
    }

    static func initialWindowOrigin(
        storedPosition: StoredPetPosition?,
        legacyContentSize: CGSize,
        spriteSize: CGSize,
        stableSpriteBounds: CGRect,
        petFrame: CGRect,
        preferredVisibleFrame: CGRect,
        activeVisibleFrames: [CGRect]
    ) -> CGPoint {
        let defaultOrigin = defaultWindowOrigin(contentSize: legacyContentSize, visibleFrame: preferredVisibleFrame)
        let initialAnchor = initialPetAnchor(
            storedPosition: storedPosition,
            legacyContentSize: legacyContentSize,
            spriteSize: spriteSize,
            stableSpriteBounds: stableSpriteBounds,
            defaultWindowOrigin: defaultOrigin
        )
        let initialOrigin = windowOrigin(preservingPetAnchor: initialAnchor, petFrame: petFrame)

        guard isVisible(screenFrame(windowOrigin: initialOrigin, petFrame: petFrame), in: activeVisibleFrames) else {
            let defaultAnchor = initialPetAnchor(
                storedPosition: nil,
                legacyContentSize: legacyContentSize,
                spriteSize: spriteSize,
                stableSpriteBounds: stableSpriteBounds,
                defaultWindowOrigin: defaultOrigin
            )
            return windowOrigin(preservingPetAnchor: defaultAnchor, petFrame: petFrame)
        }

        return initialOrigin
    }

    static func initialPetAnchor(
        storedPosition: StoredPetPosition?,
        legacyContentSize: CGSize,
        spriteSize: CGSize,
        stableSpriteBounds: CGRect,
        defaultWindowOrigin: CGPoint? = nil
    ) -> CGPoint {
        if let storedPosition {
            switch storedPosition.kind {
            case .petAnchor:
                return storedPosition.point
            case .windowOrigin:
                let legacySpriteFrame = legacySpriteFrame(
                    contentSize: legacyContentSize,
                    spriteSize: spriteSize
                )
                return CGPoint(
                    x: storedPosition.point.x + legacySpriteFrame.minX + stableSpriteBounds.minX,
                    y: storedPosition.point.y + legacySpriteFrame.minY + stableSpriteBounds.minY
                )
            }
        }

        let defaultOrigin = defaultWindowOrigin ?? self.defaultWindowOrigin(contentSize: legacyContentSize)
        let legacySpriteFrame = legacySpriteFrame(contentSize: legacyContentSize, spriteSize: spriteSize)
        return CGPoint(
            x: defaultOrigin.x + legacySpriteFrame.minX + stableSpriteBounds.minX,
            y: defaultOrigin.y + legacySpriteFrame.minY + stableSpriteBounds.minY
        )
    }

    static func legacySpriteFrame(contentSize: CGSize, spriteSize: CGSize) -> CGRect {
        CGRect(
            x: contentSize.width - spriteSize.width - OpenPetsMessageLayout.sideInset,
            y: 0,
            width: spriteSize.width,
            height: spriteSize.height
        )
    }

    static func defaultWindowOrigin(contentSize: CGSize) -> CGPoint {
        defaultWindowOrigin(contentSize: contentSize, visibleFrame: preferredVisibleFrame())
    }

    static func defaultWindowOrigin(contentSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - contentSize.width - 40,
            y: visibleFrame.minY + 40
        )
    }

    static func preferredVisibleFrame() -> CGRect {
        preferredVisibleFrame(
            mainVisibleFrame: NSScreen.main?.visibleFrame,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    static func activeVisibleFrames() -> [CGRect] {
        let frames = NSScreen.screens.map(\.visibleFrame)
        return frames.isEmpty ? [fallbackVisibleFrame] : frames
    }

    static func preferredVisibleFrame(mainVisibleFrame: CGRect?, screenVisibleFrames: [CGRect]) -> CGRect {
        mainVisibleFrame ?? screenVisibleFrames.first ?? fallbackVisibleFrame
    }

    static func screenFrame(windowOrigin: CGPoint, petFrame: CGRect) -> CGRect {
        CGRect(
            x: windowOrigin.x + petFrame.minX,
            y: windowOrigin.y + petFrame.minY,
            width: petFrame.width,
            height: petFrame.height
        )
    }

    static func isVisible(_ frame: CGRect, in visibleFrames: [CGRect]) -> Bool {
        visibleFrames.contains { visibleFrame in
            frame.intersects(visibleFrame)
        }
    }
}

@MainActor
private enum ResolvedPetReactionAnimation: Equatable {
    case standard(PetAnimation)
    case custom(OpenPetsPetReactionKind)
}

@MainActor
private final class PetHostController {
    private let petBundle: PetBundle
    private let positionStore: PetPositionStore
    private let window: NSPanel
    private let petView: PetHostView
    private let messagePanel: NSPanel
    private let messageView: PetMessagePanelView
    private let surfacePanel: NSPanel
    private let surfaceView: PetSurfacePanelView
    private let messageAreaHeight: CGFloat
    private let legacyContentSize: CGSize
    private let spriteSize: CGSize
    private let stableSpriteBounds: CGRect
    private let surfacePalette: OpenPetsPetSurfacePalette
    private let reactionFrames: [OpenPetsPetReactionKind: [CGImage]]
    private let reactionFrameDurations: [OpenPetsPetReactionKind: [Int]]
    private var animationTimer: Timer?
    private var glideTimer: Timer?
    private var callMotionTask: Task<Void, Never>?
    private var screenParametersObserver: NSObjectProtocol?
    private var glideVelocity = CGVector.zero
    private var lastGlideUpdateTime: TimeInterval?
    private var glideAnimationFallback: PetAnimation = .runningRight
    private var ttlWorkItem: DispatchWorkItem?
    private var messageWorkItems: [String: DispatchWorkItem] = [:]
    private var reactionWorkItems: [String: DispatchWorkItem] = [:]
    private var surfaceRevealTask: Task<Void, Never>?
    private var petReactionUpdatesByID: [String: OpenPetsPetReactionUpdate] = [:]
    private var resolvedSurfaces: [OpenPetsResolvedSurface] = []
    private var currentAnimation: PetAnimation = .idle
    private var currentReactionKind: OpenPetsPetReactionKind?
    private var currentFrameIndex = 0
    private var remainingAnimationCycles: Int?
    private let surfaceResolver = OpenPetsSurfacePlacementResolver()
    private var activeReactionAnimation: ResolvedPetReactionAnimation?
    private var surfaceGlobalMouseMonitor: Any?
    private var surfaceLocalMouseMonitor: Any?
    private var hidesSurfacesDuringPetMovement = false

    var petManifest: PetManifest {
        petBundle.manifest
    }

    init(
        petAssets: PetHostAssets,
        display: OpenPetsDisplayConfiguration,
        positionStore: PetPositionStore,
        contextMenuProvider: (@MainActor () -> NSMenu?)? = nil,
        surfaceContextMenuProvider: OpenPetsSurfaceContextMenuProvider? = nil
    ) throws {
        let petBundle = petAssets.petBundle
        self.petBundle = petBundle
        self.positionStore = positionStore
        messageAreaHeight = max(display.messageAreaHeight, 108)

        let frames = petAssets.frames
        surfacePalette = petAssets.surfacePalette
        reactionFrames = petAssets.reactionFrames
        reactionFrameDurations = petAssets.reactionFrameDurations
        spriteSize = CGSize(
            width: CGFloat(petBundle.atlas.cellWidth) * display.scale,
            height: CGFloat(petBundle.atlas.cellHeight) * display.scale
        )
        legacyContentSize = PetWindowPositioning.legacyContentSize(
            spriteSize: spriteSize,
            messageAreaHeight: messageAreaHeight
        )
        stableSpriteBounds = petAssets.stableSpriteBounds
        petView = PetHostView(
            spriteSize: spriteSize,
            stableSpriteBounds: stableSpriteBounds,
            frames: frames,
            contextMenuProvider: contextMenuProvider
        )
        messageView = PetMessagePanelView(
            petSize: stableSpriteBounds.size,
            messageAreaHeight: messageAreaHeight
        )
        surfaceView = PetSurfacePanelView(palette: surfacePalette)

        let contentSize = petView.bounds.size
        let initialOrigin = PetWindowPositioning.initialWindowOrigin(
            storedPosition: positionStore.loadStoredPosition(forPetID: petBundle.manifest.id),
            legacyContentSize: legacyContentSize,
            spriteSize: spriteSize,
            stableSpriteBounds: stableSpriteBounds,
            petFrame: petView.petAnchorFrame,
            preferredVisibleFrame: PetWindowPositioning.preferredVisibleFrame(),
            activeVisibleFrames: PetWindowPositioning.activeVisibleFrames()
        )
        window = NSPanel(
            contentRect: CGRect(origin: initialOrigin, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        messagePanel = NSPanel(
            contentRect: CGRect(origin: .zero, size: .zero),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        surfacePanel = NSPanel(
            contentRect: CGRect(origin: .zero, size: .zero),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = petView
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.level = .statusBar

        messagePanel.backgroundColor = .clear
        messagePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        messagePanel.contentView = messageView
        messagePanel.hasShadow = false
        messagePanel.ignoresMouseEvents = false
        messagePanel.isMovableByWindowBackground = false
        messagePanel.isOpaque = false
        messagePanel.level = .statusBar

        surfacePanel.backgroundColor = .clear
        surfacePanel.acceptsMouseMovedEvents = false
        surfacePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        surfacePanel.contentView = surfaceView
        surfacePanel.hasShadow = false
        surfacePanel.ignoresMouseEvents = true
        surfacePanel.isMovableByWindowBackground = false
        surfacePanel.isOpaque = false
        surfacePanel.level = .statusBar

        petView.onClick = { [weak self] in
            self?.play(.waving, loop: false, ttlSeconds: nil)
        }
        petView.onDragStart = { [weak self] in
            self?.cancelLaunchGlide()
            self?.cancelCallMotion()
            self?.messagePanel.ignoresMouseEvents = true
            self?.hideSurfacesForPetMovement()
        }
        petView.onDragMove = { [weak self] _ in
            self?.positionMessagePanel()
            self?.positionSurfacePanel()
        }
        petView.onDragDirectionChange = { [weak self] direction in
            self?.switchDragDirection(to: direction)
        }
        petView.onDragEnd = { [weak self] velocity, fallbackAnimation in
            self?.messagePanel.ignoresMouseEvents = false
            self?.handleDragEnd(releaseVelocity: velocity, fallbackAnimation: fallbackAnimation)
        }
        petView.onInteractionEnd = { [weak self] in
            self?.messagePanel.ignoresMouseEvents = false
            if self?.glideTimer == nil {
                self?.showSurfacesAfterPetMovement()
            }
        }
        messageView.onDismissMessage = { [weak self] threadId in
            self?.clearBubble(threadId: threadId)
        }
        messageView.onLayoutChanged = { [weak self] in
            self?.positionMessagePanel()
        }
        surfaceView.onSelectSurface = { [weak self] surface in
            self?.showSurfaceDetail(for: surface)
        }
        surfaceView.onContextMenuSurface = { [weak self] surface, screenPoint in
            guard
                let self,
                let menu = surfaceContextMenuProvider?(surface)
            else {
                return
            }
            self.surfaceView.showContextMenu(menu, atScreenPoint: screenPoint)
        }
        installSurfaceMouseTracking()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverFromScreenChangeIfNeeded()
            }
        }

        play(.idle, loop: true, ttlSeconds: nil)
    }

    func show() {
        window.orderFrontRegardless()
        showSurfacePanelIfNeeded()
        if messageView.hasVisibleMessages {
            positionMessagePanel()
            messagePanel.orderFrontRegardless()
        }
    }

    func close() {
        animationTimer?.invalidate()
        animationTimer = nil
        cancelLaunchGlide()
        cancelCallMotion()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        ttlWorkItem?.cancel()
        ttlWorkItem = nil
        cancelMessageWorkItems()
        cancelReactionWorkItems()
        surfaceRevealTask?.cancel()
        surfaceRevealTask = nil
        removeSurfaceMouseTracking()
        surfacePanel.orderOut(nil)
        surfacePanel.close()
        messagePanel.orderOut(nil)
        messagePanel.close()
        window.orderOut(nil)
        window.close()
    }

    func apply(_ command: PetCommand) {
        switch command {
        case .notify(let notification):
            let resolvedNotification = notification.resolvingThreadId()
            setBubble(
                bubble(for: resolvedNotification),
                threadId: resolvedNotification.threadId ?? UUID().uuidString,
                ttlSeconds: resolvedNotification.ttlSeconds
            )
            if let finiteAnimation = finiteAnimation(forStatusKind: notification.status) {
                play(finiteAnimation, loopCount: 3, ttlSeconds: nil)
            } else {
                play(animation(forStatusKind: notification.status), loop: true, ttlSeconds: notification.ttlSeconds)
            }
        case .playAnimation(let name, let loop, let ttlSeconds):
            play(name, loop: loop ?? true, ttlSeconds: ttlSeconds)
        case .stopAnimation:
            stopAnimation()
        case .clearMessage(let threadId):
            clearBubble(threadId: threadId)
        case .clearMessages:
            clearBubbles()
        case .ping, .shutdown:
            break
        }
    }

    func savePosition() {
        try? positionStore.savePosition(petAnchorInScreen(), kind: .petAnchor, forPetID: petBundle.manifest.id)
    }

    func callPet() {
        let currentOrigin = window.frame.origin
        let targetOrigin = defaultWindowOrigin()
        guard hypot(targetOrigin.x - currentOrigin.x, targetOrigin.y - currentOrigin.y) > 1 else {
            window.setFrameOrigin(targetOrigin)
            positionMessagePanel()
            positionSurfacePanel()
            savePosition()
            return
        }

        cancelLaunchGlide()
        cancelCallMotion()
        ttlWorkItem?.cancel()
        let animation = PetCallMotion.animation(
            from: currentOrigin,
            to: targetOrigin,
            fallback: directionalAnimation(from: nil)
        )
        switchDragDirection(to: animation)
        callMotionTask = Task { [weak self] in
            await self?.runCallMotion(from: currentOrigin, to: targetOrigin)
        }
    }

    func revealSurfacePositions(surfaceIDs: Set<String>?, duration: TimeInterval) {
        guard surfaceView.hasVisibleSurfaces, !hidesSurfacesDuringPetMovement else { return }

        surfaceRevealTask?.cancel()
        surfaceView.startSurfaceReveal(targetSurfaceIDs: surfaceIDs)
        orderSurfacePanelBehindPet()
        play(.waving, loop: false, ttlSeconds: nil)

        let revealDuration = max(0.1, duration)
        surfaceRevealTask = Task { @MainActor [weak self] in
            let frameInterval = UInt64(33_000_000)
            let startedAt = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let progress = min(1, CGFloat(elapsed / revealDuration))
                self?.surfaceView.setSurfaceRevealProgress(progress)
                guard progress < 1 else { break }
                try? await Task.sleep(nanoseconds: frameInterval)
            }
            if !Task.isCancelled {
                self?.surfaceView.clearSurfaceReveal()
                self?.surfaceRevealTask = nil
            }
        }
    }

    @discardableResult
    func setSurfaceUpdates(_ updates: [OpenPetsSurfaceUpdate]) -> [OpenPetsResolvedSurface] {
        let resolvedSurfaces = surfaceResolver.resolve(updates)
        self.resolvedSurfaces = resolvedSurfaces
        surfaceView.set(resolvedSurfaces: resolvedSurfaces)
        if surfaceView.hasVisibleSurfaces, !hidesSurfacesDuringPetMovement {
            showSurfacePanelIfNeeded()
        } else {
            surfaceRevealTask?.cancel()
            surfaceRevealTask = nil
            surfaceView.clearSurfaceReveal()
            if !hidesSurfacesDuringPetMovement {
                surfacePanel.orderOut(nil)
            }
        }
        return resolvedSurfaces
    }

    @discardableResult
    func showSurfaceDetail(forSurfaceID surfaceID: String) -> Bool {
        guard let surface = resolvedSurfaces.first(where: { $0.update.surfaceID == surfaceID }) else {
            return false
        }

        return showSurfaceDetail(for: surface)
    }

    func setPetReactionUpdates(_ updates: [OpenPetsPetReactionUpdate]) {
        let previousReactionAnimation = activeReactionAnimation

        var updatesByID: [String: OpenPetsPetReactionUpdate] = [:]
        for update in updates where update.type == "pet.reaction" {
            updatesByID[update.reactionID] = update
        }

        for reactionID in Set(petReactionUpdatesByID.keys).subtracting(updatesByID.keys) {
            reactionWorkItems[reactionID]?.cancel()
            reactionWorkItems[reactionID] = nil
        }

        petReactionUpdatesByID = updatesByID
        scheduleReactionExpirations(for: updatesByID.values)
        selectActiveReaction(previousReactionAnimation: previousReactionAnimation)
    }

    private func defaultWindowOrigin() -> CGPoint {
        let defaultAnchor = PetWindowPositioning.initialPetAnchor(
            storedPosition: nil,
            legacyContentSize: legacyContentSize,
            spriteSize: spriteSize,
            stableSpriteBounds: stableSpriteBounds,
            defaultWindowOrigin: PetWindowPositioning.defaultWindowOrigin(
                contentSize: legacyContentSize,
                visibleFrame: PetWindowPositioning.preferredVisibleFrame()
            )
        )
        return PetWindowPositioning.windowOrigin(
            preservingPetAnchor: defaultAnchor,
            petFrame: petView.petAnchorFrame
        )
    }

    private func petAnchorInScreen() -> CGPoint {
        CGPoint(
            x: window.frame.origin.x + petView.petAnchorFrame.minX,
            y: window.frame.origin.y + petView.petAnchorFrame.minY
        )
    }

    private func currentPetScreenFrame() -> CGRect {
        PetWindowPositioning.screenFrame(
            windowOrigin: window.frame.origin,
            petFrame: petView.visibleSpriteFrame
        )
    }

    private func setBubble(_ bubble: PetBubble, threadId: String, ttlSeconds: Double?) {
        messageWorkItems[threadId]?.cancel()
        messageView.setBubble(bubble, threadId: threadId)
        positionMessagePanel()
        messagePanel.orderFrontRegardless()

        guard let ttlSeconds, ttlSeconds > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.clearBubble(threadId: threadId)
            }
        }
        messageWorkItems[threadId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ttlSeconds, execute: workItem)
    }

    @discardableResult
    private func showSurfaceDetail(for surface: OpenPetsResolvedSurface) -> Bool {
        guard let detail = surface.update.detail else { return false }
        let rows = detail.rows.map { row in
            if row.label.isEmpty {
                return row.value
            }
            return "\(row.label): \(row.value)"
        }
        let action: PetBubbleAction?
        if
            let actionURL = detail.actionURL,
            let url = URL(string: actionURL)
        {
            action = PetBubbleAction(label: detail.actionLabel ?? "open", url: url)
        } else {
            action = nil
        }
        setBubble(
            PetBubble(
                title: detail.title,
                detail: rows.joined(separator: "\n"),
                indicator: .none,
                action: action,
                detailLineLimit: nil
            ),
            threadId: "surface-detail.\(surface.update.surfaceID)",
            ttlSeconds: detail.ttlSeconds
        )
        play(.waving, loop: false, ttlSeconds: nil)
        return true
    }

    private func clearBubble(threadId: String) {
        messageWorkItems[threadId]?.cancel()
        messageWorkItems[threadId] = nil
        messageView.clearBubble(threadId: threadId)
        if messageView.hasVisibleMessages {
            positionMessagePanel()
        } else {
            messagePanel.orderOut(nil)
        }
    }

    private func clearBubbles() {
        for workItem in messageWorkItems.values {
            workItem.cancel()
        }
        messageWorkItems.removeAll()
        messageView.clearBubbles()
        messagePanel.orderOut(nil)
    }

    private func cancelMessageWorkItems() {
        for workItem in messageWorkItems.values {
            workItem.cancel()
        }
        messageWorkItems.removeAll()
    }

    private func scheduleReactionExpirations(for updates: Dictionary<String, OpenPetsPetReactionUpdate>.Values) {
        for update in updates {
            reactionWorkItems[update.reactionID]?.cancel()
            guard let ttlSeconds = update.ttlSeconds, ttlSeconds > 0 else {
                reactionWorkItems[update.reactionID] = nil
                continue
            }

            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.expireReaction(reactionID: update.reactionID)
                }
            }
            reactionWorkItems[update.reactionID] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + ttlSeconds, execute: workItem)
        }
    }

    private func expireReaction(reactionID: String) {
        reactionWorkItems[reactionID]?.cancel()
        reactionWorkItems[reactionID] = nil
        guard petReactionUpdatesByID.removeValue(forKey: reactionID) != nil else { return }
        selectActiveReaction(previousReactionAnimation: activeReactionAnimation)
    }

    private func cancelReactionWorkItems() {
        for workItem in reactionWorkItems.values {
            workItem.cancel()
        }
        reactionWorkItems.removeAll()
    }

    private func play(_ animation: PetAnimation, loop: Bool, ttlSeconds: Double?) {
        play(animation, loopCount: loop ? nil : 1, ttlSeconds: ttlSeconds)
    }

    private func play(_ animation: PetAnimation, loopCount: Int?, ttlSeconds: Double?) {
        cancelLaunchGlide()
        cancelCallMotion()
        ttlWorkItem?.cancel()
        currentReactionKind = nil
        currentAnimation = animation
        currentFrameIndex = entryFrame(for: animation)
        remainingAnimationCycles = loopCount
        petView.set(animation: animation, frameIndex: currentFrameIndex)
        scheduleNextFrame()

        guard let ttlSeconds, ttlSeconds > 0, animation != .idle else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.resumeAmbientAnimation()
            }
        }
        ttlWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ttlSeconds, execute: workItem)
    }

    private func stopAnimation() {
        resumeAmbientAnimation()
    }

    private func playReaction(_ reaction: OpenPetsPetReactionKind) {
        guard let frames = reactionFrames[reaction], !frames.isEmpty else { return }
        cancelLaunchGlide()
        cancelCallMotion()
        ttlWorkItem?.cancel()
        currentReactionKind = reaction
        currentFrameIndex = 0
        remainingAnimationCycles = nil
        petView.set(image: frames[0])
        scheduleNextFrame()
    }

    private func selectActiveReaction(previousReactionAnimation: ResolvedPetReactionAnimation?) {
        let reaction = petReactionUpdatesByID.values
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
                return $0.reactionID < $1.reactionID
            }
            .first
        if let reaction {
            activeReactionAnimation = animation(forReaction: reaction.kind)
        } else {
            activeReactionAnimation = nil
        }
        applyActiveReactionIfIdle(previousReactionAnimation: previousReactionAnimation)
    }

    private func applyActiveReactionIfIdle(previousReactionAnimation: ResolvedPetReactionAnimation?) {
        let currentReactionAnimation = currentReactionKind.map(ResolvedPetReactionAnimation.custom)
        guard
            currentAnimation == .idle ||
                (activeReactionAnimation != nil && currentReactionAnimation == activeReactionAnimation) ||
                currentReactionAnimation == previousReactionAnimation ||
                previousReactionAnimation == .standard(currentAnimation)
        else {
            return
        }
        guard let activeReactionAnimation else {
            play(.idle, loop: true, ttlSeconds: nil)
            return
        }
        switch activeReactionAnimation {
        case .standard(let animation):
            play(animation, loop: true, ttlSeconds: nil)
        case .custom(let kind):
            playReaction(kind)
        }
    }

    private func resumeAmbientAnimation() {
        guard let activeReactionAnimation else {
            play(.idle, loop: true, ttlSeconds: nil)
            return
        }
        switch activeReactionAnimation {
        case .standard(let animation):
            play(animation, loop: true, ttlSeconds: nil)
        case .custom(let kind):
            playReaction(kind)
        }
    }

    private func animation(forReaction kind: OpenPetsPetReactionKind) -> ResolvedPetReactionAnimation? {
        if reactionFrames[kind]?.isEmpty == false {
            return .custom(kind)
        }
        if let mappedAnimation = petBundle.manifest.reactionAnimations.first(where: { $0.kind == kind })?.animation {
            return .standard(mappedAnimation)
        }
        switch kind {
        case .lowEnergy, .resting:
            return .standard(.waiting)
        case .charging, .celebrate:
            return .standard(.jumping)
        case .alert:
            return .standard(.failed)
        case .working:
            return .standard(.running)
        default:
            return nil
        }
    }

    private func handleDragEnd(releaseVelocity: CGVector, fallbackAnimation: PetAnimation?) {
        cancelCallMotion()
        let fallbackAnimation = directionalAnimation(from: fallbackAnimation)
        guard PetLaunchMotion.shouldLaunch(velocity: releaseVelocity) else {
            savePosition()
            resumeAmbientAnimation()
            showSurfacesAfterPetMovement()
            return
        }

        glideVelocity = releaseVelocity
        glideAnimationFallback = PetLaunchMotion.animation(for: releaseVelocity, fallback: fallbackAnimation)
        switchDragDirection(to: glideAnimationFallback)
        lastGlideUpdateTime = ProcessInfo.processInfo.systemUptime
        glideTimer?.invalidate()
        glideTimer = Timer.scheduledTimer(
            withTimeInterval: PetLaunchMotion.frameInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advanceLaunchGlide()
            }
        }
    }

    private func advanceLaunchGlide() {
        let now = ProcessInfo.processInfo.systemUptime
        let previousTime = lastGlideUpdateTime ?? now
        lastGlideUpdateTime = now
        let deltaTime = min(max(now - previousTime, 1.0 / 120.0), 1.0 / 30.0)
        let step = PetLaunchMotion.step(
            origin: window.frame.origin,
            velocity: glideVelocity,
            movingFrame: petView.visibleSpriteFrame,
            visibleFrame: visibleFrameForGlide(),
            fallbackAnimation: glideAnimationFallback,
            deltaTime: deltaTime
        )

        window.setFrameOrigin(step.origin)
        positionMessagePanel()
        positionSurfacePanel()
        glideVelocity = step.velocity
        if step.animation != glideAnimationFallback {
            glideAnimationFallback = step.animation
            switchDragDirection(to: step.animation)
        }

        if step.shouldStop {
            finishLaunchGlide()
        }
    }

    private func finishLaunchGlide() {
        cancelLaunchGlide()
        savePosition()
        resumeAmbientAnimation()
        showSurfacesAfterPetMovement()
    }

    private func cancelLaunchGlide() {
        let wasGliding = glideTimer != nil
        glideTimer?.invalidate()
        glideTimer = nil
        lastGlideUpdateTime = nil
        if wasGliding {
            showSurfacesAfterPetMovement()
        }
    }

    private func runCallMotion(from origin: CGPoint, to targetOrigin: CGPoint) async {
        let duration = PetCallMotion.duration(from: origin, to: targetOrigin)
        let startTime = ProcessInfo.processInfo.systemUptime

        while !Task.isCancelled {
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(CGFloat(elapsed / duration), 1)
            window.setFrameOrigin(PetCallMotion.origin(from: origin, to: targetOrigin, progress: progress))
            positionMessagePanel()
            positionSurfacePanel()

            guard progress < 1 else {
                finishCallMotion(at: targetOrigin)
                return
            }

            try? await Task.sleep(nanoseconds: PetCallMotion.frameIntervalNanoseconds)
        }
    }

    private func finishCallMotion(at targetOrigin: CGPoint) {
        callMotionTask = nil
        window.setFrameOrigin(targetOrigin)
        positionMessagePanel()
        positionSurfacePanel()
        savePosition()
        resumeAmbientAnimation()
    }

    private func cancelCallMotion() {
        callMotionTask?.cancel()
        callMotionTask = nil
    }

    private func recoverFromScreenChangeIfNeeded() {
        guard !PetWindowPositioning.isVisible(
            currentPetScreenFrame(),
            in: PetWindowPositioning.activeVisibleFrames()
        ) else {
            return
        }

        callPet()
    }

    private func visibleFrameForGlide() -> CGRect {
        if let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
            return screen.visibleFrame
        }
        return window.frame
    }

    private func positionMessagePanel() {
        guard messageView.hasVisibleMessages else { return }
        let petAnchor = petAnchorInScreen()
        messageView.resizeWindow(preservingPetAnchor: petAnchor)
    }

    private func positionSurfacePanel() {
        guard surfaceView.hasVisibleSurfaces, !hidesSurfacesDuringPetMovement else { return }
        let petFrame = currentPetScreenFrame()
        surfaceView.resizeWindow(aroundPetFrame: petFrame)
        updateSurfaceCursor()
    }

    private func showSurfacePanelIfNeeded() {
        guard surfaceView.hasVisibleSurfaces, !hidesSurfacesDuringPetMovement else { return }
        positionSurfacePanel()
        orderSurfacePanelBehindPet()
    }

    private func orderSurfacePanelBehindPet() {
        surfacePanel.order(.below, relativeTo: window.windowNumber)
    }

    private func hideSurfacesForPetMovement() {
        guard !hidesSurfacesDuringPetMovement else { return }
        hidesSurfacesDuringPetMovement = true
        surfaceView.setCursorScreenPoint(nil)
        surfacePanel.orderOut(nil)
    }

    private func showSurfacesAfterPetMovement() {
        guard hidesSurfacesDuringPetMovement else { return }
        hidesSurfacesDuringPetMovement = false
        showSurfacePanelIfNeeded()
    }

    private func installSurfaceMouseTracking() {
        let eventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        surfaceGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor in
                self?.handleSurfaceMouseEvent(event)
            }
        }
        surfaceLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor in
                self?.handleSurfaceMouseEvent(event)
            }
            return event
        }
    }

    private func removeSurfaceMouseTracking() {
        if let surfaceGlobalMouseMonitor {
            NSEvent.removeMonitor(surfaceGlobalMouseMonitor)
            self.surfaceGlobalMouseMonitor = nil
        }
        if let surfaceLocalMouseMonitor {
            NSEvent.removeMonitor(surfaceLocalMouseMonitor)
            self.surfaceLocalMouseMonitor = nil
        }
    }

    private func handleSurfaceMouseEvent(_ event: NSEvent) {
        guard !hidesSurfacesDuringPetMovement else { return }
        updateSurfaceCursor(screenPoint: NSEvent.mouseLocation)
        switch event.type {
        case .leftMouseDown:
            surfaceView.selectSurface(atScreenPoint: NSEvent.mouseLocation)
        case .rightMouseDown:
            surfaceView.showContextMenu(atScreenPoint: NSEvent.mouseLocation)
        default:
            break
        }
    }

    private func updateSurfaceCursor(screenPoint: CGPoint = NSEvent.mouseLocation) {
        guard surfaceView.hasVisibleSurfaces, surfacePanel.isVisible, !hidesSurfacesDuringPetMovement else { return }
        surfaceView.setCursorScreenPoint(screenPoint)
    }

    private func directionalAnimation(from animation: PetAnimation?) -> PetAnimation {
        if let animation {
            return animation == .runningLeft ? .runningLeft : .runningRight
        }
        if currentAnimation == .runningLeft {
            return .runningLeft
        }
        return .runningRight
    }

    private func switchDragDirection(to animation: PetAnimation) {
        ttlWorkItem?.cancel()
        let previousAnimation = currentAnimation
        currentReactionKind = nil
        currentAnimation = animation
        remainingAnimationCycles = nil
        if previousAnimation == .runningRight || previousAnimation == .runningLeft {
            currentFrameIndex %= animation.frameCount
        } else {
            currentFrameIndex = entryFrame(for: animation)
        }
        petView.set(animation: animation, frameIndex: currentFrameIndex)
        scheduleNextFrame()
    }

    private func entryFrame(for animation: PetAnimation) -> Int {
        switch animation {
        case .runningRight, .runningLeft:
            1
        case .waving, .jumping, .failed:
            min(1, animation.frameCount - 1)
        case .idle, .waiting, .running, .review:
            0
        }
    }

    private func scheduleNextFrame() {
        animationTimer?.invalidate()
        let durations = currentReactionKind.flatMap { reactionFrameDurations[$0] } ?? currentAnimation.frameDurationsMilliseconds
        let duration = Double(durations[min(currentFrameIndex, durations.count - 1)]) / 1000
        animationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        let frameCount = currentReactionKind.flatMap { reactionFrames[$0]?.count } ?? currentAnimation.frameCount
        currentFrameIndex += 1

        if currentFrameIndex >= frameCount {
            if let remainingAnimationCycles {
                let remainingCycles = remainingAnimationCycles - 1
                if remainingCycles > 0 {
                    self.remainingAnimationCycles = remainingCycles
                    currentFrameIndex = 0
                } else {
                    resumeAmbientAnimation()
                    return
                }
            } else {
                currentFrameIndex = 0
            }
        }

        if let currentReactionKind, let frames = reactionFrames[currentReactionKind], !frames.isEmpty {
            petView.set(image: frames[currentFrameIndex % frames.count])
        } else {
            petView.set(animation: currentAnimation, frameIndex: currentFrameIndex)
        }
        scheduleNextFrame()
    }

    private func indicator(forSurfaceTone tone: OpenPetsSurfaceTone) -> PetBubbleIndicator {
        switch tone {
        case .critical, .warning:
            .attention
        case .success:
            .success
        case .muted:
            .none
        case .normal:
            .working
        }
    }

    private func animation(forStatusKind kind: String) -> PetAnimation {
        switch kind.lowercased() {
        case "failed", "failure", "error":
            .failed
        case "review", "reviewing":
            .review
        case "waiting", "queued", "pending":
            .waiting
        case "running", "task", "working":
            .running
        case "done", "success", "completed", "complete", "committed":
            .jumping
        case "attention", "reply", "message":
            .waving
        default:
            .idle
        }
    }

    private func finiteAnimation(forStatusKind kind: String) -> PetAnimation? {
        switch kind.lowercased() {
        case "done", "success", "completed", "complete", "committed":
            .jumping
        case "review", "reviewing":
            .review
        case "running", "task", "working":
            .running
        default:
            nil
        }
    }

    private func bubble(for notification: PetNotification) -> PetBubble {
        PetBubble(
            title: notification.title,
            detail: notification.text,
            indicator: indicator(forStatusKind: notification.status),
            action: action(for: notification)
        )
    }

    private func indicator(forStatusKind kind: String) -> PetBubbleIndicator {
        openPetsBubbleIndicator(forStatusKind: kind)
    }

    private func action(for notification: PetNotification) -> PetBubbleAction? {
        guard
            let actionURL = notification.url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !actionURL.isEmpty,
            let url = URL(string: actionURL)
        else {
            return nil
        }

        let label = notification.buttonLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetBubbleAction(
            label: label?.isEmpty == false ? label! : "open",
            url: url
        )
    }

}

struct PetMessage: Equatable, Identifiable {
    var id: String { threadId }
    var threadId: String
    var bubble: PetBubble
}

struct PetMessageStack: Equatable {
    static let visibleLimit = 4

    private var orderedThreadIds: [String] = []
    private var bubblesByThreadId: [String: PetBubble] = [:]

    var activeMessages: [PetMessage] {
        orderedThreadIds.compactMap { threadId in
            bubblesByThreadId[threadId].map { PetMessage(threadId: threadId, bubble: $0) }
        }
    }

    var activeCount: Int {
        activeMessages.count
    }

    mutating func setBubble(_ bubble: PetBubble, threadId: String) {
        if bubblesByThreadId[threadId] == nil {
            orderedThreadIds.append(threadId)
        }
        bubblesByThreadId[threadId] = bubble
    }

    mutating func clearBubble(threadId: String) {
        bubblesByThreadId[threadId] = nil
        orderedThreadIds.removeAll { $0 == threadId }
    }

    mutating func clearBubbles() {
        bubblesByThreadId.removeAll()
        orderedThreadIds.removeAll()
    }

    func visibleMessages(limit: Int = visibleLimit) -> [PetMessage] {
        Array(activeMessages.suffix(max(0, limit)))
    }

    func hiddenMessageCount(limit: Int = visibleLimit) -> Int {
        max(0, activeCount - max(0, limit))
    }
}

struct PetBubble: Equatable {
    var title: String
    var detail: String?
    var indicator: PetBubbleIndicator
    var action: PetBubbleAction? = nil
    var detailLineLimit: Int? = 2
}

struct PetBubbleAction: Equatable {
    var label: String
    var url: URL

    func open(source: String, using opener: OpenPetsActionURLOpener = OpenPetsActionURLOpener()) {
        let urlDescription = OpenPetsActionURLOpener.traceDescription(for: url)
        NSLog("%@", "OpenPets action URL click detected from \(source): label=\(label) url=\(urlDescription)" as NSString)
        opener.open(url)
    }
}

enum PetBubbleIndicator: Equatable {
    case none
    case working
    case waiting
    case review
    case success
    case attention
}

func openPetsBubbleIndicator(forStatusKind kind: String) -> PetBubbleIndicator {
    switch kind.lowercased() {
    case "waiting":
        .waiting
    case "review", "reviewing":
        .review
    case "done", "success", "completed", "complete", "committed":
        .success
    case "failed", "fail", "failure", "error":
        .attention
    case "attention", "reply", "message":
        .none
    default:
        .working
    }
}

private final class SurfaceHostingView: NSHostingView<OpenPetsSurfaceOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class PetSurfacePanelView: NSView {
    private static let surfaceOutset: CGFloat = 184

    var onSelectSurface: ((OpenPetsResolvedSurface) -> Void)?
    var onContextMenuSurface: ((OpenPetsResolvedSurface, CGPoint) -> Void)?
    var contextMenuPresenter: (NSMenu, CGPoint, PetSurfacePanelView) -> Void = { menu, screenPoint, view in
        menu.popUp(positioning: nil, at: view.localPoint(forScreenPoint: screenPoint), in: view)
    }

    var hasVisibleSurfaces: Bool {
        !visibleSurfaces.isEmpty
    }

    private var visibleSurfaces: [OpenPetsResolvedSurface] = []
    private var currentPetFrameInPanel: CGRect = .zero
    private var cursorPoint: CGPoint?
    private var surfaceRevealState: OpenPetsSurfaceRevealState?
    private var hotspotFrames: [String: CGRect] = [:]
    private let palette: OpenPetsPetSurfacePalette
    private lazy var hostingView = SurfaceHostingView(rootView: OpenPetsSurfaceOverlayView(
        resolvedSurfaces: [],
        petFrame: .zero,
        cursorPoint: nil,
        revealState: nil,
        hotspotFrames: [:],
        palette: palette
    ))

    init(palette: OpenPetsPetSurfacePalette = .fallback) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        updateHostingView()
    }

    func set(resolvedSurfaces: [OpenPetsResolvedSurface]) {
        visibleSurfaces = resolvedSurfaces.filter(\.isVisibleSurface)
        if visibleSurfaces.isEmpty {
            setFrameSize(.zero)
        }
        updateHotspotFrames()
        updateHostingView()
    }

    func resizeWindow(aroundPetFrame petFrame: CGRect) {
        guard let window, hasVisibleSurfaces else { return }
        let frame = petFrame.insetBy(dx: -Self.surfaceOutset, dy: -Self.surfaceOutset)
        currentPetFrameInPanel = CGRect(
            x: Self.surfaceOutset,
            y: Self.surfaceOutset,
            width: petFrame.width,
            height: petFrame.height
        )
        setFrameSize(frame.size)
        hostingView.frame = bounds
        window.setFrame(frame, display: false)
        updateHotspotFrames()
        updateHostingView()
    }

    func setCursorScreenPoint(_ screenPoint: CGPoint?) {
        cursorPoint = screenPoint.map { surfacePoint(forLocalPoint: localPoint(forScreenPoint: $0)) }
        updateHostingView()
    }

    func startSurfaceReveal(targetSurfaceIDs: Set<String>?) {
        let targets = targetSurfaceIDs ?? Set(visibleSurfaces.map(\.update.surfaceID))
        surfaceRevealState = OpenPetsSurfaceRevealState(
            progress: 0,
            targetSurfaceIDs: targets,
            startOffsetsBySurfaceID: OpenPetsSurfaceRevealState.startOffsets(for: targets)
        )
        updateHostingView()
    }

    func setSurfaceRevealProgress(_ progress: CGFloat) {
        guard var surfaceRevealState else { return }
        surfaceRevealState.progress = max(0, min(progress, 1))
        self.surfaceRevealState = surfaceRevealState
        updateHostingView()
    }

    func clearSurfaceReveal() {
        surfaceRevealState = nil
        updateHostingView()
    }

    @discardableResult
    func selectSurface(atScreenPoint screenPoint: CGPoint) -> Bool {
        guard let target = hotspotTarget(at: surfacePoint(forLocalPoint: localPoint(forScreenPoint: screenPoint))) else { return false }
        onSelectSurface?(target)
        return true
    }

    @discardableResult
    func showContextMenu(atScreenPoint screenPoint: CGPoint) -> Bool {
        guard let target = hotspotTarget(at: surfacePoint(forLocalPoint: localPoint(forScreenPoint: screenPoint))) else { return false }
        onContextMenuSurface?(target, screenPoint)
        return true
    }

    func showContextMenu(_ menu: NSMenu, atScreenPoint screenPoint: CGPoint) {
        contextMenuPresenter(menu, screenPoint, self)
    }

    private func updateHostingView() {
        hostingView.rootView = OpenPetsSurfaceOverlayView(
            resolvedSurfaces: visibleSurfaces,
            petFrame: currentPetFrameInPanel,
            cursorPoint: cursorPoint,
            revealState: surfaceRevealState,
            hotspotFrames: hotspotFrames,
            palette: palette
        )
    }

    private func updateHotspotFrames() {
        hotspotFrames = Dictionary(uniqueKeysWithValues: visibleSurfaces.filter(\.isHotspotSurface).map { surface in
            (
                surface.update.surfaceID,
                OpenPetsSurfaceHotspotLayout.frame(
                    for: surface.primarySlot,
                    petFrame: currentPetFrameInPanel,
                    panelSize: bounds.size
                )
            )
        })
    }

    private func hotspotTarget(at point: CGPoint) -> OpenPetsResolvedSurface? {
        guard !currentPetFrameInPanel.contains(point) else { return nil }
        return visibleSurfaces.filter(\.isHotspotSurface).first { surface in
            guard let frame = hotspotFrames[surface.update.surfaceID] else { return false }
            let visibility = OpenPetsHotspotVisibility(distance: OpenPetsSurfaceHotspotLayout.hotspotDistance(from: point, to: frame))
            return OpenPetsSurfaceHotspotLayout.hitFrame(for: frame, visibility: visibility).contains(point)
        }
    }

    private func localPoint(forScreenPoint screenPoint: CGPoint) -> CGPoint {
        guard let window else { return screenPoint }
        let frame = window.frame
        return CGPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
    }

    private func surfacePoint(forLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: bounds.height - point.y)
    }
}

private struct OpenPetsSurfaceOverlayView: View {
    let resolvedSurfaces: [OpenPetsResolvedSurface]
    let petFrame: CGRect
    let cursorPoint: CGPoint?
    let revealState: OpenPetsSurfaceRevealState?
    let hotspotFrames: [String: CGRect]
    let palette: OpenPetsPetSurfacePalette

    private var overlaySurfaces: [OpenPetsResolvedSurface] {
        resolvedSurfaces.filter { resolved in
            guard case .placed = resolved.placement else { return false }
            return true
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let revealGeometry {
                    OpenPetsSurfaceRevealView(
                        geometry: revealGeometry,
                        palette: palette
                    )
                }
                ForEach(Array(overlaySurfaces.enumerated()), id: \.offset) { _, resolved in
                    overlayView(for: resolved, in: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }

    private var revealGeometry: OpenPetsSurfaceRevealGeometry? {
        guard let revealState else { return nil }
        let targetFrames = hotspotFrames.filter { revealState.targetSurfaceIDs.contains($0.key) }
        return OpenPetsSurfaceRevealGeometry(
            progress: revealState.progress,
            petFrame: petFrame,
            targetFrames: targetFrames,
            startOffsetsBySurfaceID: revealState.startOffsetsBySurfaceID
        )
    }

    @ViewBuilder
    private func overlayView(for resolved: OpenPetsResolvedSurface, in size: CGSize) -> some View {
        OpenPetsCloudHotspotSurfaceView(
            surface: resolved.update,
            visibility: visibility(for: resolved),
            palette: palette
        )
        .frame(width: OpenPetsSurfaceHotspotLayout.widgetSize.width, height: OpenPetsSurfaceHotspotLayout.widgetSize.height)
        .position(position(for: resolved, in: size))
    }

    private func position(for resolved: OpenPetsResolvedSurface, in size: CGSize) -> CGPoint {
        let frame = hotspotFrames[resolved.update.surfaceID] ?? OpenPetsSurfaceHotspotLayout.frame(
            for: resolved.primarySlot,
            petFrame: petFrame,
            panelSize: size
        )
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func visibility(for resolved: OpenPetsResolvedSurface) -> OpenPetsHotspotVisibility {
        let targetRevealProgress: CGFloat
        if let revealState, revealState.targetSurfaceIDs.contains(resolved.update.surfaceID) {
            targetRevealProgress = OpenPetsSurfaceRevealPhase(
                progress: revealState.progress(for: resolved.update.surfaceID)
            ).targetRevealProgress
        } else {
            targetRevealProgress = 0
        }

        guard
            let cursorPoint,
            let frame = hotspotFrames[resolved.update.surfaceID]
        else {
            return OpenPetsHotspotVisibility(distance: .infinity, positionRevealProgress: targetRevealProgress)
        }
        return OpenPetsHotspotVisibility(
            distance: OpenPetsSurfaceHotspotLayout.hotspotDistance(from: cursorPoint, to: frame),
            positionRevealProgress: targetRevealProgress
        )
    }
}

struct OpenPetsSurfaceRevealState: Equatable {
    static let maximumStartOffset: CGFloat = 0.04

    var progress: CGFloat
    var targetSurfaceIDs: Set<String>

    var startOffsetsBySurfaceID: [String: CGFloat] = [:]

    func progress(for surfaceID: String) -> CGFloat {
        let offset = startOffsetsBySurfaceID[surfaceID] ?? 0
        guard offset > 0 else { return progress }
        return max(0, min((progress - offset) / (1 - Self.maximumStartOffset), 1))
    }

    static func startOffsets(for targetSurfaceIDs: Set<String>) -> [String: CGFloat] {
        guard targetSurfaceIDs.count > 1 else {
            return Dictionary(uniqueKeysWithValues: targetSurfaceIDs.map { ($0, 0) })
        }

        let shuffledSurfaceIDs = targetSurfaceIDs.shuffled()
        let step = maximumStartOffset / CGFloat(shuffledSurfaceIDs.count - 1)
        return Dictionary(uniqueKeysWithValues: shuffledSurfaceIDs.enumerated().map { index, surfaceID in
            (surfaceID, CGFloat(index) * step)
        })
    }
}

struct OpenPetsSurfaceRevealPhase: Equatable {
    var beamProgress: CGFloat
    var beamOpacity: CGFloat
    var targetRevealProgress: CGFloat

    init(progress: CGFloat) {
        let progress = max(0, min(progress, 1))
        beamProgress = Self.smoothed(min(progress / 0.1, 1))

        if progress < 0.015 {
            beamOpacity = (progress / 0.015) * 0.62
        } else if progress > 0.16 {
            beamOpacity = max(0, 1 - (progress - 0.16) / 0.06) * 0.62
        } else {
            beamOpacity = 0.62
        }

        if progress < 0.04 {
            targetRevealProgress = 0
        } else if progress < 0.075 {
            targetRevealProgress = Self.smoothed((progress - 0.04) / 0.035)
        } else if progress < 0.88 {
            targetRevealProgress = 1
        } else {
            targetRevealProgress = Self.smoothed(max(0, 1 - (progress - 0.88) / 0.12))
        }
    }

    private static func smoothed(_ progress: CGFloat) -> CGFloat {
        progress * progress * (3 - 2 * progress)
    }
}

struct OpenPetsSurfaceRevealGeometry: Equatable {
    var progress: CGFloat
    var petFrame: CGRect
    var targetFrames: [String: CGRect]
    var startOffsetsBySurfaceID: [String: CGFloat] = [:]

    var isVisible: Bool {
        targetFrames.keys.contains { surfaceID in
            let phase = phase(for: surfaceID)
            return phase.beamOpacity > 0
        }
    }

    var origin: CGPoint {
        CGPoint(x: petFrame.midX, y: petFrame.midY)
    }

    var targetCenters: [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: targetFrames.map { surfaceID, frame in
            (surfaceID, CGPoint(x: frame.midX, y: frame.midY))
        })
    }

    func phase(for surfaceID: String) -> OpenPetsSurfaceRevealPhase {
        let offset = startOffsetsBySurfaceID[surfaceID] ?? 0
        let localProgress: CGFloat
        if offset > 0 {
            localProgress = max(0, min((progress - offset) / (1 - OpenPetsSurfaceRevealState.maximumStartOffset), 1))
        } else {
            localProgress = progress
        }
        return OpenPetsSurfaceRevealPhase(progress: localProgress)
    }

    func beamPoint(for target: CGPoint, surfaceID: String) -> CGPoint {
        let phase = phase(for: surfaceID)
        return CGPoint(
            x: origin.x + (target.x - origin.x) * phase.beamProgress,
            y: origin.y + (target.y - origin.y) * phase.beamProgress
        )
    }
}

private struct OpenPetsSurfaceRevealView: View {
    let geometry: OpenPetsSurfaceRevealGeometry
    let palette: OpenPetsPetSurfacePalette

    var body: some View {
        if geometry.isVisible {
            ZStack {
                ForEach(geometry.targetCenters.keys.sorted(), id: \.self) { surfaceID in
                    if let target = geometry.targetCenters[surfaceID] {
                        let phase = geometry.phase(for: surfaceID)
                        OpenPetsSurfaceBeamView(
                            origin: geometry.origin,
                            target: target,
                            currentPoint: geometry.beamPoint(for: target, surfaceID: surfaceID),
                            phase: phase,
                            palette: palette
                        )
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct OpenPetsSurfaceBeamView: View {
    let origin: CGPoint
    let target: CGPoint
    let currentPoint: CGPoint
    let phase: OpenPetsSurfaceRevealPhase
    let palette: OpenPetsPetSurfacePalette

    var body: some View {
        ZStack {
            if beamLength > 1 {
                OpenPetsHotspotStyleCloudView(
                    palette: palette,
                    width: max(42, beamLength + 18),
                    height: 24,
                    blurScale: 0.72
                )
                .opacity(phase.beamOpacity * approachOpacity * 0.22)
                .rotationEffect(beamAngle)
                .position(beamMidpoint)
            }

            ForEach(Array(trailSamples.enumerated()), id: \.offset) { index, sampleProgress in
                OpenPetsHotspotStyleCloudView(
                    palette: palette,
                    width: 38 - CGFloat(index) * 2.2,
                    height: 18 - CGFloat(index) * 0.9,
                    blurScale: 0.68
                )
                .opacity(trailOpacity(for: index, sampleProgress: sampleProgress))
                .position(point(at: sampleProgress))
            }

            OpenPetsBeamOrbView(palette: palette, opacity: phase.beamOpacity * approachOpacity * 0.68)
                .position(currentPoint)
        }
    }

    private var trailSamples: [CGFloat] {
        let head = phase.beamProgress
        return (0..<7).map { index in
            max(0, head - CGFloat(index) * 0.075)
        }.filter { $0 > 0 }
    }

    private var beamLength: CGFloat {
        hypot(currentPoint.x - origin.x, currentPoint.y - origin.y)
    }

    private var beamAngle: Angle {
        Angle(radians: atan2(currentPoint.y - origin.y, currentPoint.x - origin.x))
    }

    private var beamMidpoint: CGPoint {
        CGPoint(x: (origin.x + currentPoint.x) / 2, y: (origin.y + currentPoint.y) / 2)
    }

    private var approachOpacity: CGFloat {
        max(0, 1 - max(0, phase.beamProgress - 0.82) / 0.18)
    }

    private func point(at progress: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + (target.x - origin.x) * progress,
            y: origin.y + (target.y - origin.y) * progress
        )
    }

    private func trailOpacity(for index: Int, sampleProgress: CGFloat) -> CGFloat {
        let distanceFromHead = max(0, phase.beamProgress - sampleProgress)
        let tailFade = max(0, 1 - distanceFromHead / 0.5)
        let indexFade = max(0.25, 1 - CGFloat(index) * 0.11)
        return phase.beamOpacity * approachOpacity * tailFade * indexFade * 0.38
    }
}

private struct OpenPetsBeamOrbView: View {
    let palette: OpenPetsPetSurfacePalette
    let opacity: CGFloat

    var body: some View {
        OpenPetsHotspotStyleCloudView(palette: palette, width: 52, height: 24, blurScale: 0.78)
        .opacity(opacity)
    }
}

struct OpenPetsHotspotVisibility: Equatable {
    static let defaultAlpha: CGFloat = 0.035
    static let revealDistance: CGFloat = 144
    static let compactDistance: CGFloat = 96
    static let fullDistance: CGFloat = 28

    var opacity: CGFloat
    var compactProgress: CGFloat

    init(distance: CGFloat, positionRevealProgress: CGFloat = 0) {
        let positionRevealProgress = max(0, min(positionRevealProgress, 1))
        if distance.isInfinite || distance >= Self.revealDistance {
            opacity = Self.defaultAlpha + positionRevealProgress * (1 - Self.defaultAlpha)
            compactProgress = positionRevealProgress
            return
        }

        let revealProgress = Self.smoothed(1 - max(0, min(distance / Self.revealDistance, 1)))
        opacity = Self.defaultAlpha + max(revealProgress, positionRevealProgress) * (1 - Self.defaultAlpha)

        if distance <= Self.fullDistance {
            compactProgress = 1
        } else if distance >= Self.compactDistance {
            compactProgress = positionRevealProgress
        } else {
            compactProgress = max(positionRevealProgress, Self.smoothed(
                1 - ((distance - Self.fullDistance) / (Self.compactDistance - Self.fullDistance))
            ))
        }
    }

    private static func smoothed(_ progress: CGFloat) -> CGFloat {
        progress * progress * (3 - 2 * progress)
    }
}

enum OpenPetsSurfaceHotspotLayout {
    static let widgetSize = CGSize(width: 184, height: 68)
    static let revealedHitSize = CGSize(width: 72, height: 26)
    static let minimalHitSize = CGSize(width: 14, height: 14)
    private static let sideGap: CGFloat = 73
    private static let belowGap: CGFloat = 18

    static func frame(for slot: OpenPetsSurfaceSlot?, petFrame: CGRect, panelSize: CGSize) -> CGRect {
        let center: CGPoint
        switch slot {
        case .some(.hotspotTopLeading):
            center = CGPoint(x: petFrame.minX - sideGap, y: petFrame.minY + 18)
        case .some(.hotspotTopTrailing), .none:
            center = CGPoint(x: petFrame.maxX + sideGap, y: petFrame.minY + 18)
        case .some(.hotspotRight):
            center = CGPoint(x: petFrame.maxX + sideGap, y: petFrame.midY)
        case .some(.hotspotBottomTrailing):
            center = CGPoint(x: petFrame.maxX + sideGap, y: petFrame.maxY - 18)
        case .some(.hotspotBottomLeading):
            center = CGPoint(x: petFrame.minX - sideGap, y: petFrame.maxY - 18)
        case .some(.hotspotLeft):
            center = CGPoint(x: petFrame.minX - sideGap, y: petFrame.midY)
        case .some(.hotspotBelowLeading):
            center = CGPoint(
                x: petFrame.midX - widgetSize.width / 2,
                y: petFrame.maxY + belowGap + widgetSize.height / 2
            )
        case .some(.hotspotBelowTrailing):
            center = CGPoint(
                x: petFrame.midX + widgetSize.width / 2,
                y: petFrame.maxY + belowGap + widgetSize.height / 2
            )
        case .some:
            center = CGPoint(x: petFrame.maxX + sideGap, y: petFrame.minY + 18)
        }

        let halfWidth = widgetSize.width / 2
        let halfHeight = widgetSize.height / 2
        let clampedCenter = CGPoint(
            x: min(max(center.x, halfWidth), max(halfWidth, panelSize.width - halfWidth)),
            y: min(max(center.y, halfHeight), max(halfHeight, panelSize.height - halfHeight))
        )
        return CGRect(
            x: clampedCenter.x - halfWidth,
            y: clampedCenter.y - halfHeight,
            width: widgetSize.width,
            height: widgetSize.height
        )
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    static func hotspotDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        hypot(point.x - frame.midX, point.y - frame.midY)
    }

    static func hitFrame(for frame: CGRect, visibility: OpenPetsHotspotVisibility) -> CGRect {
        let progress = visibility.compactProgress
        let size = CGSize(
            width: minimalHitSize.width + (revealedHitSize.width - minimalHitSize.width) * progress,
            height: minimalHitSize.height + (revealedHitSize.height - minimalHitSize.height) * progress
        )
        return CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private extension OpenPetsResolvedSurface {
    var primarySlot: OpenPetsSurfaceSlot? {
        guard case .placed(let slot) = placement else { return nil }
        return slot
    }

    var isVisibleSurface: Bool {
        guard case .placed = placement else { return false }
        return true
    }

    var isHotspotSurface: Bool {
        isVisibleSurface
    }
}

struct OpenPetsPetSurfaceColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var vividColor: Color {
        Color(
            hue: hue,
            saturation: 1,
            brightness: 1
        )
    }

    var brightness: Double {
        max(red, green, blue)
    }

    var saturation: Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        guard maximum > 0 else { return 0 }
        return (maximum - minimum) / maximum
    }

    var hue: Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }

        let rawHue: Double
        if maximum == red {
            rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            rawHue = ((blue - red) / delta) + 2
        } else {
            rawHue = ((red - green) / delta) + 4
        }

        let normalized = rawHue / 6
        return normalized < 0 ? normalized + 1 : normalized
    }

    var complementaryHue: Double {
        let hue = hue + 0.5
        return hue >= 1 ? hue - 1 : hue
    }

    func hueDistance(to other: OpenPetsPetSurfaceColor) -> Double {
        hueDistance(toHue: other.hue)
    }

    func hueDistance(toHue otherHue: Double) -> Double {
        let delta = abs(hue - otherHue)
        return min(delta, 1 - delta)
    }

    func distance(to other: OpenPetsPetSurfaceColor) -> Double {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue
        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }
}

struct OpenPetsPetSurfacePalette: Equatable {
    var primary: OpenPetsPetSurfaceColor
    var accent: OpenPetsPetSurfaceColor
    var highlight: OpenPetsPetSurfaceColor

    static let fallback = OpenPetsPetSurfacePalette(
        primary: OpenPetsPetSurfaceColor(red: 0.70, green: 0.30, blue: 0.96),
        accent: OpenPetsPetSurfaceColor(red: 1.00, green: 0.74, blue: 0.20),
        highlight: OpenPetsPetSurfaceColor(red: 1.00, green: 0.48, blue: 0.74)
    )

    static func extract(from frames: [PetAnimation: [CGImage]]) -> OpenPetsPetSurfacePalette {
        if let image = frames[.idle]?.first, let palette = extract(from: image) {
            return palette
        }
        for image in frames.values.flatMap({ $0 }) {
            if let palette = extract(from: image) {
                return palette
            }
        }
        return fallback
    }

    static func extract(from image: CGImage) -> OpenPetsPetSurfacePalette? {
        guard let buckets = OpenPetsPetSurfacePaletteBuckets(image: image), !buckets.colors.isEmpty else {
            return nil
        }
        let sortedColors = buckets.colors.sorted { lhs, rhs in
            lhs.score > rhs.score
        }
        guard let primary = sortedColors.first?.color else { return nil }
        let complementaryHue = primary.complementaryHue
        let accent = sortedColors
            .filter {
                $0.color.distance(to: primary) > 0.35
                    && $0.color.hueDistance(to: primary) > 0.22
                    && $0.color.saturation > 0.18
            }
            .max { lhs, rhs in
                accentScore(lhs, primary: primary, complementaryHue: complementaryHue)
                    < accentScore(rhs, primary: primary, complementaryHue: complementaryHue)
            }?.color
            ?? complementaryColor(for: primary)
        let highlight = sortedColors.first { candidate in
            candidate.color.distance(to: primary) > 0.20 && candidate.color.distance(to: accent) > 0.20
        }?.color ?? blended(primary, accent)
        return OpenPetsPetSurfacePalette(primary: primary, accent: accent, highlight: highlight)
    }

    private static func accentScore(
        _ candidate: OpenPetsPetSurfacePaletteBuckets.ScoredColor,
        primary: OpenPetsPetSurfaceColor,
        complementaryHue: Double
    ) -> Double {
        let hueFit = 1 - min(candidate.color.hueDistance(toHue: complementaryHue) / 0.5, 1)
        let representation = log(candidate.score + 1)
        return hueFit * 3
            + candidate.color.distance(to: primary) * 1.25
            + candidate.color.saturation * 0.75
            + representation * 0.15
    }

    private static func complementaryColor(for color: OpenPetsPetSurfaceColor) -> OpenPetsPetSurfaceColor {
        OpenPetsPetSurfaceColor(
            red: min(1, max(0, 1.0 - color.red + 0.12)),
            green: min(1, max(0, 1.0 - color.green + 0.12)),
            blue: min(1, max(0, 1.0 - color.blue + 0.12))
        )
    }

    private static func blended(
        _ first: OpenPetsPetSurfaceColor,
        _ second: OpenPetsPetSurfaceColor
    ) -> OpenPetsPetSurfaceColor {
        OpenPetsPetSurfaceColor(
            red: min(1, (first.red + second.red) / 2 + 0.08),
            green: min(1, (first.green + second.green) / 2 + 0.08),
            blue: min(1, (first.blue + second.blue) / 2 + 0.08)
        )
    }
}

private struct OpenPetsPetSurfacePaletteBuckets {
    struct ScoredColor {
        var color: OpenPetsPetSurfaceColor
        var score: Double
    }

    var colors: [ScoredColor]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampleStep = max(1, Int(sqrt(Double(width * height) / 4096.0)))
        var buckets: [Int: (count: Int, red: Double, green: Double, blue: Double, saturation: Double)] = [:]
        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = Double(pixels[offset + 3]) / 255.0
                guard alpha > 0.18 else { continue }
                let red = min(1, Double(pixels[offset]) / 255.0 / alpha)
                let green = min(1, Double(pixels[offset + 1]) / 255.0 / alpha)
                let blue = min(1, Double(pixels[offset + 2]) / 255.0 / alpha)
                let color = OpenPetsPetSurfaceColor(red: red, green: green, blue: blue)
                let brightness = max(red, green, blue)
                guard brightness > 0.12, color.saturation > 0.12 else { continue }

                let key = (Int(red * 7) << 8) | (Int(green * 7) << 4) | Int(blue * 7)
                var bucket = buckets[key] ?? (0, 0, 0, 0, 0)
                bucket.count += 1
                bucket.red += red
                bucket.green += green
                bucket.blue += blue
                bucket.saturation += color.saturation
                buckets[key] = bucket
            }
        }

        colors = buckets.values.compactMap { bucket in
            guard bucket.count > 0 else { return nil }
            let count = Double(bucket.count)
            let color = OpenPetsPetSurfaceColor(
                red: bucket.red / count,
                green: bucket.green / count,
                blue: bucket.blue / count
            )
            let score = count * (0.55 + bucket.saturation / count)
            return ScoredColor(color: color, score: score)
        }
    }
}

private struct OpenPetsCloudHotspotSurfaceView: View {
    let surface: OpenPetsSurfaceUpdate
    let visibility: OpenPetsHotspotVisibility
    let palette: OpenPetsPetSurfacePalette

    var body: some View {
        ZStack {
            hiddenGlow
                .opacity(1 - visibility.compactProgress)

            OpenPetsHotspotStyleCloudView(palette: palette)
                .opacity(visibility.compactProgress)

            HStack(spacing: 5) {
                Image(systemName: surface.icon)
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                Text(surface.value)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .opacity(visibility.compactProgress)
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.18), radius: 1)
            .scaleEffect(0.84 + visibility.compactProgress * 0.16)
        }
        .opacity(visibility.opacity)
    }

    private var hiddenGlow: some View {
        Circle()
            .fill(palette.primary.vividColor)
            .frame(width: 9, height: 9)
            .blur(radius: 6)
            .overlay {
                Circle()
                    .fill(palette.accent.vividColor)
                    .frame(width: 5, height: 5)
                    .blur(radius: 4)
                    .offset(x: 4, y: 0)
            }
    }

}

private struct OpenPetsHotspotStyleCloudView: View {
    let palette: OpenPetsPetSurfacePalette
    var width: CGFloat = 66
    var height: CGFloat = 30
    var blurScale: CGFloat = 1

    var body: some View {
        ZStack {
            Ellipse()
                .fill(palette.accent.vividColor)
                .frame(width: width, height: height)
                .blur(radius: 13 * blurScale)
                .offset(x: -width * 0.27, y: -height * 0.03)
                .blendMode(.screen)
            Ellipse()
                .fill(palette.primary.vividColor)
                .frame(width: width, height: height)
                .blur(radius: 13 * blurScale)
                .offset(x: width * 0.27, y: height * 0.03)
                .blendMode(.screen)
            Ellipse()
                .fill(palette.highlight.vividColor)
                .frame(width: width * 0.64, height: height * 0.8)
                .blur(radius: 12 * blurScale)
                .offset(x: -width * 0.03, y: 0)
                .blendMode(.screen)
        }
        .compositingGroup()
        .blur(radius: blurScale)
    }
}

@MainActor
final class PetHostView: NSView {
    var onClick: (() -> Void)? {
        get { spriteView.onClick }
        set { spriteView.onClick = newValue }
    }

    var onDragMove: ((CGPoint) -> Void)? {
        get { spriteView.onDragMove }
        set { spriteView.onDragMove = newValue }
    }

    var onDragDirectionChange: ((PetAnimation) -> Void)? {
        get { spriteView.onDragDirectionChange }
        set { spriteView.onDragDirectionChange = newValue }
    }

    var onDragStart: (() -> Void)? {
        get { spriteView.onDragStart }
        set { spriteView.onDragStart = newValue }
    }

    var onDragEnd: ((CGVector, PetAnimation?) -> Void)? {
        get { spriteView.onDragEnd }
        set { spriteView.onDragEnd = newValue }
    }

    var onInteractionEnd: (() -> Void)? {
        get { spriteView.onInteractionEnd }
        set { spriteView.onInteractionEnd = newValue }
    }

    var contextMenuPresenter: (NSMenu, NSEvent, NSView) -> Void {
        get { spriteView.contextMenuPresenter }
        set { spriteView.contextMenuPresenter = newValue }
    }

    var visibleSpriteFrame: CGRect {
        bounds
    }

    var petAnchorFrame: CGRect {
        bounds
    }

    private let spriteView: PetSpriteView
    private let spriteSize: CGSize
    private let stableSpriteBounds: CGRect

    init(
        spriteSize: CGSize,
        stableSpriteBounds: CGRect,
        frames: [PetAnimation: [CGImage]],
        contextMenuProvider: (@MainActor () -> NSMenu?)? = nil
    ) {
        self.spriteSize = spriteSize
        self.stableSpriteBounds = stableSpriteBounds
        let size = CGSize(
            width: max(1, stableSpriteBounds.width),
            height: max(1, stableSpriteBounds.height)
        )
        spriteView = PetSpriteView(
            frame: CGRect(origin: .zero, size: size),
            spriteSize: spriteSize,
            frames: frames,
            contextMenuProvider: contextMenuProvider
        )
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(spriteView)
        applyCurrentLayoutToSubviews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return spriteView.hitTest(convert(point, to: spriteView))
    }

    override func layout() {
        super.layout()
        applyCurrentLayoutToSubviews()
    }

    func set(animation: PetAnimation, frameIndex: Int) {
        spriteView.set(animation: animation, frameIndex: frameIndex)
    }

    func set(image: CGImage) {
        spriteView.set(image: image)
    }

    private func applyCurrentLayoutToSubviews() {
        spriteView.frame = bounds
        spriteView.spriteFrame = CGRect(
            x: -stableSpriteBounds.minX,
            y: -stableSpriteBounds.minY,
            width: spriteSize.width,
            height: spriteSize.height
        )
    }
}

@MainActor
final class PetMessagePanelView: NSView {
    var onDismissMessage: ((String) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var actionURLOpener = OpenPetsActionURLOpener()

    var hasVisibleMessages: Bool {
        !messageStack.visibleMessages().isEmpty
    }

    var petAnchorFrame: CGRect {
        currentMessageLayout.petFrame
    }

    private lazy var bubbleView: MessageHostingView = {
        MessageHostingView(rootView: OpenPetsMessageView(
            messages: [],
            hiddenMessageCount: 0,
            isCollapsed: false,
            activeMessageCount: 0,
            layout: .empty,
            cardFrames: [],
            messageAreaHeight: messageAreaHeight,
            onDismiss: { _ in },
            onToggle: {}
        ))
    }()
    private let petSize: CGSize
    private let messageAreaHeight: CGFloat
    private let closedModeRevealDurationNanoseconds: UInt64
    private var messageStack = PetMessageStack()
    private var isMessageStackCollapsed = false
    private var isSurfacingClosedModeMessages = false
    private var closedModeRevealTask: Task<Void, Never>?
    private var closedModeRevealGeneration = 0
    private var currentMessageLayout = OpenPetsMessageLayout.empty
    private var mouseDownMessageTarget: MessageMouseTarget?

    var isEffectivelyCollapsedForTesting: Bool {
        isEffectivelyCollapsed
    }

    var isSurfacingClosedModeMessagesForTesting: Bool {
        isSurfacingClosedModeMessages
    }

    private enum MessageMouseTarget: Equatable {
        case toggle
        case dismiss(String)
        case action(String, PetBubbleAction)
    }

    init(
        petSize: CGSize,
        messageAreaHeight: CGFloat,
        closedModeRevealDurationNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.petSize = petSize
        self.messageAreaHeight = messageAreaHeight
        self.closedModeRevealDurationNanoseconds = closedModeRevealDurationNanoseconds
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        bubbleView.wantsLayer = true
        bubbleView.layer?.backgroundColor = NSColor.clear.cgColor
        bubbleView.isHidden = true
        addSubview(bubbleView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if messageMouseTarget(at: point) != nil {
            return self
        }
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        return messageMouseTarget(for: event) != nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownMessageTarget = messageMouseTarget(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        let target = messageMouseTarget(for: event)
        defer { mouseDownMessageTarget = nil }

        guard let mouseDownMessageTarget, mouseDownMessageTarget == target else {
            return
        }

        switch mouseDownMessageTarget {
        case .toggle:
            toggleMessageStackCollapsed()
        case .dismiss(let threadId):
            onDismissMessage?(threadId)
        case .action(let threadId, let action):
            action.open(source: "bubble", using: actionURLOpener)
            onDismissMessage?(threadId)
        }
    }

    override func layout() {
        super.layout()
        bubbleView.frame = bounds
    }

    func setBubble(_ bubble: PetBubble, threadId: String) {
        let shouldSurfaceInClosedMode = isMessageStackCollapsed
        messageStack.setBubble(bubble, threadId: threadId)
        if shouldSurfaceInClosedMode {
            surfaceClosedModeMessagesTemporarily()
        } else {
            relayoutMessages()
        }
    }

    func clearBubble(threadId: String) {
        messageStack.clearBubble(threadId: threadId)
        if messageStack.activeCount == 0 {
            isMessageStackCollapsed = false
            cancelClosedModeReveal()
        }
        relayoutMessages()
    }

    func clearBubbles() {
        messageStack.clearBubbles()
        isMessageStackCollapsed = false
        cancelClosedModeReveal()
        relayoutMessages()
    }

    func resizeWindow(preservingPetAnchor petAnchor: CGPoint) {
        guard let window, hasVisibleMessages else { return }
        var frame = window.frame
        frame.origin = PetWindowPositioning.windowOrigin(
            preservingPetAnchor: petAnchor,
            petFrame: currentMessageLayout.petFrame
        )
        frame.size = currentMessageLayout.containerSize
        window.setFrame(frame, display: false)
    }

    private var isEffectivelyCollapsed: Bool {
        isMessageStackCollapsed && !isSurfacingClosedModeMessages
    }

    private func relayoutMessages() {
        let messages = messageStack.visibleMessages()
        if messages.isEmpty {
            currentMessageLayout = .empty
            bubbleView.frame = .zero
            bubbleView.interactiveRects = []
            bubbleView.dismissRegions = []
            updateMessageView(messages: [], hiddenMessageCount: 0, layout: .empty)
            setFrameSize(.zero)
            onLayoutChanged?()
            return
        }

        currentMessageLayout = OpenPetsMessageLayout.makeMessagePanel(
            messages: messages,
            hiddenMessageCount: messageStack.hiddenMessageCount(),
            isCollapsed: isEffectivelyCollapsed,
            petSize: petSize,
            messageAreaHeight: messageAreaHeight
        )
        setFrameSize(currentMessageLayout.containerSize)
        bubbleView.frame = bounds
        updateMessageHitRegions(messages: messages, layout: currentMessageLayout)
        updateMessageView(
            messages: messages,
            hiddenMessageCount: messageStack.hiddenMessageCount(),
            layout: currentMessageLayout
        )
        onLayoutChanged?()
    }

    private func updateMessageView(
        messages: [PetMessage],
        hiddenMessageCount: Int,
        layout: OpenPetsMessageLayout
    ) {
        bubbleView.rootView = OpenPetsMessageView(
            messages: messages,
            hiddenMessageCount: hiddenMessageCount,
            isCollapsed: isEffectivelyCollapsed,
            activeMessageCount: messageStack.activeCount,
            layout: layout,
            cardFrames: layout.cardFrames,
            messageAreaHeight: messageAreaHeight,
            onDismiss: { [weak self] threadId in
                self?.onDismissMessage?(threadId)
            },
            onToggle: { [weak self] in
                self?.toggleMessageStackCollapsed()
            }
        )
        bubbleView.isHidden = messages.isEmpty
    }

    private func updateMessageHitRegions(messages: [PetMessage], layout: OpenPetsMessageLayout) {
        bubbleView.interactiveRects = layout.cardFrames + (layout.toggleFrame.isEmpty ? [] : [layout.toggleFrame])
        bubbleView.dismissRegions = zip(messages, layout.cardFrames).map { message, cardFrame in
            MessageHostingView.InteractiveRegion(
                threadId: message.threadId,
                cardFrame: cardFrame,
                closeButtonFrame: OpenPetsMessageLayout.closeButtonFrame(in: cardFrame),
                action: message.bubble.action
            )
        }
        bubbleView.onDismissMessage = { [weak self] threadId in
            self?.onDismissMessage?(threadId)
        }
    }

    private func messageMouseTarget(at point: NSPoint) -> MessageMouseTarget? {
        let normalizedPoint = isFlipped
            ? CGPoint(x: point.x, y: bounds.height - point.y)
            : point
        if currentMessageLayout.toggleFrame.contains(normalizedPoint), messageStack.activeCount > 0 {
            return .toggle
        }
        if let dismissRegion = bubbleView.dismissRegions.first(where: { $0.closeButtonFrame.contains(normalizedPoint) }) {
            return .dismiss(dismissRegion.threadId)
        }
        if
            let actionRegion = bubbleView.dismissRegions.first(where: { $0.cardFrame.contains(normalizedPoint) && $0.action != nil }),
            let action = actionRegion.action
        {
            return .action(actionRegion.threadId, action)
        }
        return nil
    }

    private func messageMouseTarget(for event: NSEvent) -> MessageMouseTarget? {
        messageMouseTarget(at: convert(event.locationInWindow, from: nil))
    }

    private func toggleMessageStackCollapsed() {
        guard messageStack.activeCount > 0 else { return }
        if isEffectivelyCollapsed {
            isMessageStackCollapsed = false
        } else {
            isMessageStackCollapsed = true
        }
        cancelClosedModeReveal()
        relayoutMessages()
    }

    private func surfaceClosedModeMessagesTemporarily() {
        closedModeRevealTask?.cancel()
        closedModeRevealGeneration += 1
        isSurfacingClosedModeMessages = true
        relayoutMessages()

        let generation = closedModeRevealGeneration
        let durationNanoseconds = closedModeRevealDurationNanoseconds
        closedModeRevealTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }
            guard
                let self,
                self.isMessageStackCollapsed,
                self.closedModeRevealGeneration == generation
            else {
                return
            }
            self.isSurfacingClosedModeMessages = false
            self.closedModeRevealTask = nil
            self.relayoutMessages()
        }
    }

    private func cancelClosedModeReveal() {
        closedModeRevealTask?.cancel()
        closedModeRevealTask = nil
        closedModeRevealGeneration += 1
        isSurfacingClosedModeMessages = false
    }
}

struct OpenPetsMessageLayout {
    static let toggleDiameter: CGFloat = 34
    static let messageShadowOutset: CGFloat = 4
    static let verticalGap: CGFloat = 10
    static let messagePanelHorizontalOffset: CGFloat = 5
    static let messagePanelVerticalOffset: CGFloat = -10
    static let stackGap: CGFloat = 8
    static let toggleGapBelowCard: CGFloat = 4
    static let sideInset: CGFloat = 12
    static let maxCardWidth: CGFloat = 260
    static let closeButtonSize = CGSize(width: 22, height: 22)
    static let closeButtonInset: CGFloat = 8
    static let empty = OpenPetsMessageLayout(
        containerSize: .zero,
        cardFrames: [],
        spriteFrame: .zero,
        petFrame: .zero,
        toggleFrame: .zero
    )

    var containerSize: CGSize
    var cardFrames: [CGRect]
    var spriteFrame: CGRect
    var petFrame: CGRect
    var toggleFrame: CGRect

    var cardFrame: CGRect {
        cardFrames.first ?? .zero
    }

    static func closeButtonFrame(in cardFrame: CGRect) -> CGRect {
        CGRect(
            x: cardFrame.minX + closeButtonInset,
            y: cardFrame.maxY - closeButtonInset - closeButtonSize.height,
            width: closeButtonSize.width,
            height: closeButtonSize.height
        )
    }

    private static func bounds(for frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { partialResult, frame in
            partialResult.union(frame)
        }
    }

    private static func boundsIncludingMessageShadow(for frames: [CGRect]) -> CGRect {
        bounds(for: frames).insetBy(dx: -messageShadowOutset, dy: -messageShadowOutset)
    }

    @MainActor
    static func make(
        bubble: PetBubble,
        isCollapsed: Bool,
        containerWidth: CGFloat,
        spriteSize: CGSize,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        _ = isCollapsed
        return make(
            messages: [PetMessage(threadId: "preview", bubble: bubble)],
            hiddenMessageCount: 0,
            isCollapsed: isCollapsed,
            containerWidth: containerWidth,
            spriteSize: spriteSize,
            messageAreaHeight: messageAreaHeight
        )
    }

    @MainActor
    static func make(
        messages: [PetMessage],
        hiddenMessageCount: Int,
        isCollapsed: Bool = false,
        containerWidth: CGFloat,
        spriteSize: CGSize,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        let cardMaxWidth = min(maxCardWidth, max(1, containerWidth - sideInset * 2))
        let rightEdge = containerWidth - sideInset
        let spriteFrame = CGRect(
            x: rightEdge - spriteSize.width,
            y: 0,
            width: spriteSize.width,
            height: spriteSize.height
        )
        var cardFrames: [CGRect] = []
        var nextY = spriteFrame.maxY + verticalGap

        for message in isCollapsed ? [] : messages {
            let cardSize = OpenPetsBubbleContentView.size(
                for: message.bubble,
                maxWidth: cardMaxWidth,
                messageAreaHeight: messageAreaHeight
            )
            cardFrames.append(CGRect(
                x: rightEdge - cardSize.width,
                y: nextY,
                width: cardSize.width,
                height: cardSize.height
            ))
            nextY += cardSize.height + stackGap
        }

        let toggleFrame: CGRect
        if messages.isEmpty {
            toggleFrame = .zero
        } else {
            let bottomCardMinY = cardFrames.first?.minY ?? spriteFrame.maxY + verticalGap
            toggleFrame = CGRect(
                x: rightEdge - toggleDiameter,
                y: bottomCardMinY - toggleDiameter - toggleGapBelowCard,
                width: toggleDiameter,
                height: toggleDiameter
            )
        }

        if !cardFrames.isEmpty {
            nextY -= stackGap
        }

        let messageFrames = cardFrames + (toggleFrame.isEmpty ? [] : [toggleFrame])
        let messageMaxY = messageFrames.isEmpty ? 0 : boundsIncludingMessageShadow(for: messageFrames).maxY
        let contentHeight: CGFloat
        if messages.isEmpty {
            contentHeight = spriteSize.height
        } else if isCollapsed {
            contentHeight = max(spriteSize.height + toggleDiameter / 2, messageMaxY)
        } else {
            contentHeight = max(spriteSize.height, nextY, messageMaxY)
        }

        return OpenPetsMessageLayout(
            containerSize: CGSize(width: containerWidth, height: contentHeight),
            cardFrames: cardFrames,
            spriteFrame: spriteFrame,
            petFrame: spriteFrame,
            toggleFrame: toggleFrame
        )
    }

    @MainActor
    static func makeMinimal(
        messages: [PetMessage],
        hiddenMessageCount: Int,
        isCollapsed: Bool = false,
        spriteSize: CGSize,
        stableSpriteBounds: CGRect,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        _ = hiddenMessageCount
        let petSize = CGSize(
            width: max(1, stableSpriteBounds.width),
            height: max(1, stableSpriteBounds.height)
        )
        let cardSizes = isCollapsed ? [] : messages.map {
            OpenPetsBubbleContentView.size(
                for: $0.bubble,
                maxWidth: maxCardWidth,
                messageAreaHeight: messageAreaHeight
            )
        }
        let widestCard = cardSizes.map(\.width).max() ?? 0
        let rightEdge = max(petSize.width, widestCard, messages.isEmpty ? 0 : toggleDiameter)
        let petFrame = CGRect(
            x: rightEdge - petSize.width,
            y: 0,
            width: petSize.width,
            height: petSize.height
        )
        let spriteFrame = CGRect(
            x: petFrame.minX - stableSpriteBounds.minX,
            y: petFrame.minY - stableSpriteBounds.minY,
            width: spriteSize.width,
            height: spriteSize.height
        )

        var cardFrames: [CGRect] = []
        var nextY = petFrame.maxY + verticalGap
        for cardSize in cardSizes {
            cardFrames.append(CGRect(
                x: rightEdge - cardSize.width,
                y: nextY,
                width: cardSize.width,
                height: cardSize.height
            ))
            nextY += cardSize.height + stackGap
        }

        let toggleFrame: CGRect
        if messages.isEmpty {
            toggleFrame = .zero
        } else {
            let bottomCardMinY = cardFrames.first?.minY ?? petFrame.maxY + verticalGap
            toggleFrame = CGRect(
                x: rightEdge - toggleDiameter,
                y: bottomCardMinY - toggleDiameter - toggleGapBelowCard,
                width: toggleDiameter,
                height: toggleDiameter
            )
        }

        let messageFrames = cardFrames + (toggleFrame.isEmpty ? [] : [toggleFrame])
        let contentBounds: CGRect
        if messageFrames.isEmpty {
            contentBounds = petFrame
        } else {
            contentBounds = petFrame.union(boundsIncludingMessageShadow(for: messageFrames))
        }
        let offset = CGVector(dx: -contentBounds.minX, dy: -contentBounds.minY)
        let normalizedCardFrames = cardFrames.map { $0.offsetBy(dx: offset.dx, dy: offset.dy) }

        return OpenPetsMessageLayout(
            containerSize: contentBounds.size,
            cardFrames: normalizedCardFrames,
            spriteFrame: spriteFrame.offsetBy(dx: offset.dx, dy: offset.dy),
            petFrame: petFrame.offsetBy(dx: offset.dx, dy: offset.dy),
            toggleFrame: toggleFrame.isEmpty ? .zero : toggleFrame.offsetBy(dx: offset.dx, dy: offset.dy)
        )
    }

    @MainActor
    static func makeMessagePanel(
        messages: [PetMessage],
        hiddenMessageCount: Int,
        isCollapsed: Bool = false,
        petSize: CGSize,
        messageAreaHeight: CGFloat
    ) -> OpenPetsMessageLayout {
        _ = hiddenMessageCount
        guard !messages.isEmpty else { return .empty }

        let cardSizes = isCollapsed ? [] : messages.map {
            OpenPetsBubbleContentView.size(
                for: $0.bubble,
                maxWidth: maxCardWidth,
                messageAreaHeight: messageAreaHeight
            )
        }
        let widestCard = cardSizes.map(\.width).max() ?? 0
        let rightEdge = max(petSize.width, widestCard, toggleDiameter)
        let petFrame = CGRect(
            x: rightEdge - petSize.width,
            y: 0,
            width: max(1, petSize.width),
            height: max(1, petSize.height)
        )

        var cardFrames: [CGRect] = []
        var nextY = petFrame.maxY + verticalGap + messagePanelVerticalOffset
        for cardSize in cardSizes {
            cardFrames.append(CGRect(
                x: rightEdge + messagePanelHorizontalOffset - cardSize.width,
                y: nextY,
                width: cardSize.width,
                height: cardSize.height
            ))
            nextY += cardSize.height + stackGap
        }

        let toggleFrame = CGRect(
            x: rightEdge + messagePanelHorizontalOffset - toggleDiameter,
            y: petFrame.maxY + verticalGap + messagePanelVerticalOffset,
            width: toggleDiameter,
            height: toggleDiameter
        )
        for index in cardFrames.indices {
            cardFrames[index].origin.y += toggleDiameter + toggleGapBelowCard
        }
        let messageFrames = cardFrames + [toggleFrame]
        let messageBounds = boundsIncludingMessageShadow(for: messageFrames)
        let offset = CGVector(dx: -messageBounds.minX, dy: -messageBounds.minY)
        let normalizedCardFrames = cardFrames.map { $0.offsetBy(dx: offset.dx, dy: offset.dy) }

        return OpenPetsMessageLayout(
            containerSize: messageBounds.size,
            cardFrames: normalizedCardFrames,
            spriteFrame: .zero,
            petFrame: petFrame.offsetBy(dx: offset.dx, dy: offset.dy),
            toggleFrame: toggleFrame.offsetBy(dx: offset.dx, dy: offset.dy)
        )
    }

}

private final class MessageHostingView: NSHostingView<OpenPetsMessageView> {
    struct InteractiveRegion {
        var threadId: String
        var cardFrame: CGRect
        var closeButtonFrame: CGRect
        var action: PetBubbleAction?
    }

    var interactiveRects: [CGRect] = []
    var dismissRegions: [InteractiveRegion] = []
    var onDismissMessage: ((String) -> Void)?
    private var mouseDownDismissThreadId: String?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsInteractiveContent(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownDismissThreadId = dismissThreadId(for: event)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownDismissThreadId = nil }
        guard
            let mouseDownDismissThreadId,
            dismissThreadId(for: event) == mouseDownDismissThreadId
        else {
            super.mouseUp(with: event)
            return
        }

        onDismissMessage?(mouseDownDismissThreadId)
    }

    private func containsInteractiveContent(_ point: NSPoint) -> Bool {
        let normalizedPoint = layoutPoint(fromViewPoint: point)
        return interactiveRects.contains { $0.contains(normalizedPoint) }
    }

    private func dismissThreadId(for event: NSEvent) -> String? {
        let point = convert(event.locationInWindow, from: nil)
        let layoutPoint = layoutPoint(fromViewPoint: point)
        return dismissRegions.first { $0.closeButtonFrame.contains(layoutPoint) }?.threadId
    }

    private func layoutPoint(fromViewPoint point: NSPoint) -> CGPoint {
        isFlipped
            ? CGPoint(x: point.x, y: bounds.height - point.y)
            : point
    }
}

private struct OpenPetsMessageView: View {
    let messages: [PetMessage]
    let hiddenMessageCount: Int
    let isCollapsed: Bool
    let activeMessageCount: Int
    let layout: OpenPetsMessageLayout
    let cardFrames: [CGRect]
    let messageAreaHeight: CGFloat
    let onDismiss: (String) -> Void
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if !messages.isEmpty {
                ZStack(alignment: .topLeading) {
                    if !isCollapsed {
                        ForEach(Array(zip(messages, cardFrames)), id: \.0.threadId) { message, frame in
                            OpenPetsDismissibleBubbleView(
                                message: message,
                                messageAreaHeight: messageAreaHeight,
                                onDismiss: onDismiss
                            )
                                .position(swiftUIPosition(for: frame))
                        }
                    }
                    if !layout.toggleFrame.isEmpty {
                        toggleButton
                            .position(swiftUIPosition(for: layout.toggleFrame))
                    }
                }
                .frame(
                    width: layout.containerSize.width,
                    height: layout.containerSize.height,
                    alignment: .topLeading
                )
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private func swiftUIPosition(for frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.midX,
            y: layout.containerSize.height - frame.midY
        )
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.96 : 0.98))
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.6 : 0.35), lineWidth: 1)

                if isCollapsed {
                    Text("\(min(max(activeMessageCount, 1), 99))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: OpenPetsMessageLayout.toggleDiameter, height: OpenPetsMessageLayout.toggleDiameter)
            .contentShape(Circle())
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Show messages" : "Hide messages")
        .accessibilityValue(isCollapsed ? "\(activeMessageCount) active" : "")
    }
}

private struct OpenPetsDismissibleBubbleView: View {
    let message: PetMessage
    let messageAreaHeight: CGFloat
    let onDismiss: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        OpenPetsBubbleContentView(
            bubble: message.bubble,
            messageAreaHeight: messageAreaHeight,
            showsAction: isHovered
        )
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button {
                        onDismiss(message.threadId)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(
                                width: OpenPetsMessageLayout.closeButtonSize.width,
                                height: OpenPetsMessageLayout.closeButtonSize.height
                            )
                    }
                    .buttonStyle(.plain)
                    .background(closeButtonBackground)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.55 : 0.35), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.07), radius: 2, x: 0, y: 1)
                    .padding(.top, OpenPetsMessageLayout.closeButtonInset)
                    .padding(.leading, OpenPetsMessageLayout.closeButtonInset)
                    .transition(.offset(x: -6).combined(with: .opacity))
                    .accessibilityLabel("Dismiss message")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.16)) {
                    isHovered = hovering
                }
            }
    }

    private var closeButtonBackground: some View {
        Color(nsColor: colorScheme == .dark ? .black : .white)
            .opacity(colorScheme == .dark ? 0.82 : 0.94)
    }
}

private struct OpenPetsBubbleContentView: View {
    let bubble: PetBubble
    var messageAreaHeight: CGFloat = 84
    var showsAction = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let action = bubble.action {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    action.open(source: "bubble")
                } label: {
                    bubbleContent
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityLabel(bubble.title)

                if showsAction {
                    actionButton(action)
                        .frame(maxWidth: max(1, bubbleSize.width - 24), alignment: .trailing)
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                        .transition(.offset(x: 8).combined(with: .opacity))
                }
            }
            .frame(width: bubbleSize.width, height: bubbleSize.height)
            .animation(.easeOut(duration: 0.16), value: showsAction)
        } else {
            bubbleContent
        }
    }

    private var bubbleSize: CGSize {
        Self.size(for: bubble, messageAreaHeight: messageAreaHeight)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bubble.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id("title-\(bubble.title)")
                        .transition(Self.textTransition)

                    if let detail = bubble.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(bubble.detailLineLimit)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: false)
                            .id("detail-\(detail)")
                            .transition(Self.textTransition)
                    }
                }
                .animation(Self.textAnimation, value: bubble.title)
                .animation(Self.textAnimation, value: bubble.detail)

                Spacer(minLength: 4)
                if bubble.indicator != .none {
                    indicator(for: bubble.indicator)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(width: bubbleSize.width, height: bubbleSize.height)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.55 : 0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 4, x: 0, y: 1)
    }

    private static var textAnimation: Animation {
        .easeOut(duration: 0.16)
    }

    private static var textTransition: AnyTransition {
        .opacity.combined(with: .offset(y: 2))
    }

    static func size(for bubble: PetBubble, maxWidth: CGFloat = 260, messageAreaHeight: CGFloat = 84) -> CGSize {
        let width = min(260, maxWidth)
        let maxHeight = messageAreaHeight - 12
        guard let detail = bubble.detail, !detail.isEmpty else {
            return CGSize(width: width, height: min(maxHeight, 44))
        }

        let bodyLineCount = measuredBodyLineCount(
            for: detail,
            bubbleWidth: width,
            lineLimit: bubble.detailLineLimit
        )
        let oneLineBodyHeight: CGFloat = 56
        let bodyLineHeight: CGFloat = 16
        let desiredHeight = oneLineBodyHeight + CGFloat(bodyLineCount - 1) * bodyLineHeight
        let height = bubble.detailLineLimit == nil ? desiredHeight : min(maxHeight, desiredHeight)
        return CGSize(
            width: width,
            height: height
        )
    }

    private static func measuredBodyLineCount(for detail: String, bubbleWidth: CGFloat, lineLimit: Int?) -> Int {
        let bodyWidth = max(1, bubbleWidth - 54)
        let font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let rect = NSString(string: detail).boundingRect(
            with: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        let bodyLineHeight: CGFloat = 15
        let measuredLineCount = max(1, Int(ceil((rect.height - 0.5) / bodyLineHeight)))
        guard let lineLimit else {
            return measuredLineCount
        }
        return min(lineLimit, measuredLineCount)
    }

    private var background: some View {
        Color(nsColor: .controlBackgroundColor)
            .opacity(colorScheme == .dark ? 0.92 : 0.96)
    }

    private func actionButton(_ action: PetBubbleAction) -> some View {
        Button {
            action.open(source: "button")
        } label: {
            Text(action.label)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .frame(height: 20)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: colorScheme == .dark ? .black : .white).opacity(colorScheme == .dark ? 0.82 : 0.94))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.55 : 0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 2, x: 0, y: 1)
        .accessibilityLabel(action.label)
    }

    @ViewBuilder
    private func indicator(for indicator: PetBubbleIndicator) -> some View {
        switch indicator {
        case .none:
            EmptyView()
        case .working:
            ProgressView()
                .scaleEffect(0.5)
                .opacity(0.7)
        case .waiting:
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemOrange))
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .review:
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemPurple))
                Image(systemName: "eye")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .success:
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemGreen))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .attention:
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct WorkingProgressRing: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.2) / 1.2
            let progress = 0.12 + phase * 0.76

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        }
    }
}

struct PetSpriteVisibility {
    private let width: Int
    private let height: Int
    private let alphas: [UInt8]

    init?(image: CGImage) {
        let imageWidth = image.width
        let imageHeight = image.height
        guard imageWidth > 0, imageHeight > 0, imageWidth <= Int.max / imageHeight / 4 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = imageWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * imageHeight)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        guard let renderedAlphas = rgba.withUnsafeMutableBytes({ buffer -> [UInt8]? in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                )
            else {
                return nil
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

            let bytes = buffer.bindMemory(to: UInt8.self)
            var alphas = [UInt8](repeating: 0, count: imageWidth * imageHeight)
            for index in 0..<alphas.count {
                alphas[index] = bytes[index * bytesPerPixel + 3]
            }
            return alphas
        }) else {
            return nil
        }

        width = imageWidth
        height = imageHeight
        alphas = renderedAlphas
    }

    func visibleBounds(in frame: CGRect) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for pixelY in 0..<height {
            for pixelX in 0..<width where alphas[pixelY * width + pixelX] > 0 {
                minX = min(minX, pixelX)
                minY = min(minY, pixelY)
                maxX = max(maxX, pixelX)
                maxY = max(maxY, pixelY)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        let scaleX = frame.width / CGFloat(width)
        let scaleY = frame.height / CGFloat(height)
        return CGRect(
            x: frame.minX + CGFloat(minX) * scaleX,
            y: frame.minY + CGFloat(minY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
    }

    static func stableVisibleBounds(in frames: [PetAnimation: [CGImage]], spriteSize: CGSize) -> CGRect {
        let fullSpriteBounds = CGRect(origin: .zero, size: spriteSize)
        let images = frames.values.flatMap { $0 }
        var stableBounds = CGRect.null
        for image in images {
            guard let mask = PetSpriteVisibility(image: image) else {
                return fullSpriteBounds
            }
            guard let visibleBounds = mask.visibleBounds(in: fullSpriteBounds) else {
                continue
            }
            stableBounds = stableBounds.union(visibleBounds)
        }

        guard !stableBounds.isNull else {
            return fullSpriteBounds
        }

        return stableBounds
    }
}

final class PetSpriteFrameAsset {
    let image: CGImage
    let renderedImage: NSImage

    init(image: CGImage, spriteSize: CGSize) {
        self.image = image
        renderedImage = NSImage(cgImage: image, size: spriteSize)
    }
}

final class PetSpriteFrameStore {
    private let assetsByAnimation: [PetAnimation: [PetSpriteFrameAsset]]

    init(frames: [PetAnimation: [CGImage]], spriteSize: CGSize) {
        assetsByAnimation = frames.mapValues { images in
            images.map { PetSpriteFrameAsset(image: $0, spriteSize: spriteSize) }
        }
    }

    func asset(for animation: PetAnimation, frameIndex: Int) -> PetSpriteFrameAsset? {
        guard let assets = assetsByAnimation[animation], !assets.isEmpty else { return nil }
        return assets[frameIndex % assets.count]
    }
}

struct PetDragUpdate: Equatable {
    var windowOrigin: CGPoint
    var isDragging: Bool
    var directionChange: PetAnimation?
}

struct PetDragEnd: Equatable {
    var wasDragging: Bool
    var releaseVelocity: CGVector
    var fallbackAnimation: PetAnimation?
}

struct PetDragTracker {
    private var mouseDownScreenLocation = CGPoint.zero
    private var previousDragScreenLocation = CGPoint.zero
    private var mouseDownWindowOrigin = CGPoint.zero
    private var dragging = false
    private var active = false
    private var lastDragAnimation: PetAnimation?
    private var dragSamples: [DragSample] = []

    private struct DragSample {
        var location: CGPoint
        var timestamp: TimeInterval
    }

    private static let dragStartDistance: CGFloat = 4
    private static let dragDirectionThreshold: CGFloat = 0.5
    private static let dragVelocitySampleWindow: TimeInterval = 0.12
    private static let maximumDragVelocitySamples = 8

    var isDragging: Bool {
        dragging
    }

    mutating func start(screenLocation: CGPoint, windowOrigin: CGPoint, timestamp: TimeInterval) {
        active = true
        mouseDownScreenLocation = screenLocation
        previousDragScreenLocation = screenLocation
        mouseDownWindowOrigin = windowOrigin
        dragging = false
        lastDragAnimation = nil
        dragSamples = [DragSample(location: screenLocation, timestamp: timestamp)]
    }

    mutating func drag(to screenLocation: CGPoint, timestamp: TimeInterval) -> PetDragUpdate? {
        guard active else { return nil }
        appendDragSample(location: screenLocation, timestamp: timestamp)
        let delta = CGPoint(
            x: screenLocation.x - mouseDownScreenLocation.x,
            y: screenLocation.y - mouseDownScreenLocation.y
        )

        if !dragging, hypot(delta.x, delta.y) > PetDragTracker.dragStartDistance {
            dragging = true
        }

        let windowOrigin = dragging
            ? CGPoint(
                x: mouseDownWindowOrigin.x + delta.x,
                y: mouseDownWindowOrigin.y + delta.y
            )
            : mouseDownWindowOrigin

        let incrementalX = screenLocation.x - previousDragScreenLocation.x
        previousDragScreenLocation = screenLocation

        let directionChange: PetAnimation?
        if abs(incrementalX) > PetDragTracker.dragDirectionThreshold {
            let animation: PetAnimation = incrementalX >= 0 ? .runningRight : .runningLeft
            if animation != lastDragAnimation {
                lastDragAnimation = animation
                directionChange = animation
            } else {
                directionChange = nil
            }
        } else {
            directionChange = nil
        }

        return PetDragUpdate(
            windowOrigin: windowOrigin,
            isDragging: dragging,
            directionChange: directionChange
        )
    }

    mutating func end(at screenLocation: CGPoint, timestamp: TimeInterval) -> PetDragEnd {
        guard active else {
            return PetDragEnd(wasDragging: false, releaseVelocity: .zero, fallbackAnimation: nil)
        }

        if dragging {
            appendDragSample(location: screenLocation, timestamp: timestamp)
        }

        let result = PetDragEnd(
            wasDragging: dragging,
            releaseVelocity: dragging ? releaseVelocity() : .zero,
            fallbackAnimation: lastDragAnimation
        )
        reset()
        return result
    }

    private mutating func reset() {
        active = false
        dragging = false
        lastDragAnimation = nil
        dragSamples.removeAll(keepingCapacity: true)
    }

    private mutating func appendDragSample(location: CGPoint, timestamp: TimeInterval) {
        dragSamples.append(DragSample(location: location, timestamp: timestamp))
        let minimumTimestamp = timestamp - PetDragTracker.dragVelocitySampleWindow
        dragSamples.removeAll { sample in
            sample.timestamp < minimumTimestamp
        }

        if dragSamples.count > PetDragTracker.maximumDragVelocitySamples {
            dragSamples.removeFirst(dragSamples.count - PetDragTracker.maximumDragVelocitySamples)
        }
    }

    private func releaseVelocity() -> CGVector {
        guard
            let first = dragSamples.first,
            let last = dragSamples.last,
            last.timestamp > first.timestamp
        else {
            return .zero
        }

        let elapsed = last.timestamp - first.timestamp
        return CGVector(
            dx: (last.location.x - first.location.x) / elapsed,
            dy: (last.location.y - first.location.y) / elapsed
        )
    }
}

@MainActor
private final class PetSpriteView: NSView {
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragMove: ((CGPoint) -> Void)?
    var onDragDirectionChange: ((PetAnimation) -> Void)?
    var onDragEnd: ((CGVector, PetAnimation?) -> Void)?
    var onInteractionEnd: (() -> Void)?
    var contextMenuPresenter: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    var spriteFrame: CGRect {
        didSet {
            needsDisplay = true
        }
    }

    private let spriteSize: CGSize
    private let frameStore: PetSpriteFrameStore
    private let contextMenuProvider: (@MainActor () -> NSMenu?)?
    private var currentFrameAsset: PetSpriteFrameAsset?
    private var dragTracker = PetDragTracker()

    init(
        frame: CGRect,
        spriteSize: CGSize,
        frames: [PetAnimation: [CGImage]],
        contextMenuProvider: (@MainActor () -> NSMenu?)? = nil
    ) {
        self.spriteSize = spriteSize
        self.contextMenuProvider = contextMenuProvider
        frameStore = PetSpriteFrameStore(frames: frames, spriteSize: spriteSize)
        let initialAsset = frameStore.asset(for: .idle, frameIndex: 0)
        spriteFrame = CGRect(
            x: frame.width - spriteSize.width - OpenPetsMessageLayout.sideInset,
            y: 0,
            width: spriteSize.width,
            height: spriteSize.height
        )
        currentFrameAsset = initialAsset
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard spriteFrame.contains(point), currentFrameAsset != nil else { return nil }
        return self
    }

    func set(animation: PetAnimation, frameIndex: Int) {
        guard let asset = frameStore.asset(for: animation, frameIndex: frameIndex) else { return }
        currentFrameAsset = asset
        needsDisplay = true
    }

    func set(image: CGImage) {
        currentFrameAsset = PetSpriteFrameAsset(image: image, spriteSize: spriteSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let currentFrameAsset else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        currentFrameAsset.renderedImage.draw(in: spriteFrame)
    }

    override func mouseDown(with event: NSEvent) {
        onDragStart?()
        dragTracker.start(
            screenLocation: NSEvent.mouseLocation,
            windowOrigin: window?.frame.origin ?? .zero,
            timestamp: event.timestamp
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }

        contextMenuPresenter(menu, event, self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let update = dragTracker.drag(to: NSEvent.mouseLocation, timestamp: event.timestamp)
        else {
            return
        }
        window.setFrameOrigin(update.windowOrigin)
        onDragMove?(update.windowOrigin)
        if let directionChange = update.directionChange {
            onDragDirectionChange?(directionChange)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let result = dragTracker.end(at: NSEvent.mouseLocation, timestamp: event.timestamp)
        if result.wasDragging {
            onDragEnd?(result.releaseVelocity, result.fallbackAnimation)
        } else {
            onClick?()
        }
        onInteractionEnd?()
    }

}

#if DEBUG
private struct OpenPetsMessagingPreviewGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview(
                "Title Only",
                bubble: PetBubble(
                    title: "Waiting",
                    detail: nil,
                    indicator: .waiting
                ),
                isCollapsed: false,
                activeMessageCount: 1,
                appearance: .aqua
            )
            preview(
                "One Body Line",
                bubble: PetBubble(
                    title: "Working",
                    detail: "Updating the interface.",
                    indicator: .working
                ),
                isCollapsed: false,
                activeMessageCount: 1,
                appearance: .aqua
            )
            preview(
                "One Body Line Success",
                bubble: PetBubble(
                    title: "Complete",
                    detail: "Layout is ready for review.",
                    indicator: .success
                ),
                isCollapsed: false,
                activeMessageCount: 1,
                appearance: .aqua
            )
            preview(
                "Two Body Lines",
                bubble: PetBubble(
                    title: "Describe project",
                    detail: "This project is OpenPets, a macOS Swift package for showing an animated desktop pet while work runs.",
                    indicator: .working
                ),
                isCollapsed: false,
                activeMessageCount: 1,
                appearance: .aqua
            )
            preview(
                "Two Lines Truncated",
                bubble: PetBubble(
                    title: "Summarize implementation",
                    detail: "The bubble should expand to two lines and then truncate any extra copy with an ellipsis so the card stays compact.",
                    indicator: .working
                ),
                isCollapsed: false,
                activeMessageCount: 1,
                appearance: .aqua
            )
            preview(
                "Collapsed Active",
                bubble: PetBubble(
                    title: "Describe project",
                    detail: "No. I checked for CLAUDE.md, AGENTS.md, AGENT.md, .agents.md,...",
                    indicator: .success
                ),
                isCollapsed: true,
                activeMessageCount: 1,
                appearance: .aqua
            )
            preview(
                "Collapsed Multiple",
                bubble: PetBubble(
                    title: "Working",
                    detail: "Three active updates are hidden.",
                    indicator: .working
                ),
                isCollapsed: true,
                activeMessageCount: 3,
                appearance: .aqua
            )
            preview(
                "Dark Two Lines Truncated",
                bubble: PetBubble(
                    title: "Needs attention",
                    detail: "Longer status copy wraps cleanly without crowding the indicator, even when there is more detail than the bubble can show.",
                    indicator: .working
                ),
                isCollapsed: false,
                activeMessageCount: 1,
                appearance: .darkAqua
            )
            preview(
                "Dark Collapsed Multiple",
                bubble: PetBubble(
                    title: "Needs attention",
                    detail: "Hidden status copy.",
                    indicator: .working
                ),
                isCollapsed: true,
                activeMessageCount: 12,
                appearance: .darkAqua
            )
        }
        .padding(16)
        .frame(width: 324)
    }

    private func preview(
        _ title: String,
        bubble: PetBubble,
        isCollapsed: Bool,
        activeMessageCount: Int,
        appearance: NSAppearance.Name
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            let layout = previewLayout(for: bubble, isCollapsed: isCollapsed)
            ZStack(alignment: .topLeading) {
                PreviewStarcornSprite()
                    .position(
                        x: layout.spriteFrame.midX,
                        y: layout.containerSize.height - layout.spriteFrame.midY
                    )
                OpenPetsMessageView(
                    messages: [PetMessage(threadId: "preview", bubble: bubble)],
                    hiddenMessageCount: isCollapsed ? activeMessageCount : 0,
                    isCollapsed: isCollapsed,
                    activeMessageCount: activeMessageCount,
                    layout: layout,
                    cardFrames: layout.cardFrames,
                    messageAreaHeight: 84,
                    onDismiss: { _ in },
                    onToggle: {}
                )
            }
            .frame(width: layout.containerSize.width, height: layout.containerSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        }
    }

    private var previewCanvasSize: CGSize {
        CGSize(width: 316, height: 190)
    }

    private func previewLayout(for bubble: PetBubble, isCollapsed: Bool) -> OpenPetsMessageLayout {
        OpenPetsMessageLayout.make(
            bubble: bubble,
            isCollapsed: isCollapsed,
            containerWidth: previewCanvasSize.width,
            spriteSize: CGSize(width: 112, height: 126),
            messageAreaHeight: 84
        )
    }
}

private struct PreviewStarcornSprite: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = Self.idleFrame {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Text("Starcorn")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 112, height: 126)
        .opacity(colorScheme == .dark ? 0.82 : 1)
    }

    private static let idleFrame: CGImage? = {
        guard
            let spritesheetURL = OpenPetsPreviewResources.starcornResourceURL(
                named: "spritesheet",
                extension: "webp"
            ),
            let source = CGImageSourceCreateWithURL(spritesheetURL as CFURL, nil),
            let spritesheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        let columns = 8
        let rows = 9
        let cellWidth = spritesheet.width / columns
        let cellHeight = spritesheet.height / rows
        return spritesheet.cropping(to: CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
    }()
}

#Preview("Starcorn Sprite Resource") {
    PreviewStarcornSprite()
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Starcorn Bundle Resource") {
    VStack(alignment: .leading, spacing: 8) {
        if let petURL = OpenPetsPreviewResources.starcornResourceURL(named: "pet", extension: "json") {
            Text(petURL.lastPathComponent)
        }
        PreviewStarcornSprite()
    }
}

private final class OpenPetsPreviewBundleToken {}

private enum OpenPetsPreviewResources {
    static func starcornResourceURL(named name: String, extension pathExtension: String) -> URL? {
        let subdirectory = "Pets/starcorn"
        let filename = "\(name).\(pathExtension)"
        let packageResourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(subdirectory)
            .appendingPathComponent(filename)

        let bundles = [
            Bundle.module,
            Bundle(for: OpenPetsPreviewBundleToken.self),
            Bundle.main
        ]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: pathExtension, subdirectory: subdirectory) {
                return url
            }
            if let url = bundle.resourceURL?
                .appendingPathComponent(subdirectory)
                .appendingPathComponent(filename),
                FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        guard FileManager.default.fileExists(atPath: packageResourceURL.path) else {
            return nil
        }
        return packageResourceURL
    }
}

#Preview("Messaging Blocks") {
    OpenPetsMessagingPreviewGallery()
}
#endif
