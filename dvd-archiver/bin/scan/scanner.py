#!/usr/bin/env python3
"""Orchestrateur de la phase 2 (scan + OCR + IA) du pipeline DVD."""
from __future__ import annotations

import json
import logging
import os
import shlex
import sys
import time
from dataclasses import dataclass
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


class ScanError(Exception):
    """Erreur bloquante lors du scan."""


@dataclass
class Config:
    dest: Path
    raw_backup_rel: str
    ffmpeg_bin: str
    tesseract_bin: str
    ocr_langs: str
    menu_frame_fps: float
    menu_max_frames: int
    menu_scene_mode: int
    menu_scene_threshold: float
    menu_preproc_filters: str
    struct_fallback_from_mkv: bool
    mkvmerge_bin: str

    @classmethod
    def from_env(cls) -> "Config":
        dest = Path(os.environ.get("DEST", "/mnt/media_master"))
        raw_rel = os.environ.get("RAW_BACKUP_DIR", "raw/VIDEO_TS_BACKUP")
        return cls(
            dest=dest,
            raw_backup_rel=raw_rel,
            ffmpeg_bin=os.environ.get("FFMPEG_BIN", "ffmpeg"),
            tesseract_bin=os.environ.get("TESSERACT_BIN", os.environ.get("OCR_BIN", "tesseract")),
            ocr_langs=os.environ.get("OCR_LANGS", "eng+fra+spa+ita+deu"),
            menu_frame_fps=float(os.environ.get("MENU_FRAME_FPS", os.environ.get("FRAME_RATE_MENU_FPS", "1"))),
            menu_max_frames=int(os.environ.get("MENU_MAX_FRAMES", os.environ.get("FRAME_MAX_MENU", "30"))),
            menu_scene_mode=int(os.environ.get("MENU_SCENE_MODE", "0")),
            menu_scene_threshold=float(os.environ.get("MENU_SCENE_THRESHOLD", "0.4")),
            menu_preproc_filters=os.environ.get("MENU_PREPROC_FILTERS", ""),
            struct_fallback_from_mkv=os.environ.get("STRUCT_FALLBACK_FROM_MKV", "1") == "1",
            mkvmerge_bin=os.environ.get("MKVMERGE_BIN", "mkvmerge"),
        )


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


def list_menu_vobs(raw_dir: Path) -> List[Path]:
    matches: List[Path] = []
    for pattern in ["VIDEO_TS.VOB", "VTS_*_0.VOB"]:
        matches.extend(sorted(raw_dir.glob(pattern)))
    return matches


def build_metadata(
    disc_uid: str,
    struct: Dict[str, object],
    labels: Dict[str, object],
    ai_payload: Dict[str, object] | None,
    ocr_results: List[Dict[str, object]],
    config: Config,
    structure_path: Path,
    ocr_dir: Path | None,
) -> Dict[str, object]:
    titles = heuristics.normalize_titles(struct)
    if not titles:
        raise ScanError("Structure technique vide, impossible de continuer")

    main_info = heuristics.detect_main_feature(struct)
    content_type_default = heuristics.guess_content_type(struct)
    content_type = content_type_default
    movie_title = None
    series_title = None
    year = None
    mapping_default = heuristics.default_mapping(titles, main_info.get("main_indexes", []))
    mapping = dict(mapping_default)
    items = heuristics.default_items(titles, content_type_default, main_info.get("main_indexes", []))
    confidence = 0.4
    language = heuristics.compute_language(labels.get("language", "unknown"), None)
    provider = "heuristics"
    model = None

    if ai_payload:
        content_type = ai_payload.get("content_type", content_type_default) or content_type_default
        movie_title = ai_payload.get("movie_title")
        series_title = ai_payload.get("series_title")
        year_value = ai_payload.get("year")
        if isinstance(year_value, str):
            try:
                year = int(year_value)
            except ValueError:
                year = None
        else:
            year = year_value if isinstance(year_value, int) else None
        mapping = heuristics.merge_mapping(mapping_default, ai_payload.get("mapping", {}))
        items = heuristics.merge_items(items, ai_payload.get("items", []))
        language = heuristics.compute_language(labels.get("language", "unknown"), ai_payload.get("language"))
        confidence = heuristics.compute_confidence(ai_payload.get("confidence"), fallback=0.4)
        provider = ai_payload.get("provider", "unknown")
        model = ai_payload.get("model")
    else:
        year = None

    runtime_by_index = {title.title_index: title.runtime_seconds for title in titles}
    audio_by_index = {title.title_index: title.audio_langs for title in titles}
    sub_by_index = {title.title_index: title.sub_langs for title in titles}
    for entry in items:
        try:
            idx = int(entry.get("title_index"))
        except (TypeError, ValueError):
            idx = 0
        entry.setdefault("runtime_seconds", runtime_by_index.get(idx, 0))
        entry.setdefault("audio_langs", list(audio_by_index.get(idx, [])))
        entry.setdefault("sub_langs", list(sub_by_index.get(idx, [])))

    items_sorted = sorted(items, key=lambda it: int(it.get("title_index", 0)))
    metadata = {
        "disc_uid": disc_uid,
        "content_type": content_type,
        "movie_title": movie_title,
        "series_title": series_title,
        "year": year if isinstance(year, int) else None,
        "language": language or "unknown",
        "items": items_sorted,
        "mapping": mapping,
        "confidence": confidence,
        "sources": {
            "ocr": str(ocr_dir) if ocr_dir else None,
            "tech_dump": str(structure_path),
            "llm": {"provider": provider, "model": model},
        },
    }
    return metadata


