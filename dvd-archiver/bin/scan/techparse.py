"""Parsing technique des disques."""
from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path
from typing import Dict, List

try:
    import yaml
except ImportError:  # pragma: no cover - dépendance optionnelle
    yaml = None  # type: ignore


def _parse_runtime(value: object) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        parts = value.strip().split(":")
        try:
            parts = [float(p) for p in parts]
        except ValueError:
            return 0.0
        if len(parts) == 3:
            hours, minutes, seconds = parts
            return hours * 3600 + minutes * 60 + seconds
        if len(parts) == 2:
            minutes, seconds = parts
            return minutes * 60 + seconds
        if len(parts) == 1:
            return parts[0]
    return 0.0


def parse_lsdvd(path: Path) -> Dict[str, object]:
    if not path.exists():
        logging.debug("structure.lsdvd.yml absent: %s", path)
        return {}
    if yaml is None:
        logging.warning("PyYAML non disponible, impossible de parser %s", path)
        return {}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception as exc:  # pylint: disable=broad-except
        logging.warning("Lecture YAML échouée pour %s: %s", path, exc)
        return {}

    titles_raw = data.get("title", [])
    titles: List[Dict[str, object]] = []
    for idx, title in enumerate(titles_raw):
        runtime = _parse_runtime(title.get("length"))
        chapters = len(title.get("chapter", []))
        audio_langs = [track.get("langcode") for track in title.get("audio", []) if track.get("langcode")]
        sub_langs = [track.get("langcode") for track in title.get("subp", []) if track.get("langcode")]
        angles = len(title.get("angles", [])) if isinstance(title.get("angles"), list) else 0
        titles.append(
            {
                "index": title.get("ix", idx + 1),
                "runtime_s": runtime,
                "chapters": chapters,
                "audio_langs": audio_langs,
                "sub_langs": sub_langs,
                "angles": angles,
            }
        )
    return {"source": "lsdvd", "titles": titles}


def _run_mkvmerge_json(target: Path, mkvmerge_bin: str = "mkvmerge") -> Dict[str, object]:
    cmd = [mkvmerge_bin, "-J", str(target)]
    logging.info("Analyse mkvmerge: %s", " ".join(cmd))
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        logging.warning("mkvmerge échoué pour %s: %s", target, exc)
        return {}


def probe_backup_titles(backup_dir: Path, mkvmerge_bin: str = "mkvmerge") -> Dict[str, object]:
    """Analyse les VOB du backup pour récupérer durées et langues."""

    video_ts = backup_dir / "VIDEO_TS"
    if not video_ts.exists():
        logging.debug("Répertoire VIDEO_TS introuvable: %s", video_ts)
        return {}

    titles: List[Dict[str, object]] = []
    for vob in sorted(video_ts.glob("VTS_*_1.VOB")):
        parts = vob.stem.split("_")
        try:
            title_index = int(parts[1])
        except (IndexError, ValueError):
            continue
        data = _run_mkvmerge_json(vob, mkvmerge_bin=mkvmerge_bin)
        if not data:
            continue
        container = data.get("container", {}).get("properties", {})
        duration_ns = container.get("duration")
        runtime = float(duration_ns) / 1e9 if duration_ns else 0.0
        audio_langs = [
            track.get("properties", {}).get("language")
            for track in data.get("tracks", [])
            if track.get("type") == "audio"
        ]
        sub_langs = [
            track.get("properties", {}).get("language")
            for track in data.get("tracks", [])
            if track.get("type") == "subtitles"
        ]
        titles.append(
            {
                "index": title_index,
                "runtime_s": runtime,
                "chapters": len(container.get("chapters", [])),
                "audio_langs": [lang for lang in audio_langs if lang],
                "sub_langs": [lang for lang in sub_langs if lang],
                "angles": 0,
            }
        )
    if not titles:
        return {}
    return {"source": "mkvmerge", "titles": titles}

