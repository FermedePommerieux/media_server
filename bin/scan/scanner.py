#!/usr/bin/env python3
"""Orchestrateur OCR + LLM pour la phase 2 du DVD Archiver."""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import ai_analyzer  # type: ignore  # noqa: E402
import heuristics  # type: ignore  # noqa: E402
import ocr  # type: ignore  # noqa: E402
import techparse  # type: ignore  # noqa: E402
import writers  # type: ignore  # noqa: E402


@dataclass
class Config:
    ffmpeg_bin: str = "ffmpeg"
    ffprobe_bin: str = "ffprobe"
    tesseract_bin: str = "tesseract"
    ocr_langs: str = "eng+fra+spa+ita+deu"
    menu_frame_fps: float = 1.0
    menu_max_frames: int = 30
    menu_scene_mode: int = 1
    menu_scene_threshold: float = 0.4
    menu_preproc_filters: str = "yadif,eq=contrast=1.1:brightness=0.02"
    menu_vob_glob: str = "VIDEO_TS.VOB VTS_*_0.VOB"
    llm_enable: bool = True
    archive_layout_version: str = "1.0"

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            ffmpeg_bin=os.environ.get("FFMPEG_BIN", cls.ffmpeg_bin),
            ffprobe_bin=os.environ.get("FFPROBE_BIN", "ffprobe"),
            tesseract_bin=os.environ.get("TESSERACT_BIN", cls.tesseract_bin),
            ocr_langs=os.environ.get("OCR_LANGS", cls.ocr_langs),
            menu_frame_fps=float(os.environ.get("MENU_FRAME_FPS", str(cls.menu_frame_fps))),
            menu_max_frames=int(os.environ.get("MENU_MAX_FRAMES", str(cls.menu_max_frames))),
            menu_scene_mode=int(os.environ.get("MENU_SCENE_MODE", str(cls.menu_scene_mode))),
            menu_scene_threshold=float(
                os.environ.get("MENU_SCENE_THRESHOLD", str(cls.menu_scene_threshold))
            ),
            menu_preproc_filters=os.environ.get(
                "MENU_PREPROC_FILTERS", cls.menu_preproc_filters
            ),
            menu_vob_glob=os.environ.get("MENU_VOB_GLOB", cls.menu_vob_glob),
            llm_enable=os.environ.get("LLM_ENABLE", "1") == "1",
            archive_layout_version=os.environ.get("ARCHIVE_LAYOUT_VERSION", cls.archive_layout_version),
        )


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


