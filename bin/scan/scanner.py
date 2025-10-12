#!/usr/bin/env python3
"""Orchestrateur de la phase 2 (scan + OCR + IA) du pipeline DVD."""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List

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
    """Configuration lue depuis l'environnement."""

    ffmpeg_bin: str = "ffmpeg"
    ffprobe_bin: str = "ffprobe"
    ocr_bin: str = "tesseract"
    ocr_langs: str = "eng"
    frame_rate_menu_fps: float = 1.0
    frame_max_menu: int = 30
    menu_vob_patterns: List[str] = field(default_factory=list)
    struct_fallback_from_mkv: bool = True
    runtime_tolerance_sec: int = 120
    confidence_min: float = 0.5
    llm_enable: bool = True
    archive_layout_version: str = "1.0"

    @classmethod
    def from_env(cls) -> "Config":
        patterns = os.environ.get("MENU_VOB_GLOB", "VIDEO_TS.VOB VTS_*_0.VOB").split()
        return cls(
            ffmpeg_bin=os.environ.get("FFMPEG_BIN", "ffmpeg"),
            ffprobe_bin=os.environ.get("FFPROBE_BIN", "ffprobe"),
            ocr_bin=os.environ.get("OCR_BIN", "tesseract"),
            ocr_langs=os.environ.get("OCR_LANGS", "eng+fra"),
            frame_rate_menu_fps=float(os.environ.get("FRAME_RATE_MENU_FPS", "1")),
            frame_max_menu=int(os.environ.get("FRAME_MAX_MENU", "30")),
            menu_vob_patterns=patterns,
            struct_fallback_from_mkv=os.environ.get("STRUCT_FALLBACK_FROM_MKV", "1") == "1",
            runtime_tolerance_sec=int(os.environ.get("RUNTIME_TOLERANCE_SEC", "120")),
            confidence_min=float(os.environ.get("CONFIDENCE_MIN", "0.5")),
            llm_enable=os.environ.get("LLM_ENABLE", "1") == "1",
            archive_layout_version=os.environ.get("ARCHIVE_LAYOUT_VERSION", "1.0"),
        )


class ScanError(Exception):
    """Erreur bloquante lors du scan."""


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


def ensure_tool(name: str) -> bool:
    return shutil.which(name) is not None


def extract_menu_frames(
    vob_paths: Iterable[Path],
    output_dir: Path,
    config: Config,
) -> List[Path]:
    """Extrait des frames de menus depuis des fichiers VOB avec ffmpeg."""

    extracted: List[Path] = []
    if not ensure_tool(config.ffmpeg_bin):
        logging.warning("ffmpeg (%s) introuvable, extraction des menus ignorée", config.ffmpeg_bin)
        return extracted

    output_dir.mkdir(parents=True, exist_ok=True)

    for vob in vob_paths:
        if not vob.exists():
            continue
        stem = vob.stem.replace(" ", "_")
        target_pattern = output_dir / f"{stem}_%03d.png"
        for existing in output_dir.glob(f"{stem}_*.png"):
            try:
                existing.unlink()
            except OSError:
                logging.debug("Impossible de supprimer %s", existing)
        cmd = [
            config.ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(vob),
            "-vf",
            f"fps={config.frame_rate_menu_fps}",
            "-frames:v",
            str(config.frame_max_menu),
            str(target_pattern),
        ]
        logging.info("Extraction des menus via ffmpeg: %s", " ".join(cmd))
        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as exc:
            logging.warning("Extraction ffmpeg échouée pour %s: %s", vob, exc)
            continue

        for frame_path in sorted(output_dir.glob(f"{stem}_*.png")):
            extracted.append(frame_path)

    return extracted


def list_menu_vobs(raw_dir: Path, config: Config) -> List[Path]:
    matches: List[Path] = []
    for pattern in config.menu_vob_patterns:
        matches.extend(sorted(raw_dir.glob(pattern)))
    return matches


