"""Écriture du fichier metadata_ia.json."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict

try:  # compat exécution directe
    from .heuristics import HeuristicHints  # type: ignore
    from .ai_analyzer import AIInference  # type: ignore
except ImportError:  # pragma: no cover - fallback
    from heuristics import HeuristicHints  # type: ignore
    from ai_analyzer import AIInference  # type: ignore


def write_metadata_json(
    out_path: Path,
    disc_uid: str,
    layout_version: str,
    mkv_struct: Dict[str, object],
    fingerprint: Dict[str, object],
    hints: HeuristicHints,
    ai_inference: AIInference,
    fallback_payload: Dict[str, object],
    llm_enabled: bool,
    total_time: float,
) -> None:
    files = mkv_struct.get("files", []) if isinstance(mkv_struct, dict) else []
    inferred = ai_inference.parsed or fallback_payload
    inferred = dict(inferred)
    inferred.setdefault("items", fallback_payload.get("items", []))
    inferred.setdefault("mapping", fallback_payload.get("mapping", {}))

    payload = {
        "disc_uid": disc_uid,
        "layout_version": layout_version,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "processing_time_sec": round(total_time, 3),
        "fingerprint": fingerprint,
        "inferred": {
            "movie_title": inferred.get("movie_title"),
            "content_type": inferred.get("content_type", "autre"),
            "language": inferred.get("language", "unknown"),
            "confidence": float(inferred.get("confidence", 0.0)),
            "source": inferred.get("source", "ia" if ai_inference.parsed else "heuristics"),
            "model": inferred.get("model"),
        },
        "items": inferred.get("items", []),
        "mapping": inferred.get("mapping", {}),
        "files": files,
        "hints": hints.as_dict(),
        "sources": {
            "mkv_probe": {
                "tool": mkv_struct.get("tool"),
                "version": mkv_struct.get("tool_version"),
                "errors": mkv_struct.get("errors", []),
            },
            "llm": {
                "enabled": llm_enabled,
                "attempts": ai_inference.attempts,
                "provider": ai_inference.parsed.get("source") if ai_inference.parsed else fallback_payload.get("source"),
                "model": ai_inference.parsed.get("model") if ai_inference.parsed else fallback_payload.get("model"),
            },
        },
    }

    if ai_inference.raw_response is not None:
        payload["sources"]["llm"]["raw_response"] = ai_inference.raw_response
    if ai_inference.prompt:
        payload["sources"]["llm"]["prompt"] = ai_inference.prompt

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

