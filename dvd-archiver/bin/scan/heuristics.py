"""Heuristiques pour interpréter la structure DVD."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Iterable, List


DEFAULT_RUNTIME_TOLERANCE = 120.0


@dataclass
class TitleInfo:
    """Représentation normalisée d'un titre DVD."""

    title_index: int
    runtime_seconds: int
    audio_langs: List[str]
    sub_langs: List[str]


def _safe_int(value: object, default: int = 0) -> int:
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return int(value)
        return int(float(value))
    except (TypeError, ValueError):
        return default


def normalize_titles(struct: Dict[str, object]) -> List[TitleInfo]:
    """Convertit la structure brute en liste de TitleInfo."""

    titles_raw = struct.get("titles", []) if isinstance(struct, dict) else []
    normalized: List[TitleInfo] = []
    used_indexes: set[int] = set()
    for idx, title in enumerate(titles_raw):
        raw_index = title.get("index") if isinstance(title, dict) else None
        title_number = _safe_int(raw_index, default=idx + 1)
        if title_number <= 0:
            title_number = idx + 1
        while title_number in used_indexes:
            title_number += 1
        used_indexes.add(title_number)
        runtime_seconds = _safe_int(title.get("runtime_s") if isinstance(title, dict) else 0)
        audio_langs = []
        sub_langs = []
        if isinstance(title, dict):
            audio_langs = [str(lang).lower() for lang in title.get("audio_langs", []) if lang]
            sub_langs = [str(lang).lower() for lang in title.get("sub_langs", []) if lang]
        normalized.append(
            TitleInfo(
                title_index=title_number,
                runtime_seconds=max(runtime_seconds, 0),
                audio_langs=sorted(set(audio_langs)),
                sub_langs=sorted(set(sub_langs)),
            )
        )
    return normalized


def detect_main_feature(struct: Dict[str, object], runtime_tol: float = DEFAULT_RUNTIME_TOLERANCE) -> Dict[str, object]:
    """Détecte le ou les titres principaux selon la durée."""

    titles = normalize_titles(struct)
    if not titles:
        return {"mode": "unknown", "main_indexes": [], "main_runtime": 0.0}

    durations = [title.runtime_seconds for title in titles]
    if not durations:
        return {"mode": "unknown", "main_indexes": [], "main_runtime": 0.0}

    max_runtime = max(durations)
    main_indexes = [title.title_index for title in titles if abs(title.runtime_seconds - max_runtime) <= runtime_tol]
    mode = "series" if len(main_indexes) > 1 else "single"
    return {"mode": mode, "main_indexes": main_indexes, "main_runtime": float(max_runtime)}


def guess_content_type(struct: Dict[str, object]) -> str:
    main = detect_main_feature(struct)
    if main["mode"] == "series" and len(main.get("main_indexes", [])) >= 2:
        return "serie"
    titles = normalize_titles(struct)
    if len(titles) == 1:
        return "film"
    if len(titles) >= 2 and titles[0].runtime_seconds > 0 and titles[1].runtime_seconds > 0:
        return "serie"
    return "autre"


def default_mapping(titles: Iterable[TitleInfo], main_indexes: Iterable[int]) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    main_indexes_set = set(main_indexes)
    for title in titles:
        key = f"title_{title.title_index}"
        if title.title_index in main_indexes_set:
            mapping[key] = "Main Feature"
        else:
            mapping.setdefault(key, "Bonus")
    return mapping


def default_items(
    titles: List[TitleInfo],
    content_type: str,
    main_indexes: Iterable[int],
) -> List[Dict[str, object]]:
    """Construit une liste d'items de base à partir de la structure."""

    items: List[Dict[str, object]] = []
    main_set = set(main_indexes)
    episode_counter = 1
    for title in titles:
        if title.title_index in main_set:
            if content_type == "serie":
                item_type = "episode"
                season = 1
                episode = episode_counter
                label = f"Episode {episode_counter}"
                episode_counter += 1
            else:
                item_type = "main"
                season = None
                episode = None
                label = "Main Feature"
        else:
            item_type = "bonus"
            season = None
            episode = None
            label = "Bonus"
        items.append(
            {
                "type": item_type,
                "title_index": title.title_index,
                "label": label,
                "season": season,
                "episode": episode,
                "episode_title": None,
                "runtime_seconds": title.runtime_seconds,
                "audio_langs": title.audio_langs,
                "sub_langs": title.sub_langs,
            }
        )
    return items


def merge_items(base: List[Dict[str, object]], hints: Iterable[Dict[str, object]]) -> List[Dict[str, object]]:
    """Fusionne les items heuristiques avec ceux proposés par l'IA."""

    base_by_index: Dict[int, Dict[str, object]] = {item["title_index"]: dict(item) for item in base}
    for hint in hints:
        if not isinstance(hint, dict):
            continue
        index = hint.get("title_index")
        try:
            index = int(index)
        except (TypeError, ValueError):
            continue
        if index not in base_by_index:
            continue
        merged = base_by_index[index]
        for key in ["type", "label", "season", "episode", "episode_title"]:
            if hint.get(key) not in {None, ""}:
                merged[key] = hint.get(key)
        base_by_index[index] = merged
    return list(base_by_index.values())


def merge_mapping(default: Dict[str, str], hint: Dict[str, str]) -> Dict[str, str]:
    merged = dict(default)
    for key, value in (hint or {}).items():
        if not key.startswith("title_"):
            continue
        if value:
            merged[key] = str(value)
    return merged


def compute_language(default_language: str, ia_language: str | None) -> str:
    lang = (ia_language or "").strip().lower()
    if lang:
        return lang
    return (default_language or "unknown").lower() or "unknown"


def compute_confidence(ia_confidence: object, fallback: float = 0.4) -> float:
    try:
        value = float(ia_confidence)
    except (TypeError, ValueError):
        value = fallback
    return max(0.0, min(1.0, value))

