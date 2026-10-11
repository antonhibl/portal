---
status: done
---
# Triage dependency security findings

## Goal and evidence

Resolve dependency advisories relevant to the shipped application, with a
reviewable explanation for any remaining findings. Read [shared context](README.md).

The audit's `bun audit --json` flagged six transitive package names: `braces`,
`dompurify`, `katex`, `lodash-es`, `nanoid` and `source-map-js`, including high
severity findings. Nano ID 3.3.3 and 4.0.2 appeared in the lockfile; see the
[upstream advisory](https://github.com/advisories/GHSA-mwcw-c2x4-8c55).
These scanner findings do not by themselves establish exploitable Portal bugs.
Re-run the audit against current locked dependencies and read current primary
advisories before choosing fixes; do not rely on an old advisory count.

## Start here

[Host manifest](../../host/package.json), [lockfile](../../host/bun.lock),
[editor bundler](../../host/build-editor.ts), [Excalidraw entry](../../host/excalidraw.tsx),
[Markdown rendering](../../host/markdown.ts), [server](../../host/server.ts),
[editor bridge](../../docs/editor-bridge.md),
[Excalidraw GUI tests](../../test/portal-excalidraw-gui-tests.el), and
[Markdown GUI tests](../../test/portal-markdown-gui-tests.el).

## Work

1. Record audit output/date/tool version and dependency paths (for example
   `bun pm why <package>` from `host/`). Deduplicate advisories while retaining
   every installed affected version.
2. For each finding distinguish build tooling, bundled browser/host code, affected
   functions actually used, and attacker-controlled inputs that can reach them.
   Cite official advisories, patched releases and source evidence. Distinguish
   lack of demonstrated reachability from proof of safety.
3. Prefer compatible upstream dependency upgrades; use overrides only with an
   explicit compatibility justification. Update manifests and lockfiles together,
   preserve frozen installs, and avoid unrelated dependency churn.
4. Record each disposition: fixed version, demonstrated non-applicability, or
   unresolved exposure and a concrete follow-up. Justified exceptions need their
   scope, evidence and review trigger; blanket audit suppression is not a fix.
5. Preserve offline editor assets/fonts, scene imports, embedded images, save and
   reopen/revert behavior, Markdown rendering and the host/bridge protocol.
   Add focused regression coverage for any demonstrated vulnerable path.

## Acceptance and verification

- [ ] A fresh frozen install and current audit have no unexplained findings.
      Confirmed relevant vulnerabilities are fixed or mitigation and remaining
      release risk are explicitly documented; audit exit status alone is not a
      substitute for the disposition record.
- [ ] Shared build, CTest, host lint/type checks and Python tests pass. CTest's
      `licenses` suite covers task 6's notices: update the license inventory for
      changed bundled packages as [its guide](../../docs/licenses.md#when-dependencies-change)
      describes.
- [ ] If shipped rendering/editor dependencies change, run corresponding real
      editor/Markdown GUI acceptance through `bash test/vm.sh <command>` and
      verify drawing image import/save/reopen and offline operation.
- [ ] The PR links primary advisory evidence and reports before/after installed
      versions and remaining exceptions without claiming unproven exploitability.
