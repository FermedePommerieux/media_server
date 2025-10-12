"""Abstraction des différents fournisseurs LLM."""
from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Optional

try:
    import requests
except ImportError:  # pragma: no cover
    requests = None  # type: ignore


@dataclass
class LLMConfig:
    provider: str
    model: str
    endpoint: str
    api_key: str
    timeout: int
    temperature: float

    @classmethod
    def from_env(cls) -> "LLMConfig":
        return cls(
            provider=os.environ.get("LLM_PROVIDER", "mock"),
            model=os.environ.get("LLM_MODEL", "mock"),
            endpoint=os.environ.get("LLM_ENDPOINT", ""),
            api_key=os.environ.get("LLM_API_KEY", ""),
            timeout=int(os.environ.get("LLM_TIMEOUT_SEC", "60")),
            temperature=float(os.environ.get("LLM_TEMPERATURE", "0.2")),
        )


class LLMClient:
    def complete(self, prompt: str) -> str:  # pragma: no cover - interface
        raise NotImplementedError


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
        logging.debug("Appel OpenAI %s", url)
        response = requests.post(url, headers=headers, json=payload, timeout=self.cfg.timeout)
        response.raise_for_status()
        data = response.json()
        choice = data["choices"][0]["message"]["content"]
        return str(choice)


class OllamaClient(LLMClient):
    def __init__(self, cfg: LLMConfig) -> None:
        self.cfg = cfg
        self.endpoint = cfg.endpoint.rstrip("/") or "http://localhost:11434"

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
        logging.debug("Appel Ollama %s", url)
        response = requests.post(url, json=payload, timeout=self.cfg.timeout)
        response.raise_for_status()
        data = response.json()
        return str(data.get("response", ""))


class MockClient(LLMClient):
    def __init__(self, cfg: Optional[LLMConfig] = None) -> None:
        self.cfg = cfg or LLMConfig("mock", "mock", "", "", 1, 0.0)

    def complete(self, prompt: str) -> str:  # pragma: no cover - trivial
        logging.info("Mock LLM utilisé")
        return json.dumps(
            {
                "movie_title": None,
                "content_type": "autre",
                "language": "unknown",
                "menu_labels": [],
                "mapping": {},
                "confidence": 0.1,
            }
        )


def build_client(cfg: LLMConfig) -> LLMClient:
    provider = cfg.provider.lower()
    if provider == "openai":
        return OpenAIClient(cfg)
    if provider == "ollama":
        return OllamaClient(cfg)
    return MockClient(cfg)
