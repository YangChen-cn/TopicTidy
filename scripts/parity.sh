#!/bin/bash
# Differential harness used during the Python -> Swift migration.
#
# Runs the same scenario through the Python reference core and the native Swift
# core, then diffs their JSON output and resulting database. The two runs use
# separate state directories, so the comparison normalises the run root away.
#
# This is the method record for the migration (see docs/MIGRATION.md). It needs
# the pre-migration Python package, which lived in `src/downloads_organizer`;
# restore it from git history (the commit before the "port core to Swift"
# change) to re-run. The durable regression baseline is the frozen golden
# output in Tests/TopicTidyCoreTests/Fixtures.
#
# Usage: scripts/parity.sh [scenario ...]     (default: all scenarios)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"
SWIFT_TT="${SWIFT_TT:-$ROOT/.build/debug/tt}"
# `pwd -P` gives the canonical (symlink-resolved) form both cores report.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/topictidy-parity-XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -d "$ROOT/src/downloads_organizer" ]; then
  echo "parity.sh needs the pre-migration Python package (src/downloads_organizer)." >&2
  echo "Restore it from git history to re-run this harness; see docs/MIGRATION.md." >&2
  exit 2
fi

SCENARIOS=("$@")
if [ ${#SCENARIOS[@]} -eq 0 ]; then
  SCENARIOS=(courses markdown-collection mixed-formats office-documents)
fi

fail=0

compare() {
  # Semantic comparison: 1 and 1.0 are the same number, paths are normalised.
  python3 - "$1" "$2" "$3" "$4" <<'PYSCRIPT'
import json, re, sys
left_path, right_path, left_root, right_root = sys.argv[1:5]

def load(path):
    raw = open(path, encoding='utf-8').read()
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return re.sub(r"^(扫描完成：).*$", r"\\1<STATS>", raw, flags=re.M)

def scrub(value, root):
    if isinstance(value, str):
        return value.replace("/private" + root, "<ROOT>").replace(root, "<ROOT>")
    if isinstance(value, list):
        return [scrub(v, root) for v in value]
    if isinstance(value, dict):
        return {k: scrub(v, root) for k, v in value.items()}
    return value

def same(a, b, path="$"):
    if isinstance(a, bool) or isinstance(b, bool):
        return (a == b), path, a, b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return float(a) == float(b), path, a, b
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                return False, f"{path}.{key} (missing on one side)", a.get(key), b.get(key)
            ok, where, left_value, right_value = same(a[key], b[key], f"{path}.{key}")
            if not ok:
                return False, where, left_value, right_value
        return True, path, a, b
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return False, f"{path} (length {len(a)} != {len(b)})", a, b
        for index, (x, y) in enumerate(zip(a, b)):
            ok, where, left_value, right_value = same(x, y, f"{path}[{index}]")
            if not ok:
                return False, where, left_value, right_value
        return True, path, a, b
    if isinstance(a, str) and isinstance(b, str):
        if a.strip()[:1] in "[{" and b.strip()[:1] in "[{":
            # Columns such as plan_members.evidence hold embedded JSON; compare
            # those structurally so key order and float spelling do not matter.
            try:
                return same(json.loads(a), json.loads(b), path)
            except json.JSONDecodeError:
                pass
        if a.startswith("apple-") and b.startswith("apple-"):
            # Backend identity legitimately differs: the native core no longer
            # carries a helper source digest.
            return a.split(":")[:2] == b.split(":")[:2], path, a, b
    return (a == b), path, a, b

left, right = scrub(load(left_path), left_root), scrub(load(right_path), right_root)
ok, where, left_value, right_value = same(left, right)
if ok:
    print("OK")
    sys.exit(0)
print(f"DIFF at {where}")
print("  python:", json.dumps(left_value, ensure_ascii=False)[:1500])
print("  swift: ", json.dumps(right_value, ensure_ascii=False)[:1500])
sys.exit(1)
PYSCRIPT
}

summarize_db() {
  "$PYTHON" - "$1" <<'PY'
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.row_factory = sqlite3.Row
out = {}
out['files'] = [dict(r) for r in conn.execute(
    "SELECT name,extension,size,fingerprint,source_urls,status FROM files ORDER BY name")]
out['features'] = [dict(r) for r in conn.execute(
    "SELECT f.name AS name,x.title,x.keywords,x.summary,x.truncated,x.extraction_error,"
    "x.native_embedding_space,x.model_version,"
    "CAST(x.native_embedding AS TEXT) AS native_embedding "
    "FROM features x JOIN files f ON f.id=x.file_id ORDER BY f.name")]
out['pivots'] = [dict(r) for r in conn.execute(
    "SELECT f.name AS name,p.source_language,p.target_language,p.semantic_text,p.translated_text,"
    "p.translation_version,p.embedding_version,p.pivot_embedding_space,"
    "CAST(p.pivot_embedding AS TEXT) AS pivot_embedding "
    "FROM semantic_pivots p JOIN files f ON f.id=p.file_id ORDER BY f.name")]
out['members'] = [dict(r) for r in conn.execute(
    "SELECT group_name,topic_key,confidence,reasons,evidence,conflicts,excluded,applied,destination,"
    "source_fingerprint FROM plan_members ORDER BY id")]
out['app_settings'] = {r['key']: r['value'] for r in conn.execute("SELECT key,value FROM app_settings")}
out['batches'] = [dict(r) for r in conn.execute(
    "SELECT id,kind,status FROM operation_batches ORDER BY id")]
out['logs'] = [dict(r) for r in conn.execute(
    "SELECT batch_id,file_id,source,destination,fingerprint,status,error FROM operation_logs ORDER BY id")]
out['associations'] = [dict(r) for r in conn.execute(
    "SELECT topic_key,file_fingerprint,active FROM associations ORDER BY id")]
out['topics'] = [dict(r) for r in conn.execute(
    "SELECT topic_key,display_name,source,active FROM topics ORDER BY topic_key")]
out['plans'] = [dict(r) for r in conn.execute("SELECT id,status,config_json FROM plans ORDER BY id")]
print(json.dumps(out, ensure_ascii=False, sort_keys=True, indent=1))
PY
}

# The scenario template is built once and copied to both sides, so both cores
# read byte-identical inputs.
build_template() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  case "$name" in
    courses)
      printf 'ELEC6008 power electronics converter design\n' > "$dir/ELEC6008 Chapter 1.md"
      printf 'ELEC6008 power electronics inverter design\n' > "$dir/ELEC6008 Chapter 2.md"
      printf 'ELEC6103 power electronics converter design\n' > "$dir/ELEC6103 Chapter 1.md"
      printf 'ELEC6103 power electronics inverter design\n' > "$dir/ELEC6103 Chapter 2.md"
      printf '{"unrelated": true}\n' > "$dir/random.json"
      ;;
    markdown-collection)
      printf '# Reading list\n\nSee [01 Introduction.md](01 Introduction.md) and [02 Renewable Energy.md](02 Renewable Energy.md)\n' > "$dir/README.md"
      printf 'renewable energy solar wind systems overview introduction\n' > "$dir/01 Introduction.md"
      printf 'renewable energy solar wind generation systems\n' > "$dir/02 Renewable Energy.md"
      printf 'renewable energy solar wind storage systems\n' > "$dir/03 Storage.md"
      printf 'ELEC7011 Energy Internet overview\n' > "$dir/04 Grid.md"
      ;;
    mixed-formats)
      printf 'FreeRTOS memory management notes for embedded kernels\n' > "$dir/01-memory.md"
      printf 'FreeRTOS queue management notes for embedded kernels\n' > "$dir/02-queues.md"
      printf 'Grid Storage Design v1\nlarge scale battery storage design report\nsecond line\n' > "$dir/Grid Storage Design v1.txt"
      printf 'random archive content with no signal at all\n' > "$dir/random-archive.bin"
      printf 'power electronics converter design\n\nsecond page of the lecture\n\nthird page\n' > "$dir/lecture.txt"
      if command -v cupsfilter > /dev/null; then
        cupsfilter -m application/pdf "$dir/lecture.txt" > "$dir/ELEC6008 Lecture Notes.pdf" 2>/dev/null
        rm -f "$dir/lecture.txt"
      else
        rm -f "$dir/lecture.txt"
      fi
      ;;
    office-documents)
      "$PYTHON" - "$dir" <<'PY'
