# reforge

Flutter upgrade infrastructure. Reforge inspects a Flutter project, plans the
migration to a target Flutter release from recorded facts, applies it with a
journal and backups, and verifies the result with real builds.

## Install

```bash
dart pub global activate reforge 0.1.0-dev
```

Make sure the pub cache's `bin` directory is on your `PATH`, as
`dart pub global activate` explains. Executables for Linux, macOS and Windows
are also attached to the
[GitHub releases](https://github.com/KEREM-BAS/reforge/releases).

## Use

In a Flutter project, or with `-C path/to/flutter_app` from anywhere:

```bash
reforge inspect                         # read-only: toolchain, platforms, plugins, problems
reforge plan --to stable                # read-only: every step, why, and the exact file changes
reforge apply --to stable --accept-all  # after reviewing the plan
reforge verify                          # static checks, then flutter pub get, analyze and builds
reforge rollback                        # restore the files of the migration
```

Apply migrations on a clean Git branch. `verify` runs the project's Gradle and
CocoaPods build logic; only run it on repositories you trust.

Each Reforge release contains its knowledge about Flutter releases. When a
newer Flutter release is out, upgrade Reforge; `reforge --version` shows the
knowledge base date.

## Documentation

- [Overview](https://github.com/KEREM-BAS/reforge#readme)
- [Command reference](https://github.com/KEREM-BAS/reforge/blob/main/docs/cli.md)
- [Recipes](https://github.com/KEREM-BAS/reforge/tree/main/docs/recipes)
- [Validation with real builds](https://github.com/KEREM-BAS/reforge/blob/main/docs/validation.md)

## Status

0.1.0-dev is an early development release; expect breaking changes before
1.0. Report problems at
[GitHub issues](https://github.com/KEREM-BAS/reforge/issues).
