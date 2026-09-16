# Reforge CLI

```text
reforge [global options] <command> [command options]
```

## Global options

| Option | Meaning |
| --- | --- |
| `-C`, `--project <dir>` | Project or workspace directory (default: current directory). |
| `--format text\|json` | Output format. |
| `-v`, `--verbose` | Rationale, evidence, skipped recipes and tool output. |
| `--no-color` | Plain output (also honours `NO_COLOR`). |
| `--version` | Reforge and knowledge base versions. |

## Commands

### `inspect`

Builds the project model (all projects of a pub or Melos workspace) and
checks it against the Flutter version the project currently uses: pinned with
FVM or `.tool-versions`, otherwise `flutter` on PATH, otherwise the SDK that
last ran `pub get`, otherwise the SDK that created the project.

`--no-env` skips probing the local toolchain.

### `env`

Shows the Flutter SDK, the JDK Flutter will most likely use (mirroring
Flutter's selection order: `flutter config --jdk-dir`, Android Studio's JDK,
`JAVA_HOME`, `PATH`), Xcode, CocoaPods and Git.

### `plan`

```text
reforge plan --to <version> [--accept RECIPE_ID,...] [--accept-all]
             [--include RECIPE_ID,...] [--include-recommended]
             [--skip RECIPE_ID] [--workspace-project <path>]
             [--diff] [--out plan.json] [--fail-on never|blocked|incomplete|changes]
```

`--to` accepts `3.47.4`, `3.47` (latest known patch) or `stable`.

Steps are **required** (the target release fails without them or does not
support the project), **flutterMigration** (the Flutter tool would make the
same change during the next build; planned by default so it is reviewed and
reversible) or **recommended** (Flutter warning thresholds, template
modernizations).
Recommended steps are listed under "Recommended, not planned" until they are
requested: `--include RECIPE_ID` plans those of one recipe,
`--include-recommended` plans all of them. Including a toolchain recipe (for
example `ANDROID_AGP_VERSION`) also upgrades the tools it depends on as
required.

Review steps are not applied unless accepted, and steps that depend on them
are blocked. A plan is **complete** when no required step is left unapplied,
no error remains for the target, and every project file could be analyzed.

### `apply`

```text
reforge apply --to <version> [plan options] [--plan plan.json]
              [--allow-incomplete] [--allow-dirty] [--yes]
```

Refuses to apply when:

- the plan is incomplete (unless `--allow-incomplete`);
- files to change have uncommitted Git changes (unless `--allow-dirty`);
- no confirmation is given (`--yes` is required when not interactive);
- the project changed since planning, or differs from a reviewed `--plan`.

Every file is backed up and journaled in `.reforge/sessions/<id>/` before it is
changed; files are replaced atomically; if a write fails, earlier writes are
restored.

### `verify`

```text
reforge verify [--session <id>] [--check static|pub-get|analyze|android|ios]... [--flutter <exe>]
```

Default checks are those required by the applied steps of the latest session.
Android and iOS builds run the project's Gradle and CocoaPods build logic.
When checks run with a Flutter version other than the migration target, the
results are marked as not being evidence for the target. Files modified by the
tools while they run are reported and recorded.

Failed checks are explained when the output matches a known failure, for
example `GRADLE_OUT_OF_MEMORY`, `JETIFIER_TRANSFORM_FAILED`,
`FLUTTER_DEPENDENCY_BELOW_MINIMUM`, `GRADLE_JDK_TOO_NEW` or
`DART_COMPILATION_ERROR`, with the recipes that address them. Output that
matches nothing known is shown as is, never guessed at.

### `rollback [session]`

Restores the most recent applied session (or the given one). Refuses when a
file changed after the migration; `--force` restores the backups anyway.

### `history`

Lists migration sessions, their status and verification results.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | The command ran and the outcome is failing (`plan --fail-on`, `verify`, failed static verification after `apply`). |
| 2 | Invalid usage (unknown option, missing `--to`, confirmation required). |
| 3 | Not a Flutter project Reforge can read. |
| 4 | Migration blocked (incomplete plan, dirty files, stale or changed plan, locked project). |
| 5 | Applying failed (files were restored). |
| 6 | Unsupported target or environment (for example a Flutter version unknown to the knowledge base). |
| 7 | An external tool is missing or failed. |
| 8 | Journal problem or rollback conflict. |
| 70 | Internal error. |

## JSON output

Every command prints one JSON document:

```json
{
  "schemaVersion": 1,
  "reforge": {"version": "0.1.0-dev", "knowledgeBase": "2026-09-16"},
  "command": "plan",
  "result": { }
}
```

Errors replace `result` with:

```json
{"error": {"code": "TARGET_UNKNOWN_FLUTTER_VERSION", "category": "unsupportedTarget", "message": "...", "hints": ["..."]}}
```

Identifiers (`code`, recipe ids, finding codes, statuses) are stable.
`schemaVersion` changes when a field is removed or changes meaning.
