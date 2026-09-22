# TopicTidy Repository Guide

## Product

TopicTidy is a local macOS Downloads organizer. It groups files by course, project, or topic using explainable local signals. It must remain conservative, offline by default, reviewable before file moves, and safely undoable.

The CLI and user-facing explanations are Chinese by default. Source code, identifiers, and developer documentation may use English.

The product is a pure native Swift package. There is no Python runtime, no helper subprocess, and no JSON bridge; `Sources/TopicTidyCore` is the single implementation shared by the `tt` CLI and the SwiftUI app.

## Layout

- `Sources/TopicTidyCore/Config` owns `Settings`, the course-code pattern, and path resolution. `Support/PythonCompat.swift` provides the CPython-compatible string semantics the clustering rules were written against; use those helpers (`Py`, `OrderedCounter`, `PyPath`) instead of Swift's default grapheme-cluster behaviour whenever a rule is ported from the original specification.
- `Sources/TopicTidyCore/Database` owns the SQLite3 wrapper and schema. Rows are materialised value types; never keep a statement pointer alive past materialisation.
- `Sources/TopicTidyCore/Scanner` owns directory enumeration, fingerprints, cache lookup, provenance metadata, and persistence. It may depend on the `ExtractorRegistry` interface but must not import PDFKit or OOXML specifics.
- `Sources/TopicTidyCore/Extractors` owns document-format integrations. Every extractor implements `DocumentExtractor`, declares a cache version, enforces the supplied text budget, and returns `Extracted`. `MiniZip` + `XMLParser` provide the minimal OOXML reader; do not add a third-party ZIP or Office dependency.
- `Sources/TopicTidyCore/Semantic` owns `SemanticEncoder`, the `NLEmbedding` implementation, the installed-only Apple Translation backend, and the bounded representative text. Nothing here may download models or language assets.
- `Sources/TopicTidyCore/Clustering` owns pair assessment, conservative clustering, evidence aggregation, naming, and plan creation. `ClusterCache` may memoise pure per-file derivations; it must never cache anything that depends on another file or on the database.
- `Sources/TopicTidyCore/Operations` owns plan edits, file moves, durable operation intent, recovery, undo, preferences, the LaunchAgent scheduler, the daily automation service, and `AppService` (the request/response facade the GUI uses).
- `Sources/tt` is the CLI. `Sources/TopicTidy` is the SwiftUI menu bar client; it maps core values onto presentation models and must not reimplement classification or filesystem work.

## Core Invariants

- Never scan recursively, follow symlinks, overwrite an existing file, or move a file without an explicit saved plan and user confirmation.
- Persisted auto-confirm enablement is explicit ongoing confirmation. It may move only complete conflict-free groups at or above the configured threshold, after saving a plan and durable intent; it must remain off by default.
- Auto-confirm must reject an entire topic when any member is excluded. Strong `document_links` requires a second independent strong course, series identifier, semantic, cross-language semantic, or source signal before automatic movement.
- A plan must retain its destination root. Changing the current preference must never retarget an existing plan or break undo for an earlier batch.
- Tests and benchmarks must use temporary Downloads directories. Never point automated validation at the real `~/Downloads`.
- PDF extraction must not read every page of a large document. Preserve front pages, representative middle pages, and tail pages within `max_chars`.
- An unchanged size/mtime does not make an extraction cache valid by itself. Scanner cache hits must also match the file fingerprint and current extractor cache version.
- Course-code conflicts are hard negative evidence. A shared source domain alone must never create a cluster.
- Generic filename tokens such as report, project, and notes must not receive overlap-coefficient amplification by themselves.
- Proposed groups expose structured evidence for course code, filename, content, native semantic similarity, cross-language semantic similarity, and source URL, each marked `strong`, `weak`, or `none`.
- Native vectors from different language spaces must never be compared. Persist and check `native_embedding_space`; cross-language comparison requires two cached English pivot vectors and distinct `semantic_cross_language` evidence.
- Translation is propose-time fallback for plausible cross-language candidates. Never run translation during scan or for every indexed file.
- Cross-language recall without lexical clues must stay bounded by nearest-neighbor and per-proposal limits; course conflicts remain hard negatives.
- `topic_key` is durable identity; `display_name` is editable presentation. Rename operations must preserve `topic_key`.
- Dismissing a topic is durable: it excludes the members in the current plan and writes one `corrections` row with `action='dismiss'` per member. Clustering drops dismissed files from proposals entirely (they must not reappear as groups or as unclassified), and `restore-dismissed` re-opens them. Since `corrections` has no topic column, dismissal is grouped by `topic_name`; two topics sharing a display name restore together.
- Confidence values are heuristic scores, not calibrated probabilities.
- The project is still pre-user. Do not add backward database migrations yet. Change the current schema and bump `Database.schemaVersion`; incompatible local test databases may be deleted and rebuilt.
- Interrupted apply/auto-apply recovery must restore both file state and the plan's topic association after a completed rename.
- The GUI must keep presenting the exact saved-plan preview it was confirmed with; `AppService` re-validates the submitted move list before applying.

