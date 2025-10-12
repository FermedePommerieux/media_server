"""Écriture des métadonnées finales."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional


def _enrich_titles(titles: Iterable[Dict[str, object]]) -> List[Dict[str, object]]:
    enriched: List[Dict[str, object]] = []
    for idx, title in enumerate(titles):
        entry = dict(title)
        entry.setdefault("id", f"title_{idx + 1}")
        entry.setdefault("index", title.get("index", idx))
        entry.setdefault("runtime_s", float(title.get("runtime_s", 0.0) or 0.0))
        entry.setdefault("chapters", title.get("chapters", 0))
        entry.setdefault("audio_langs", title.get("audio_langs", []))
        entry.setdefault("sub_langs", title.get("sub_langs", []))
        entry.setdefault("angles", title.get("angles", 0))
        enriched.append(entry)
    return enriched


def _detect_ocr_dir(ocr_results: List[Dict[str, object]]) -> Optional[str]:
    for entry in ocr_results:
        frame = entry.get("frame")
        if frame:
            return str(Path(frame).resolve().parent)
    return None


def write_metadata_json(
    out_path: Path,
    disc_uid: str,
    layout_version: str,
    struct: Dict[str, object],
    labels: Dict[str, object],
    mapping: Dict[str, str],
    ia_payload: Dict[str, object],
    ocr_results: List[Dict[str, object]],
    fingerprint: Dict[str, object],
    total_time: float,
    llm_enabled: bool,
) -> None:
    """Écrit le fichier metadata_ia.json avec les informations consolidées."""

    titles = _enrich_titles(struct.get("titles", []) if isinstance(struct, dict) else [])
    inferred_title = ia_payload.get("movie_title") if isinstance(ia_payload, dict) else None
    inferred_type = ia_payload.get("content_type") if isinstance(ia_payload, dict) else "autre"
    inferred_lang = ia_payload.get("language") if isinstance(ia_payload, dict) else labels.get("language", "unknown")
    inferred_conf = ia_payload.get("confidence") if isinstance(ia_payload, dict) else 0.0
    provider = ia_payload.get("source") if isinstance(ia_payload, dict) else "heuristics"
    model = ia_payload.get("model") if isinstance(ia_payload, dict) else None

    payload = {
        "disc_uid": disc_uid,
        "layout_version": layout_version,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "processing_time_sec": round(total_time, 3),
        "inferred": {
            "title": inferred_title,
            "content_type": inferred_type,
            "language": inferred_lang,
            "confidence": inferred_conf,
            "source": provider,
            "model": model,
        },
        "structure": {
            "source": struct.get("source", "unknown") if isinstance(struct, dict) else "unknown",
            "titles": titles,
        },
        "menus": {
            "labels": labels,
            "frames_used": [entry.get("frame") for entry in ocr_results if entry.get("frame")],
        },
        "mapping": mapping,
        "fingerprint": fingerprint,
        "sources": {
            "tech": struct.get("source", "unknown") if isinstance(struct, dict) else "unknown",
            "ocr_dir": _detect_ocr_dir(ocr_results),
            "llm": {
                "enabled": llm_enabled,
                "provider": provider,
                "model": model,
            },
        },
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

