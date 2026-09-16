# Contributing to Reforge

Reforge changes production repositories. Every contribution is judged first by
correctness and safety, then by explainability and reproducibility, and only
then by how much it automates.

## Setup

```bash
dart pub get
dart analyze
(cd packages/reforge_core && dart test)
(cd packages/reforge && dart test)
dart format packages
```

## Writing a migration recipe

A recipe is a class extending `MigrationRecipe` in
`packages/reforge_core/lib/src/migration/recipes/`. Before opening a pull
request, make sure it meets every rule below.

### 1. Facts, with sources

Version boundaries and requirements come from the knowledge base, never from
constants invented in the recipe. If a fact is missing, add it to the
knowledge base with its source (see [docs/knowledge-base.md](docs/knowledge-base.md))
and a test pinning the value.

### 2. Version-aware applicability

`evaluate` must compare the project's effective state (after earlier steps of
the plan) with the target release. A string being present in a file is never
enough. When the recipe does not apply, return `NotApplicable` with a reason a
user can understand.

### 3. Deterministic, surgical edits

- Produce `TextEdit`s from parser source ranges. Never rewrite or reformat a
  whole file unless the file is being replaced by a known template, and then
  preserve every statement the recipe does not recognize.
- Keep line endings, quoting style and indentation of the file.
- The same input must always produce the same edits. Recipes must not read
  the network, the clock, or the environment to decide on edits.

### 4. Honest status

| Status | Use when |
| --- | --- |
| `auto` | Only code Reforge fully recognizes is changed and the result is verifiable. |
| `review` | The change is right in general but a human must confirm it: customizations, behaviour changes, major version jumps. Say why in `notes`. |
| `manual` | Reforge can explain the change but cannot make it safely. Give precise `manualSteps`. |
| `blocked` | Something outside the project must change first. |

When in doubt, choose the more conservative status.

### 5. Idempotency

After a recipe's edits are applied, evaluating it again must return
`NotApplicable`. The planner enforces this at runtime and the golden tests
enforce it on every fixture.

### 6. Evidence and explanation

Every `Proposal` states what changes (`summary`), why (`rationale`), what
happens without it (`impact`), and the `evidence` behind it, distinguishing
project files, generated files, the environment, documented knowledge and
inference. `confidence` follows from the evidence.

### 7. Verification

List the `verification` checks that prove the step worked. Static analysis is
always included; add toolchain checks (`pubGet`, `androidBuild`, ...) that
exercise the changed configuration.

### 8. Tests

- Add fixture projects under `fixtures/projects/` that look like real projects
  from the relevant Flutter era. Prefer rendering historical templates with
  `tool/render_flutter_app_template.dart` over hand-writing them.
- Add a golden case under `fixtures/migrations/` and review the generated
  expectations line by line.
- Add unit tests for edge cases that lead to `review`, `manual` or `blocked`.

### 9. Documentation

Add `docs/recipes/<RECIPE_ID>.md`: what it detects, why it exists, affected
versions, what it changes, statuses, verification and manual follow-up. A
recipe ID is permanent once released.
Then run `dart run tool/generate_recipe_docs.dart` in `packages/reforge` to
bundle the document for `reforge explain`; a test fails otherwise.

## Checking parsers against real files

Fixtures cannot cover every build script in the wild. Before changing a
parser, run it over the real files on your machine, for example the pub cache
(plugins' Gradle scripts and podspecs) and a Flutter checkout (apps, templates,
integration tests):

```bash
cd packages/reforge_core
dart run tool/check_parsers.dart ~/.pub-cache/hosted ~/flutter
```

It lists every file a parser cannot read reliably. On the maintainers'
machines (September 2026) all 1,527 Groovy and 190 Kotlin DSL Gradle scripts,
410 Podfiles and 318 podspecs found this way were read reliably; keep it that
way, or add the file's construct to a parser test.

## Security

- Inspection and planning only read files and never execute project code.
- Commands that run project build logic (Gradle, CocoaPods) are explicit and
  labelled as such.
- Never follow symbolic links outside the project, never build shell command
  lines, and never run Git without disabling `core.fsmonitor`.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
