# OpenPetsKit

OpenPetsKit is the embeddable Swift runtime for OpenPets. It lets macOS apps load a bundled sample pet, host the desktop pet UI, and send pet commands through the shared local socket without depending on the OpenPets desktop app.

For the desktop app, MCP server, and user-facing project, see [openpets.sh](https://openpets.sh) and the [OpenPets desktop GitHub repository](https://github.com/alterhq/openpets).

## Installation

Add OpenPetsKit to your Swift package:

```swift
.package(url: "https://github.com/alterhq/OpenPetsKit.git", branch: "main")
```

Then add the library product to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "OpenPetsKit", package: "OpenPetsKit")
    ]
)
```

## Quick Start

```swift
import OpenPetsKit

let client = OpenPetsClient()
let response = try client.send(.notify(PetNotification(
    title: "Export Complete",
    text: "The customer report is ready.",
    status: "done"
)))

print(response.threadId ?? "")
```

OpenPetsKit includes the bundled Starcorn pet for local development and integration tests:

```swift
import OpenPetsKit

let petURL = OpenPetsBundledPets.starcornURL
let petBundle = try PetBundle.load(from: petURL)
```

## Shared Pet System

By default, OpenPetsKit talks to the per-user socket at `/tmp/openpets-UID.sock`. See [Shared Pet System](docs/shared-pet-system.md) for the socket topology, `threadId` workflow, and app integration guidance.
