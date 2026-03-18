# Repository Guidelines

## Project Structure & Module Organization
`Loom` is a Swift package with two library targets declared in [Package.swift](/Users/ethan/Developer/Loom/Package.swift): `Sources/Loom` for the core transport, identity, trust, bootstrap, and diagnostics APIs, and `Sources/LoomCloudKit` for optional CloudKit-backed peer sharing and trust. Keep public API surface in `Public/` and implementation details in `Internal/`. DocC content lives in `Sources/Loom/Loom.docc`, tests live in `Tests/LoomTests` and `Tests/LoomCloudKitTests`, and generated documentation is published from `docs/`.

## Build, Test, and Development Commands
Use SwiftPM from the repository root:

```bash
swift build
swift test --scratch-path .build-local
./Scripts/build-docc-site.sh
```

`swift build` validates both library targets. `swift test --scratch-path .build-local` runs the full suite without polluting the default build directory. `./Scripts/build-docc-site.sh` generates the static DocC site used by the GitHub Pages workflow.

## Coding Style & Naming Conventions
Follow the existing Swift style: 4-space indentation, one top-level type per file when practical, `UpperCamelCase` for types/files, and `lowerCamelCase` for methods, properties, and test functions. Prefer small, composable value types and protocol boundaries over product-specific conditionals. Public APIs should carry concise `///` DocC documentation comments, and new or changed public surface area should update the DocC catalog in `Sources/Loom/Loom.docc` as part of the same change. Internal helpers should stay narrowly scoped. Do not introduce app-specific service names, CloudKit schema assumptions, or UI semantics into Loom targets.

## Testing Guidelines
Tests use Swift's `Testing` framework, not `XCTest`. Mirror source modules with target-specific suites such as `LoomDiagnosticsTests` or `LoomCloudKitBootstrapMetadataTests`, and use descriptive `@Test("...")` names that state behavior. Add regression coverage for new public API, security logic, serialization, and bootstrap/signaling flows. Run `swift test --scratch-path .build-local` before opening a PR.

## Commit & Pull Request Guidelines
Recent commits use short, imperative subjects such as `Rewrite README and fix Pages CI` and `Fix DocC temp directory on CI`. Keep commit titles brief, capitalized, and behavior-focused. PRs should explain the user-visible or API-level change, note platform impact (`macOS`, `iOS`, `visionOS`) when relevant, and call out any DocC or README updates. New behavior should ship with updated documentation, and major additions such as a new library target or similarly large feature area should include a DocC tutorial, not just symbol comments or overview articles. Include logs or screenshots only when they clarify documentation or CI behavior.

## Architecture Boundary
Read [Architecture.md](/Users/ethan/Developer/Loom/Architecture.md) before widening scope. Loom is intentionally product-agnostic: transport, trust, diagnostics, and remote reachability belong here; app-level schemas and naming do not.
