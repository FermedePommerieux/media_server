"""Heuristiques d'association des menus avec la structure technique."""
from __future__ import annotations

import logging
from typing import Dict, List, Optional


def detect_main_feature(struct: Dict[str, object]) -> Optional[Dict[str, object]]:
    """Retourne le titre principal estimé à partir des durées."""

    titles: List[Dict[str, object]] = list(struct.get("titles", []))  # type: ignore[arg-type]
    if not titles:
        return None

    candidates = [t for t in titles if t.get("runtime_s")]
    if not candidates:
        return None

    main = max(candidates, key=lambda t: t.get("runtime_s", 0))
    max_runtime = main.get("runtime_s", 0)
    similar = [t for t in candidates if abs(t.get("runtime_s", 0) - max_runtime) <= 180]
    if len(similar) > 1:
        main = {**main, "series_candidates": [t.get("index") for t in similar]}
    logging.debug("Main feature détectée: %s", main)
    return main


def map_menu_labels_to_titles(
    normalized_labels: Dict[str, object],
    struct: Dict[str, object],
    runtime_tol: int,
    min_conf: float,
) -> Dict[str, str]:
    """Associe les étiquettes de menus aux titres connus."""

    mapping: Dict[str, str] = {}
    titles: List[Dict[str, object]] = list(struct.get("titles", []))  # type: ignore[arg-type]
    if not titles:
        return mapping

    main = detect_main_feature(struct)
    if main:
        mapping[f"title_{main.get('index')}"] = "Main Feature"

    categories: Dict[str, List[Dict[str, object]]] = normalized_labels.get("categories", {})  # type: ignore[assignment]

    # Bonus = titres courts (< 25 min) si libellé bonus présent
    bonus_labels = categories.get("bonus", []) if isinstance(categories, dict) else []
    if bonus_labels:
        for title in titles:
            runtime = title.get("runtime_s") or 0
            if runtime and runtime <= 1500 and any(
                (label.get("confidence") or 1.0) >= min_conf for label in bonus_labels
            ):
                mapping[f"title_{title.get('index')}"] = "Bonus"

    # Épisodes: associer par index si libellés contiennent des numéros
    episode_labels = categories.get("episodes", []) if isinstance(categories, dict) else []
    if episode_labels:
        for label in episode_labels:
            text = str(label.get("text", ""))
            for title in titles:
                idx = title.get("index")
                if idx and str(idx) in text:
                    mapping[f"title_{idx}"] = f"Episode {idx}"

    # Chapitres: si chapitres courts
    chapter_labels = categories.get("chapters", []) if isinstance(categories, dict) else []
    if chapter_labels and main:
        mapping.setdefault(f"title_{main.get('index')}", "Main Feature (Chapitres)")

    if main and len(titles) > 1:
        longest = main.get("runtime_s") or 0
        for title in titles:
            runtime = title.get("runtime_s") or 0
            if title.get("index") == main.get("index"):
                continue
            if abs(longest - runtime) <= runtime_tol:
                mapping.setdefault(f"title_{title.get('index')}", "Episode")

    return mapping
