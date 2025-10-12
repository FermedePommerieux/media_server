"""Extraction des métadonnées techniques depuis des fichiers MKV."""
from __future__ import annotations

import json
import logging
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


@dataclass
class ProbeResult:
    files: List[Dict[str, object]]
    tool: str
    tool_version: Optional[str]
    errors: List[str]

    def as_dict(self) -> Dict[str, object]:
        return {
            "files": self.files,
            "tool": self.tool,
            "tool_version": self.tool_version,
            "errors": self.errors,
        }


ISO639_MAPPING = {
    "fre": "fra",
    "ger": "deu",
    "gre": "ell",
    "alb": "sqi",
    "chi": "zho",
    "cze": "ces",
    "dut": "nld",
    "rum": "ron",
    "scc": "srp",
    "slo": "slk",
    "wel": "cym",
}


def _normalise_lang(code: Optional[str]) -> Optional[str]:
    if not code:
        return None
    code = code.strip().lower()
    if len(code) == 2:
        return code
    return ISO639_MAPPING.get(code, code)


def _run_command(cmd: List[str]) -> subprocess.CompletedProcess[str]:
    logging.debug("Commande: %s", " ".join(cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True)


def _detect_version(binary: str, version_flag: str = "--version") -> Optional[str]:
    try:
        result = subprocess.run([binary, version_flag], check=True, capture_output=True, text=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    return result.stdout.splitlines()[0].strip() if result.stdout else None


def _collect_with_mkvmerge(mkv_dir: Path, binary: str) -> ProbeResult:
    files: List[Dict[str, object]] = []
    errors: List[str] = []
    for mkv_path in sorted(mkv_dir.glob("*.mkv")):
        cmd = [binary, "-J", str(mkv_path)]
        try:
            result = _run_command(cmd)
            data = json.loads(result.stdout)
        except FileNotFoundError as exc:
            raise RuntimeError(f"binaire mkvmerge introuvable: {binary}") from exc
        except subprocess.CalledProcessError as exc:
            errors.append(f"mkvmerge échec ({mkv_path.name}): {exc}")
            continue
        except json.JSONDecodeError as exc:
            errors.append(f"mkvmerge JSON invalide ({mkv_path.name}): {exc}")
            continue

        container = data.get("container", {}).get("properties", {})
        duration_ns = container.get("duration")
        duration_s = float(duration_ns) / 1e9 if duration_ns else 0.0
        track_titles = []
        audio_langs: List[str] = []
        sub_langs: List[str] = []
        for track in data.get("tracks", []):
            properties = track.get("properties", {})
            track_name = properties.get("track_name")
            if track_name:
                track_titles.append(str(track_name))
            lang = _normalise_lang(properties.get("language"))
            if track.get("type") == "audio" and lang:
                audio_langs.append(lang)
            if track.get("type") == "subtitles" and lang:
                sub_langs.append(lang)

        files.append(
            {
                "file": mkv_path.name,
                "path": str(mkv_path),
                "duration_s": round(duration_s, 3),
                "audio_langs": sorted({code for code in audio_langs}),
                "sub_langs": sorted({code for code in sub_langs}),
                "container_title": container.get("title"),
                "track_titles": track_titles,
                "size_bytes": mkv_path.stat().st_size,
            }
        )

    version = _detect_version(binary)
    files.sort(key=lambda entry: entry.get("duration_s", 0.0), reverse=True)
    return ProbeResult(files=files, tool=binary, tool_version=version, errors=errors)


def _collect_with_mediainfo(mkv_dir: Path, binary: str) -> ProbeResult:
    if not shutil.which(binary):
        raise RuntimeError("mediainfo non disponible")
    files: List[Dict[str, object]] = []
    errors: List[str] = []
    for mkv_path in sorted(mkv_dir.glob("*.mkv")):
        cmd = [binary, "--Output=JSON", str(mkv_path)]
        try:
            result = _run_command(cmd)
            data = json.loads(result.stdout)
        except subprocess.CalledProcessError as exc:
            errors.append(f"mediainfo échec ({mkv_path.name}): {exc}")
            continue
        except json.JSONDecodeError as exc:
            errors.append(f"mediainfo JSON invalide ({mkv_path.name}): {exc}")
            continue

        media = (data.get("media", {}) if isinstance(data, dict) else {}).get("track", [])
        general = next((track for track in media if track.get("@type") == "General"), {})
        duration_ms = general.get("Duration")
        try:
            duration_s = float(duration_ms) / 1000.0 if duration_ms else 0.0
        except (TypeError, ValueError):
            duration_s = 0.0

        audio_langs: List[str] = []
        sub_langs: List[str] = []
        track_titles: List[str] = []
        for track in media:
            ttype = track.get("@type")
            lang = _normalise_lang(track.get("Language"))
            track_name = track.get("Title") or track.get("Track")
            if track_name:
                track_titles.append(str(track_name))
            if ttype == "Audio" and lang:
                audio_langs.append(lang)
            if ttype == "Text" and lang:
                sub_langs.append(lang)

        files.append(
            {
                "file": mkv_path.name,
                "path": str(mkv_path),
                "duration_s": round(duration_s, 3),
                "audio_langs": sorted({code for code in audio_langs}),
                "sub_langs": sorted({code for code in sub_langs}),
                "container_title": general.get("Title"),
                "track_titles": track_titles,
                "size_bytes": mkv_path.stat().st_size,
            }
        )

    version = _detect_version(binary, "--Version")
    files.sort(key=lambda entry: entry.get("duration_s", 0.0), reverse=True)
    return ProbeResult(files=files, tool=binary, tool_version=version, errors=errors)


def collect(mkv_dir: Path, mkvmerge_bin: str = "mkvmerge", mediainfo_bin: Optional[str] = "mediainfo") -> Dict[str, object]:
    """Collecte les métadonnées de tous les MKV présents dans mkv_dir."""

    if not mkv_dir.exists():
        raise FileNotFoundError(f"Répertoire introuvable: {mkv_dir}")

    if shutil.which(mkvmerge_bin):
        logging.info("Extraction des métadonnées via %s", mkvmerge_bin)
        result = _collect_with_mkvmerge(mkv_dir, mkvmerge_bin)
        if result.files:
            return result.as_dict()
        logging.warning("mkvmerge n'a renvoyé aucun fichier, bascule sur mediainfo si disponible")
    else:
        logging.warning("mkvmerge (%s) indisponible", mkvmerge_bin)

    if mediainfo_bin:
        try:
            logging.info("Extraction des métadonnées via %s", mediainfo_bin)
            result = _collect_with_mediainfo(mkv_dir, mediainfo_bin)
            return result.as_dict()
        except RuntimeError as exc:
            logging.error("mediainfo inutilisable: %s", exc)
    raise RuntimeError("Impossible de collecter les métadonnées MKV")

