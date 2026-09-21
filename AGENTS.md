# TopicTidy Repository Guide

## Product

TopicTidy is a local macOS Downloads organizer. It groups files by course, project, or topic using explainable local signals. It must remain conservative, offline by default, reviewable before file moves, and safely undoable.

The CLI and user-facing explanations are Chinese by default. Source code, identifiers, and developer documentation may use English.

## Architecture Boundaries

- `scanner.py` owns directory enumeration, fingerprints, cache lookup, and persistence. It may depend on the `ExtractorRegistry` interface but must not import PDF, DOCX, or PPTX libraries.
- `extractors/` owns document-format integrations. Every extractor implements `DocumentExtractor`, declares a cache version, enforces the supplied text budget, and returns `Extracted` rather than leaking library-specific objects.
- `metadata.py` owns macOS metadata such as `kMDItemWhereFroms`.
- `text_features.py` owns shared token, keyword, and URL feature helpers. Clustering must not import concrete extractors.
- `clustering.py` owns pair assessment, conservative clustering, evidence aggregation, and plan creation.
- `embedding.py` owns the `SemanticEncoder` interface and macOS-native implementation. The default path must not download models or install Python ML frameworks.
- `semantic_text.py` owns the bounded representative text used by both native and pivot embeddings. Do not send full extracted documents to Translation.
- `translation.py` owns installed-only Apple Translation integration, pivot caching, and graceful language-asset fallback. It must never request or initiate a language download.
- `topic_naming.py` owns display-name generation and internal topic-key generation. Never use a display name as the durable topic identity.
- `operations.py` owns plan edits, file moves, durable operation intent, recovery, and undo.
- `benchmark.py` and packaged fixtures protect clustering quality when weights or naming logic change.

## Core Invariants

- Never scan recursively, follow symlinks, overwrite an existing file, or move a file without an explicit saved plan and user confirmation.
- Tests and benchmarks must use temporary Downloads directories. Never point automated validation at the real `~/Downloads`.
- PDF extraction must not read every page of a large document. Preserve front pages, representative middle pages, and tail pages within `max_chars`.
- Course-code conflicts are hard negative evidence. A shared source domain alone must never create a cluster.
- Proposed groups expose structured evidence for course code, filename, content, native semantic similarity, cross-language semantic similarity, and source URL, each marked `strong`, `weak`, or `none`.
- Native vectors from different language spaces must never be compared. Persist and check `native_embedding_space`; cross-language comparison requires two cached English pivot vectors and distinct `semantic_cross_language` evidence.
- Translation is propose-time fallback for plausible cross-language candidates. Never run translation during scan or for every indexed file.
- `topic_key` is durable identity; `display_name` is editable presentation. Rename operations must preserve `topic_key`.
- Confidence values are heuristic scores, not calibrated probabilities.
- The project is still pre-user. Do not add backward database migrations yet. Change the current schema and bump `SCHEMA_VERSION`; incompatible local test databases may be deleted and rebuilt.

## Development

Use Python 3.12+ in `.venv` and keep dependencies pinned in `pyproject.toml`.

```bash
source .venv/bin/activate
python -m pip install -e '.[dev]'
pytest
tt benchmark
python -m pip wheel . --no-deps --wheel-dir /tmp/topictidy-wheel-check
```

Before committing, require:

- the complete pytest suite passes;
- the core benchmark meets its checked-in F1 threshold and unclassified set;
- `git diff --check` passes;
- a wheel builds and includes the packaged benchmark fixture;
- CLI JSON output remains machine-readable and contains topic identity plus structured evidence.

When adding a file format, add an extractor-focused test. When changing clustering weights or naming, update or extend the benchmark fixture and explain any intentional expected-output change.