def validate_metadata(metadata: Dict[str, object], titles: List[heuristics.TitleInfo]) -> None:
    required_top = [
        "disc_uid",
        "content_type",
        "movie_title",
        "series_title",
        "year",
        "language",
        "items",
        "mapping",
        "confidence",
        "sources",
    ]
    for key in required_top:
        if key not in metadata:
            raise ScanError(f"Clé manquante dans metadata: {key}")

    content_type = metadata.get("content_type")
    if content_type not in {"film", "serie", "autre"}:
        raise ScanError("content_type invalide")

    items = metadata.get("items")
    if not isinstance(items, list) or not items:
        raise ScanError("items doit être une liste non vide")

    title_indexes = {title.title_index for title in titles}
    mapping = metadata.get("mapping") if isinstance(metadata.get("mapping"), dict) else {}
    covered_indexes = {int(key.split("_")[1]) for key in mapping if key.startswith("title_") and key.split("_")[1].isdigit()}

    main_indexes = {title.title_index for title in titles if any(it.get("title_index") == title.title_index and it.get("type") in {"main", "episode"} for it in items)}
    if not main_indexes:
        raise ScanError("Aucun item principal ou épisode identifié")

    for item in items:
        if not isinstance(item, dict):
            raise ScanError("Chaque item doit être un dictionnaire")
        try:
            title_index = int(item.get("title_index"))
        except (TypeError, ValueError):
            raise ScanError("title_index invalide") from None
        if title_index not in title_indexes:
            raise ScanError(f"title_index {title_index} inconnu")
        item.setdefault("runtime_seconds", 0)
        item.setdefault("audio_langs", [])
        item.setdefault("sub_langs", [])
        if not isinstance(item["audio_langs"], list) or not isinstance(item["sub_langs"], list):
            raise ScanError("audio_langs/sub_langs doivent être des listes")
        if item.get("type") not in {"main", "episode", "bonus", "trailer"}:
            raise ScanError("type d'item invalide")
        if item.get("type") == "episode":
            season = item.get("season")
            episode = item.get("episode")
            if season in {None, ""} or episode in {None, ""}:
                raise ScanError("Saison/épisode obligatoires pour un item épisode")
    if content_type == "film":
        if not metadata.get("movie_title") and float(metadata.get("confidence", 0.0)) < 0.7:
            raise ScanError("Titre film manquant et confiance insuffisante")
        main_idx = next(iter(main_indexes))
        if f"title_{main_idx}" not in mapping:
            raise ScanError("Mapping principal manquant pour le film")
    if content_type == "serie":
        if not metadata.get("series_title"):
            raise ScanError("Titre de série obligatoire")
        episodes = [item for item in items if item.get("type") == "episode"]
        if not episodes:
            raise ScanError("Aucun épisode détecté pour une série")
        for ep in episodes:
            season = int(ep.get("season")) if ep.get("season") is not None else None
            episode_num = int(ep.get("episode")) if ep.get("episode") is not None else None
            if not season or not episode_num:
                raise ScanError("Saison/épisode invalides")
            idx = int(ep["title_index"])
            if f"title_{idx}" not in mapping:
                raise ScanError(f"Mapping manquant pour l'épisode {idx}")
    if content_type == "autre":
        if not mapping:
            raise ScanError("Mapping requis pour le contenu 'autre'")
    if not covered_indexes.issuperset(main_indexes):
        raise ScanError("Mapping incomplet pour les titres principaux/épisodes")
    confidence = metadata.get("confidence")
    try:
        conf_value = float(confidence)
    except (TypeError, ValueError):
        raise ScanError("Confiance invalide") from None
    if not 0.0 <= conf_value <= 1.0:
        raise ScanError("Confiance hors bornes")


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

    raw_dir = (disc_dir / config.raw_backup_rel).resolve()
    menu_dir = raw_dir / "VIDEO_TS"
    if not menu_dir.exists():
        logging.error("Backup VIDEO_TS introuvable: %s", menu_dir)
        return 1

    tech_dir = disc_dir / "tech"
    if not tech_dir.exists():
        logging.error("Répertoire tech/ absent dans %s", disc_dir)
        return 1

    (disc_dir / "meta").mkdir(parents=True, exist_ok=True)

    structure_path = tech_dir / "structure.lsdvd.yml"
    structure: Dict[str, object] = {}
    if structure_path.exists():
        structure = techparse.parse_lsdvd(structure_path)

    if (not structure or not structure.get("titles")) and config.struct_fallback_from_mkv:
        logging.info("Structure vide, fallback mkvmerge depuis le backup")
        structure = techparse.probe_backup_titles(raw_dir, mkvmerge_bin=config.mkvmerge_bin)

    fingerprint = load_fingerprint(disc_dir)

    vob_paths = list_menu_vobs(menu_dir)
    ocr_results: List[Dict[str, object]] = []
    normalized_labels: Dict[str, object] = {"raw": [], "categories": {}, "language": "unknown"}
    frames_dir = disc_dir / "meta" / "menu_frames"
    frame_paths: List[Path] = []
    if vob_paths:
        logging.info("Extraction de frames sur %d fichiers VOB", len(vob_paths))
        frame_paths = ocr.extract_menu_frames(
            vob_paths=vob_paths,
            output_dir=frames_dir,
            frame_rate=config.menu_frame_fps,
            frame_max=config.menu_max_frames,
            ffmpeg_bin=config.ffmpeg_bin,
            scene_mode=config.menu_scene_mode,
            scene_threshold=config.menu_scene_threshold,
            preproc_filters=config.menu_preproc_filters,
        )
    else:
        logging.warning("Aucun menu VOB détecté")

    if frame_paths:
        logging.info("OCR sur %d frames", len(frame_paths))
        try:
            ocr_results = ocr.ocr_frames(frame_paths, config.ocr_langs, bin_path=config.tesseract_bin)
            normalized_labels = ocr.normalize_labels(ocr_results)
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Erreur OCR: %s", exc)
    else:
        logging.info("Aucune frame extraite, OCR ignoré")

    ai_payload: Dict[str, object] | None = None
    if os.environ.get("LLM_ENABLE", "1") == "1":
        try:
            ai_payload = ai_analyzer.infer_structure(
                ocr_texts=ocr_results,
                normalized_labels=normalized_labels,
                struct=structure,
                fingerprint=fingerprint,
            )
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Erreur IA: %s", exc)
    else:
        logging.info("LLM désactivé, heuristiques uniquement")

    metadata = build_metadata(
        disc_uid=disc_dir.name,
        struct=structure,
        labels=normalized_labels,
        ai_payload=ai_payload,
        ocr_results=ocr_results,
        config=config,
        structure_path=structure_path,
        ocr_dir=frames_dir if frame_paths else None,
    )

    titles = heuristics.normalize_titles(structure)
    try:
        validate_metadata(metadata, titles)
    except ScanError as exc:
        logging.error("Validation metadata échouée: %s", exc)
        return 1

    writers.write_metadata_json(metadata_path, metadata)
    logging.info("metadata_ia.json généré pour %s en %.2fs", disc_dir.name, time.time() - start_total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
