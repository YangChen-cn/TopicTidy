from __future__ import annotations

import json

from downloads_organizer.clustering import cluster
from downloads_organizer.scanner import scan

from conftest import put


def test_same_course_clusters_and_conflicting_courses_stay_apart(workspace):
    settings, db = workspace
    put(settings.downloads, "ELEC6008 Chapter 1.md", "power electronics converter")
    put(settings.downloads, "ELEC6008 Chapter 2.md", "power electronics inverter")
    put(settings.downloads, "ELEC6103 Chapter 1.md", "power electronics converter")
    put(settings.downloads, "ELEC6103 Chapter 2.md", "power electronics inverter")
    put(settings.downloads, "random.json", "{}")
    scan(db, settings)

    groups, unclassified = cluster(db, settings)

    assert {g.name for g in groups} == {"ELEC6008", "ELEC6103"}
    assert {f.name for f in unclassified} == {"random.json"}
    assert all(len(g.files) == 2 for g in groups)


def test_content_and_fixed_semantic_vectors_cluster_numbered_documents(workspace):
    settings, db = workspace
    put(settings.downloads, "01 Introduction.md", "renewable energy solar wind systems overview")
    put(settings.downloads, "02 Renewable Energy.md", "renewable energy solar wind generation systems")
    scan(db, settings)
    vector = json.dumps([1.0, 0.0]).encode()
    db.conn.execute(
        "UPDATE features SET native_embedding=?,native_embedding_space='test',model_version='test-fixed'",
        (vector,),
    )
    db.conn.commit()

    groups, unclassified = cluster(db, settings)

    assert len(groups) == 1
    assert {f.name for f in groups[0].files} == {"01 Introduction.md", "02 Renewable Energy.md"}
    assert not unclassified
    assert groups[0].display_name == "Renewable Energy"
    assert groups[0].topic_key.startswith("cluster:")
    evidence = {item.kind: item for item in groups[0].evidence}
    assert set(evidence) == {
        "course_code", "filename_similarity", "content_similarity", "semantic_similarity",
        "semantic_cross_language", "source_url",
    }
    assert evidence["semantic_similarity"].strength == "strong"
    assert evidence["source_url"].strength == "none"


def test_body_course_code_groups_files_without_code_in_filename(workspace):
    settings, db = workspace
    put(settings.downloads, "01 Systems Overview.md", "ELEC6200 ELEC6200 autonomous control architecture")
    put(settings.downloads, "02 Control Design.md", "ELEC6200 ELEC6200 autonomous control design")
    scan(db, settings)

    groups, unclassified = cluster(db, settings)

    assert not unclassified
    assert len(groups) == 1
    assert groups[0].display_name == "ELEC6200"
    assert groups[0].topic_key == "course:ELEC6200"
    course = next(item for item in groups[0].evidence if item.kind == "course_code")
    assert course.strength == "strong"


def test_course_code_seen_once_in_each_body_becomes_collective_evidence(workspace):
    settings, db = workspace
    put(settings.downloads, "01 Introduction.md", "ELEC7011 Energy Internet systems overview")
    put(settings.downloads, "02 Renewable Energy.md", "ELEC7011 Energy Internet solar wind generation")
    scan(db, settings)

    groups, unclassified = cluster(db, settings)

    assert not unclassified
    assert len(groups) == 1
    assert groups[0].display_name == "ELEC7011"
    assert {file.name for file in groups[0].files} == {
        "01 Introduction.md", "02 Renewable Energy.md",
    }


def test_single_body_course_reference_does_not_classify_a_file(workspace):
    settings, db = workspace
    put(settings.downloads, "Introduction.md", "ELEC7011 Energy Internet overview")
    scan(db, settings)

    groups, unclassified = cluster(db, settings)

    assert not groups
    assert [file.name for file in unclassified] == ["Introduction.md"]


def test_term_and_year_is_not_mistaken_for_course_code(workspace):
    settings, db = workspace
    put(settings.downloads, "lec1.md", "ELEC7043 Digital Image Processing Autumn 2026")
    put(settings.downloads, "lec2.md", "Autumn 2026 Digital Image Processing intensity transformations")
    scan(db, settings)
    vector = json.dumps([1.0, 0.0]).encode()
    db.conn.execute(
        "UPDATE features SET native_embedding=?,native_embedding_space='test',model_version='test-fixed'",
        (vector,),
    )
    db.conn.execute(
        "UPDATE files SET source_urls=?",
        ('["https://moodle.example/course/7043/lecture"]',),
    )
    db.conn.commit()

    groups, unclassified = cluster(db, settings)

    assert not unclassified
    assert len(groups) == 1
    assert groups[0].display_name == "ELEC7043"
    assert {file.name for file in groups[0].files} == {"lec1.md", "lec2.md"}


def test_generic_shared_domain_is_not_enough_to_cluster(workspace, monkeypatch):
    settings, db = workspace
    put(settings.downloads, "tax receipt.md", "annual personal tax receipt")
    put(settings.downloads, "holiday booking.md", "hotel booking itinerary")
    monkeypatch.setattr("downloads_organizer.scanner.source_urls", lambda _: ["https://example.com/download/file"])
    scan(db, settings)

    groups, unclassified = cluster(db, settings)

    assert not groups
    assert len(unclassified) == 2
