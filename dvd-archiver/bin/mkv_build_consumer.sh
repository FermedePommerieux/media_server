#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

DEST="${DEST:-/mnt/media_master}"
BUILD_QUEUE_DIR="${BUILD_QUEUE_DIR:-/var/spool/dvdarchiver-build}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/var/log/dvdarchiver-build}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RAW_BACKUP_DIR="${RAW_BACKUP_DIR:-raw/VIDEO_TS_BACKUP}"
MAKEMKV_BIN="${MAKEMKV_BIN:-makemkvcon}"
MAKEMKV_MKV_OPTS="${MAKEMKV_MKV_OPTS:---minlength=0}"
OUTPUT_NAMING_TEMPLATE_MOVIE="${OUTPUT_NAMING_TEMPLATE_MOVIE:-{title} ({year}).mkv}"
OUTPUT_NAMING_TEMPLATE_SHOW="${OUTPUT_NAMING_TEMPLATE_SHOW:-{series_title} - S{season:02d}E{episode:02d} - {episode_title}.mkv}"
OUTPUT_NAMING_TEMPLATE_BONUS="${OUTPUT_NAMING_TEMPLATE_BONUS:-{title} - Bonus - {label}.mkv}"
WRITE_NFO="${WRITE_NFO:-1}"
MKVMERGE_BIN="${MKVMERGE_BIN:-mkvmerge}"
TMP_DIR="${TMP_DIR:-/var/tmp/dvdarchiver}"

log() { printf '[mkv_consumer] %s\n' "$*"; }

mkdir -p "$BUILD_QUEUE_DIR" "$BUILD_LOG_DIR" "$TMP_DIR"

