# Contributing to OpenPetsKit

Thanks for helping improve OpenPetsKit. This guide covers local setup, development workflow, tests, and pull request expectations.

## Requirements

- macOS 14 or later.
- Swift 6.0 or later.
- Xcode command line tools.

Check your Swift version:

```sh
swift --version
```

## Setup

From a local checkout, fetch dependencies through Swift Package Manager:

```sh
cd OpenPetsKit
swift build
```

Run the tests before making changes:

```sh
swift test
```

## Project Layout

- `Sources/OpenPetsKit`: Embeddable runtime, IPC, animation, configuration, host UI, pet loading, and bundled pet support.
- `Sources/OpenPetsKit/Resources/Pets`: Bundled pet assets, including Starcorn.
- `Tests/OpenPetsKitTests`: Unit tests for runtime behavior, IPC, config, pet bundles, UI layout helpers, installer/library behavior, and resource loading.
- `docs`: Integration notes for the shared pet system.

The desktop app, CLI, MCP server, assistant setup, and release packaging live in the separate OpenPets repository at `https://github.com/alterhq/openpets`.

## Development Workflow

1. Create a focused branch for your change.
2. Keep changes small and purpose-driven.
3. Add or update tests for behavior changes.
4. Update `README.md` or other docs when user-facing behavior changes.
5. Run `swift test` before opening a pull request.

Prefer minimal, direct changes over large rewrites. If a change affects public APIs, config keys, socket behavior, or pet bundle format, call that out clearly in the pull request.

## Coding Guidelines

- Follow the style already present in the codebase.
- Prefer clear names and straightforward control flow.
- Keep APIs small unless there is a concrete reuse need.
- Avoid adding compatibility layers unless they protect persisted config, shipped behavior, or external integrations.
- Add comments only when they explain non-obvious behavior or constraints.
- Use Swift concurrency and `@MainActor` consistently for AppKit/UI work.

## Tests

Run the full test suite:

```sh
swift test
```

Useful manual checks:

```sh
swift test --filter BundledStarcornPetLoads
swift test --filter UnixSocketClientServerFraming
```

When changing pet rendering or message layout, add tests for geometry helpers where possible. When changing IPC, command coding, or config behavior, include round-trip or persistence coverage.

## Pet Assets

Pet bundles must include a `pet.json` manifest and a spritesheet with an 8x9 atlas layout. Keep contributed assets original or clearly licensed for redistribution.

If you add or modify bundled assets, include provenance and licensing details in the pull request.

## Security

OpenPetsKit can open callback URLs from notification actions and communicates over local IPC. Treat URL handling, local socket behavior, and file/archive extraction changes as security-sensitive.

Do not open public issues for vulnerabilities. Report security issues privately to the maintainers.

## Pull Requests

A good pull request includes:

- A short description of the user-facing or developer-facing change.
- Tests or a clear explanation of why tests were not added.
- Documentation updates for public APIs, config, pet bundle behavior, or integration guidance.
- Screenshots or a short screen recording for visible UI changes.
- Notes about security-sensitive behavior, migration concerns, or compatibility impacts.

Before requesting review, confirm:

- `swift test` passes.
- New files do not include secrets, local machine paths, or generated build output.
- `.build/`, `.swiftpm/`, Xcode user data, and other local artifacts are not committed.

## Reporting Bugs

Please include:

- macOS version.
- Swift version.
- How you installed or launched OpenPetsKit.
- Steps to reproduce the issue.
- Expected and actual behavior.
- Relevant logs or terminal output.
- Whether the issue involves runtime hosting, IPC, config, pet assets, or rendering.

## Feature Requests

Please describe the problem you want solved, the proposed behavior, and whether it affects public APIs, config, pet assets, socket behavior, or the embedded UI.