import pathlib, sys
from docx import Document
from pptx import Presentation
from pptx.util import Inches
out = pathlib.Path(sys.argv[1])
doc = Document()
doc.add_heading('ELEC6008 Power Electronics', level=1)
doc.add_paragraph('Converter design and inverter control for power electronics systems.')
doc.add_paragraph('Lecture notes on switching losses, modulation and thermal design.')
table = doc.add_table(rows=2, cols=2)
table.cell(0, 0).text = 'Week 1'
table.cell(0, 1).text = 'Converter basics'
table.cell(1, 0).text = 'Week 2'
table.cell(1, 1).text = 'Inverter control'
doc.save(str(out / 'ELEC6008 Chapter 1.docx'))
deck = Presentation()
layout = deck.slide_layouts[5]
for title, body in [('ELEC6008 Lecture 01', 'Power electronics converter design'),
                    ('ELEC6008 Lecture 02', 'Inverter control and modulation')]:
    slide = deck.slides.add_slide(layout)
    slide.shapes.title.text = title
    box = slide.shapes.add_textbox(Inches(1), Inches(2), Inches(6), Inches(2))
    box.text_frame.text = body
deck.save(str(out / 'ELEC6008 Slides.pptx'))
PY
      ;;
    *)
      echo "unknown scenario: $name" >&2
      exit 2
      ;;
  esac
}

