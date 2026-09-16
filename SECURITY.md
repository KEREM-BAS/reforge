# Security policy

Reforge reads, and with `apply` modifies, the configuration of software
projects, and `verify` runs their build tools. Please report vulnerabilities
privately to the maintainers instead of opening a public issue. Include the
Reforge version, the command, and a minimal repository that reproduces the
problem.

## Trust boundaries

| Operation | Executes project code? |
| --- | --- |
| `inspect`, `plan`, `history` | No. Files are only read. Symbolic links pointing outside the project are refused. |
| `env` | Runs `flutter`, `java`, `xcodebuild`, `pod` and `git` with version flags only. |
| `apply`, `rollback` | No. Writes files inside the project and `.reforge/`. Runs `git status` with `core.fsmonitor` disabled. |
| `verify --check pub-get/analyze` | Runs `flutter pub get` / `flutter analyze`. Analyzer plugins configured by the project may run. |
| `verify --check android/ios` | Runs `flutter build`, which executes the project's Gradle scripts, Gradle wrapper and CocoaPods. Only run these on repositories you trust. |

Reforge never constructs shell command lines from project content.
