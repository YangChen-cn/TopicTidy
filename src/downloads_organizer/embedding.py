from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from importlib.resources import files as resource_files
from pathlib import Path
from typing import Protocol

from .config import Settings


@dataclass(frozen=True)
class EncodedVector:
    vector: list[float] | None
    space: str | None


class SemanticEncoder(Protocol):
    @property
    def version(self) -> str: ...

    def encode(self, texts: list[str]) -> list[EncodedVector]: ...

    def encode_in_language(self, texts: list[str], language: str) -> list[EncodedVector]: ...


def _source_path() -> Path:
    return Path(str(resource_files("downloads_organizer.native").joinpath("embedding.swift")))


class NativeMacOSEncoder:
    """Offline sentence embeddings backed by macOS NaturalLanguage."""

    def __init__(self, settings: Settings, *, prepare: bool = True):
        if sys.platform != "darwin":
            raise RuntimeError("原生语义 backend 仅支持 macOS")
        self.settings = settings
        self.source = _source_path()
        self.source_digest = hashlib.sha256(self.source.read_bytes()).hexdigest()
        if prepare:
            self.prepare()

    @property
    def version(self) -> str:
        release = platform.mac_ver()[0] or "unknown"
        return f"apple-nlembedding:{release}:{self.source_digest[:12]}"

    def is_prepared(self) -> bool:
        stamp = self.settings.native_helper_stamp
        return (
            self.settings.native_helper.is_file()
            and os.access(self.settings.native_helper, os.X_OK)
            and stamp.is_file()
            and stamp.read_text(encoding="utf-8").strip() == self.source_digest
        )

    def prepare(self) -> Path:
        if self.is_prepared():
            return self.settings.native_helper
        if not shutil.which("xcrun"):
            raise RuntimeError("未找到 xcrun；请安装 Xcode Command Line Tools")
        self.settings.native_helper.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.settings.native_helper.with_name(f"native-embedding.tmp-{os.getpid()}")
        command = [
            "xcrun", "swiftc", "-O", str(self.source),
            "-framework", "NaturalLanguage", "-o", str(temporary),
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=180)
            os.chmod(temporary, 0o755)
            os.replace(temporary, self.settings.native_helper)
            self.settings.native_helper_stamp.write_text(self.source_digest, encoding="utf-8")
        except (OSError, subprocess.SubprocessError) as exc:
            temporary.unlink(missing_ok=True)
            detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else str(exc)
            raise RuntimeError(f"无法构建 macOS 原生语义 helper：{detail}") from exc
        return self.settings.native_helper

    def _encode(self, texts: list[str], language: str | None = None) -> list[EncodedVector]:
        if not texts:
            return []
        request = json.dumps({"texts": texts, "language": language}, ensure_ascii=False).encode("utf-8")
        try:
            result = subprocess.run(
                [str(self.prepare())], input=request, check=True, capture_output=True, timeout=180,
            )
            payload = json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
            detail = ""
            if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
                detail = exc.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"macOS 原生语义编码失败：{detail or exc}") from exc
        vectors = payload.get("vectors")
        if not isinstance(vectors, list) or len(vectors) != len(texts):
            raise RuntimeError("macOS 原生语义 helper 返回了无效结果")
        languages = payload.get("languages")
        if not isinstance(languages, list) or len(languages) != len(texts):
            raise RuntimeError("macOS 原生语义 helper 缺少语言空间信息")
        return [EncodedVector(vector, language) for vector, language in zip(vectors, languages)]

    def encode(self, texts: list[str]) -> list[EncodedVector]:
        return self._encode(texts)

    def encode_in_language(self, texts: list[str], language: str) -> list[EncodedVector]:
        """Encode with one explicit NLEmbedding language space."""
        return self._encode(texts, language)


def native_status(
    settings: Settings,
    languages: tuple[str, ...] = ("en", "zh-Hans"),
    *,
    inspect_languages: bool = False,
) -> dict[str, object]:
    available = sys.platform == "darwin" and bool(shutil.which("xcrun"))
    encoder = NativeMacOSEncoder(settings, prepare=False) if available else None
    result: dict[str, object] = {
        "backend": "apple-nlembedding",
        "available": available,
        "prepared": encoder.is_prepared() if encoder else False,
        "helper": str(settings.native_helper),
        "download_required": False,
    }
    if inspect_languages and encoder:
        samples = {"en": "renewable energy systems", "zh-Hans": "可再生能源系统"}
        try:
            encoded = [
                encoder.encode_in_language([samples.get(language, language)], language)[0]
                for language in languages
            ]
            result["languages"] = {
                language: "available" if value.vector else "unavailable"
                for language, value in zip(languages, encoded)
            }
            result["prepared"] = encoder.is_prepared()
        except RuntimeError as exc:
            result["languages"] = {language: "unavailable" for language in languages}
            result["error"] = str(exc)
    elif inspect_languages:
        result["languages"] = {language: "unavailable" for language in languages}
    return result