## Behaviour Changes Require Evidence

The clustering rules, thresholds, evidence wording, and naming logic were migrated one-to-one from the previous implementation. Do not retune weights or redesign the algorithm as part of unrelated work. When changing them intentionally:

- update or extend the benchmark fixture and explain the expected-output change;
- refresh the frozen golden outputs in `Tests/TopicTidyCoreTests/Fixtures`;
- keep `tt benchmark` and `tt benchmark Resources/fixtures/holdout_unseen.json` green.

`Resources/fixtures/*.json` is the editable source of truth; `Tests/TopicTidyCoreTests/FixtureTests.swift` fails if the embedded Swift copies drift from it.

## Release Pipeline

- `AppInfo.version` (in `Sources/TopicTidyCore/Config/AppInfo.swift`) is the only version literal. `scripts/build_app.sh` reads it for the bundle, `tt --version` reports it, and the release workflow refuses to publish when the pushed tag does not match.
- Pushing a `v*` tag runs `.github/workflows/release.yml`: toolchain check, `swift test`, benchmark gates, `scripts/build_app.sh`, `scripts/package_cli.sh`, `SHA256SUMS.txt`, then a GitHub Release with the DMG, the CLI archive and the checksums. No Python distribution is published any more.
- `install.sh` is the user-facing CLI installer: macOS + arm64 only, latest release by default, SHA-256 verified against `SHA256SUMS.txt`, installed to `~/.local/bin/tt` via write-and-rename, with a PATH hint. It accepts `TOPICTIDY_API_BASE`/`TOPICTIDY_DOWNLOAD_BASE` overrides so it can be tested against a local mock before a release exists.
- The Homebrew tap is `YangChen-cn/homebrew-tap`, prepared from `packaging/homebrew/` by `scripts/publish_tap.sh`. Never open pull requests against Homebrew's official repositories from CI.
- CI runs on a macOS 26 runner image; `macos-15` ships Swift 6.1 and cannot build the package.

## Development

```bash
swift build
swift test
swift build -c release && .build/release/tt benchmark --json
scripts/build_app.sh                    # signed .app + DMG + size report
```

Before committing, require:

- the full `swift test` suite passes;
- the core benchmark meets its checked-in F1 threshold and unclassified set, and the holdout fixture keeps precision 1.0 with F1 ≥ 0.94;
- `git diff --check` passes;
- CLI JSON output remains machine-readable and contains topic identity plus structured evidence.

## Native macOS client

- Build with `swift build`; package with `scripts/build_app.sh`.
- The bundle must stay pure native: `Contents/MacOS/TopicTidy` plus `Contents/Resources/tt` and the icon. `scripts/build_app.sh` fails the build if Python files, a `python` directory, or build-host paths appear in the bundle.
- The daily LaunchAgent invokes the bundled `tt`; keep `LaunchAgentScheduler.executablePath()` working for both the app bundle and a source build.
- UI verification must use isolated Downloads/state directories.
- Preserve bundle signatures: sign nested Mach-O code before signing the app; validate with `codesign --verify --deep --strict`.
- GUI visual acceptance is manual by the user. Do not use Computer Use by default; validate builds, service contracts, and distribution with command-line tools. Keep the menu bar panel compact with content-driven height.
