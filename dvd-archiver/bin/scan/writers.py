"""Écriture des métadonnées finales conformément au schéma."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict


def write_metadata_json(out_path: Path, metadata: Dict[str, object] | Any) -> None:
    """Écrit le JSON final avec indentation."""

    if hasattr(metadata, "model_dump"):
        payload = metadata.model_dump()
    else:
        payload = dict(metadata)
    payload.setdefault("generated_at", datetime.now(timezone.utc).isoformat())
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

