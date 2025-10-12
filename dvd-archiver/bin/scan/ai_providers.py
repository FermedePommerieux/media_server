"""Gestion des fournisseurs LLM."""
from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Optional

try:
    import requests
except ImportError:  # pragma: no cover - bibliothèque optionnelle
    requests = None  # type: ignore


DEFAULT_PROVIDER = "ollama"
DEFAULT_ENDPOINT = "http://127.0.0.1:11434"
DEFAULT_MODEL = "qwen2.5:14b-instruct-q4_K_M"
DEFAULT_TIMEOUT = 3600
DEFAULT_TEMPERATURE = 0.2


@dataclass
class LLMConfig:
    provider: str = DEFAULT_PROVIDER
    model: str = DEFAULT_MODEL
    endpoint: str = DEFAULT_ENDPOINT
    api_key: str = ""
    timeout: int = DEFAULT_TIMEOUT
    temperature: float = DEFAULT_TEMPERATURE

    @classmethod
    def from_env(cls) -> "LLMConfig":
        return cls(
            provider=os.environ.get("LLM_PROVIDER", DEFAULT_PROVIDER),
            model=os.environ.get("LLM_MODEL", DEFAULT_MODEL),
            endpoint=os.environ.get("LLM_ENDPOINT", DEFAULT_ENDPOINT),
            api_key=os.environ.get("LLM_API_KEY", ""),
            timeout=int(os.environ.get("LLM_TIMEOUT_SEC", str(DEFAULT_TIMEOUT))),
            temperature=float(os.environ.get("LLM_TEMPERATURE", str(DEFAULT_TEMPERATURE))),
        )


class LLMClient:
    """Interface minimale pour interroger un modèle de langage."""

    def complete(self, prompt: str) -> str:  # pragma: no cover - interface
        raise NotImplementedError


class OllamaClient(LLMClient):
    def __init__(self, cfg: LLMConfig) -> None:
        self.cfg = cfg
        self.endpoint = cfg.endpoint.rstrip("/") or DEFAULT_ENDPOINT

    def complete(self, prompt: str) -> str:
        if not requests:
            raise RuntimeError("Le module requests est requis pour OllamaClient")
        payload = {
            "model": self.cfg.model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": self.cfg.temperature},
        }
        url = f"{self.endpoint}/api/generate"
        logging.debug("Appel Ollama POST %s", url)
        response = requests.post(url, json=payload, timeout=self.cfg.timeout)
        response.raise_for_status()
        data = response.json()
        if "response" not in data:
            raise RuntimeError("Réponse Ollama invalide: champ 'response' manquant")
        return str(data.get("response", ""))


class OpenAIClient(LLMClient):
    def __init__(self, cfg: LLMConfig) -> None:
        self.cfg = cfg
        self.endpoint = cfg.endpoint.rstrip("/") or "https://api.openai.com/v1"

    def complete(self, prompt: str) -> str:
        if not requests:
            raise RuntimeError("Le module requests est requis pour OpenAIClient")
        headers = {"Content-Type": "application/json"}
        if self.cfg.api_key:
            headers["Authorization"] = f"Bearer {self.cfg.api_key}"
        payload = {
            "model": self.cfg.model,
            "temperature": self.cfg.temperature,
            "messages": [
                {"role": "system", "content": "Tu es un expert des métadonnées vidéo."},
                {"role": "user", "content": prompt},
            ],
        }
        url = f"{self.endpoint}/chat/completions"
        logging.debug("Appel OpenAI POST %s", url)
        response = requests.post(url, headers=headers, json=payload, timeout=self.cfg.timeout)
        response.raise_for_status()
        data = response.json()
        try:
            message = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:  # pragma: no cover - dépend du fournisseur
            raise RuntimeError(f"Réponse OpenAI invalide: {data}") from exc
        return str(message)


class MockClient(LLMClient):
    def __init__(self, cfg: Optional[LLMConfig] = None) -> None:
        self.cfg = cfg or LLMConfig()

    def complete(self, prompt: str) -> str:  # pragma: no cover - trivial
        logging.info("Client LLM fictif utilisé, retour statique")
        return json.dumps(
            {
                "movie_title": None,
                "content_type": "autre",
                "language": "unknown",
                "items": [],
                "mapping": {},
                "confidence": 0.0,
                "source": "mock",
            }
        )


def build_client(cfg: LLMConfig) -> LLMClient:
    provider = cfg.provider.lower()
    if provider == "ollama":
        return OllamaClient(cfg)
    if provider == "openai":
        return OpenAIClient(cfg)
    return MockClient(cfg)

