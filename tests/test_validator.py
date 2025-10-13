from __future__ import annotations

from pathlib import Path
import sys

import pytest

pytest.importorskip("pydantic", minversion="2")

SCAN_DIR = Path(__file__).resolve().parents[1] / "dvd-archiver" / "bin" / "scan"
if str(SCAN_DIR) not in sys.path:
    sys.path.insert(0, str(SCAN_DIR))

import validator  # type: ignore  # noqa: E402


def base_sources() -> dict[str, object]:
    return {"ocr": None, "tech_dump": "structure.lsdvd.yml", "llm": {}}


def test_validate_film_valid() -> None:
    payload = {
        "disc_uid": "DISC001",
        "content_type": "film",
        "movie_title": "Film Test",
        "series_title": None,
        "language": "fr",
        "year": 2001,
        "items": [
            {
                "type": "main",
                "title_index": 1,
                "runtime_seconds": 5400,
                "audio_langs": ["fr"],
                "sub_langs": ["fr"],
            }
        ],
        "mapping": {"title_1": "Main Feature"},
        "confidence": 0.9,
        "sources": base_sources(),
    }
    meta = validator.validate_payload(payload)
    assert meta.movie_title == "Film Test"
    assert meta.items[0].type == "main"


def test_validate_film_requires_mapping() -> None:
    payload = {
        "disc_uid": "DISC002",
        "content_type": "film",
        "movie_title": "Film sans mapping",
        "series_title": None,
        "language": "fr",
        "year": 2005,
        "items": [
            {
                "type": "main",
                "title_index": 1,
                "runtime_seconds": 3600,
                "audio_langs": ["fr"],
                "sub_langs": [],
            }
        ],
        "mapping": {},
        "confidence": 0.8,
        "sources": base_sources(),
    }
    with pytest.raises(validator.ValidationError):
        validator.validate_payload(payload)


def test_validate_serie_valid() -> None:
    payload = {
        "disc_uid": "DISC003",
        "content_type": "serie",
        "movie_title": None,
        "series_title": "Série Test",
        "language": "fr",
        "year": None,
        "items": [
            {
                "type": "episode",
                "title_index": 1,
                "season": 1,
                "episode": 2,
                "runtime_seconds": 2400,
                "audio_langs": ["fr"],
                "sub_langs": ["fr"],
            }
        ],
        "mapping": {"title_1": "Episode 2"},
        "confidence": 0.75,
        "sources": base_sources(),
    }
    meta = validator.validate_payload(payload)
    assert meta.series_title == "Série Test"
    assert meta.items[0].episode == 2


def test_validate_serie_missing_episode_details() -> None:
    payload = {
        "disc_uid": "DISC004",
        "content_type": "serie",
        "movie_title": None,
        "series_title": "Série Invalide",
        "language": "fr",
        "year": None,
        "items": [
            {
                "type": "episode",
                "title_index": 1,
                "season": None,
                "episode": None,
                "runtime_seconds": 1800,
                "audio_langs": ["fr"],
                "sub_langs": [],
            }
        ],
        "mapping": {"title_1": "Episode"},
        "confidence": 0.6,
        "sources": base_sources(),
    }
    with pytest.raises(validator.ValidationError):
        validator.validate_payload(payload)


def test_validate_autre_rules() -> None:
    payload = {
        "disc_uid": "DISC005",
        "content_type": "autre",
        "movie_title": None,
        "series_title": None,
        "language": "fr",
        "year": None,
        "items": [
            {
                "type": "bonus",
                "title_index": 1,
                "runtime_seconds": 900,
                "audio_langs": ["fr"],
                "sub_langs": [],
            },
            {
                "type": "trailer",
                "title_index": 2,
                "runtime_seconds": 600,
                "audio_langs": ["fr"],
                "sub_langs": [],
            },
        ],
        "mapping": {"title_1": "Bonus", "title_2": "Trailer"},
        "confidence": 0.55,
        "sources": base_sources(),
    }
    meta = validator.validate_payload(payload)
    assert meta.content_type == "autre"
    assert len(meta.items) == 2


def test_validate_autre_reject_low_confidence() -> None:
    payload = {
        "disc_uid": "DISC006",
        "content_type": "autre",
        "movie_title": None,
        "series_title": None,
        "language": "fr",
        "year": None,
        "items": [
            {
                "type": "bonus",
                "title_index": 1,
                "runtime_seconds": 900,
                "audio_langs": [],
                "sub_langs": [],
            }
        ],
        "mapping": {"title_1": "Bonus"},
        "confidence": 0.4,
        "sources": base_sources(),
    }
    with pytest.raises(validator.ValidationError):
        validator.validate_payload(payload)
