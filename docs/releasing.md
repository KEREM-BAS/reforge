# Releasing

## Versions

Reforge uses semantic versioning; before 1.0, any minor version may break
compatibility. Both packages, `reforge_core` (the engine) and `reforge` (the
command-line tool), are released together at the same version, which is
written in:

- `version` in `packages/reforge/pubspec.yaml` and
  `packages/reforge_core/pubspec.yaml`;
- the `reforge_core: ^<version>` dependency in `packages/reforge/pubspec.yaml`;
- `reforgeVersion` in `packages/reforge_core/lib/reforge_core.dart`.

`CHANGELOG.md` needs a `## <version>` section, which becomes the GitHub
release notes, and each package's `CHANGELOG.md` a `## <version>` section for
pub.dev. Each package carries a copy of `LICENSE`. The release workflow checks
all of this.

## Publishing a release

```bash
git switch main
git pull
# Update the versions and CHANGELOG.md, then commit.
dart analyze --fatal-infos
(cd packages/reforge_core && dart test)
(cd packages/reforge && dart test)
git tag v0.1.0-dev
git push origin v0.1.0-dev
```

Pushing the tag runs `.github/workflows/release.yml`:

1. it checks that the tag matches `reforgeVersion` and that the changelog has
   a section for the version;
2. it analyzes, tests and compiles `reforge` on Linux (x64), macOS (arm64) and
   Windows (x64);
3. it publishes a GitHub release with the three executables, `SHA256SUMS` and
   the changelog section. Versions with a suffix (`0.1.0-dev`, `0.2.0-beta.1`)
   are published as pre-releases.

Nothing is published when a check or build fails. Fix the problem, then move
the tag to the fixed commit:

```bash
git tag --force v0.1.0-dev
git push --force origin v0.1.0-dev
```

## Publishing to pub.dev

Package versions on pub.dev are permanent: they cannot be deleted, only
retracted within seven days. Publish from a clean checkout of the tagged
commit, `reforge_core` first, since `reforge` depends on it:

```bash
cd packages/reforge_core
dart pub publish --dry-run
dart pub publish
cd ../reforge
dart pub publish --dry-run
dart pub publish
```

Always run `dart pub publish` inside `packages/reforge_core` and
`packages/reforge`. At the repository root it tries to publish the development
workspace, which is not a package.

After the first version, releases can publish to pub.dev automatically when
the tag is pushed:

1. On pub.dev, open **Admin → Automated publishing** of each package, enable
   publishing from GitHub Actions for the repository `KEREM-BAS/reforge`, and
   set the tag pattern to `v{{version}}`.
2. In the GitHub repository, add the variable `PUB_AUTOMATED_PUBLISHING` with
   the value `true` (**Settings → Secrets and variables → Actions →
   Variables**).

The `pub` job of the release workflow then publishes `reforge_core` and
`reforge` after the executables are built.

## Keeping the knowledge base current

Reforge's knowledge about Flutter releases is compiled into each release, so
users need a new Reforge version to plan for a new Flutter release.

`.github/workflows/update-knowledge.yml` runs every Monday, and on demand from
the Actions tab or with `gh workflow run update-knowledge.yml`. It compares
Flutter's release manifest with the knowledge base. When stable releases are
missing, it clones Flutter, runs the generators (downloading the Android
embedding's AndroidX AARs from Google's Maven repository), formats, analyzes
and tests, and opens a pull request from `knowledge/flutter-<version>`. The
pull request is a draft when the tests fail, and it is not opened again while
one from the same branch is open.

Repository settings it needs:

- **Settings → Actions → General → Workflow permissions:** allow GitHub Actions
  to create and approve pull requests. Otherwise opening the pull request
  fails.

GitHub does not start other workflows for pull requests opened by GitHub
Actions, so CI does not run on them by itself. The update workflow reports its
own test result in the pull request; close and reopen the pull request to run
CI as well.

Before merging, work through the checklist in the pull request: review the
generated values, update the curated tables in
`packages/reforge_core/lib/src/knowledge/data/android_toolchain.dart` for new
Android Gradle Plugin versions and API levels, add recipes or failure
signatures for new breaking changes, and build a migrated fixture with the new
release ([validation.md](validation.md)). Then publish a new version.

### Updating by hand

```bash
curl -o /tmp/releases_macos.json \
  https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json
cd packages/reforge_core
dart run tool/new_flutter_releases.dart --manifest /tmp/releases_macos.json
dart run tool/generate_flutter_knowledge.dart \
  --flutter <flutter checkout with tags> \
  --manifest /tmp/releases_macos.json --download-aars
dart run tool/generate_toolchain_releases.dart
```

The generators rewrite a file only when its knowledge changed, so a generation
date always says when the knowledge last changed.
