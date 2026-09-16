# Reforge architecture

This document describes the foundation of Reforge: how a Flutter repository
becomes a typed model, how migrations are planned against a target Flutter
release, how files are changed safely, and how results are verified. It is
intentionally short; each section names the code that implements it.

Product priorities, in order: correctness, safety, explainability, developer
trust, reproducibility, extensibility, automation, convenience. Every design
decision below traces back to that list.

## 1. Technology and packages

Reforge is written in Dart.

- Flutter developers already have a Dart toolchain, and package maintainers who
  will contribute migration knowledge already write Dart.
- `pub_semver` gives pub's exact constraint semantics; `yaml`, `xml` and
  `crypto` cover the rest. Parsers for Gradle scripts, Java properties, Xcode
  projects, Podfiles and podspecs are Reforge's own, because edits need source
  spans those formats' existing tools do not expose.
- `dart compile exe` produces self-contained binaries for macOS, Linux and
  Windows, so Reforge does not depend on the (possibly very old) Dart SDK of the
  project being upgraded.

The repository is a pub workspace:

| Package | Role |
| --- | --- |
| `packages/reforge_core` | The engine: parsers, project model, inspection, knowledge base, planner, recipes, transactional apply, journal, verification. No terminal concerns. |
| `packages/reforge` | The `reforge` CLI: argument parsing, rendering, exit codes. |

Future consumers (GitHub Action, upgrade bot, MCP server, dashboard) depend on
`reforge_core` and never re-implement engine logic.

## 2. Domain model

The model is built once per inspection and is immutable.

```
Workspace (single project, pub workspace or Melos)
└── FlutterProject (one per pubspec that depends on Flutter)
    ├── Pubspec, PubspecLock, PackageConfig, FlutterPluginsDependencies, .metadata
    ├── FlutterVersionObservations   (.fvmrc, .tool-versions, package_config, .metadata)
    ├── AndroidProject?
    │   ├── settings / root / app GradleScript (Groovy or Kotlin DSL)
    │   ├── AndroidToolchain   AGP, Kotlin and Gradle wrapper declarations,
    │   │                      gradle.properties flags
    │   ├── AndroidAppModule   namespace, applicationId, SDK levels (and flavor
    │   │                      minSdk), plugin application style
    │   └── manifests
    └── DarwinProject? (ios, macos)
        ├── Podfile            platform, customizations
        ├── XcodeProject       build configurations, deployment targets
        └── dependency manager (CocoaPods / Swift Package Manager / both / none)
DependencyReport (per project, after pub get: resolved packages with their
    pubspec, Android plugin facts and podspec facts)
Environment (probed separately: OS, Flutter, JDK candidates, Xcode, CocoaPods, Git)
```

Values extracted from files are never bare strings. A version is a
`VersionDeclaration`: the parsed value, the raw text, where it is used, where
its literal is defined (a variable may be defined elsewhere), and how it was
resolved (literal, variable, Flutter default, version catalog, unresolved).
This provenance is what lets Reforge say *how it knows* something and edit the
exact literal that defines it.

## 3. Inspection strategy

- **Read-only file system abstraction.** Inspection reads through
  `ProjectFileSystem`. The same inspector runs against the disk or against an
  in-memory overlay containing planned edits (see planning).
- **Structured parsers, never regex over whole files.** YAML via `yaml`, XML via
  `xml` event parsing with source locations, JSON via `dart:convert`, Java
  properties with a lossless line parser, `project.pbxproj` with an OpenStep
  plist parser that records spans, Gradle scripts (Groovy and Kotlin DSL) with a
  tolerant lexer and block-structure parser, and Podfiles with a Ruby-aware
  tokenizer that tracks `do … end` blocks. Every parser keeps source offsets so
  mutations can be surgical.
- **Graceful degradation.** Unparseable or unrecognized constructs become
  diagnostics and lower confidence; they never crash inspection and never
  become silent assumptions. A project is not assumed to look like a freshly
  generated template.
- **Dependencies from what pub resolved.** Packages are read from the
  directories recorded in `.dart_tool/package_config.json` (the pub cache,
  path dependencies), each through its own read-only `ProjectFileSystem`, only
  after `pub get` has run. Reforge reads each package's pubspec, the Android
  build script of plugins (does it set `namespace`?) and plugin Java/Kotlin
  sources (tokenized, so comments and strings do not count) for uses of the
  removed v1 embedding, whether it applies the Kotlin Gradle plugin (always or
  only conditionally), its literal `compileSdk` and `minSdk`, and the iOS and
  macOS minimums of its podspecs (for the platforms its pubspec declares).
  Facts describe the locked versions; a later `pub get` with a new SDK may
  select others, and findings say so.
- **Evidence-derived confidence.** `certain` (literal in a project file),
  `high` (resolved through a variable or a generated file), `medium`
  (heuristic, e.g. which JDK Flutter will pick), `low` (weak signal).

## 4. Knowledge base

Knowledge is data, not code paths, and every entry cites a source.