run_side() {
  local label="$1" scenario="$2" template="$3"
  local base="$WORK/$scenario/$label"
  local downloads="$base/Downloads"
  mkdir -p "$downloads" "$base/state"
  cp -R "$template"/. "$downloads"/

  export DOWNLOADS_ORGANIZER_DOWNLOADS="$downloads"
  export DOWNLOADS_ORGANIZER_HOME="$base/state"
  export DOWNLOADS_ORGANIZER_DESTINATION="$base/Organized"

  local tt
  if [ "$label" = "python" ]; then
    tt=("$PYTHON" -m downloads_organizer)
    (cd "$ROOT" && "${tt[@]}" scan > "$base/scan.txt" 2>&1)
    (cd "$ROOT" && "${tt[@]}" propose --json > "$base/propose.json" 2>&1)
  else
    tt=("$SWIFT_TT")
    "${tt[@]}" scan > "$base/scan.txt" 2>&1
    "${tt[@]}" propose --json > "$base/propose.json" 2>&1
  fi
  summarize_db "$base/state/organizer.sqlite3" > "$base/db.json"

  # Operations phase: per-topic apply, then undo, then a plan edit.
  (cd "$ROOT" && "${tt[@]}" apply 1 --yes > "$base/apply.txt" 2>&1) || true
  summarize_db "$base/state/organizer.sqlite3" > "$base/apply-db.json"
  (cd "$ROOT" && "${tt[@]}" undo 1 > "$base/undo.txt" 2>&1) || true
  summarize_db "$base/state/organizer.sqlite3" > "$base/undo-db.json"
  (cd "$ROOT" && printf 'rename ELEC6008 ELEC6008 Renamed\ndone\n' | "${tt[@]}" review 1 > "$base/review.txt" 2>&1) || true
  summarize_db "$base/state/organizer.sqlite3" > "$base/review-db.json"
}

for scenario in "${SCENARIOS[@]}"; do
  echo "=== scenario: $scenario ==="
  template="$WORK/$scenario/template"
  build_template "$template" "$scenario"
  run_side python "$scenario" "$template"
  run_side swift "$scenario" "$template"
  for artifact in scan.txt propose.json db.json apply-db.json undo-db.json review-db.json; do
    if compare "$WORK/$scenario/python/$artifact" "$WORK/$scenario/swift/$artifact" \
         "$WORK/$scenario/python" "$WORK/$scenario/swift" > "$WORK/compare.$artifact" 2>&1; then
      echo "  $artifact OK"
    else
      echo "  $artifact DIFF"
      head -60 "$WORK/compare.$artifact"
      fail=1
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "parity: FAILED"
  exit 1
fi
echo "parity: all scenarios match"
