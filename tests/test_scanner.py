from __future__ import annotations

from downloads_organizer.extractors import ExtractorRegistry
from downloads_organizer.models import Extracted

from downloads_organizer.scanner import candidates, scan

from conftest import put


class VersionedExtractor:
    name = "versioned"

    def __init__(self, version: str, text: str):
        self.version = version
        self.text = text
        self.calls = 0

    def supports(self, path):
        return path.suffix == ".fixture"

    def extract(self, path, context):
        self.calls += 1
        return Extracted(text=self.text, title=self.text, summary=self.text)


def test_scan_excludes_hidden_incomplete_directories_and_symlinks(workspace):
    settings, db = workspace
    put(settings.downloads, "visible.md", "hello")
    put(settings.downloads, ".hidden.md", "secret")
    put(settings.downloads, "partial.crdownload", "partial")
    (settings.downloads / "folder").mkdir()
    (settings.downloads / "link.md").symlink_to(settings.downloads / "visible.md")

    assert [p.name for p in candidates(settings)] == ["visible.md"]
    stats = scan(db, settings)
    assert stats["scanned"] == 1


def test_corrupt_pdf_does_not_stop_scan(workspace):
    settings, db = workspace
    put(settings.downloads, "broken.pdf", "not a pdf")
    put(settings.downloads, "notes.md", "valid notes")

    stats = scan(db, settings)

    assert stats["scanned"] == 2
    assert stats["errors"] == 1
    errors = db.conn.execute("SELECT extraction_error FROM features WHERE extraction_error IS NOT NULL").fetchall()
    assert len(errors) == 1


def test_changed_file_clears_cached_embedding_and_language_space(workspace):
    settings, db = workspace
    path = put(settings.downloads, "notes.md", "first version")
    scan(db, settings)
    db.conn.execute(
        "UPDATE features SET native_embedding=?,native_embedding_space='en',model_version='old'",
        (b"[1.0,0.0]",),
    )
    row = db.conn.execute("SELECT id,fingerprint FROM files").fetchone()
    db.conn.execute(
        """INSERT INTO semantic_pivots(
        file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
        translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
        ) VALUES(?,?,'en','en','first','first','identity:1',?,'en','old',1)""",
        (row["id"], row["fingerprint"], b"[1.0,0.0]"),
    )
    db.conn.commit()
    path.write_text("second version with new content", encoding="utf-8")

    scan(db, settings)

    feature = db.conn.execute(
        "SELECT native_embedding,native_embedding_space,model_version FROM features"
    ).fetchone()
    assert feature["native_embedding"] is None
    assert feature["native_embedding_space"] is None
    assert feature["model_version"] is None
    assert db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0] == 0


def test_extractor_version_change_invalidates_unchanged_file_cache(workspace):
    settings, db = workspace
    put(settings.downloads, "document.fixture", "unchanged bytes")
    first = VersionedExtractor("1", "first extraction")
    scan(db, settings, extractors=ExtractorRegistry([first]))
    row = db.conn.execute("SELECT id,fingerprint FROM files").fetchone()
    db.conn.execute(
        "UPDATE features SET native_embedding=?,native_embedding_space='en',model_version='old'",
        (b"[1.0,0.0]",),
    )
    db.conn.execute(
        """INSERT INTO semantic_pivots(
        file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
        translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
        ) VALUES(?,?,'en','en','old','old','identity:1',?,'en','old',1)""",
        (row["id"], row["fingerprint"], b"[1.0,0.0]"),
    )
    db.conn.commit()
    second = VersionedExtractor("2", "second extraction")

    stats = scan(db, settings, extractors=ExtractorRegistry([second]))

    assert stats["scanned"] == 1
    assert stats["unchanged"] == 0
    feature = db.conn.execute("SELECT * FROM features").fetchone()
    assert feature["extractor_version"] == "versioned:2"
    assert feature["text"] == "second extraction"
    assert feature["native_embedding"] is None
    assert feature["native_embedding_space"] is None
    assert feature["model_version"] is None
    assert db.conn.execute("SELECT count(*) FROM semantic_pivots").fetchone()[0] == 0
    assert second.calls == 1

    repeated = scan(db, settings, extractors=ExtractorRegistry([second]))
    assert repeated["unchanged"] == 1
    assert second.calls == 1


def test_interrupted_move_recovery_updates_file_location(workspace):
    settings, db = workspace
    source = put(settings.downloads, "recover.md", "recover me")
    scan(db, settings)
    row = db.conn.execute("SELECT id,fingerprint FROM files WHERE name='recover.md'").fetchone()
    destination = settings.organized_dir / "Recovered" / source.name
    destination.parent.mkdir(parents=True)
    batch = db.conn.execute(
        "INSERT INTO operation_batches(kind,status,created_at) VALUES('apply','running',1)"
    ).lastrowid
    db.conn.execute(
        """INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
        VALUES(?,?,?,?,?,'intent',1)""",
        (batch, row["id"], str(source), str(destination), row["fingerprint"]),
    )
    db.conn.commit()
    source.rename(destination)

    assert db.recover_interrupted() == 1
    recovered = db.conn.execute("SELECT path,status FROM files WHERE id=?", (row["id"],)).fetchone()
    assert recovered["path"] == str(destination)
    assert recovered["status"] == "organized"
