from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from importlib.resources import files as resource_files
from pathlib import Path
from typing import Protocol

from .config import Settings
from .db import Database
from .embedding import NativeMacOSEncoder
from .models import IndexedFile
from .semantic_text import build_semantic_text


@dataclass(frozen=True)
class LanguagePair:
    source: str
    target: str = "en"


class TranslationBackend(Protocol):
    @property
    def version(self) -> str: ...

    def statuses(self, pairs: list[LanguagePair]) -> dict[LanguagePair, str]: ...

    def translate(self, texts: list[str], *, source: str, target: str = "en") -> list[str]: ...


def _source_path() -> Path:
    return Path(str(resource_files("downloads_organizer.native").joinpath("translation.swift")))


class NativeTranslationBackend:
    """Installed-only Apple Translation helper; it never requests assets."""

    def __init__(self, settings: Settings, *, prepare: bool = True):
        if sys.platform != "darwin":
            raise RuntimeError("Apple Translation backend 仅支持 macOS")
        self.settings = settings
        self.source = _source_path()
        self.source_digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        if prepare:
            self.prepare()

    @property
    def version(self) -> str:
        release = platform.mac_ver()[0] or "unknown"
        return f"apple-translation:{release}:{self.source_digest[:12]}"

    def is_prepared(self) -> bool:
        return (
            self.settings.translation_helper.is_file()
            and os.access(self.settings.translation_helper, os.X_OK)
            and self.settings.translation_helper_stamp.is_file()
            and self.settings.translation_helper_stamp.read_text(encoding="utf-8").strip()
            == self.source_digest
        )

    def prepare(self) -> Path:
        if self.is_prepared():
            return self.settings.translation_helper
        if not shutil.which("xcrun"):
            raise RuntimeError("未找到 xcrun；请安装 Xcode Command Line Tools")
        self.settings.translation_helper.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.settings.translation_helper.with_name(f"native-translation.tmp-{os.getpid()}")
        command = [
            "xcrun", "swiftc", "-O", "-parse-as-library", str(self.source),
            "-framework", "Translation", "-o", str(temporary),
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=180)
            os.chmod(temporary, 0o755)
            os.replace(temporary, self.settings.translation_helper)
            self.settings.translation_helper_stamp.write_text(self.source_digest, encoding="utf-8")
        except (OSError, subprocess.SubprocessError) as exc:
            temporary.unlink(missing_ok=True)
            detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else str(exc)
            raise RuntimeError(f"无法构建 Apple Translation helper：{detail}") from exc
        return self.settings.translation_helper

    def _run(self, payload: dict[str, object]) -> dict[str, object]:
        try:
            result = subprocess.run(
                [str(self.prepare())],
                input=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                check=True,
                capture_output=True,
                timeout=180,
            )
            response = json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
            detail = ""
            if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
                detail = exc.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"Apple Translation helper 执行失败：{detail or exc}") from exc
        if response.get("error"):
            raise RuntimeError(str(response["error"]))
        return response

    def statuses(self, pairs: list[LanguagePair]) -> dict[LanguagePair, str]:
        unique = list(dict.fromkeys(pairs))
        if not unique:
            return {}
        response = self._run({
            "operation": "status",
            "pairs": [{"source": pair.source, "target": pair.target} for pair in unique],
        })
        values = response.get("statuses")
        if not isinstance(values, list):
            raise RuntimeError("Apple Translation helper 缺少语言状态")
        return {
            LanguagePair(str(item["source"]), str(item["target"])): str(item["status"])
            for item in values
            if isinstance(item, dict)
        }

    def translate(self, texts: list[str], *, source: str, target: str = "en") -> list[str]:
        if not texts:
            return []
        response = self._run({
            "operation": "translate", "source": source, "target": target, "texts": texts,
        })
        translations = response.get("translations")
        if not isinstance(translations, list) or len(translations) != len(texts):
            raise RuntimeError("Apple Translation helper 返回了无效翻译结果")
        return [str(value) for value in translations]


