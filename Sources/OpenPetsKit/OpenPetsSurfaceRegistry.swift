import Foundation

public enum OpenPetsSurfaceValidationError: Error, LocalizedError, Equatable, Sendable {
    case duplicateSurfaceID(String)
    case unsupportedMessageType(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateSurfaceID(let surfaceID):
            "Duplicate surface update ID in one batch: \(surfaceID)"
        case .unsupportedMessageType(let type):
            "Unsupported surface plugin message type: \(type)"
        }
    }
}

public enum OpenPetsSurfacePlacement: Equatable, Sendable {
    case placed(OpenPetsSurfaceSlot)
    case hidden(reason: String)
    case rejected(OpenPetsSurfaceValidationError)
}

public struct OpenPetsResolvedSurface: Equatable, Sendable {
    public var update: OpenPetsSurfaceUpdate
    public var placement: OpenPetsSurfacePlacement

    public init(
        update: OpenPetsSurfaceUpdate,
        placement: OpenPetsSurfacePlacement
    ) {
        self.update = update
        self.placement = placement
    }
}

public struct OpenPetsSurfacePlacementResolver: Sendable {
    public var slotOrder: [OpenPetsSurfaceSlot]

    public init(slotOrder: [OpenPetsSurfaceSlot] = OpenPetsSurfaceSlots.defaultOrder) {
        self.slotOrder = slotOrder
    }

    public func resolve(_ updates: [OpenPetsSurfaceUpdate]) -> [OpenPetsResolvedSurface] {
        var occupiedSlots = Set<OpenPetsSurfaceSlot>()
        let duplicateSurfaceIDs = Set(
            Dictionary(grouping: updates.map(\.surfaceID), by: { $0 })
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
        let indexedUpdates = updates.enumerated().map { (index: $0.offset, update: $0.element) }
        let sortedUpdates = indexedUpdates.sorted {
            if $0.update.priority != $1.update.priority {
                return $0.update.priority > $1.update.priority
            }
            return $0.index < $1.index
        }

        var resolvedByIndex = Array<OpenPetsResolvedSurface?>(repeating: nil, count: updates.count)

        for item in sortedUpdates {
            guard !duplicateSurfaceIDs.contains(item.update.surfaceID) else {
                resolvedByIndex[item.index] = OpenPetsResolvedSurface(
                    update: item.update,
                    placement: .rejected(.duplicateSurfaceID(item.update.surfaceID))
                )
                continue
            }
            guard item.update.type == "surface.update" else {
                resolvedByIndex[item.index] = OpenPetsResolvedSurface(
                    update: item.update,
                    placement: .rejected(.unsupportedMessageType(item.update.type))
                )
                continue
            }
            guard let slot = firstAvailableSlot(for: item.update, occupiedSlots: occupiedSlots) else {
                resolvedByIndex[item.index] = OpenPetsResolvedSurface(
                    update: item.update,
                    placement: .hidden(reason: "No compatible slot available")
                )
                continue
            }

            occupiedSlots.insert(slot)
            resolvedByIndex[item.index] = OpenPetsResolvedSurface(
                update: item.update,
                placement: .placed(slot)
            )
        }

        return resolvedByIndex.compactMap { $0 }
    }

    private func firstAvailableSlot(
        for update: OpenPetsSurfaceUpdate,
        occupiedSlots: Set<OpenPetsSurfaceSlot>
    ) -> OpenPetsSurfaceSlot? {
        let preferredSlots = update.slotPreference.filter(slotOrder.contains)
        let candidates = preferredSlots + slotOrder.filter { !preferredSlots.contains($0) }

        return candidates.first { !occupiedSlots.contains($0) }
    }
}
