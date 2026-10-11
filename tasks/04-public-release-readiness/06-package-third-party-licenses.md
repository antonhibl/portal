---
status: todo
---
# Package third-party licenses

## Goal and evidence

Ship a complete, reproducible set of applicable licenses and notices with Portal
source/binary distributions. Read [shared context](README.md).

The repository has a GPL license, but contributor distribution instructions omit
the root `LICENSE`. The audit found a Bash integration notice in the generated
native bundle but did not find the Swift wrapper license staged there. The host
embeds Bun, JavaScript dependencies and fonts. This is a packaging gap requiring
an inventory, not a blanket conclusion about license compatibility.

## Start here

[Project license](../../LICENSE),
[distribution instructions](../../CONTRIBUTING.md#build-outputs-and-distribution),
[Bun distribution notes](../../docs/bun-distribution.md),
[native package](../../native/Package.swift), [Swift lockfile](../../native/Package.resolved),
[CMake packaging](../../CMakeLists.txt),
[editor asset bundler](../../host/build-editor.ts),
[host manifest](../../host/package.json), and [host lockfile](../../host/bun.lock).
Inspect fetched dependency license files and the actual generated bundle/host.

## Work

1. Inventory what the distributed artifacts actually contain: Portal, Bun runtime,
   GhosttyKit and its Swift wrapper, terminal integration/resources, bundled JS,
   Excalidraw fonts/assets and other copied code. Record locked version/source,
   license, notice/source obligations and destination in the release layout.
   Distinguish build-only dependencies from redistributed contents.
2. Read upstream license/notice texts at the pinned versions. Identify compatibility
   or source-availability questions that need resolution; do not infer obligations
   from package names or strip upstream notices. Retain existing notices.
3. Stage root LICENSE and applicable third-party texts deterministically as part
   of the build/release layout (for example a notices directory and index).
   Include notices for code embedded in the standalone host and resources in the
   module bundle. Avoid hand-editing generated outputs.
4. Make a complete distributable layout and its source/license material explicit
   in contributor/release documentation. Include any required corresponding-source
   access instructions; do not claim future binary release compliance merely
   because a list of dependency names exists.
5. Add a focused packaging check that fails if a required notice is absent from a
   staged distribution and provides a maintenance path when dependencies change.

## Acceptance and verification

- [ ] Inventory is tied to locked versions and actual shipped assets, cites source
      licenses and resolves or clearly identifies release-blocking questions.
- [ ] A fresh build/staging run contains Portal LICENSE plus the complete required
      notices, including the Swift wrapper, Bun and bundled fonts where applicable.
- [ ] Packaging checks inspect outputs and fail on a missing required file.
- [ ] Distribution instructions name the notices and required source materials;
      generated files remain generated and no private/local absolute paths leak.
- [ ] Run shared host checks if build/staging code changes. Coordinate with task 4
      so a dependency update refreshes this inventory and staged notices.
