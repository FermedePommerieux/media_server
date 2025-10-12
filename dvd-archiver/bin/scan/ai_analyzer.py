"""Interface avec le LLM pour déduire les métadonnées logiques."""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Dict, Optional

try:  # compat exécution directe
    from . import ai_providers  # type: ignore
    from .heuristics import HeuristicHints  # type: ignore
except ImportError:  # pragma: no cover - fallback script
    import ai_providers  # type: ignore
    from heuristics import HeuristicHints  # type: ignore


@dataclass
class AIInference:
    prompt: str
    raw_response: Optional[str]
    parsed: Optional[Dict[str, object]]
    attempts: int


def _serialise_files(mkv_struct: Dict[str, object]) -> str:
    files = mkv_struct.get("files", []) if isinstance(mkv_struct, dict) else []
    serialisable = []
    for entry in files:
        serialisable.append(
            {
                "file": entry.get("file"),
                "duration_s": entry.get("duration_s"),
                "audio_langs": entry.get("audio_langs"),
                "sub_langs": entry.get("sub_langs"),
                "container_title": entry.get("container_title"),
                "track_titles": entry.get("track_titles"),
                "size_bytes": entry.get("size_bytes"),
            }
        )
    return json.dumps(serialisable, ensure_ascii=False)


def _build_prompt(
    mkv_struct: Dict[str, object],
    fingerprint: Dict[str, object],
    hints: HeuristicHints,
) -> str:
    schema = (
        "Réponds uniquement avec un JSON strict respectant exactement ce format :\n"
        "{\n"
        "  \"movie_title\": \"string|null\",\n"
        "  \"content_type\": \"film|serie|autre\",\n"
        "  \"language\": \"code langue principal ou unknown\",\n"
        "  \"items\": [\n"
        "    {\"file\": \"nom.mkv\", \"label\": \"titre humain\", \"order\": 1}\n"
        "  ],\n"
        "  \"mapping\": {\"nom.mkv\": \"label\"},\n"
        "  \"confidence\": 0.0\n"
        "}\n"
        "Aucune explication, aucun texte avant ou après."
    )
    files_json = _serialise_files(mkv_struct)
    fingerprint_json = json.dumps(fingerprint or {}, ensure_ascii=False)
    hints_json = json.dumps(hints.as_dict(), ensure_ascii=False)
    return (
        "Tu es un expert d'archives vidéo. Analyse uniquement les métadonnées techniques des fichiers MKV fournis.\n"
        "Déduis le titre du contenu (film ou série), la langue principale et la correspondance fichiers -> éléments logiques.\n"
        "Consignes :\n"
        "- Pas d'invention : si le titre est inconnu, retourne null.\n"
        "- Utilise les durées pour distinguer film principal, épisodes ou bonus.\n"
        "- Utilise les langues de pistes pour proposer la langue principale.\n"
        "- Respecte l'ordre logique (principal en premier).\n"
        "- Utilise la sortie heuristique comme simple indice, pas comme vérité absolue.\n"
        f"{schema}\n"
        f"Empreinte disque : {fingerprint_json}\n"
        f"Fichiers MKV : {files_json}\n"
        f"Indices heuristiques : {hints_json}\n"
        "Réponds maintenant avec le JSON demandé."
    )


def _validate_payload(payload: Dict[str, object], files: Dict[str, Dict[str, object]]) -> Dict[str, object]:
    result = dict(payload)
    movie_title = result.get("movie_title")
    if movie_title is not None and not isinstance(movie_title, str):
        result["movie_title"] = None

    content_type = result.get("content_type", "autre")
    if content_type not in {"film", "serie", "autre"}:
        result["content_type"] = "autre"

    language = result.get("language", "unknown")
    if not isinstance(language, str) or not language:
        result["language"] = "unknown"

    mapping = result.get("mapping")
    if not isinstance(mapping, dict):
        mapping = {}
    cleaned_mapping = {}
    for key, value in mapping.items():
        if key in files and isinstance(value, str):
            cleaned_mapping[key] = value
    result["mapping"] = cleaned_mapping

    items = result.get("items")
    if not isinstance(items, list):
        items = []
    cleaned_items = []
    seen_files = set()
    for idx, item in enumerate(items, start=1):
        file_name = item.get("file") if isinstance(item, dict) else None
        label = item.get("label") if isinstance(item, dict) else None
        order = item.get("order") if isinstance(item, dict) else idx
        if file_name in files and isinstance(label, str):
            cleaned_items.append({"file": file_name, "label": label, "order": int(order) if isinstance(order, int) else idx})
            seen_files.add(file_name)
    # Complète avec les fichiers manquants pour assurer une correspondance totale
    missing = [name for name in files if name not in seen_files]
    next_order = len(cleaned_items) + 1
    for name in missing:
        label = cleaned_mapping.get(name) or f"Item {next_order}"
        cleaned_items.append({"file": name, "label": label, "order": next_order})
        cleaned_mapping.setdefault(name, label)
        next_order += 1

    cleaned_items.sort(key=lambda entry: entry.get("order", 0))
    result["items"] = cleaned_items
    result["mapping"] = cleaned_mapping

    confidence = result.get("confidence")
    try:
        result["confidence"] = float(confidence)
    except (TypeError, ValueError):
        result["confidence"] = 0.0

    return result


def infer_from_mkv(
    mkv_struct: Dict[str, object],
    fingerprint: Dict[str, object],
    hints: HeuristicHints,
    llm_enabled: bool,
) -> AIInference:
    cfg = ai_providers.LLMConfig.from_env()
    client = ai_providers.build_client(cfg)
    prompt = _build_prompt(mkv_struct, fingerprint, hints)
    logging.info("Appel IA via %s (modèle=%s)", cfg.provider, cfg.model)

    files_dict = {entry.get("file"): entry for entry in mkv_struct.get("files", [])}
    if not files_dict:
        return AIInference(prompt=prompt, raw_response=None, parsed=None, attempts=0)

    if not llm_enabled:
        logging.info("LLM désactivé, aucun appel effectué")
        return AIInference(prompt=prompt, raw_response=None, parsed=None, attempts=0)

    attempts = 0
    raw_response: Optional[str] = None
    parsed: Optional[Dict[str, object]] = None
    while attempts < 2 and parsed is None:
        attempts += 1
        current_prompt = prompt if attempts == 1 else prompt + "\nRespecte strictement le format JSON sans texte additionnel."
        try:
            raw_response = client.complete(current_prompt)
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Appel LLM échoué (tentative %d): %s", attempts, exc)
            raw_response = None
            break
        if raw_response is None:
            break
        logging.debug("Réponse IA (tentative %d): %s", attempts, raw_response)
        try:
            candidate = json.loads(raw_response)
        except json.JSONDecodeError as exc:
            logging.warning("JSON IA invalide (tentative %d): %s", attempts, exc)
            continue
        if not isinstance(candidate, dict):
            logging.warning("Réponse IA inattendue (type %s)", type(candidate))
            continue
        parsed = _validate_payload(candidate, files_dict)
        parsed.setdefault("source", cfg.provider)
        parsed.setdefault("model", cfg.model)

    return AIInference(prompt=prompt, raw_response=raw_response, parsed=parsed, attempts=attempts)

