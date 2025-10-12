"""Analyse IA des menus via LLM."""
from __future__ import annotations

import json
import logging
import textwrap
from typing import Any, Dict

import ai_providers
import heuristics

JSON_TEMPLATE = (
    '{"movie_title":"string|null","content_type":"film|serie|autre",'
    '"language":"fr|en|...|unknown","menu_labels":["Play","Chapitres",'
    '"Bonus","Sous-titres"],"mapping":{"title00.mkv":"Main Feature"},'
    '"confidence":0.0}'
)


def _simplify_mkv_struct(mkv_struct: Dict[str, Any]) -> Dict[str, Any]:
    titles = []
    for title in mkv_struct.get("titles", []):
        titles.append(
            {
                "index": title.get("index"),
                "filename": title.get("filename"),
                "duration_s": title.get("runtime_s") or title.get("duration_s"),
                "audio_langs": title.get("audio_langs"),
                "sub_langs": title.get("sub_langs"),
                "title": title.get("title"),
            }
        )
    return {"titles": titles}


def _heuristic_result(ocr_summary: Dict[str, Any], mkv_struct: Dict[str, Any]) -> Dict[str, Any]:
    normalized = ocr_summary.get("normalized", {})
    menu_labels = []
    canonical = {
        "play": "Play",
        "chapters": "Chapitres",
        "bonus": "Bonus",
        "audio": "Audio",
        "subtitles": "Sous-titres",
        "episodes": "Episodes",
    }
    for key, label in canonical.items():
        if normalized.get(key):
            menu_labels.append(label)
    main_feature = heuristics.main_feature_candidate(mkv_struct)
    mapping = {}
    if main_feature:
        filename = main_feature.get("filename") or f"title{int(main_feature.get('index', 0)):02d}.mkv"
        mapping[str(filename)] = "Main Feature"
    content_type = heuristics.guess_content_type(mkv_struct)
    language = normalized.get("language", "unknown")
    movie_title = None
    if main_feature:
        movie_title = main_feature.get("title") or main_feature.get("filename")
    return {
        "movie_title": movie_title,
        "content_type": content_type,
        "language": language or "unknown",
        "menu_labels": menu_labels,
        "mapping": mapping,
        "confidence": 0.3,
    }


def _build_prompt(
    normalized: Dict[str, Any],
    raw_items: Any,
    mkv_summary: Dict[str, Any],
    fingerprint: Dict[str, Any],
    remind_invalid: bool,
) -> str:
    reminder = "Ta précédente réponse n'était pas un JSON valide. Recommence en respectant le format demandé.\n" if remind_invalid else ""
    prompt = f"""
    Tu es un archiviste DVD chargé d'interpréter des menus OCRisés.
    {reminder}Analyse les données ci-dessous et produis une synthèse structurée.

    Menus normalisés:
    {json.dumps(normalized, ensure_ascii=False, indent=2)}

    Menus bruts (échantillon):
    {json.dumps(raw_items, ensure_ascii=False, indent=2)}

    Fichiers MKV détectés:
    {json.dumps(mkv_summary, ensure_ascii=False, indent=2)}

    Empreinte disque:
    {json.dumps(fingerprint, ensure_ascii=False, indent=2)}

    Contraintes:
    - Utilise uniquement les informations fournies.
    - Le champ "mapping" doit référencer les noms exacts des fichiers MKV.
    - content_type doit être l'une des valeurs : film, serie ou autre.
    - language doit être un code langue (fr, en, es, ...) ou "unknown".
    - menu_labels doit contenir les libellés pertinents présents dans les menus.
    - confidence est un nombre entre 0 et 1.

    Forme de réponse attendue (JSON strict unique, sans prose) :
    {JSON_TEMPLATE}

    Réponds uniquement avec ce JSON valide.
    """
    return textwrap.dedent(prompt).strip()


def _merge_with_fallback(fallback: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    result = dict(fallback)
    if isinstance(payload.get("movie_title"), str) or payload.get("movie_title") is None:
        result["movie_title"] = payload.get("movie_title")
    content_type = payload.get("content_type")
    if isinstance(content_type, str) and content_type in {"film", "serie", "autre"}:
        result["content_type"] = content_type
    language = payload.get("language")
    if isinstance(language, str) and language:
        result["language"] = language
    menu_labels = payload.get("menu_labels")
    if isinstance(menu_labels, list):
        result["menu_labels"] = [str(label) for label in menu_labels if label]
    mapping = payload.get("mapping")
    if isinstance(mapping, dict) and mapping:
        result["mapping"] = {str(k): str(v) for k, v in mapping.items() if k}
    confidence = payload.get("confidence")
    if isinstance(confidence, (int, float)):
        result["confidence"] = float(confidence)
    return result


def infer_structure_from_menus(
    ocr_summary: Dict[str, Any],
    mkv_struct: Dict[str, Any],
    fingerprint: Dict[str, Any],
    cfg: Dict[str, Any],
) -> Dict[str, Any]:
    """Pilote l'appel LLM et retourne le résultat consolidé."""

    fallback = _heuristic_result(ocr_summary, mkv_struct)
    llm_cfg = ai_providers.LLMConfig.from_env()
    result = {
        "result": fallback,
        "provider": llm_cfg.provider,
        "model": llm_cfg.model,
        "used_llm": False,
        "attempts": 0,
        "raw_responses": [],
        "error": None,
    }

    if not bool(cfg.get("llm_enable", True)):
        result["error"] = "llm_disabled"
        return result

    client = ai_providers.build_client(llm_cfg)
    normalized = ocr_summary.get("normalized", {})
    raw_items = ocr_summary.get("items", [])
    raw_sample = [
        {"vob": item.get("vob"), "text": item.get("text"), "conf": item.get("conf")}
        for item in raw_items[:20]
    ]
    mkv_summary = _simplify_mkv_struct(mkv_struct)

    prompt = _build_prompt(normalized, raw_sample, mkv_summary, fingerprint, remind_invalid=False)

    for attempt in (1, 2):
        try:
            response = client.complete(prompt)
            result["raw_responses"].append(response)
            payload = json.loads(response)
            merged = _merge_with_fallback(fallback, payload)
            result.update({
                "result": merged,
                "used_llm": True,
                "attempts": attempt,
                "error": None,
            })
            return result
        except json.JSONDecodeError as exc:
            logging.warning("Réponse LLM invalide (tentative %d): %s", attempt, exc)
            result["error"] = f"invalid_json_attempt_{attempt}"
            prompt = _build_prompt(normalized, raw_sample, mkv_summary, fingerprint, remind_invalid=True)
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Appel LLM impossible: %s", exc)
            result["error"] = str(exc)
            break

    return result

