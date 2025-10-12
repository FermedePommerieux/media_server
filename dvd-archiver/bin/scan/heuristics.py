"""Heuristiques pour la détection de structure DVD."""
from __future__ import annotations

import logging
from typing import Dict, List


DEFAULT_RUNTIME_TOLERANCE = 120.0


def detect_main_feature(struct: Dict[str, object], runtime_tol: float = DEFAULT_RUNTIME_TOLERANCE) -> Dict[str, object]:
    """Détecte le ou les titres principaux selon la durée."""

    titles = struct.get("titles", []) if isinstance(struct, dict) else []
    if not titles:
        return {"mode": "unknown", "main_positions": [], "main_runtime": 0.0}

    durations: List[float] = []
    for title in titles:
        try:
            durations.append(float(title.get("runtime_s", 0.0)))
        except (TypeError, ValueError):
            durations.append(0.0)
    if not durations:
        return {"mode": "unknown", "main_positions": [], "main_runtime": 0.0}

    max_runtime = max(durations)
    main_positions = [idx for idx, value in enumerate(durations) if abs(value - max_runtime) <= runtime_tol]

    if len(main_positions) > 1:
        mode = "series"
    else:
        mode = "single"

    return {
        "mode": mode,
        "main_positions": main_positions,
        "main_runtime": max_runtime,
    }


def _title_key(position: int) -> str:
    return f"title_{position + 1}"


def map_menu_labels_to_titles(
    normalized_labels: Dict[str, object],
    structure: Dict[str, object],
    runtime_tol: float = DEFAULT_RUNTIME_TOLERANCE,
    min_conf: float = 0.5,
) -> Dict[str, str]:
    """Associe les labels détectés aux titres connus."""

    titles = structure.get("titles", []) if isinstance(structure, dict) else []
    if not titles:
        return {}

    categories = normalized_labels.get("categories", {}) if isinstance(normalized_labels, dict) else {}
    if not isinstance(categories, dict):
        categories = {}

    main_info = detect_main_feature(structure, runtime_tol)
    main_positions: List[int] = list(main_info.get("main_positions", []))
    main_runtime = float(main_info.get("main_runtime", 0.0))

    mapping: Dict[str, str] = {}
    for pos, title in enumerate(titles):
        key = _title_key(pos)
        runtime = float(title.get("runtime_s", 0.0) or 0.0)
        label_candidates: List[str] = []

        if pos in main_positions:
            label_candidates.append("Main Feature")
            if "chapters" in categories:
                label_candidates.append("Chapters")
            if len(main_positions) > 1 and "episodes" in categories:
                label_candidates.append(f"Episode {pos + 1}")
        else:
            if runtime and main_runtime and runtime + runtime_tol < main_runtime:
                label_candidates.append("Bonus")
            if "bonus" in categories:
                label_candidates.append("Bonus")

        if not label_candidates and "episodes" in categories:
            label_candidates.append(f"Episode {pos + 1}")

        if not label_candidates and runtime and main_runtime and abs(runtime - main_runtime) <= runtime_tol:
            label_candidates.append("Feature Alt")

        if not label_candidates:
            continue

        # Filtre selon confiance moyenne
        entries = [entry for entry in categories.get("bonus", [])] + [entry for entry in categories.get("play", [])]
        average_conf = None
        confidences: List[float] = []
        for entry in entries:
            conf = entry.get("confidence") if isinstance(entry, dict) else None
            if conf is not None:
                try:
                    confidences.append(float(conf))
                except (TypeError, ValueError):
                    continue
        if confidences:
            average_conf = sum(confidences) / len(confidences)
        if average_conf is not None and average_conf < min_conf:
            logging.debug("Confiance trop faible pour %s (%.2f)", key, average_conf)
            continue

        mapping[key] = ", ".join(dict.fromkeys(label_candidates))

    return mapping


def fallback_payload(
    normalized_labels: Dict[str, object],
    structure: Dict[str, object],
    main_feature: Dict[str, object],
) -> Dict[str, object]:
    """Produit un résultat heuristique minimal en absence d'IA."""

    categories = normalized_labels.get("categories", {}) if isinstance(normalized_labels, dict) else {}
    menu_labels = sorted({label.capitalize() for label in categories.keys()})
    titles = structure.get("titles", []) if isinstance(structure, dict) else []
    mode = main_feature.get("mode", "unknown")
    if mode == "single" and len(titles) == 1:
        content_type = "film"
    elif mode == "series" or len(titles) > 1:
        content_type = "serie"
    else:
        content_type = "autre"

    main_positions: List[int] = list(main_feature.get("main_positions", []))
    mapping = {_title_key(pos): "Main Feature" for pos in main_positions}

    return {
        "movie_title": None,
        "content_type": content_type,
        "language": normalized_labels.get("language", "unknown"),
        "menu_labels": menu_labels,
        "mapping": mapping,
        "confidence": 0.3,
        "source": "heuristics",
    }

