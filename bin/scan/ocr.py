"""Extraction de frames de menus DVD et OCR Tesseract."""
from __future__ import annotations

import csv
import io
import logging
import subprocess
from pathlib import Path
from typing import Dict, List, Sequence


def _build_filters(
    scene_mode: int,
    fps: float,
    scene_threshold: float,
    extra_filters: str,
) -> str:
    base_filters: List[str] = ["yadif"]
    extra = extra_filters.strip().strip(",")
    if scene_mode == 1:
        base_filters.append(f"select='gt(scene,{scene_threshold})'")
    else:
        base_filters.append(f"fps={fps}")
    if extra:
        base_filters.append(extra)
    return ",".join(filter(None, base_filters))


def extract_menu_frames(
    vob_path: str | Path,
    out_dir: str | Path,
    fps: float,
    max_frames: int,
    scene_mode: int,
    scene_threshold: float,
    filters: str,
    ffmpeg_bin: str,
) -> List[str]:
    """Extrait des frames de menus à partir d'un VOB via ffmpeg."""

    vob = Path(vob_path)
    out_path = Path(out_dir)
    if not vob.exists():
        logging.warning("VOB %s introuvable, extraction ignorée", vob)
        return []

    out_path.mkdir(parents=True, exist_ok=True)
    stem = vob.stem.replace(" ", "_")
    target_pattern = out_path / f"{stem}_%04d.png"

    filter_chain = _build_filters(scene_mode, fps, scene_threshold, filters)

    cmd: List[str] = [
        ffmpeg_bin,
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(vob),
        "-vf",
        filter_chain,
    ]
    if scene_mode == 1:
        cmd.extend(["-vsync", "vfr"])
    cmd.extend(["-frames:v", str(max(1, int(max_frames))), str(target_pattern)])

    logging.debug("Extraction menus (%s): %s", vob.name, " ".join(cmd))
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        logging.warning("ffmpeg n'a pas pu extraire %s: %s", vob, exc)
        return []

    frames = sorted(str(p) for p in out_path.glob(f"{stem}_*.png"))
    logging.info("%d frames extraites pour %s", len(frames), vob.name)
    return frames[: max(0, int(max_frames))]


def _parse_tsv_output(raw: str) -> tuple[str, float | None]:
    reader = csv.DictReader(io.StringIO(raw), delimiter="\t")
    texts: List[str] = []
    confidences: List[float] = []
    for row in reader:
        if not row:
            continue
        text = (row.get("text") or "").strip()
        if text:
            texts.append(text)
        conf = row.get("conf")
        if conf and conf not in {"-1", "-1.0"}:
            try:
                confidences.append(float(conf))
            except ValueError:
                continue
    mean_conf: float | None = None
    if confidences:
        mean_conf = sum(confidences) / (len(confidences) * 100.0)
    return " ".join(texts).strip(), mean_conf


def run_tesseract(
    image_paths: Sequence[str | Path],
    langs: str,
    tesseract_bin: str,
) -> List[Dict[str, object]]:
    """Lance Tesseract sur chaque image et retourne les textes détectés."""

    results: List[Dict[str, object]] = []
    for image in image_paths:
        img_path = Path(image)
        if not img_path.exists():
            logging.debug("Frame %s absente, ignorée", img_path)
            continue
        cmd = [
            tesseract_bin,
            str(img_path),
            "stdout",
            "-l",
            langs,
            "--psm",
            "6",
            "--oem",
            "1",
            "tsv",
        ]
        logging.debug("OCR Tesseract: %s", " ".join(cmd))
        text = ""
        conf: float | None = None
        try:
            proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
            text, conf = _parse_tsv_output(proc.stdout)
        except subprocess.CalledProcessError as exc:
            logging.warning("Tesseract a échoué sur %s: %s", img_path, exc)
        results.append({"frame": str(img_path), "text": text, "conf": conf})
    return results


def collect_menu_texts(backup_dir: str | Path, cfg: Dict[str, object]) -> List[Dict[str, object]]:
    """Explore le backup VIDEO_TS et retourne les textes OCR des menus."""

    backup_path = Path(backup_dir)
    video_ts = backup_path / "VIDEO_TS"
    if not video_ts.exists():
        logging.info("%s absent, aucun menu à OCR", video_ts)
        return []

    patterns = str(cfg.get("menu_vob_glob", "VIDEO_TS.VOB VTS_*_0.VOB")).split()
    frames_dir = Path(cfg.get("frames_dir", backup_path / "frames"))
    ffmpeg_bin = str(cfg.get("ffmpeg_bin", "ffmpeg"))
    tesseract_bin = str(cfg.get("tesseract_bin", "tesseract"))
    langs = str(cfg.get("ocr_langs", "eng"))
    fps = float(cfg.get("menu_frame_fps", 1.0))
    max_frames = int(cfg.get("menu_max_frames", 30))
    scene_mode = int(cfg.get("menu_scene_mode", 1))
    scene_threshold = float(cfg.get("menu_scene_threshold", 0.4))
    filters = str(cfg.get("menu_preproc_filters", ""))

    results: List[Dict[str, object]] = []
    vob_count = 0
    for pattern in patterns:
        for vob in sorted(video_ts.glob(pattern)):
            vob_count += 1
            frames = extract_menu_frames(
                vob,
                frames_dir,
                fps=fps,
                max_frames=max_frames,
                scene_mode=scene_mode,
                scene_threshold=scene_threshold,
                filters=filters,
                ffmpeg_bin=ffmpeg_bin,
            )
            if not frames:
                continue
            ocr_entries = run_tesseract(frames, langs=langs, tesseract_bin=tesseract_bin)
            for entry in ocr_entries:
                results.append(
                    {
                        "vob": vob.name,
                        "frame": entry.get("frame"),
                        "text": entry.get("text", ""),
                        "conf": entry.get("conf"),
                    }
                )
    logging.info("OCR terminé: %d VOB menus, %d entrées", vob_count, len(results))
    return results

