"""Analyse IA des structures DVD pour remplir le schéma requis."""
from __future__ import annotations

import json
import logging
from typing import Dict, List

import ai_providers


SCHEMA_DOC = """
Tu dois répondre avec un JSON strict respectant exactement ce schéma :
{
  "content_type": "film|serie|autre",
  "movie_title": "string|null",
  "series_title": "string|null",
  "year": 2000|null,
  "language": "fr|en|...|unknown",
  "items": [
    {
      "title_index": 1,
      "type": "main|episode|bonus|trailer",
      "label": "Main Feature|Episode 1|Bonus...",
      "season": 1|null,
      "episode": 1|null,
      "episode_title": "string|null"
    }
  ],
  "mapping": {"title_1": "Main Feature"},
  "confidence": 0.0
}
- Laisse runtime_seconds/audio_langs/sub_langs au système : ne les retourne pas.
- Utilise le français.
- Appuie-toi sur les durées et langues techniques pour déterminer le type de contenu.
""".strip()


def _build_prompt(
    ocr_texts: List[Dict[str, object]],
    normalized_labels: Dict[str, object],
    struct: Dict[str, object],
    fingerprint: Dict[str, object],
) -> str:
    prompt = (
        "Tu es un assistant expert en archivage DVD. Analyse les menus, les données techniques et les empreintes.\n"
        "Objectif : fournir le JSON décrit ci-dessous pour aider à nommer correctement les MKV.\n"
        f"{SCHEMA_DOC}\n"
        "Consignes :\n"
        "- Ne rends aucune clé en plus.\n"
        "- Garde une approche prudente, baisse la confiance si doute.\n"
        "- Si le titre ou l'année sont inconnus, renvoie null.\n"
        "- Pour les séries, renseigne saison/épisode à partir des menus si possible.\n"
        "- Pour les bonus, titre clair (ex: 'Bonus: Making Of').\n"
        "- mapping doit couvrir tous les titres importants.\n"
        "Données OCR (texte, frame, confiance) :\n"
        f"{json.dumps(ocr_texts, ensure_ascii=False)}\n"
        "Labels catégorisés :\n"
        f"{json.dumps(normalized_labels, ensure_ascii=False)}\n"
        "Structure technique (durées/langues) :\n"
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

    payload.setdefault("content_type", "autre")
    payload.setdefault("movie_title", None)
    payload.setdefault("series_title", None)
    payload.setdefault("year", None)
    payload.setdefault("language", "unknown")
    payload.setdefault("items", [])
    payload.setdefault("mapping", {})
    payload.setdefault("confidence", 0.3)
    payload["provider"] = cfg.provider
    payload["model"] = cfg.model
    return payload

