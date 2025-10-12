"""Clients LLM pour l'analyse IA des menus."""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Optional

try:
    import requests
except ImportError:  # pragma: no cover - dépendance optionnelle
    requests = None  # type: ignore


@dataclass
class LLMConfig:
    provider: str = "ollama"
    model: str = "qwen2.5:14b-instruct-q4_K_M"
    endpoint: str = "http://127.0.0.1:11434"
    api_key: str = ""
    timeout: int = 3600
    temperature: float = 0.2

    @classmethod
    def from_env(cls) -> "LLMConfig":
        return cls(
            provider=os.environ.get("LLM_PROVIDER", cls.provider),
            model=os.environ.get("LLM_MODEL", cls.model),
            endpoint=os.environ.get("LLM_ENDPOINT", cls.endpoint),
            api_key=os.environ.get("LLM_API_KEY", ""),
            timeout=int(os.environ.get("LLM_TIMEOUT_SEC", str(cls.timeout))),
            temperature=float(os.environ.get("LLM_TEMPERATURE", str(cls.temperature))),
        )


class LLMClient:
    """Interface minimale pour un fournisseur LLM."""

    def complete(self, prompt: str) -> str:  # pragma: no cover - interface
        raise NotImplementedError


class OllamaClient(LLMClient):
    def __init__(self, cfg: LLMConfig) -> None:
        self.cfg = cfg
        self.endpoint = cfg.endpoint.rstrip("/") or "http://127.0.0.1:11434"

    def complete(self, prompt: str) -> str:
        if not requests:
            raise RuntimeError("Le module requests est requis pour OllamaClient")
        url = f"{self.endpoint}/api/generate"
        payload = {
            "model": self.cfg.model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": self.cfg.temperature},
        }
        logging.debug("Appel Ollama: %s", url)
        response = requests.post(url, json=payload, timeout=self.cfg.timeout)
        response.raise_for_status()
        data = response.json()
        return str(data.get("response", ""))


class OpenAIClient(LLMClient):
    def __init__(self, cfg: LLMConfig) -> None:
        self.cfg = cfg
        self.endpoint = cfg.endpoint.rstrip("/") or "https://api.openai.com/v1"

    def complete(self, prompt: str) -> str:
        if not requests:
            raise RuntimeError("Le module requests est requis pour OpenAIClient")
        url = f"{self.endpoint}/chat/completions"
        headers = {"Content-Type": "application/json"}
        if self.cfg.api_key:
            headers["Authorization"] = f"Bearer {self.cfg.api_key}"
        payload = {
            "model": self.cfg.model,
            "temperature": self.cfg.temperature,
            "messages": [
                {"role": "system", "content": "Tu es un assistant d'analyse DVD."},
                {"role": "user", "content": prompt},
            ],
        }
        logging.debug("Appel OpenAI: %s", url)
        response = requests.post(url, headers=headers, json=payload, timeout=self.cfg.timeout)
        response.raise_for_status()
        data = response.json()
        choice = data.get("choices", [{}])[0].get("message", {}).get("content", "")
        return str(choice)


class MockClient(LLMClient):
    def __init__(self, cfg: Optional[LLMConfig] = None) -> None:
        self.cfg = cfg or LLMConfig()

    def complete(self, prompt: str) -> str:  # pragma: no cover - simple
        logging.info("Mock LLM appelé, retourne une structure minimale")
        return (
            "{\"movie_title\":null,\"content_type\":\"autre\","
            "\"language\":\"unknown\",\"menu_labels\":[],\"mapping\":{},\"confidence\":0.1}"
        )


def build_client(cfg: LLMConfig) -> LLMClient:
    provider = cfg.provider.lower()
    if provider == "ollama":
        return OllamaClient(cfg)
    if provider == "openai":
        return OpenAIClient(cfg)
    return MockClient(cfg)