def load_fingerprint(disc_dir: Path) -> Dict[str, Any]:
    fingerprint_path = disc_dir / "tech" / "fingerprint.json"
    if not fingerprint_path.exists():
        return {}
    try:
        return json.loads(fingerprint_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        logging.warning("fingerprint.json illisible: %s", exc)
        return {}


def _probe_with_ffprobe(mkv_dir: Path, ffprobe_bin: str) -> Dict[str, Any]:
    if not shutil.which(ffprobe_bin):
        return {}
    titles: List[Dict[str, Any]] = []
    for index, mkv in enumerate(sorted(mkv_dir.glob("*.mkv")), start=1):
        cmd = [
            ffprobe_bin,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_entries",
            "format=duration:stream=index,codec_type:tags=language",
            str(mkv),
        ]
        try:
            proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logging.warning("ffprobe a échoué pour %s: %s", mkv, exc)
            continue
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            logging.warning("ffprobe JSON invalide pour %s: %s", mkv, exc)
            continue
        duration = payload.get("format", {}).get("duration")
        try:
            duration_value = float(duration) if duration is not None else None
        except (TypeError, ValueError):
            duration_value = None
        audio_langs = []
        sub_langs = []
        for stream in payload.get("streams", []):
            lang = stream.get("tags", {}).get("language")
            if stream.get("codec_type") == "audio" and lang:
                audio_langs.append(lang)
            if stream.get("codec_type") == "subtitle" and lang:
                sub_langs.append(lang)
        titles.append(
            {
                "index": index,
                "filename": mkv.name,
                "runtime_s": duration_value,
                "audio_langs": audio_langs,
                "sub_langs": sub_langs,
            }
        )
    if not titles:
        return {}
    return {"source": "ffprobe", "titles": titles}


def _merge_structures(lsdvd_data: Dict[str, Any], mkv_data: Dict[str, Any]) -> Dict[str, Any]:
    if not lsdvd_data and not mkv_data:
        return {"titles": []}
    if not lsdvd_data:
        return mkv_data
    titles = list(lsdvd_data.get("titles", []))
    if mkv_data:
        mkv_lookup = {entry.get("index"): entry for entry in mkv_data.get("titles", [])}
        for title in titles:
            idx = title.get("index")
            match = mkv_lookup.get(idx)
            if not match:
                continue
            for key in ("filename", "audio_langs", "sub_langs", "title"):
                if match.get(key) and not title.get(key):
                    title[key] = match.get(key)
            if not title.get("runtime_s") and match.get("runtime_s"):
                title["runtime_s"] = match.get("runtime_s")
    return {"source": lsdvd_data.get("source", "lsdvd"), "titles": titles}


def load_mkv_structure(disc_dir: Path, cfg: Config) -> Dict[str, Any]:
    mkv_dir = disc_dir / "mkv"
    lsdvd_path = disc_dir / "tech" / "structure.lsdvd.yml"

    lsdvd_data = techparse.parse_lsdvd(lsdvd_path)
    mkv_data = techparse.probe_mkv_titles(mkv_dir)
    if not mkv_data:
        ffprobe_data = _probe_with_ffprobe(mkv_dir, cfg.ffprobe_bin)
        if ffprobe_data:
            logging.info("Fallback ffprobe pour l'analyse MKV")
            mkv_data = ffprobe_data
    if not lsdvd_data:
        return mkv_data or {"titles": []}
    return _merge_structures(lsdvd_data, mkv_data)


def collect_menus(disc_dir: Path, cfg: Config) -> Dict[str, Any]:
    backup_root = disc_dir / "raw" / "VIDEO_TS_BACKUP"
    frames_dir = disc_dir / "meta" / "menu_frames"
    ocr_cfg = {
        "frames_dir": frames_dir,
        "ffmpeg_bin": cfg.ffmpeg_bin,
        "tesseract_bin": cfg.tesseract_bin,
        "ocr_langs": cfg.ocr_langs,
        "menu_frame_fps": cfg.menu_frame_fps,
        "menu_max_frames": cfg.menu_max_frames,
        "menu_scene_mode": cfg.menu_scene_mode,
        "menu_scene_threshold": cfg.menu_scene_threshold,
        "menu_preproc_filters": cfg.menu_preproc_filters,
        "menu_vob_glob": cfg.menu_vob_glob,
    }
    items = ocr.collect_menu_texts(backup_root, ocr_cfg)
    normalized = heuristics.normalize_labels_from_texts(items) if items else {"raw_labels": [], "language": "unknown"}
    return {
        "items": items,
        "normalized": normalized,
        "menus_dir": str(backup_root / "VIDEO_TS") if (backup_root / "VIDEO_TS").exists() else None,
        "frames_dir": str(frames_dir),
        "tools": {"ffmpeg": cfg.ffmpeg_bin, "tesseract": cfg.tesseract_bin},
    }


def main() -> int:
    setup_logging()
    cfg = Config.from_env()

    disc_dir_env = os.environ.get("DISC_DIR")
    if not disc_dir_env:
        logging.error("DISC_DIR non défini dans l'environnement")
        return 1

    disc_dir = Path(disc_dir_env).resolve()
    logging.info("Analyse OCR/IA pour %s", disc_dir)

    if not disc_dir.exists():
        logging.error("Répertoire disque introuvable: %s", disc_dir)
        return 1

    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    if metadata_path.exists():
        logging.info("metadata_ia.json déjà présent, idempotence respectée")
        return 0

    start = time.time()

    mkv_struct = load_mkv_structure(disc_dir, cfg)
    fingerprint = load_fingerprint(disc_dir)

    menus = collect_menus(disc_dir, cfg)
    menus["fingerprint"] = fingerprint

    ia_result = ai_analyzer.infer_structure_from_menus(
        ocr_summary=menus,
        mkv_struct=mkv_struct,
        fingerprint=fingerprint,
        cfg={"llm_enable": cfg.llm_enable},
    )

    disc_uid = disc_dir.name
    try:
        writers.write_metadata_json(
            out_path=metadata_path,
            disc_uid=disc_uid,
            ocr_summary=menus,
            mkv_struct=mkv_struct,
            ia_result=ia_result,
            layout_ver=cfg.archive_layout_version,
        )
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Impossible d'écrire metadata_ia.json: %s", exc)
        return 1

    elapsed = time.time() - start
    logging.info(
        "metadata_ia.json généré (%d entrées OCR, modèle %s, %.2fs)",
        len(menus.get("items", [])),
        ia_result.get("model"),
        elapsed,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