- `FlutterRelease` facts are generated by `tool/generate_flutter_knowledge.dart`
  from Flutter's release manifest and from `flutter/flutter` sources at each
  stable tag: Dart version; Android Gradle Plugin, Gradle, Kotlin, Java and
  minSdk error and warning floors; template toolchain versions, DSL, plugin
  style and `gradle.properties`; `flutter.*SdkVersion` defaults; the Android
  project migrations the tool runs before builds; whether Flutter applies the
  Kotlin Gradle plugin itself; imperative Gradle apply support; the minimum
  iOS and macOS deployment targets; and the Xcode and CocoaPods versions the
  tool checks.
- Toolchain release lists (Gradle with checksums, AGP, Kotlin) are generated
  from their official metadata by `tool/generate_toolchain_releases.dart`.
- Android tables and facts that are not in Flutter's sources (AGP to minimum
  Gradle, Gradle and JDK, API level to AGP, AGP 8 and 9 behavior changes,
  Jetifier, the v1 embedding removal, API level names) are curated from
  developer.android.com, docs.gradle.org, kotlinlang.org and Flutter issues and
  docs, with the retrieval date recorded.
- Knowledge distinguishes **facts** (a source says so), **observations**
  (Reforge or CI saw it happen) and **inferences** (derived). The knowledge base
  holds facts only. Observations from real builds are recorded in
  [validation.md](validation.md) and used to find gaps; the observatory will
  add observations with CI evidence (run id, toolchain versions, commit,
  timestamp) as a separate kind, so a verified observation is never confused
  with a documented requirement.

An unknown target (for example a Flutter release newer than the knowledge
base) is an explicit error. Reforge never extrapolates requirements.

## 5. Migration model

A **recipe** is a deterministic unit of migration knowledge with a stable ID
(`ANDROID_AGP_VERSION`, `IOS_DEPLOYMENT_TARGET`, …) that appears in CLI output,
JSON, docs and configuration.

```
evaluate(context) → NotApplicable(reason)
                  | Applicable(proposal)
```

A proposal states what changes, why, the impact, the evidence, a confidence,
a status, a necessity, file edits, manual instructions and the verification
checks that prove success:

| Status | Meaning |
| --- | --- |
| `auto` | Reforge can apply the change and knows how to verify it. |
| `review` | Reforge can produce the change, but a human must accept it (customizations, behaviour changes, major version jumps). |
| `manual` | Reforge can explain what to do but cannot safely do it. |
| `blocked` | The migration cannot proceed until something outside the project changes (unsupported package, missing prerequisite). |

`necessity` is one of:

| Necessity | Meaning | Planned by default | Blocks completion when not applied |
| --- | --- | --- | --- |
| `required` | The target release fails without it or does not support the project. | yes | yes |
| `flutterMigration` | The Flutter tool of the target release makes the same change itself before the next build. | yes | no |
| `recommended` | Deprecations, warning thresholds, template modernizations. | only with `--include` | no |

`flutterMigration` exists because `flutter build` and `flutter run` migrate
Android host projects before every Gradle build (for example
`DisableNewDslMigration`, `TopLevelGradleBuildFileMigration`,
`MinSdkVersionMigration`). Without mirroring them, the first build after a
migration changes files outside the reviewed plan, rewrites them with LF line
endings, and makes a clean rollback impossible. The knowledge base records,
for every release, which migrations its tool runs; recipes that mirror one
cite its source and change exactly what it would, while keeping the file's
formatting. `reforge verify` still reports any file a tool modifies.

Recipes are:

- **version-aware**: they compare the project's effective state with the
  target's requirements; a string being present in a file is never enough;
- **idempotent**: after a recipe's edits are applied, evaluating it again must
  yield `NotApplicable`. The test suite enforces this for every fixture;
- **conservative**: when a file deviates from known template shapes in ways a
  recipe does not understand, the status degrades to `review` or `manual`.

Rollback is not a per-recipe responsibility; the journal restores exact bytes.

## 6. Planning model

`MigrationPlanner` evaluates recipes **sequentially over an overlay file
system**:

1. Order recipes topologically by their declared `runsAfter` relations.
2. For each recipe: inspect the overlay, evaluate, validate the proposed edits
   (edited files must still parse), and apply accepted edits to the overlay so
   later recipes observe the migrated state.
3. A step whose prerequisite was not applied becomes `blocked` with an
   explanation.

This makes recipes composable without edit-conflict resolution: the AGP recipe
sees the `plugins {}` block created by the plugin DSL recipe; the namespace
recipe sees the AGP version chosen by the AGP recipe.

