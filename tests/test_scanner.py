from __future__ import annotations


from downloads_organizer.scanner import candidates, scan

from conftest import put


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
