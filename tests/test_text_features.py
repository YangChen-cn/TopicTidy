from __future__ import annotations

from pathlib import Path

from downloads_organizer.config import all_courses, body_courses, normalize_course
from downloads_organizer.models import IndexedFile
from downloads_organizer.semantic_text import semantic_language
from downloads_organizer.text_features import document_reference_names, tokenize
from downloads_organizer.topic_naming import display_name


def _file(title: str, summary: str = "") -> IndexedFile:
    return IndexedFile(
        id=1,
        path=Path("sample.md"),
        name="sample.md",
        extension=".md",
        size=1,
        created_at=0,
        modified_at=0,
        device=1,
        inode=1,
        fingerprint="f",
        source_urls=[],
        text=summary,
        title=title,
        keywords=[],
        summary=summary,
        extraction_error=None,
    )


def test_filename_tokenization_splits_hyphens_and_underscores():
    assert tokenize("mit6_622_s23-lec01.pdf") == ["mit6", "s23", "lec01", "pdf"]


def test_year_shaped_citations_are_not_course_codes():
    assert normalize_course("ELEC-6008 lecture") == "ELEC6008"
    assert not normalize_course("NOTES2021 ORNL2005 ILSVRC2012")
    assert all_courses("ELEC7043 and NOTES2021") == {"ELEC7043"}


def test_document_body_only_accepts_known_academic_course_prefixes():
    assert body_courses("ELEC 7043 Digital Image Processing") == {"ELEC7043"}
    assert not body_courses("HAVE1000 TASK1000 IN1882 THE2500")


def test_semantic_language_uses_human_metadata_for_code_heavy_notes():
    assert semantic_language(_file("02 FreeRTOS 任务管理", "void task(void *arg)")) == "zh-Hans"
    assert semantic_language(_file("Neural Networks for Machine Learning")) == "en"


def test_document_references_decode_markdown_and_wiki_links():
    names, stems = document_reference_names(
        "[GCC](03-%20GCC.md) and [[04-Signals#intro|Signals]] plus [web](https://example.com/a.md)"
    )
    assert names == {"03- gcc.md", "04-signals"}
    assert stems == {"03- gcc", "04-signals"}


def test_topic_name_can_expand_opaque_filename_series_from_source_path():
    first = _file("Machine Learning Introduction")
    first.path = Path("MLB-01.md")
    first.source_urls = ["https://raw.githubusercontent.com/microsoft/ML-For-Beginners/main/1-Introduction/1-intro-to-ML/README.md"]
    second = _file("Regression Tools")
    second.id = 2
    second.path = Path("MLB-02.md")
    second.source_urls = ["https://raw.githubusercontent.com/microsoft/ML-For-Beginners/main/regression/README.md"]

    assert display_name([first, second]) == "Microsoft ML Beginners"
