"""Écriture du fichier metadata_ia.json."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict


def write_metadata_json(
    out_path: Path | str,
    disc_uid: str,
    ocr_summary: Dict[str, Any],
    mkv_struct: Dict[str, Any],
    ia_result: Dict[str, Any],
    layout_ver: str,
) -> None:
    """Sérialise les résultats OCR + IA dans metadata_ia.json."""

    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    menus_section = {
        "normalized": ocr_summary.get("normalized", {}),
        "items": ocr_summary.get("items", []),
        "language": (ocr_summary.get("normalized") or {}).get("language", "unknown"),
    }

    ia_payload = ia_result.get("result", {})

    sources = {
        "menus_vob_dir": ocr_summary.get("menus_dir"),
        "frames_dir": ocr_summary.get("frames_dir"),
        "llm": {
            "provider": ia_result.get("provider"),
            "model": ia_result.get("model"),
            "used": ia_result.get("used_llm", False),
            "attempts": ia_result.get("attempts", 0),
            "error": ia_result.get("error"),
        },
        "tools": {
            "ffmpeg": (ocr_summary.get("tools") or {}).get("ffmpeg"),
            "tesseract": (ocr_summary.get("tools") or {}).get("tesseract"),
        },
    }

    payload = {
        "disc_uid": disc_uid,
        "layout_version": layout_ver,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "menus": menus_section,
        "mkv": mkv_struct,
        "analysis": ia_payload,
        "sources": sources,
        "raw_llm_responses": ia_result.get("raw_responses", []),
        "fingerprint": ocr_summary.get("fingerprint", {}),
    }

    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

