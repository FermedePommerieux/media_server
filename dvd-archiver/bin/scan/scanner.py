#!/usr/bin/env python3
"""Orchestrateur de la phase 2 (scan + OCR + IA) du pipeline DVD."""
from __future__ import annotations

import json
import logging
import os
import shlex
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import ai_analyzer  # noqa: E402
import heuristics  # noqa: E402
import ocr  # noqa: E402
import techparse  # noqa: E402
import writers  # noqa: E402


CONFIG_FILE = Path("/etc/dvdarchiver.conf")


def load_env_from_conf(path: Path = CONFIG_FILE) -> None:
    """Charge les variables du fichier de configuration dans l'environnement."""

    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key.startswith("#"):
            continue
        if key in os.environ:
            continue
        value = value.strip()
        if value:
            try:
                parts = shlex.split(value, posix=True)
            except ValueError:
                parts = [value.strip("\"\'")]
            if len(parts) == 0:
                final = ""
            elif len(parts) == 1:
                final = parts[0]
            else:
                final = " ".join(parts)
        else:
            final = ""
        os.environ.setdefault(key, final)


@dataclass
class Config:
    ffmpeg_bin: str = "ffmpeg"
    ffprobe_bin: str = "ffprobe"
    ocr_bin: str = "tesseract"
    ocr_langs: str = "eng+fra+spa+ita+deu"
    frame_rate_menu_fps: float = 1.0
    frame_max_menu: int = 30
    menu_vob_patterns: List[str] = field(default_factory=lambda: ["VIDEO_TS.VOB", "VTS_*_0.VOB"])
    struct_fallback_from_mkv: bool = True
    runtime_tolerance_sec: int = 120
    confidence_min: float = 0.5
    llm_enable: bool = True
    layout_version: str = "1.0"

    @classmethod
    def from_env(cls) -> "Config":
        patterns = os.environ.get("MENU_VOB_GLOB", "VIDEO_TS.VOB VTS_*_0.VOB").split()
        return cls(
            ffmpeg_bin=os.environ.get("FFMPEG_BIN", "ffmpeg"),
            ffprobe_bin=os.environ.get("FFPROBE_BIN", "ffprobe"),
            ocr_bin=os.environ.get("OCR_BIN", "tesseract"),
            ocr_langs=os.environ.get("OCR_LANGS", "eng+fra+spa+ita+deu"),
            frame_rate_menu_fps=float(os.environ.get("FRAME_RATE_MENU_FPS", "1")),
            frame_max_menu=int(os.environ.get("FRAME_MAX_MENU", "30")),
            menu_vob_patterns=patterns,
            struct_fallback_from_mkv=os.environ.get("STRUCT_FALLBACK_FROM_MKV", "1") == "1",
            runtime_tolerance_sec=int(os.environ.get("RUNTIME_TOLERANCE_SEC", "120")),
            confidence_min=float(os.environ.get("CONFIDENCE_MIN", "0.5")),
            llm_enable=os.environ.get("LLM_ENABLE", "1") == "1",
            layout_version=os.environ.get("ARCHIVE_LAYOUT_VERSION", "1.0"),
        )


class ScanError(Exception):
    """Erreur bloquante lors du scan."""


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


