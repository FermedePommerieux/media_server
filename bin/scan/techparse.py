"""Parsing des structures techniques (lsdvd, mkvmerge)."""
from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path
from typing import Dict, List

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore


def parse_lsdvd(path: Path) -> Dict[str, object]:
    if not path.exists():
        return {}
    try:
        data = path.read_text(encoding="utf-8")
    except OSError as exc:
        logging.warning("Lecture lsdvd échouée: %s", exc)
        return {}

    if yaml:
        try:
            loaded = yaml.safe_load(data)
        except yaml.YAMLError as exc:  # type: ignore[attr-defined]
            logging.warning("YAML invalide pour %s: %s", path, exc)
            return {}
        titles = []
        for title in loaded.get("track", []):
            runtime = title.get("length")
            if isinstance(runtime, str):
                try:
                    runtime = float(runtime)
                except ValueError:
                    parts = runtime.split(":")
                    if len(parts) == 3:
                        h, m, s = parts
                        runtime = int(h) * 3600 + int(m) * 60 + float(s)
                    else:
                        runtime = None
            titles.append(
                {
                    "index": title.get("ix"),
                    "runtime_s": runtime,
                    "chapters": len(title.get("chapter", [])),
                    "audio_langs": [a.get("langcode") for a in title.get("audio", []) if a],
                    "sub_langs": [s.get("langcode") for s in title.get("subpicture", []) if s],
                    "angles": len(title.get("angle", [])),
                }
            )
        return {"source": "lsdvd", "titles": titles}
    logging.warning("PyYAML absent, structure lsdvd ignorée")
    return {}


def probe_mkv_titles(mkv_dir: Path) -> Dict[str, object]:
    titles: List[Dict[str, object]] = []
    mkvmerge_bin = "mkvmerge"
    for mkv in sorted(mkv_dir.glob("*.mkv")):
        cmd = [mkvmerge_bin, "-J", str(mkv)]
        logging.debug("Probe mkvmerge: %s", " ".join(cmd))
        try:
            result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logging.warning("mkvmerge -J échoué pour %s: %s", mkv, exc)
            continue
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            logging.warning("JSON mkvmerge invalide pour %s: %s", mkv, exc)
            continue
        duration = payload.get("container", {}).get("properties", {}).get("duration")
        if isinstance(duration, str):
            try:
                duration = float(duration)
            except ValueError:
                duration = None
        tracks = payload.get("tracks", [])
        audio_langs = [t.get("properties", {}).get("language") for t in tracks if t.get("type") == "audio"]
        sub_langs = [t.get("properties", {}).get("language") for t in tracks if t.get("type") == "subtitles"]
        titles.append(
            {
                "index": len(titles) + 1,
                "runtime_s": duration,
                "chapters": payload.get("chapters", {}).get("count"),
                "audio_langs": [lang for lang in audio_langs if lang],
                "sub_langs": [lang for lang in sub_langs if lang],
                "angles": None,
                "filename": mkv.name,
            }
        )
    if not titles:
        return {}
    return {"source": "mkvmerge", "titles": titles}
