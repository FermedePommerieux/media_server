"""Écriture du fichier metadata_ia.json."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional


def write_metadata_json(
    out_path: Path,
    disc_uid: str,
    struct: Dict[str, object],
    labels: Dict[str, object],
    mapping: Dict[str, str],
    main_feature: Optional[Dict[str, object]],
    layout_ver: str,
    ia_payload: Optional[Dict[str, object]] = None,
    ocr_results: Optional[List[Dict[str, object]]] = None,
    fingerprint: Optional[Dict[str, object]] = None,
) -> None:
    out_path = Path(out_path)
    ocr_results = ocr_results or []
    fingerprint = fingerprint or {}
    inference = (ia_payload or {}).get("inference") if ia_payload else None
    if not inference:
        inference = (ia_payload or {}).get("fallback") if ia_payload else None
    if not inference:
        inference = {
            "movie_title": None,
            "content_type": "autre",
            "language": "unknown",
            "menu_labels": [],
            "mapping": {},
            "confidence": 0.0,
        }

    payload = {
        "disc_uid": disc_uid,
        "layout_version": layout_ver,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "structure": struct,
        "menus": {
            "labels": labels,
            "frames_used": [entry.get("frame") for entry in ocr_results if entry.get("frame")],
            "language_detected": labels.get("language", "unknown") if isinstance(labels, dict) else "unknown",
        },
        "mapping": mapping,
        "main_feature": main_feature,
        "inferred": {
            "movie_title": inference.get("movie_title"),
            "content_type": inference.get("content_type", "autre"),
            "language": inference.get("language", "unknown"),
            "confidence": inference.get("confidence", 0.0),
            "source": "ia" if (ia_payload or {}).get("used") else "heuristics",
        },
        "sources": {
            "tech_dump": struct.get("source"),
            "ocr_dir": str(out_path.parent / "ocr_frames"),
            "llm": {
                "provider": (ia_payload or {}).get("provider"),
                "model": (ia_payload or {}).get("model"),
                "used": (ia_payload or {}).get("used", False),
                "error": (ia_payload or {}).get("error"),
            },
        },
        "fingerprint": fingerprint,
    }

    payload["inferred"]["menu_labels"] = inference.get("menu_labels", [])
    payload["inferred"]["mapping"] = inference.get("mapping", {})

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
