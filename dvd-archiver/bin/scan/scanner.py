#!/usr/bin/env python3
"""Orchestrateur Phase 2 : analyse MKV + heuristiques + IA."""
from __future__ import annotations

import json
import logging
import os
import shlex
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import mkvparse  # type: ignore  # noqa: E402
import heuristics  # type: ignore  # noqa: E402
import ai_analyzer  # type: ignore  # noqa: E402
import writers  # type: ignore  # noqa: E402

CONFIG_FILE = Path("/etc/dvdarchiver.conf")


def load_env_from_conf(path: Path = CONFIG_FILE) -> None:
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
                parts = [value.strip("\"'")]
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
    mkvmerge_bin: str = "mkvmerge"
    mediainfo_bin: str | None = "mediainfo"
    runtime_tolerance_sec: float = 120.0
    episode_group_min: int = 2
    main_feature_minutes: int = 60
    llm_enable: bool = True
    layout_version: str = "2.0"

    @classmethod
    def from_env(cls) -> "Config":
        mediainfo = os.environ.get("MEDIAINFO_BIN", "mediainfo") or None
        return cls(
            mkvmerge_bin=os.environ.get("MKVMERGE_BIN", "mkvmerge"),
            mediainfo_bin=mediainfo,
            runtime_tolerance_sec=float(os.environ.get("RUNTIME_TOLERANCE_SEC", "120")),
            episode_group_min=int(os.environ.get("EPISODE_GROUP_MIN", "2")),
            main_feature_minutes=int(os.environ.get("MAIN_FEATURE_MINUTES", "60")),
            llm_enable=os.environ.get("LLM_ENABLE", "1") == "1",
            layout_version=os.environ.get("ARCHIVE_LAYOUT_VERSION", "2.0"),
        )


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


def ensure_mkv_present(mkv_dir: Path) -> bool:
    return any(mkv_dir.glob("*.mkv"))


def main() -> int:
    start_time = time.time()
    load_env_from_conf()
    setup_logging()
    config = Config.from_env()

    disc_dir_env = os.environ.get("DISC_DIR")
    if not disc_dir_env:
        logging.error("DISC_DIR non défini dans l'environnement")
        return 1

    disc_dir = Path(disc_dir_env).resolve()
    logging.info("Analyse MKV pour %s", disc_dir)

    if not disc_dir.exists():
        logging.error("Répertoire disque introuvable: %s", disc_dir)
        return 1

    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    if metadata_path.exists():
        logging.info("metadata_ia.json déjà présent, arrêt (idempotent)")
        return 0

    mkv_dir = disc_dir / "mkv"
    if not mkv_dir.is_dir():
        logging.error("Répertoire MKV absent: %s", mkv_dir)
        return 1
    if not ensure_mkv_present(mkv_dir):
        logging.error("Aucun fichier MKV détecté dans %s", mkv_dir)
        return 1

    fingerprint = load_fingerprint(disc_dir)

    try:
        mkv_struct = mkvparse.collect(mkv_dir, config.mkvmerge_bin, config.mediainfo_bin)
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Collecte MKV impossible: %s", exc)
        return 1

    files = mkv_struct.get("files", []) if isinstance(mkv_struct, dict) else []
    if not files:
        logging.error("Aucun fichier MKV interprétable dans %s", mkv_dir)
        return 1

    heur_cfg = heuristics.HeuristicConfig(
        runtime_tolerance_sec=config.runtime_tolerance_sec,
        episode_group_min=config.episode_group_min,
        main_feature_minutes=config.main_feature_minutes,
    )
    hints = heuristics.hints_for(files, heur_cfg)
    fallback = heuristics.fallback_payload(files, hints)

    ai_result = ai_analyzer.infer_from_mkv(mkv_struct, fingerprint, hints, config.llm_enable)
    if ai_result.parsed is None:
        logging.warning("Résultat IA indisponible, utilisation des heuristiques")

    try:
        writers.write_metadata_json(
            out_path=metadata_path,
            disc_uid=disc_dir.name,
            layout_version=config.layout_version,
            mkv_struct=mkv_struct,
            fingerprint=fingerprint,
            hints=hints,
            ai_inference=ai_result,
            fallback_payload=fallback,
            llm_enabled=config.llm_enable,
            total_time=time.time() - start_time,
        )
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Écriture de metadata_ia.json échouée: %s", exc)
        return 1

    logging.info("metadata_ia.json généré pour %s en %.2fs", disc_dir.name, time.time() - start_time)
    return 0


if __name__ == "__main__":
    sys.exit(main())