def load_fingerprint(disc_dir: Path) -> Dict[str, object]:
    fingerprint_path = disc_dir / "tech" / "fingerprint.json"
    if fingerprint_path.exists():
        try:
            return json.loads(fingerprint_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            logging.warning("Impossible de lire fingerprint.json: %s", exc)
    return {}


def list_menu_vobs(raw_dir: Path, config: Config) -> List[Path]:
    matches: List[Path] = []
    for pattern in config.menu_vob_patterns:
        matches.extend(sorted(raw_dir.glob(pattern)))
    return matches


def main() -> int:
    start_total = time.time()
    load_env_from_conf()
    setup_logging()
    config = Config.from_env()

    disc_dir_env = os.environ.get("DISC_DIR")
    if not disc_dir_env:
        logging.error("DISC_DIR non défini dans l'environnement")
        return 1

    disc_dir = Path(disc_dir_env).resolve()
    logging.info("Démarrage du scan pour %s", disc_dir)

    if not disc_dir.exists():
        logging.error("Le répertoire disque %s est introuvable", disc_dir)
        return 1

    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    if metadata_path.exists():
        logging.info("metadata_ia.json déjà présent, arrêt (idempotent)")
        return 0

    (disc_dir / "meta").mkdir(parents=True, exist_ok=True)

    structure_path = disc_dir / "tech" / "structure.lsdvd.yml"
    structure: Dict[str, object] = {}
    if structure_path.exists():
        structure = techparse.parse_lsdvd(structure_path)

    if not structure and config.struct_fallback_from_mkv:
        mkv_dir = disc_dir / "mkv"
        if mkv_dir.exists():
            logging.info("Structure vide, fallback mkvmerge")
            structure = techparse.probe_mkv_titles(mkv_dir)

    fingerprint = load_fingerprint(disc_dir)

    raw_dir = disc_dir / "raw"
    frame_paths: List[Path] = []
    if raw_dir.exists():
        vob_paths = list_menu_vobs(raw_dir, config)
        if vob_paths:
            frame_paths = ocr.extract_menu_frames(
                vob_paths=vob_paths,
                output_dir=disc_dir / "meta" / "ocr_frames",
                frame_rate=config.frame_rate_menu_fps,
                frame_max=config.frame_max_menu,
                ffmpeg_bin=config.ffmpeg_bin,
            )
        else:
            logging.info("Aucun VOB de menu détecté")
    else:
        logging.info("Répertoire raw/ absent, extraction des menus ignorée")

    ocr_results: List[Dict[str, object]] = []
    normalized_labels: Dict[str, object] = {"raw": [], "categories": {}, "language": "unknown"}
    if frame_paths:
        logging.info("OCR sur %d frames", len(frame_paths))
        try:
            ocr_results = ocr.ocr_frames(frame_paths, config.ocr_langs, bin_path=config.ocr_bin)
            normalized_labels = ocr.normalize_labels(ocr_results)
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Erreur OCR: %s", exc)
    else:
        logging.info("Aucune frame extraite, OCR ignoré")

    main_feature = heuristics.detect_main_feature(
        structure,
        runtime_tol=config.runtime_tolerance_sec,
    )
    mapping = heuristics.map_menu_labels_to_titles(
        normalized_labels=normalized_labels,
        structure=structure,
        runtime_tol=config.runtime_tolerance_sec,
        min_conf=config.confidence_min,
    )

    logging.info("Heuristique principale: %s", main_feature)

    ia_payload: Dict[str, object] | None = None
    if config.llm_enable:
        try:
            ia_payload = ai_analyzer.infer_structure(
                ocr_texts=ocr_results,
                normalized_labels=normalized_labels,
                struct=structure,
                fingerprint=fingerprint,
            )
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Erreur IA: %s", exc)
    else:
        logging.info("LLM désactivé, heuristiques uniquement")

    if not ia_payload:
        ia_payload = heuristics.fallback_payload(normalized_labels, structure, main_feature)

    try:
        writers.write_metadata_json(
            out_path=metadata_path,
            disc_uid=disc_dir.name,
            layout_version=config.layout_version,
            struct=structure,
            labels=normalized_labels,
            mapping=mapping,
            ia_payload=ia_payload,
            ocr_results=ocr_results,
            fingerprint=fingerprint,
            total_time=time.time() - start_total,
            llm_enabled=config.llm_enable,
        )
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Écriture de metadata_ia.json échouée: %s", exc)
        return 1

    logging.info("metadata_ia.json généré pour %s en %.2fs", disc_dir.name, time.time() - start_total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
