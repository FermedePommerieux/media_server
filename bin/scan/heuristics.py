"""Heuristiques basiques pour analyser menus et structures MKV."""
from __future__ import annotations

import re
from collections import Counter
from typing import Dict, Iterable, List, Optional

LABEL_PATTERNS = {
    "play": [r"\bplay\b", r"\blecture\b", r"\blire\b", r"\biniciar\b", r"\bstart\b"],
    "chapters": [r"chapitre", r"chapters?", r"scene", r"escena", r"kapitel"],
    "bonus": [r"bonus", r"suppl", r"extras?", r"contenu special", r"making"],
    "audio": [r"audio", r"langue", r"idioma", r"sprache", r"version"],
    "subtitles": [r"sous[- ]titres", r"subtitles?", r"subt[ií]t", r"untertitel"],
    "episodes": [r"episode", r"épisode", r"cap[ií]tulo", r"episodio", r"folge"],
}

LANGUAGE_HINTS = {
    "fr": ["lecture", "chapitre", "bonus", "version", "sous"],
    "en": ["play", "chapter", "bonus", "audio", "subtitle"],
    "es": ["reproduc", "cap", "idioma", "subt"],
    "de": ["wieder", "kapitel", "sprache", "untertitel"],
    "it": ["riprod", "capit", "lingua", "sottotit"],
}


def _duration_seconds(entry: Dict[str, object]) -> float:
    value = entry.get("runtime_s") or entry.get("duration_s")
    try:
        return float(value) if value is not None else 0.0
    except (ValueError, TypeError):
        return 0.0


def guess_content_type(mkv_struct: Dict[str, object]) -> str:
    """Estime la catégorie du contenu (film / série / autre)."""

    titles: List[Dict[str, object]] = list(mkv_struct.get("titles", []))  # type: ignore[arg-type]
    durations = [_duration_seconds(t) for t in titles if _duration_seconds(t) > 0]
    if not durations:
        return "autre"
    if len(durations) == 1:
        return "film"

    longest = max(durations)
    close = [d for d in durations if abs(d - longest) <= 180]
    if len(close) >= max(2, len(durations) // 2):
        return "serie"
    if longest >= 3600 and len(durations) >= 1:
        return "film"
    if len(durations) > 3 and sum(1 for d in durations if d >= 3000) >= 2:
        return "serie"
    return "autre"


def main_feature_candidate(mkv_struct: Dict[str, object]) -> Optional[Dict[str, object]]:
    """Retourne le titre le plus long identifié comme feature principale."""

    titles: List[Dict[str, object]] = list(mkv_struct.get("titles", []))  # type: ignore[arg-type]
    if not titles:
        return None
    return max(titles, key=_duration_seconds)


def _detect_language(labels: Iterable[str]) -> str:
    counter: Counter[str] = Counter()
    for text in labels:
        lowered = text.lower()
        for lang, hints in LANGUAGE_HINTS.items():
            if any(hint in lowered for hint in hints):
                counter[lang] += 1
    if not counter:
        return "unknown"
    return counter.most_common(1)[0][0]


def normalize_labels_from_texts(ocr_items: List[Dict[str, object]]) -> Dict[str, object]:
    """Classe les textes OCR dans les catégories de menus usuelles."""

    categorized: Dict[str, List[str]] = {key: [] for key in LABEL_PATTERNS}
    raw_labels: List[str] = []
    for item in ocr_items:
        text = str(item.get("text", "")).strip()
        if not text:
            continue
        raw_labels.append(text)
        lowered = text.lower()
        for key, patterns in LABEL_PATTERNS.items():
            if any(re.search(pattern, lowered) for pattern in patterns):
                if text not in categorized[key]:
                    categorized[key].append(text)
    language = _detect_language(raw_labels)
    result = {key: values for key, values in categorized.items() if values}
    result["raw_labels"] = raw_labels
    result["language"] = language
    return result

