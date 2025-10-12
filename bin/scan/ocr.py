"""Fonctions utilitaires pour l'OCR des menus DVD."""
from __future__ import annotations

import logging
import subprocess
from collections import Counter
from pathlib import Path
from typing import Dict, List, Sequence

try:
    import pytesseract  # type: ignore
    from PIL import Image  # type: ignore
except ImportError:  # pragma: no cover - dépendances optionnelles
    pytesseract = None  # type: ignore
    Image = None  # type: ignore


LANG_KEYWORDS = {
    "fr": ["lecture", "chapit", "bonus", "version", "langue", "sous-titres"],
    "en": ["play", "chapter", "bonus", "setup", "audio", "subtitle"],
    "es": ["reproduc", "capít", "idioma", "subtít"],
    "de": ["wieder", "kapitel", "bonus", "sprache", "untertitel"],
    "it": ["riprod", "capitol", "bonus", "lingua", "sottotit"],
}

CANONICAL_LABELS = {
    "play": ["play", "lecture", "jouer", "leer", "start", "film"],
    "chapters": ["chap", "scene", "kapitel"],
    "bonus": ["bonus", "extras", "suppl", "extra"],
    "audio": ["audio", "lang", "voix", "idioma", "sprache"],
    "subtitles": ["subtitle", "sous", "subt", "untertitel"],
    "episodes": ["episode", "épisode", "capitulo", "episodio"],
}


def _ocr_with_pytesseract(image_path: Path, langs: str) -> Dict[str, object]:
    assert pytesseract and Image  # garde pour le type-checker
    image = Image.open(image_path)
    data = pytesseract.image_to_data(image, lang=langs, output_type=pytesseract.Output.DICT)
    text = " ".join(t for t in data.get("text", []) if t.strip())
    confidences = [int(c) for c in data.get("conf", []) if c not in {"-1", ""}]
    confidence = (sum(confidences) / (len(confidences) * 100)) if confidences else None
    return {"text": text.strip(), "frame": str(image_path), "confidence": confidence}


def _ocr_with_cli(image_path: Path, langs: str, bin_path: str) -> Dict[str, object]:
    cmd = [bin_path, str(image_path), "stdout", "-l", langs]
    logging.debug("Appel tesseract CLI: %s", " ".join(cmd))
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        text = result.stdout.strip()
    except subprocess.CalledProcessError as exc:
        logging.warning("OCR CLI échoué pour %s: %s", image_path, exc)
        text = ""
    return {"text": text, "frame": str(image_path), "confidence": None}


def ocr_frames(paths: Sequence[str | Path], langs: str, bin_path: str = "tesseract") -> List[Dict[str, object]]:
    """Retourne une liste de dictionnaires OCR."""

    results: List[Dict[str, object]] = []
    for raw_path in paths:
        path = Path(raw_path)
        if pytesseract and Image:
            try:
                results.append(_ocr_with_pytesseract(path, langs))
                continue
            except Exception as exc:  # pylint: disable=broad-except
                logging.warning("OCR pytesseract échoué pour %s: %s", path, exc)
        results.append(_ocr_with_cli(path, langs, bin_path))
    return results


def detect_language(labels: Sequence[Dict[str, object]]) -> str:
    counter = Counter()
    for entry in labels:
        text = entry.get("text", "")
        lower = text.lower()
        for lang, keywords in LANG_KEYWORDS.items():
            if any(keyword in lower for keyword in keywords):
                counter[lang] += 1
    if not counter:
        return "unknown"
    return counter.most_common(1)[0][0]


def normalize_labels(labels: Sequence[Dict[str, object]]) -> Dict[str, object]:
    categories: Dict[str, List[Dict[str, object]]] = {key: [] for key in CANONICAL_LABELS}
    cleaned: List[Dict[str, object]] = []
    for entry in labels:
        text = str(entry.get("text", "")).strip()
        if not text:
            continue
        normalized = {"text": text, "frame": entry.get("frame"), "confidence": entry.get("confidence")}
        cleaned.append(normalized)
        lower = text.lower()
        for canonical, keywords in CANONICAL_LABELS.items():
            if any(keyword in lower for keyword in keywords):
                categories.setdefault(canonical, []).append(normalized)
    language = detect_language(cleaned)
    return {"raw": cleaned, "categories": {k: v for k, v in categories.items() if v}, "language": language}