def load_fingerprint(disc_dir: Path) -> Dict[str, object]:
    fingerprint_path = disc_dir / "tech" / "fingerprint.json"
    if fingerprint_path.exists():
        try:
            return json.loads(fingerprint_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            logging.warning("Impossible de lire fingerprint.json: %s", exc)
    return {}


def gather_menu_frames(disc_dir: Path, config: Config) -> List[Path]:
    raw_dir = disc_dir / "raw"
    if not raw_dir.exists():
        logging.info("Répertoire raw/ absent, OCR des menus ignoré")
        return []

    vobs = list_menu_vobs(raw_dir, config)
    if not vobs:
        logging.info("Aucun VOB de menu détecté dans %s", raw_dir)
        return []

    frames_dir = disc_dir / "meta" / "ocr_frames"
    return extract_menu_frames(vobs, frames_dir, config)


def main() -> int:
    setup_logging()
    config = Config.from_env()

    disc_dir_env = os.environ.get("DISC_DIR")
    if not disc_dir_env:
        logging.error("DISC_DIR non défini dans l'environnement")
        return 1

    disc_dir = Path(disc_dir_env).resolve()
    logging.info("Démarrage scan pour %s", disc_dir)

    if not disc_dir.exists():
        logging.error("Le répertoire disque %s est introuvable", disc_dir)
        return 1

    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    if metadata_path.exists():
        logging.info("metadata_ia.json déjà présent, rien à faire")
        return 0

    (disc_dir / "meta").mkdir(parents=True, exist_ok=True)

    structure_path = disc_dir / "tech" / "structure.lsdvd.yml"
    structure = {}
    if structure_path.exists():
        structure = techparse.parse_lsdvd(structure_path)

    if not structure and config.struct_fallback_from_mkv:
        mkv_dir = disc_dir / "mkv"
        if mkv_dir.exists():
            logging.info("Structure vide, fallback mkvmerge")
            structure = techparse.probe_mkv_titles(mkv_dir)

    fingerprint = load_fingerprint(disc_dir)

    frame_paths = gather_menu_frames(disc_dir, config)
    ocr_results: List[Dict[str, object]] = []
    normalized_labels: Dict[str, object] = {}

    if frame_paths:
        logging.info("OCR sur %d frames", len(frame_paths))
        try:
            ocr_results = ocr.ocr_frames(frame_paths, config.ocr_langs, bin_path=config.ocr_bin)
            normalized_labels = ocr.normalize_labels(ocr_results)
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Erreur OCR: %s", exc)
            ocr_results = []
            normalized_labels = {"raw": [], "categories": {}, "language": "unknown"}
    else:
        logging.info("Aucune frame extraite, OCR ignoré")
        normalized_labels = {"raw": [], "categories": {}, "language": "unknown"}

    main_feature = heuristics.detect_main_feature(structure)
    mapping = heuristics.map_menu_labels_to_titles(
        normalized_labels,
        structure,
        runtime_tol=config.runtime_tolerance_sec,
        min_conf=config.confidence_min,
    )

    ia_payload = None
    start = time.time()
    try:
        ia_payload = ai_analyzer.infer_structure(
            ocr_texts=ocr_results,
            normalized_labels=normalized_labels,
            struct=structure,
            fingerprint=fingerprint,
            disc_dir=disc_dir,
            config={
                "llm_enable": config.llm_enable,
                "runtime_tol": config.runtime_tolerance_sec,
            },
        )
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Erreur IA: %s", exc)
        ia_payload = {"error": str(exc)}
    finally:
        duration = time.time() - start
        logging.info("Analyse IA terminée en %.2fs", duration)

    disc_uid = disc_dir.name

    try:
        writers.write_metadata_json(
            out_path=metadata_path,
            disc_uid=disc_uid,
            struct=structure,
            labels=normalized_labels,
            mapping=mapping,
            main_feature=main_feature,
            layout_ver=config.archive_layout_version,
            ia_payload=ia_payload,
            ocr_results=ocr_results,
            fingerprint=fingerprint,
        )
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Écriture metadata échouée: %s", exc)
        return 1

    logging.info("metadata_ia.json généré pour %s", disc_uid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
