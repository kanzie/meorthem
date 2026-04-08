---
  Refactor: eliminate dual-module file duplication

  GOAL
  Remove all files that exist under both Sources/MeOrThemCore/ and Sources/MeOrThem/
  with equivalent content. Core becomes the single source of truth for all business
  logic. The App target keeps only genuine AppKit/UI code that cannot live in Core.

  CONTEXT
  These five files are currently duplicated:
    - Models/MetricStatus.swift
    - Models/AppSettings.swift
    - Storage/MetricStore.swift
    - Monitoring/MonitoringEngine.swift
    - Speedtest/SpeedtestRunner.swift

  The PROGRESS.md "Build Note" and CLAUDE.md warn about keeping them in sync on every
  logic change — that warning is the debt this refactor pays off.

  RULE FOR EVERY PHASE
  Always keep the Core version as the base. If the App version adds something that
  uses AppKit (NSColor, NSImage, NSAttributedString, etc.), move it to a new
  App-only extension file (e.g. MetricStatus+AppKit.swift). Then delete the App
  copy of the original file. The App target uses the Core version directly.

  After each phase: run `swift run MeOrThemTests` (must pass) and
  `bash scripts/build.sh` (must succeed) before moving to the next phase.

  ---

  PHASE 1 — MetricStatus + AppSettings  (lowest risk, start here)

  1. Read Sources/MeOrThemCore/Models/MetricStatus.swift and
     Sources/MeOrThem/Models/MetricStatus.swift side by side.
  2. Note every property/method that exists only in the App version or uses AppKit.
  3. Create Sources/MeOrThem/Models/MetricStatus+AppKit.swift and move those
     AppKit-dependent members there as an extension on MetricStatus.
  4. Delete Sources/MeOrThem/Models/MetricStatus.swift.
  5. Repeat steps 1-4 for AppSettings.swift.
  6. Fix any compiler errors (most will be missing `import MeOrThemCore` in App
     files that previously relied on the local copy).
  7. Run tests + build.

  ---

  PHASE 2 — MetricStore  (medium risk)

  1. Read both MetricStore.swift versions. The App version has extra published
     properties (latestGatewayIP, etc.) and different method signatures.
  2. For each difference: if it doesn't depend on AppKit, promote it into the
     Core version. If it does, plan an extension.
  3. Update the Core MetricStore to be the superset of both versions.
  4. Create Sources/MeOrThem/Storage/MetricStore+AppKit.swift if any AppKit
     members remain (unlikely — MetricStore has no AppKit dependency).
  5. Delete Sources/MeOrThem/Storage/MetricStore.swift.
  6. Run tests + build.

  ---

  PHASE 3 — MonitoringEngine + SpeedtestRunner  (most complex)

  MonitoringEngine:
  1. Read both versions. The App version adds: adaptive polling, gateway ping,
     pause/resume, speedtest integration, tickStarted publisher, nextTickAt.
     None of these depend on AppKit — they all belong in Core.
  2. Merge all App-only logic into the Core MonitoringEngine.
  3. Delete Sources/MeOrThem/Monitoring/MonitoringEngine.swift.

  SpeedtestRunner:
  1. Read both versions and diff them.
  2. Merge App-only additions into Core.
  3. Delete Sources/MeOrThem/Speedtest/SpeedtestRunner.swift.

  4. Run tests + build.

  ---

  DEFINITION OF DONE
  - No filename appears in both Sources/MeOrThemCore/ and Sources/MeOrThem/.
  - `swift run MeOrThemTests` passes with at least as many tests as before.
  - `bash scripts/build.sh` succeeds.
  - Remove the "Build Note" block from PROGRESS.md.
  - Remove the "must be kept in sync" warning from CLAUDE.md.
  - Update CLAUDE.md architecture section to reflect the clean separation.

  IMPORTANT CONSTRAINT
  Do not use `@testable import MeOrThem` as a workaround anywhere. Tests must
  only import MeOrThemCore. If logic cannot be tested without the App target,
  it is UI glue and belongs in the App target — not a reason to skip the refactor.