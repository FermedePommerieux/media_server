"""Heuristiques basées sur les durées MKV pour inférer la nature du contenu."""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence


@dataclass
class HeuristicConfig:
    runtime_tolerance_sec: float = 120.0
    episode_group_min: int = 2
    main_feature_minutes: int = 60


@dataclass
class HeuristicHints:
    kind: str
    main_feature: Optional[Dict[str, object]]
    episode_buckets: List[Dict[str, object]]
    language_hint: Optional[str]

    def as_dict(self) -> Dict[str, object]:
        return {
            "kind": self.kind,
            "main_feature": self.main_feature,
            "episode_buckets": self.episode_buckets,
            "language_hint": self.language_hint,
        }


def _durations(files: Sequence[Dict[str, object]]) -> List[float]:
    durations: List[float] = []
    for entry in files:
        try:
            durations.append(float(entry.get("duration_s", 0.0) or 0.0))
        except (TypeError, ValueError):
            continue
    return durations


def guess_kind(files: Sequence[Dict[str, object]], cfg: HeuristicConfig) -> str:
    durations = _durations(files)
    if not durations:
        return "autre"

    longest = max(durations)
    long_count = sum(1 for value in durations if abs(value - longest) <= cfg.runtime_tolerance_sec)

    if len(files) == 1:
        return "film" if longest >= cfg.main_feature_minutes * 60 else "autre"

    buckets = episode_buckets(files, cfg)
    if any(len(bucket.get("files", [])) >= cfg.episode_group_min for bucket in buckets):
        return "serie"

    if longest >= cfg.main_feature_minutes * 60 and long_count == 1:
        return "film"

    return "autre"


def pick_main_feature(files: Sequence[Dict[str, object]]) -> Optional[Dict[str, object]]:
    if not files:
        return None
    best = max(files, key=lambda entry: float(entry.get("duration_s", 0.0) or 0.0))
    return {
        "file": best.get("file"),
        "duration_s": float(best.get("duration_s", 0.0) or 0.0),
    }


def episode_buckets(files: Sequence[Dict[str, object]], cfg: HeuristicConfig) -> List[Dict[str, object]]:
    durations = _durations(files)
    if not durations:
        return []

    buckets: Dict[int, Dict[str, object]] = {}
    for entry in files:
        try:
            duration = float(entry.get("duration_s", 0.0) or 0.0)
        except (TypeError, ValueError):
            continue
        if duration <= 0:
            continue
        key = int(round(duration / cfg.runtime_tolerance_sec)) if cfg.runtime_tolerance_sec else int(duration)
        bucket = buckets.setdefault(key, {"duration_mean_s": 0.0, "files": []})
        bucket["files"].append(entry.get("file"))

    results: List[Dict[str, object]] = []
    for key, bucket in sorted(buckets.items()):
        durations_in_bucket = [
            float(next((f.get("duration_s", 0.0) for f in files if f.get("file") == fname), 0.0) or 0.0)
            for fname in bucket["files"]
        ]
        duration_mean = sum(durations_in_bucket) / len(durations_in_bucket) if durations_in_bucket else 0.0
        results.append(
            {
                "cluster": key,
                "duration_mean_s": round(duration_mean, 2),
                "files": bucket["files"],
            }
        )
    return results


def language_hint(files: Sequence[Dict[str, object]]) -> Optional[str]:
    counter: Dict[str, int] = defaultdict(int)
    for entry in files:
        for lang in entry.get("audio_langs", []) or []:
            counter[lang] += 1
    if not counter:
        return None
    return max(counter.items(), key=lambda item: item[1])[0]


def hints_for(files: Sequence[Dict[str, object]], cfg: HeuristicConfig) -> HeuristicHints:
    kind = guess_kind(files, cfg)
    main_feature = pick_main_feature(files)
    buckets = episode_buckets(files, cfg)
    lang = language_hint(files)
    return HeuristicHints(kind=kind, main_feature=main_feature, episode_buckets=buckets, language_hint=lang)


def fallback_payload(files: Sequence[Dict[str, object]], hints: HeuristicHints) -> Dict[str, object]:
    items: List[Dict[str, object]] = []
    mapping: Dict[str, str] = {}
    sorted_files = list(files)
    sorted_files.sort(key=lambda entry: float(entry.get("duration_s", 0.0) or 0.0), reverse=True)

    for index, entry in enumerate(sorted_files, start=1):
        filename = str(entry.get("file"))
        if hints.kind == "film":
            label = "Main Feature" if index == 1 else f"Bonus {index - 1}"
        elif hints.kind == "serie":
            label = f"Episode {index}"
        else:
            label = f"Item {index}"
        items.append({"file": filename, "label": label, "order": index})
        mapping[filename] = label

    return {
        "movie_title": None,
        "content_type": hints.kind or "autre",
        "language": hints.language_hint or "unknown",
        "items": items,
        "mapping": mapping,
        "confidence": 0.2,
        "source": "heuristics",
        "model": None,
    }

