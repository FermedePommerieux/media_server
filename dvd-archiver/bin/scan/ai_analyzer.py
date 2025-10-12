"""Analyse IA des structures DVD."""
from __future__ import annotations

import json
import logging
from typing import Dict, List

import ai_providers


def _build_prompt(
    ocr_texts: List[Dict[str, object]],
    normalized_labels: Dict[str, object],
    struct: Dict[str, object],
    fingerprint: Dict[str, object],
) -> str:
    schema = """
Tu dois répondre avec un JSON strict respectant exactement ce schéma :
{
  "movie_title": "string|null",
  "content_type": "film|serie|autre",
  "language": "fr|en|es|de|it|...|unknown",
  "menu_labels": ["Play","Chapters","Subtitles","Bonus"],
  "mapping": {"title_1":"Main Feature","title_2":"Bonus: Making Of"},
  "confidence": 0.0
}
""".strip()

    prompt = (
        "Tu es un assistant expert en DVD. Analyse les données OCR, la structure technique et les empreintes pour déduire la nature du contenu.\n"
        "Consignes :\n"
        "- Travaille en français.\n"
        "- Si l'information manque, reste prudent et baisse la confiance.\n"
        "- Ne devine pas de titre inventé.\n"
        f"{schema}\n"
        "Données OCR (liste de textes avec confiance) :\n"
        f"{json.dumps(ocr_texts, ensure_ascii=False)}\n"
        "Labels normalisés :\n"
        f"{json.dumps(normalized_labels, ensure_ascii=False)}\n"
        "Structure technique (durées, langues) :\n"
        f"{json.dumps(struct, ensure_ascii=False)}\n"
        "Empreinte disque :\n"
        f"{json.dumps(fingerprint, ensure_ascii=False)}\n"
        "Réponds uniquement avec le JSON demandé."
    )
    return prompt


def infer_structure(
    ocr_texts: List[Dict[str, object]],
    normalized_labels: Dict[str, object],
    struct: Dict[str, object],
    fingerprint: Dict[str, object],
) -> Dict[str, object] | None:
    """Appelle le LLM configuré pour analyser la structure."""

    cfg = ai_providers.LLMConfig.from_env()
    client = ai_providers.build_client(cfg)
    prompt = _build_prompt(ocr_texts, normalized_labels, struct, fingerprint)
    logging.info(
        "Appel IA via %s (modèle=%s, endpoint=%s)", cfg.provider, cfg.model, cfg.endpoint
    )
    raw_response = client.complete(prompt)
    logging.debug("Réponse brute IA: %s", raw_response)

    try:
        payload = json.loads(raw_response)
    except json.JSONDecodeError as exc:
        logging.error("Réponse IA invalide: %s", exc)
        return None

    if not isinstance(payload, dict):
        logging.error("Réponse IA inattendue (type %s)", type(payload))
        return None

    payload.setdefault("source", cfg.provider)
    payload.setdefault("model", cfg.model)
    return payload

