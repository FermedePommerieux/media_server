"""Gestion du prompt et interprétation de la réponse IA."""
from __future__ import annotations

import json
import logging
from typing import Dict, List

import ai_providers

PROMPT_TEMPLATE = (
    "Tu es un assistant qui interprète la structure d’un DVD-Video.\n"
    "Données OCR (menus) = {ocr}.\n"
    "Structure technique (lsdvd/mkv) = {struct}.\n"
    "Métadonnées disque = {fingerprint}.\n"
    "Objectifs :\n\n"
    "1. Déduire le titre probable du film/série (si possible) et la langue principale.\n"
    "2. Classer le contenu : \"film\" | \"serie\" | \"autre\".\n"
    "3. Associer les libellés de menu aux titres détectés (main feature / bonus / trailer / épisodes).\n"
    "4. Retourner un JSON strict unique :\n\n"
    "{json_schema}\n\n"
    "Ne renvoie rien d’autre que ce JSON (pas de texte hors JSON)."
)

JSON_SCHEMA = (
    "{\"movie_title\":\"string|null\",\"content_type\":\"film|serie|autre\",\"language\":\"fr|en|...|unknown\","
    "\"menu_labels\":[\"Play\",\"Chapters\",\"Subtitles\",\"Bonus\"],\"mapping\":{\"title_1\":\"Main Feature\","
    "\"title_2\":\"Bonus: Making Of\"},\"confidence\":0.0}"
)


def _heuristic_summary(struct: Dict[str, object], normalized_labels: Dict[str, object]) -> Dict[str, object]:
    titles = struct.get("titles", []) or []
    movie_title = None
    language = normalized_labels.get("language", "unknown")
    if titles:
        first = titles[0]
        movie_title = first.get("filename") or f"Titre {first.get('index')}"
    menu_labels = [entry.get("text") for entry in normalized_labels.get("raw", [])]
    return {
        "movie_title": movie_title,
        "content_type": "autre" if len(titles) != 1 else "film",
        "language": language or "unknown",
        "menu_labels": menu_labels,
        "mapping": {},
        "confidence": 0.3,
    }


def infer_structure(
    ocr_texts: List[Dict[str, object]],
    normalized_labels: Dict[str, object],
    struct: Dict[str, object],
    fingerprint: Dict[str, object],
    disc_dir,
    config: Dict[str, object],
) -> Dict[str, object]:
    """Applique le prompt IA et renvoie la structure interprétée."""

    llm_enable = bool(config.get("llm_enable", True))
    cfg = ai_providers.LLMConfig.from_env()

    payload = {
        "inference": None,
        "source": "heuristics",
        "used": False,
        "provider": cfg.provider,
        "model": cfg.model,
        "disc_dir": str(disc_dir),
    }

    if not llm_enable:
        logging.info("LLM désactivé, retour heuristique")
        payload["inference"] = _heuristic_summary(struct, normalized_labels)
        return payload

    client = ai_providers.build_client(cfg)

    prompt = PROMPT_TEMPLATE.format(
        ocr=json.dumps(ocr_texts, ensure_ascii=False),
        struct=json.dumps(struct, ensure_ascii=False),
        fingerprint=json.dumps(fingerprint, ensure_ascii=False),
        json_schema=JSON_SCHEMA,
    )

    response = ""
    try:
        response = client.complete(prompt)
        logging.debug("Réponse brute IA: %s", response)
        data = json.loads(response)
        payload.update({"inference": data, "source": "ia", "used": True, "raw_response": response})
    except json.JSONDecodeError as exc:
        logging.error("Réponse IA non JSON: %s", exc)
        payload.update({"error": f"invalid_json: {exc}", "raw_response": response})
    except Exception as exc:  # pylint: disable=broad-except
        logging.error("Erreur appel IA: %s", exc)
        payload.update({"error": str(exc)})
    finally:
        if not payload.get("inference"):
            payload.setdefault("fallback", _heuristic_summary(struct, normalized_labels))
    return payload