def ensure_pivot_embeddings(
    db: Database,
    files: list[IndexedFile],
    encoder: NativeMacOSEncoder,
    translator: TranslationBackend,
    *,
    target: str = "en",
) -> list[str]:
    """Populate missing English pivots for selected candidate files only.

    Returns human-readable degradation messages instead of failing proposal
    generation when a language asset is absent or translation is unavailable.
    """
    pending = [
        file for file in files
        if file.text and file.vector_space and not file.pivot_vector
    ]
    if not pending:
        return []

    messages: list[str] = []
    translated: dict[int, tuple[str, str]] = {}
    fresh: list[IndexedFile] = []
    for file in pending:
        cached = db.conn.execute(
            """SELECT source_language,translated_text,translation_version
            FROM semantic_pivots WHERE file_id=? AND fingerprint=? AND target_language=?""",
            (file.id, file.fingerprint, target),
        ).fetchone()
        if cached and cached["source_language"] == file.vector_space:
            translated[file.id] = (cached["translated_text"], cached["translation_version"])
        else:
            fresh.append(file)

    statuses: dict[LanguagePair, str] = {}
    pairs = [LanguagePair(file.vector_space, target) for file in fresh if file.vector_space != target]
    try:
        statuses = translator.statuses(pairs)
    except RuntimeError as exc:
        messages.append(str(exc))

    for file in fresh:
        semantic_text = build_semantic_text(file)
        source = file.vector_space or ""
        if source == target:
            translated[file.id] = (semantic_text, "identity:1")
            continue
        pair = LanguagePair(source, target)
        state = statuses.get(pair, "unsupported")
        if state != "installed":
            label = "未安装" if state == "supported" else "不可用"
            messages.append(f"{source} → {target} 翻译{label}")
            continue
        try:
            value = translator.translate([semantic_text], source=source, target=target)[0]
            translated[file.id] = (value, translator.version)
        except RuntimeError as exc:
            messages.append(f"{source} → {target} 翻译失败：{exc}")

    if not translated:
        return list(dict.fromkeys(messages))

    selected = [file for file in pending if file.id in translated]
    try:
        encoded = encoder.encode_in_language([translated[file.id][0] for file in selected], target)
    except RuntimeError as exc:
        messages.append(f"English pivot 编码失败：{exc}")
        return list(dict.fromkeys(messages))
    for file, result in zip(selected, encoded):
        translated_text, translation_version = translated[file.id]
        file.pivot_vector = result.vector
        file.pivot_space = result.space
        file.pivot_source_language = file.vector_space
        file.pivot_embedding_version = encoder.version
        db.conn.execute(
            """INSERT INTO semantic_pivots(
            file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
            translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(file_id,target_language) DO UPDATE SET
            fingerprint=excluded.fingerprint,source_language=excluded.source_language,
            semantic_text=excluded.semantic_text,translated_text=excluded.translated_text,
            translation_version=excluded.translation_version,pivot_embedding=excluded.pivot_embedding,
            pivot_embedding_space=excluded.pivot_embedding_space,
            embedding_version=excluded.embedding_version,created_at=excluded.created_at""",
            (
                file.id, file.fingerprint, file.vector_space, target,
                build_semantic_text(file), translated_text, translation_version,
                json.dumps(result.vector).encode("utf-8") if result.vector is not None else None,
                result.space, encoder.version, time.time(),
            ),
        )
    db.conn.commit()
    return list(dict.fromkeys(messages))


def translation_status(settings: Settings, languages: tuple[str, ...] = ("zh-Hans", "ja", "ko")) -> dict[str, object]:
    try:
        backend = NativeTranslationBackend(settings)
        states = backend.statuses([LanguagePair(language) for language in languages])
        return {
            "backend": "apple-translation",
            "prepared": backend.is_prepared(),
            "download_required": False,
            "pairs": {
                f"{language} -> en": states.get(LanguagePair(language), "unsupported")
                for language in languages
            },
        }
    except RuntimeError as exc:
        return {
            "backend": "apple-translation",
            "prepared": False,
            "download_required": False,
            "pairs": {f"{language} -> en": "unavailable" for language in languages},
            "error": str(exc),
        }
