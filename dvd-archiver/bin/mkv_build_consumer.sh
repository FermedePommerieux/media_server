#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
EXPORT_ENABLE="${EXPORT_ENABLE:-1}"
EXPORT_METHOD="${EXPORT_METHOD:-copy}"
EXPORT_MOVIES_DIR="${EXPORT_MOVIES_DIR:-/mnt/nas/media/Library/Movies}"
EXPORT_SERIES_DIR="${EXPORT_SERIES_DIR:-/mnt/nas/media/Library/Series}"
EXPORT_MOVIE_EXTRAS_SUBDIR="${EXPORT_MOVIE_EXTRAS_SUBDIR:-extras}"
EXPORT_SERIES_SPECIALS_SEASON="${EXPORT_SERIES_SPECIALS_SEASON:-0}"
NFO_LANGUAGE_DEFAULT="${NFO_LANGUAGE_DEFAULT:-unknown}"
SANITIZE_MAXLEN="${SANITIZE_MAXLEN:-180}"

log() { printf '[mkv_consumer] %s\n' "$*"; }

mkdir -p "$BUILD_QUEUE_DIR" "$BUILD_LOG_DIR" "$TMP_DIR"

run_builder() {
  local disc_dir="$1"
  RAW_BACKUP_DIR="$RAW_BACKUP_DIR" \
  OUTPUT_NAMING_TEMPLATE_MOVIE="$OUTPUT_NAMING_TEMPLATE_MOVIE" \
  OUTPUT_NAMING_TEMPLATE_SHOW="$OUTPUT_NAMING_TEMPLATE_SHOW" \
  OUTPUT_NAMING_TEMPLATE_BONUS="$OUTPUT_NAMING_TEMPLATE_BONUS" \
  WRITE_NFO="$WRITE_NFO" \
  EXPORT_ENABLE="$EXPORT_ENABLE" \
  EXPORT_METHOD="$EXPORT_METHOD" \
  EXPORT_MOVIES_DIR="$EXPORT_MOVIES_DIR" \
  EXPORT_SERIES_DIR="$EXPORT_SERIES_DIR" \
  EXPORT_MOVIE_EXTRAS_SUBDIR="$EXPORT_MOVIE_EXTRAS_SUBDIR" \
  EXPORT_SERIES_SPECIALS_SEASON="$EXPORT_SERIES_SPECIALS_SEASON" \
  NFO_LANGUAGE_DEFAULT="$NFO_LANGUAGE_DEFAULT" \
  SANITIZE_MAXLEN="$SANITIZE_MAXLEN" \
  MAKEMKV_BIN="$MAKEMKV_BIN" \
  MAKEMKV_MKV_OPTS="$MAKEMKV_MKV_OPTS" \
  SCAN_MODULE_DIR="${SCAN_MODULE_DIR:-${SCRIPT_DIR}/scan}" \
 "$PYTHON_BIN" - "$disc_dir" <<'PY'
from __future__ import annotations
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def extend_sys_path() -> None:
    candidates = []
    env_path = os.environ.get("SCAN_MODULE_DIR")
    if env_path:
        candidates.append(Path(env_path))
    try:
        current_base = Path(__file__).resolve().parent
        candidates.append(current_base)
        candidates.append(current_base / "scan")
        candidates.append(current_base.parent / "bin" / "scan")
    except (OSError, RuntimeError):
        pass
    for candidate in candidates:
        if candidate.exists() and str(candidate) not in sys.path:
            sys.path.insert(0, str(candidate))


extend_sys_path()

try:
    import validator  # type: ignore
    from validator import ValidationError  # type: ignore
except RuntimeError as exc:  # pragma: no cover - dépendance manquante
    print(f"Validation indisponible: {exc}", file=sys.stderr)
    sys.exit(20)

try:
    from nfo_writer import (  # type: ignore
        episode_nfo,
        movie_nfo,
        sanitize as sanitize_filename,
        tvshow_nfo,
        write_text as write_nfo_text,
    )
except ModuleNotFoundError as exc:
    print(f"Module nfo_writer introuvable: {exc}", file=sys.stderr)
    sys.exit(21)


def normalize_text(value: object, fallback: str) -> str:
    text = str(value or "").strip()
    return text or fallback


def apply_template(template: str, **values: object) -> str:
    result = template.format(**values)
    result = result.replace("()", "").replace("( )", "")
    while "  " in result:
        result = result.replace("  ", " ")
    result = result.strip()
    result = result.rstrip("-")
    result = result.replace(" - .", " .")
    for ext in (".mkv", ".nfo"):
        suffix = f" {ext}"
        if result.endswith(suffix):
            result = result[: -len(suffix)] + ext
    return result.strip()


def ensure_extension(name: str, extension: str, maxlen: int) -> str:
    candidate = name
    if extension and not candidate.lower().endswith(extension.lower()):
        candidate = f"{candidate}{extension}"
    candidate = sanitize_filename(candidate, maxlen)
    if extension and not candidate.lower().endswith(extension.lower()):
        candidate = sanitize_filename(f"{candidate}{extension}", maxlen)
    return candidate


def minutes_from_seconds(seconds: int) -> int:
    return max(1, int(round(seconds / 60)))


def int_from_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:  # pragma: no cover - configuration invalide
        raise RuntimeError(f"Valeur invalide pour {name}: {raw}") from exc


def already_present(path: Path) -> bool:
    if path.exists() or path.is_symlink():
        try:
            return path.stat().st_size > 0
        except FileNotFoundError:
            return False
    return False


def transfer_file(src: Path, dest: Path, method: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        dest.unlink()
    if method == "copy":
        shutil.copy2(src, dest)
    elif method == "move":
        shutil.move(str(src), str(dest))
    elif method == "hardlink":
        os.link(src, dest)
    elif method == "symlink":
        dest.symlink_to(src.resolve())
    else:  # pragma: no cover - méthode prévalidée en amont
        raise ValueError(method)


def write_sidecar(path: Path, content: str) -> bool:
    if already_present(path):
        return False
    write_nfo_text(path, content)
    return True


def export_movie_items(
    tasks: list[dict[str, object]],
    export_dir: Path,
    extras_subdir: str,
    method: str,
    disc_uid: str,
    language: str,
    year: int | None,
    write_nfo_flag: bool,
    sanitize_maxlen: int,
) -> None:
    main_task = next((task for task in tasks if task.get("kind") == "movie_main"), None)
    if not main_task:
        return

    movie_title_raw = str(main_task["movie_title_raw"])
    folder_base = f"{movie_title_raw} ({year})" if year else movie_title_raw
    folder_name = sanitize_filename(folder_base, sanitize_maxlen)
    movie_dir = export_dir / folder_name
    movie_dir.mkdir(parents=True, exist_ok=True)

    main_dest_name = ensure_extension(sanitize_filename(folder_base, sanitize_maxlen), ".mkv", sanitize_maxlen)
    main_dest = movie_dir / main_dest_name
    source_path = Path(main_task["source"])
    if already_present(main_dest):
        print(f"Export: déjà présent -> {main_dest}")
    else:
        transfer_file(source_path, main_dest, method)
        print(f"Export: {method} -> {main_dest}")

    if write_nfo_flag:
        nfo_content = movie_nfo(
            disc_uid,
            movie_title_raw,
            year,
            int(main_task.get("runtime", 0)),
            language,
        )
        nfo_path = main_dest.with_suffix(".nfo")
        if write_sidecar(nfo_path, nfo_content):
            print(f"Export NFO: écrit -> {nfo_path}")
        else:
            print(f"Export NFO: déjà présent -> {nfo_path}")

    extras_dir = movie_dir
    if extras_subdir:
        extras_dir = movie_dir / extras_subdir
        extras_dir.mkdir(parents=True, exist_ok=True)

    for task in tasks:
        if task.get("kind") != "movie_bonus":
            continue
        label_raw = str(task["label_raw"])
        featurette_base = f"{movie_title_raw} - Featurette - {label_raw}"
        featurette_name = ensure_extension(
            sanitize_filename(featurette_base, sanitize_maxlen),
            ".mkv",
            sanitize_maxlen,
        )
        dest = extras_dir / featurette_name
        source_path = Path(task["source"])
        if already_present(dest):
            print(f"Export: déjà présent -> {dest}")
            continue
        transfer_file(source_path, dest, method)
        print(f"Export: {method} -> {dest}")
        if write_nfo_flag:
            content = movie_nfo(
                disc_uid,
                featurette_base,
                year,
                int(task.get("runtime", 0)),
                language,
            )
            nfo_path = dest.with_suffix(".nfo")
            if write_sidecar(nfo_path, content):
                print(f"Export NFO: écrit -> {nfo_path}")
            else:
                print(f"Export NFO: déjà présent -> {nfo_path}")


def export_series_items(
    tasks: list[dict[str, object]],
    export_dir: Path,
    method: str,
    disc_uid: str,
    language: str,
    premiered_year: int | None,
    write_nfo_flag: bool,
    sanitize_maxlen: int,
) -> None:
    entries = [task for task in tasks if task.get("kind") in {"series_episode", "series_special"}]
    if not entries:
        return

    first = entries[0]
    series_title_raw = str(first["series_title_raw"])
    series_title_clean = str(first.get("series_title_clean") or sanitize_filename(series_title_raw, sanitize_maxlen))
    show_dir = export_dir / series_title_clean
    show_dir.mkdir(parents=True, exist_ok=True)

    if write_nfo_flag:
        tvshow_path = show_dir / "tvshow.nfo"
        tvshow_content = tvshow_nfo(disc_uid, series_title_raw, language, premiered_year)
        if write_sidecar(tvshow_path, tvshow_content):
            print(f"Export NFO: écrit -> {tvshow_path}")
        else:
            print(f"Export NFO: déjà présent -> {tvshow_path}")

    for entry in entries:
        season = int(entry["season"])
        episode = int(entry["episode"])
        episode_component = str(entry.get("episode_title_component") or "")
        episode_title_raw = str(entry.get("episode_title_raw"))
        series_component = str(entry.get("series_title_clean") or series_title_clean)
        base_name = f"{series_component} - S{season:02d}E{episode:02d}"
        if episode_component:
            base_name += f" - {episode_component}"
        filename = ensure_extension(
            sanitize_filename(base_name, sanitize_maxlen),
            ".mkv",
            sanitize_maxlen,
        )
        season_dir = show_dir / f"Season {season:02d}"
        season_dir.mkdir(parents=True, exist_ok=True)
        dest = season_dir / filename
        source_path = Path(entry["source"])
        if already_present(dest):
            print(f"Export: déjà présent -> {dest}")
            continue
        transfer_file(source_path, dest, method)
        print(f"Export: {method} -> {dest}")
        if write_nfo_flag:
            content = episode_nfo(
                disc_uid,
                series_title_raw,
                season,
                episode,
                episode_title_raw,
                int(entry.get("runtime", 0)),
                language,
            )
            nfo_path = dest.with_suffix(".nfo")
            if write_sidecar(nfo_path, content):
                print(f"Export NFO: écrit -> {nfo_path}")
            else:
                print(f"Export NFO: déjà présent -> {nfo_path}")


def main() -> int:
    disc_dir = Path(sys.argv[1]).resolve()
    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    if not metadata_path.exists():
        print(f"metadata_ia.json introuvable: {metadata_path}", file=sys.stderr)
        return 2

    try:
        metadata_dict = json.loads(metadata_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"JSON invalide: {exc}", file=sys.stderr)
        return 3

    try:
        metadata = validator.validate_payload(metadata_dict)
    except ValidationError as exc:
        print("Validation metadata échouée:", file=sys.stderr)
        for error in exc.errors():
            loc = error.get("loc", [])
            path = ".".join(str(part) for part in loc) if loc else "(racine)"
            print(f"  - {path}: {error.get('msg')}", file=sys.stderr)
        return 4

    try:
        sanitize_maxlen = int_from_env("SANITIZE_MAXLEN", 180)
        specials_season = int_from_env("EXPORT_SERIES_SPECIALS_SEASON", 0)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 5

    export_enable = os.environ.get("EXPORT_ENABLE", "1") == "1"
    export_method = os.environ.get("EXPORT_METHOD", "copy").strip().lower()
    allowed_methods = {"copy", "move", "hardlink", "symlink"}
    if export_method not in allowed_methods:
        print(f"Méthode d'export invalide: {export_method}", file=sys.stderr)
        return 6

    export_movies_dir = Path(os.environ.get("EXPORT_MOVIES_DIR", "/mnt/nas/media/Library/Movies"))
    export_series_dir = Path(os.environ.get("EXPORT_SERIES_DIR", "/mnt/nas/media/Library/Series"))
    extras_subdir_raw = os.environ.get("EXPORT_MOVIE_EXTRAS_SUBDIR", "extras").strip()
    extras_subdir = sanitize_filename(extras_subdir_raw, sanitize_maxlen) if extras_subdir_raw else ""
    nfo_language_default = os.environ.get("NFO_LANGUAGE_DEFAULT", "unknown")
    write_nfo = os.environ.get("WRITE_NFO", "1") == "1"

    raw_rel = os.environ.get("RAW_BACKUP_DIR", "raw/VIDEO_TS_BACKUP")
    backup_root = disc_dir / raw_rel
    movie_template = os.environ.get("OUTPUT_NAMING_TEMPLATE_MOVIE", "{title} ({year}).mkv")
    show_template = os.environ.get(
        "OUTPUT_NAMING_TEMPLATE_SHOW",
        "{series_title} - S{season:02d}E{episode:02d} - {episode_title}.mkv",
    )
    bonus_template = os.environ.get("OUTPUT_NAMING_TEMPLATE_BONUS", "{title} - Bonus - {label}.mkv")
    makemkv_bin = os.environ.get("MAKEMKV_BIN", "makemkvcon")
    makemkv_opts = shlex.split(os.environ.get("MAKEMKV_MKV_OPTS", ""))

    out_dir = disc_dir / "mkv"
    out_dir.mkdir(parents=True, exist_ok=True)

    mapping = metadata.mapping
    language = normalize_text(metadata.language, nfo_language_default)
    disc_uid = str(metadata.disc_uid)
    content_type = str(metadata.content_type)
    year_value = metadata.year

    movie_title_raw = ""
    movie_title_clean = ""
    if content_type == "film":
        movie_title_raw = normalize_text(metadata.movie_title, "")
        if not movie_title_raw:
            mains = [item for item in metadata.items if item.type == "main"]
            if mains:
                first_main = mains[0]
                map_key = f"title_{int(first_main.title_index)}"
                movie_title_raw = normalize_text(mapping.get(map_key), f"Titre {int(first_main.title_index)}")
        if not movie_title_raw:
            movie_title_raw = "Film"
        movie_title_clean = sanitize_filename(movie_title_raw, sanitize_maxlen)

    series_title_raw = normalize_text(metadata.series_title, "Série") if metadata.series_title else ""
    series_title_clean = sanitize_filename(series_title_raw, sanitize_maxlen) if series_title_raw else ""

    generated: list[str] = []
    skipped: list[str] = []
    export_tasks: list[dict[str, object]] = []
    specials_counter = 0

    for item in metadata.items:
        title_index = int(item.title_index)
        key = f"title_{title_index}"
        label_raw = normalize_text(item.label, f"Title {title_index}")
        label_clean = sanitize_filename(label_raw, sanitize_maxlen)
        runtime_minutes = minutes_from_seconds(int(item.runtime_seconds))
        export_kind = None
        export_payload: dict[str, object] = {}

        if item.type == "main":
            base_title_raw = normalize_text(
                metadata.movie_title or mapping.get(key) or label_raw,
                f"Titre {title_index}",
            )
            movie_title_raw = base_title_raw
            movie_title_clean = sanitize_filename(base_title_raw, sanitize_maxlen)
            filename_base = apply_template(
                movie_template,
                title=movie_title_clean,
                year=year_value or "",
            )
            filename = ensure_extension(filename_base, ".mkv", sanitize_maxlen)
            nfo_title = base_title_raw
            export_kind = "movie_main" if content_type == "film" else None
            export_payload = {
                "movie_title_raw": movie_title_raw,
                "movie_title_clean": movie_title_clean,
                "runtime": runtime_minutes,
            }
        elif item.type == "episode":
            if not series_title_raw:
                series_title_raw = normalize_text(metadata.series_title or metadata.movie_title, "Série")
                series_title_clean = sanitize_filename(series_title_raw, sanitize_maxlen)
            season = int(item.season or 1)
            episode_num = int(item.episode or title_index)
            raw_ep_title = str(item.episode_title or "").strip()
            if raw_ep_title:
                episode_component = sanitize_filename(normalize_text(raw_ep_title, f"Episode {episode_num}"), sanitize_maxlen)
                nfo_title = normalize_text(raw_ep_title, f"Episode {episode_num}")
            else:
                episode_component = ""
                nfo_title = normalize_text(label_raw, f"Episode {episode_num}")
            filename_base = apply_template(
                show_template,
                series_title=series_title_clean,
                season=season,
                episode=episode_num,
                episode_title=episode_component,
            )
            filename = ensure_extension(filename_base, ".mkv", sanitize_maxlen)
            export_kind = "series_episode" if content_type == "serie" else None
            export_payload = {
                "series_title_raw": series_title_raw,
                "series_title_clean": series_title_clean,
                "season": season,
                "episode": episode_num,
                "episode_title_raw": nfo_title,
                "episode_title_component": episode_component,
                "runtime": runtime_minutes,
            }
        else:
            if content_type == "film":
                filename_base = apply_template(
                    bonus_template,
                    title=movie_title_clean or sanitize_filename(label_raw, sanitize_maxlen),
                    label=label_clean,
                )
                filename = ensure_extension(filename_base, ".mkv", sanitize_maxlen)
                nfo_title = f"{movie_title_raw} - Featurette - {label_raw}"
                export_kind = "movie_bonus"
                export_payload = {
                    "movie_title_raw": movie_title_raw,
                    "movie_title_clean": movie_title_clean,
                    "label_raw": label_raw,
                    "label_clean": label_clean,
                    "runtime": runtime_minutes,
                }
            elif content_type == "serie":
                if not series_title_raw:
                    series_title_raw = normalize_text(metadata.series_title, "Série")
                    series_title_clean = sanitize_filename(series_title_raw, sanitize_maxlen)
                specials_counter += 1
                season = specials_season
                episode_num = int(item.episode or specials_counter)
                label_display = normalize_text(label_raw, f"Bonus {episode_num}")
                label_component = sanitize_filename(label_display, sanitize_maxlen)
                filename_base = apply_template(
                    show_template,
                    series_title=series_title_clean,
                    season=season,
                    episode=episode_num,
                    episode_title=label_component,
                )
                filename = ensure_extension(filename_base, ".mkv", sanitize_maxlen)
                nfo_title = label_display
                export_kind = "series_special"
                export_payload = {
                    "series_title_raw": series_title_raw,
                    "series_title_clean": series_title_clean,
                    "season": season,
                    "episode": episode_num,
                    "episode_title_raw": label_display,
                    "episode_title_component": label_component,
                    "runtime": runtime_minutes,
                }
            else:
                filename_base = apply_template(
                    bonus_template,
                    title=sanitize_filename(label_raw, sanitize_maxlen),
                    label=label_clean,
                )
                filename = ensure_extension(filename_base, ".mkv", sanitize_maxlen)
                nfo_title = label_raw

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
            nfo_path = final_path.with_suffix(".nfo")
            if item.type == "episode" or export_kind in {"series_episode", "series_special"}:
                content = episode_nfo(
                    disc_uid,
                    series_title_raw or movie_title_raw,
                    int(export_payload.get("season", item.season or 0)),
                    int(export_payload.get("episode", item.episode or 0)),
                    export_payload.get("episode_title_raw", nfo_title),
                    runtime_minutes,
                    language,
                )
            else:
                content = movie_nfo(
                    disc_uid,
                    nfo_title,
                    year_value,
                    runtime_minutes,
                    language,
                )
            if write_sidecar(nfo_path, content):
                print(f"NFO écrit: {nfo_path}")
            else:
                print(f"NFO existant, ignoré: {nfo_path}")

        if export_kind:
            export_payload.update({
                "kind": export_kind,
                "source": final_path,
            })
            export_tasks.append(export_payload)

    print("--- Récapitulatif ---")
    print(f"Générés: {len(generated)}")
    for path in generated:
        print(f"  + {path}")
    if skipped:
        print(f"Ignorés (déjà présents): {len(skipped)}")
        for path in skipped:
            print(f"  = {path}")

    if export_enable:
        try:
            if content_type == "film":
                export_movie_items(
                    export_tasks,
                    export_movies_dir,
                    extras_subdir,
                    export_method,
                    disc_uid,
                    language,
                    year_value,
                    write_nfo,
                    sanitize_maxlen,
                )
            elif content_type == "serie":
                export_series_items(
                    export_tasks,
                    export_series_dir,
                    export_method,
                    disc_uid,
                    language,
                    year_value,
                    write_nfo,
                    sanitize_maxlen,
                )
            else:
                print(f"Export Jellyfin: type '{content_type}' ignoré")
        except Exception as exc:  # pragma: no cover - dépendances externes
            print(f"Erreur export Jellyfin: {exc}", file=sys.stderr)
            return 7
    else:
        print("Export Jellyfin désactivé (EXPORT_ENABLE=0)")

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