run_builder() {
  local disc_dir="$1"
  RAW_BACKUP_DIR="$RAW_BACKUP_DIR" \
  OUTPUT_NAMING_TEMPLATE_MOVIE="$OUTPUT_NAMING_TEMPLATE_MOVIE" \
  OUTPUT_NAMING_TEMPLATE_SHOW="$OUTPUT_NAMING_TEMPLATE_SHOW" \
  OUTPUT_NAMING_TEMPLATE_BONUS="$OUTPUT_NAMING_TEMPLATE_BONUS" \
  WRITE_NFO="$WRITE_NFO" \
  MAKEMKV_BIN="$MAKEMKV_BIN" \
  MAKEMKV_MKV_OPTS="$MAKEMKV_MKV_OPTS" \
"$PYTHON_BIN" - "$disc_dir" "$MKVMERGE_BIN" <<'PY'
from __future__ import annotations
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

scan_candidates = [
    Path(os.environ.get("SCAN_MODULE_DIR", "/usr/local/bin/scan")),
]
try:
    current_base = Path(__file__).resolve().parent
    scan_candidates.append(current_base / "scan")
    scan_candidates.append(current_base.parent / "bin" / "scan")
except (OSError, RuntimeError):
    pass
for candidate in scan_candidates:
    if candidate.exists() and str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

import heuristics  # type: ignore
import scanner  # type: ignore
import techparse  # type: ignore


def sanitize(value: object) -> str:
    text = str(value or "").strip()
    text = text.replace("/", "-").replace("\\", "-").replace(":", "-")
    text = " ".join(text.split())
    return text or "Sans titre"


def apply_template(template: str, **values: object) -> str:
    result = template.format(**values)
    result = result.replace("()", "").replace("( )", "")
    while "  " in result:
        result = result.replace("  ", " ")
    return result.strip()


def xml_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def write_nfo_file(final_path: Path, item: dict, metadata: dict, title_text: str, language: str) -> None:
    nfo_path = final_path.with_suffix(".nfo")
    if nfo_path.exists() and nfo_path.stat().st_size > 0:
        return
    if item.get("type") == "episode":
        content = (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<episodedetails>\n"
            f"  <title>{xml_escape(title_text)}</title>\n"
            f"  <season>{int(item.get('season', 0))}</season>\n"
            f"  <episode>{int(item.get('episode', 0))}</episode>\n"
            f"  <plot></plot>\n"
            f"  <language>{xml_escape(language)}</language>\n"
            "</episodedetails>\n"
        )
    else:
        year_value = metadata.get("year") or ""
        content = (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<movie>\n"
            f"  <title>{xml_escape(title_text)}</title>\n"
            f"  <year>{xml_escape(str(year_value))}</year>\n"
            f"  <plot></plot>\n"
            f"  <language>{xml_escape(language)}</language>\n"
            "</movie>\n"
        )
    nfo_path.write_text(content, encoding="utf-8")


def main() -> int:
    disc_dir = Path(sys.argv[1]).resolve()
    mkvmerge_bin = sys.argv[2]
    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    if not metadata_path.exists():
        print(f"metadata_ia.json introuvable: {metadata_path}", file=sys.stderr)
        return 2

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    raw_rel = os.environ.get("RAW_BACKUP_DIR", "raw/VIDEO_TS_BACKUP")
    backup_root = disc_dir / raw_rel
    structure_path = disc_dir / "tech" / "structure.lsdvd.yml"
    structure = {}
    if structure_path.exists():
        structure = techparse.parse_lsdvd(structure_path)
    if not structure.get("titles"):
        structure = techparse.probe_backup_titles(backup_root, mkvmerge_bin=mkvmerge_bin)
    titles = heuristics.normalize_titles(structure)
    if not titles:
        print("Structure technique introuvable pour la validation", file=sys.stderr)
        return 3

    scanner.validate_metadata(metadata, titles)

    movie_template = os.environ.get("OUTPUT_NAMING_TEMPLATE_MOVIE", "{title} ({year}).mkv")
    show_template = os.environ.get(
        "OUTPUT_NAMING_TEMPLATE_SHOW",
        "{series_title} - S{season:02d}E{episode:02d} - {episode_title}.mkv",
    )
    bonus_template = os.environ.get("OUTPUT_NAMING_TEMPLATE_BONUS", "{title} - Bonus - {label}.mkv")
    write_nfo = os.environ.get("WRITE_NFO", "1") == "1"
    makemkv_bin = os.environ.get("MAKEMKV_BIN", "makemkvcon")
    makemkv_opts = shlex.split(os.environ.get("MAKEMKV_MKV_OPTS", ""))

    out_dir = disc_dir / "mkv"
    out_dir.mkdir(parents=True, exist_ok=True)

    mapping = metadata.get("mapping", {})
    language = str(metadata.get("language", "unknown"))

    generated: list[str] = []
    skipped: list[str] = []

    for item in metadata.get("items", []):
        title_index = int(item.get("title_index", 0))
        item_type = item.get("type", "bonus")
        key = f"title_{title_index}"
        label = sanitize(item.get("label"))
        if item_type == "main":
            base_title = sanitize(metadata.get("movie_title") or mapping.get(key) or label or f"Titre {title_index}")
            year = metadata.get("year") or ""
            filename = apply_template(movie_template, title=base_title, year=year or "")
            if not year:
                filename = filename.replace(" ()", "").replace("()", "").strip()
            nfo_title = base_title
        elif item_type == "episode":
            series_title = sanitize(metadata.get("series_title") or metadata.get("movie_title") or "Série")
            season = int(item.get("season", 1))
            episode = int(item.get("episode", title_index))
            episode_title = sanitize(item.get("episode_title") or label or f"Episode {episode}")
            filename = apply_template(
                show_template,
                series_title=series_title,
                season=season,
                episode=episode,
                episode_title=episode_title,
            )
            nfo_title = episode_title
        else:
            base_title = sanitize(metadata.get("movie_title") or metadata.get("series_title") or "Bonus")
            filename = apply_template(bonus_template, title=base_title, label=label or f"Title {title_index}")
            nfo_title = label or base_title
        if not filename.lower().endswith(".mkv"):
            filename = f"{filename}.mkv"
        final_path = out_dir / filename
        if final_path.exists() and final_path.stat().st_size > 0:
            print(f"Skip (déjà présent): {final_path}")
            skipped.append(str(final_path))
            continue
        before = {p.name for p in out_dir.glob("*.mkv")}
        cmd = [
            makemkv_bin,
            "-r",
            "--progress=-stdout",
            "mkv",
            f"file:{backup_root}",
            f"title:{title_index}",
            str(out_dir),
        ] + makemkv_opts
        print("Commande:", " ".join(cmd))
        subprocess.run(cmd, check=True)
        after = [path for path in out_dir.glob("*.mkv") if path.name not in before]
        if not after:
            raise RuntimeError(f"Aucun MKV généré pour title_{title_index}")
        newest = max(after, key=lambda path: path.stat().st_mtime)
        if final_path.exists():
            final_path.unlink()
        newest.rename(final_path)
        print(f"MKV généré: {final_path}")
        generated.append(str(final_path))
        if write_nfo:
            write_nfo_file(final_path, item, metadata, nfo_title, language)

    print("--- Récapitulatif ---")
    print(f"Générés: {len(generated)}")
    for path in generated:
        print(f"  + {path}")
    if skipped:
        print(f"Ignorés (déjà présents): {len(skipped)}")
        for path in skipped:
            print(f"  = {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
}

process_job() {
  local job="$1"
  # shellcheck disable=SC1090
  source "$job"
  local disc_dir="${DISC_DIR:-}"
  if [[ -z "$disc_dir" ]]; then
    log "Job $job invalide (DISC_DIR manquant)"
    mv "$job" "${job%.job}.err"
    return
  fi
  if [[ ! -d "$disc_dir" ]]; then
    log "Répertoire disque introuvable: $disc_dir"
    mv "$job" "${job%.job}.err"
    return
  fi
  local metadata="$disc_dir/meta/metadata_ia.json"
  if [[ ! -f "$metadata" ]]; then
    log "metadata_ia.json absent pour $disc_dir"
    mv "$job" "${job%.job}.err"
    return
  fi
  local ts="$(date +%Y%m%dT%H%M%S)"
  local log_file="$BUILD_LOG_DIR/build-$(basename "$disc_dir")-${ts}.log"
  log "Construction MKV pour $disc_dir (log: $log_file)"
  set +e
  run_builder "$disc_dir" 2>&1 | tee -a "$log_file"
  local status=${PIPESTATUS[0]}
  set -e
  if [[ $status -eq 0 ]]; then
    log "Job terminé: $disc_dir"
    mv "$job" "${job%.job}.done"
  else
    log "Job en erreur ($status): $disc_dir"
    mv "$job" "${job%.job}.err"
  fi
}

shopt -s nullglob
jobs=("$BUILD_QUEUE_DIR"/BUILD_*.job)
shopt -u nullglob

if [[ ${#jobs[@]} -eq 0 ]]; then
  log "Aucun job à traiter"
  exit 0
fi

for job in "${jobs[@]}"; do
  process_job "$job"
done