Recommended steps are only planned when requested (`--include RECIPE_ID` or
`--include-recommended`); otherwise they are listed as recommendations. With
package sources, the planner reads the project's resolved dependencies once and
gives them to recipes (for example, plugins' `compileSdk`) and to the analysis
of what remains open after the plan. A plan is **complete** when no required
step is left unapplied, no error finding remains, and every project file could
be analyzed.

The plan records a **fingerprint** of every file read during planning. Applying
a plan first re-verifies the fingerprint, so a stale plan can never be applied
to a project that changed after review. Planning is a pure function of
(Reforge version, knowledge base version, target, options, input files), so a
plan is reproducible and has a stable `planId`.

## 7. Mutation model

- Edits are `TextEdit(offset, length, replacement)` produced from parser spans;
  unrelated bytes, comments and formatting are untouched. Line endings of the
  original file are preserved.
- `apply` is transactional: acquire a project lock, verify fingerprints, check
  Git status of the files to be touched (refuse dirty files unless
  `--allow-dirty`), write backups and a journal entry, write each file
  atomically (temp file + rename), then mark the session applied. If any write
  fails, already-written files are restored from backups immediately.
- The journal lives in `.reforge/sessions/<id>/` (with a self-ignoring
  `.gitignore`). It records the target, recipes, per-file before/after hashes,
  backups and verification results.
- `rollback` restores backups only if each file still has the hash Reforge
  wrote; files changed afterwards are reported as conflicts instead of being
  overwritten.
- A crash during `apply` leaves the session marked `applying`. Because files
  are replaced before the journal records them, rollback of such a session
  treats a file as written when its content has the planned hash, and new
  applies are refused until the interrupted session is rolled back.
- Changes that tools make while `verify` runs them (Flutter's own project
  migrations during `flutter build`, `pod install`, `pub get`) are part of the
  session: before each toolchain check the project files are snapshotted, and
  the previous content of every file the tool created, modified or deleted is
  backed up with before/after hashes. `rollback` undoes those changes newest
  first, with the same conflict rules, and then restores the migration's
  backups, so the project returns to its exact state before the migration.
- Git is used when present (never required). It is invoked with
  `core.fsmonitor` disabled so inspecting a hostile repository cannot execute
  configured commands.

## 8. Verification model

A migration is successful only when verified.

1. **Static verification** (always, offline): re-inspect the project from disk,
   confirm every edited file parses, and re-evaluate every applied recipe; each
   must now be `NotApplicable`.
2. **Toolchain verification** (explicit): `flutter pub get`, `flutter analyze`,
   `flutter build apk --debug`, `flutter build ios --debug --no-codesign` and
   `flutter build macos --debug` (the last two on macOS only; skipped with a
   reason elsewhere). Checks are selected from the
   verification requirements of applied recipes. Commands that execute project
   build logic (Gradle, CocoaPods) are labelled as such.

Failed checks are explained by failure signatures
(`verification/failure_signatures.dart`). Where the Flutter tool itself
recognizes a failure (`gradle_errors.dart`), the signature follows its handler
and cites it. `reforge diagnose` applies the same signatures to build logs or
builds it runs, and confirms each diagnosis with inspection findings
(`verification/diagnosis.dart`): the failing Gradle module is matched to the
plugin that lacks a namespace, compiler errors in pub cache paths to the plugin
still using the v1 embedding, a pub SDK error to the package's constraint.

Results record the exact tool versions used. A verification that ran with a
Flutter SDK other than the migration target is reported as not being evidence
for the target.

The snapshot covers `pubspec.yaml`, `pubspec.lock`, `.gitignore`, `.metadata`,
`analysis_options.yaml` and every file below the platform directories, except
build output, dependency caches (`Pods`, `.gradle`, `.symlinks`, ...) and files
the Flutter tool regenerates on every build (`local.properties`,
`Generated.xcconfig`, `GeneratedPluginRegistrant.*`, ...).

## 9. Interfaces

- Text output for people; JSON (`--format json`) with a versioned envelope and
  stable identifiers for tools; SARIF 2.1.0 (`--format sarif`) for code
  scanning, from `inspect`, `plan` and `diagnose`.
- Exit codes are part of the contract (see [cli.md](cli.md)); `plan --fail-on`
  makes plans usable as CI gates.
- Recipe documentation is bundled into the CLI (`reforge explain`), so the
  reasoning behind a step is available offline.

## 10. Future compatibility intelligence

The pieces above are shaped for the long-term system:

- **Observatory**: CI jobs run verification over package × toolchain matrices
  and publish observations with evidence. They use the same recipes, planner
  and verifier as the CLI.
- **Compatibility graph**: requirements are already modeled as version
  constraints between nodes (Flutter → Dart, AGP → Gradle → JDK, API level →
  AGP, plugin → iOS deployment target). Recipes query the knowledge base; a
  graph solver can later replace per-recipe floor computations without changing
  recipe contracts.
- **Diagnose experiments**: failures are already classified and confirmed
  against inspection findings; controlled experiments (bisecting a toolchain
  dimension in a scratch copy) can reuse the overlay, apply and verification
  machinery.
- **Recipe registry**: recipes are plain classes behind a descriptor with
  stable IDs and declared ordering, so community or organization recipe packs
  can be loaded later without changing the planner. No plugin loading exists
  yet by design.
