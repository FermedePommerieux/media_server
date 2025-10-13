"""Validation des métadonnées IA via Pydantic."""
from __future__ import annotations

import json
from typing import Dict, List, Literal, Optional

try:
    from pydantic import (
        BaseModel,
        Field,
        ValidationError,
        conint,
        confloat,
        constr,
        model_validator,
    )
except ModuleNotFoundError as exc:  # pragma: no cover - dépendance manquante
    raise RuntimeError(
        "La dépendance 'pydantic>=2' est requise pour valider les métadonnées. "
        "Installez-la via 'pip install \"pydantic>=2\"'."
    ) from exc

ItemType = Literal["main", "episode", "bonus", "trailer"]
ContentType = Literal["film", "serie", "autre"]


class Item(BaseModel):
    """Description d'un élément extrait du DVD (feature, épisode, bonus...)."""

    type: ItemType
    title_index: conint(ge=1)
    runtime_seconds: conint(ge=60)
    audio_langs: List[str] = Field(default_factory=list)
    sub_langs: List[str] = Field(default_factory=list)
    season: Optional[int] = None
    episode: Optional[int] = None
    episode_title: Optional[str] = None
    label: Optional[str] = None


class Meta(BaseModel):
    """Métadonnées globales décrivant un disque et ses contenus."""

    disc_uid: constr(min_length=1)
    content_type: ContentType
    movie_title: Optional[str] = None
    series_title: Optional[str] = None
    language: constr(min_length=1)
    year: Optional[int] = None
    items: List[Item]
    mapping: Dict[str, str]
    confidence: confloat(ge=0.0, le=1.0)
    sources: Dict[str, object] = Field(default_factory=dict)
    generated_at: Optional[str] = None

    @model_validator(mode="after")
    def _gate(self) -> "Meta":
        if not self.items:
            raise ValueError("items: au moins un élément requis")

        if self.content_type == "film":
            if self.series_title is not None:
                raise ValueError("film: series_title doit être null")
            if not any(item.type == "main" for item in self.items):
                raise ValueError("film: un item 'main' est requis")
            if not self.movie_title and float(self.confidence) < 0.70:
                raise ValueError("film: movie_title absent et confidence < 0.70")
            mains = [item for item in self.items if item.type == "main"]
            if not any(f"title_{item.title_index}" in self.mapping for item in mains):
                raise ValueError("film: mapping doit couvrir le main feature")
        elif self.content_type == "serie":
            if not self.series_title:
                raise ValueError("serie: series_title requis (non vide)")
            episodes = [item for item in self.items if item.type == "episode"]
            if not episodes:
                raise ValueError("serie: au moins un item 'episode' est requis")
            for episode in episodes:
                if episode.season is None or episode.episode is None:
                    raise ValueError("serie: season et episode requis pour chaque 'episode'")
            missing = [
                episode
                for episode in episodes
                if f"title_{episode.title_index}" not in self.mapping
            ]
            if missing:
                raise ValueError("serie: mapping doit couvrir tous les épisodes")
            if self.movie_title is not None:
                raise ValueError("serie: movie_title doit être null")
        else:  # "autre"
            if float(self.confidence) < 0.50:
                raise ValueError("autre: confidence minimale 0.50")
            if not any(item.type == "main" for item in self.items):
                bonus_trailer = [
                    item for item in self.items if item.type in ("bonus", "trailer")
                ]
                if len(bonus_trailer) < 2:
                    raise ValueError("autre: nécessite un main ou ≥2 bonus/trailer")

        return self


__all__ = [
    "ContentType",
    "Item",
    "ItemType",
    "Meta",
    "ValidationError",
    "dumps",
    "validate_payload",
]


def validate_payload(data: Dict[str, object]) -> Meta:
    """Valide le dictionnaire brut et retourne l'objet `Meta` correspondant."""

    return Meta.model_validate(data)


def dumps(meta: Meta) -> str:
    """Sérialise l'objet `Meta` en JSON formaté."""

    return json.dumps(meta.model_dump(), ensure_ascii=False, indent=2)
