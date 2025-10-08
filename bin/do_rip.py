#!/usr/bin/env python3
"""Automatisation du rip DVD avec MakeMKV (version Python).

Ce script reprend la logique historique de ``do_rip.sh`` mais en Python pour
faciliter la maintenance, améliorer la lisibilité et réduire les dépendances
externes. Il gère la détection du titre, l'identifiant de disque, la
journalisation, les garde-fous sur l'espace disque, le verrouillage par disque
et l'éjection automatique du média.
"""
from __future__ import annotations

import atexit
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Iterable

SECTOR_SIZE = 2048


class RipError(RuntimeError):
    """Erreur contrôlée pendant le rip."""


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        sys.stderr.write(
            f"Valeur invalide pour {name}={value!r}, fallback {default}\n"
        )
        return default


@dataclass
class Config:
    log: pathlib.Path = pathlib.Path(os.environ.get("LOG", "/var/log/dvd_rip.log"))
    device: pathlib.Path = pathlib.Path(os.environ.get("DEVICE", "/dev/sr0"))
    dest: pathlib.Path = pathlib.Path(os.environ.get("DEST", "/mnt/media_master"))
    min_free_gb: int = env_int("MIN_FREE_GB", 10)
    disc_hash_skip_sect: int = env_int("DISC_HASH_SKIP_SECT", 10)
    disc_hash_count_sect: int = env_int("DISC_HASH_COUNT_SECT", 200)
    disc_hash_trim: int = env_int("DISC_HASH_TRIM", 12)
    makemkv_opts: str = os.environ.get("MAKEMKV_OPTS", "-r mkv")
    ionice_class: int = env_int("IONICE_CLASS", 2)
    ionice_prio: int = env_int("IONICE_PRIO", 7)
    nice_prio: int = env_int("NICE_PRIO", 19)
    tmdb_api_key: str = os.environ.get("TMDB_API_KEY", "")
    tmdb_language: str = os.environ.get("TMDB_LANGUAGE", "fr-FR")
    tmdb_year_hint: str = os.environ.get("TMDB_YEAR_HINT", "")


def ensure_permissions(path: pathlib.Path, mode: int = 0o775) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, mode)
    except PermissionError:
        # On ignore si l'utilisateur actuel ne peut pas changer les droits.
        pass


_log_handle = None


def init_logging(log_path: pathlib.Path) -> None:
    global _log_handle
    ensure_permissions(log_path.parent)
    _log_handle = log_path.open("a", encoding="utf-8")


def close_logging() -> None:
    global _log_handle
    if _log_handle and not _log_handle.closed:
        _log_handle.flush()
        _log_handle.close()


def _write_log(message: str, prefix: str = "") -> None:
    if _log_handle is None:
        raise RuntimeError("log non initialisé")
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {prefix}{message}\n"
    _log_handle.write(line)
    _log_handle.flush()
    sys.stderr.write(line)
    sys.stderr.flush()


def log(message: str) -> None:
    _write_log(message)


def log_error(message: str) -> None:
    _write_log(message, prefix="ERROR: ")


def require_bins(*binaries: str) -> None:
    missing = [b for b in binaries if shutil.which(b) is None]
    if missing:
        raise RipError(f"binaire(s) manquant(s): {', '.join(missing)}")


def ensure_device(device: pathlib.Path) -> None:
    if not device.exists():
        raise RipError(f"périphérique introuvable: {device}")
    try:
        st = device.stat()
        if not stat.S_ISBLK(st.st_mode):
            raise RipError(f"{device} n'est pas un périphérique bloc")
    except OSError as exc:
        raise RipError(f"stat impossible sur {device}: {exc}") from exc


def check_free_space_gb(path: pathlib.Path) -> int:
    statvfs = os.statvfs(path)
    free_bytes = statvfs.f_bavail * statvfs.f_frsize
    return int(free_bytes / (1024 ** 3))


def run_command(cmd: Iterable[str], *, capture: bool = False, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), check=False, capture_output=capture, text=text)


def makemkv_disc_title(device: pathlib.Path) -> str:
    if shutil.which("makemkvcon") is None:
        return ""
    cmd = ["makemkvcon", "-r", "--cache=1", "info", f'dev:"{device}"']
    result = run_command(cmd, capture=True)
    if result.returncode != 0 or not result.stdout:
        return ""
    for line in result.stdout.splitlines():
        if line.startswith("CINFO:2,16,"):
            return _strip_quotes(line.split(",", 2)[-1])
    for line in result.stdout.splitlines():
        if line.startswith("TINFO:0,2,"):
            return _strip_quotes(line.split(",", 2)[-1])
    return ""


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    return value


def raw_disc_title(device: pathlib.Path) -> str:
    title = makemkv_disc_title(device)
    if title:
        return title

    result = run_command(["blkid", "-o", "value", "-s", "LABEL", str(device)], capture=True)
    if result.returncode == 0 and result.stdout:
        return result.stdout.strip()

    if shutil.which("volname") is not None:
        result = run_command(["volname", str(device)], capture=True)
        if result.returncode == 0 and result.stdout:
            return result.stdout.strip()

    return time.strftime("dvd_%Y%m%d_%H%M%S")


def transliterate(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    return "".join(ch for ch in normalized if not unicodedata.combining(ch))


def sanitize_title(raw: str) -> str:
    raw = transliterate(raw)
    raw = raw.replace(" ", "_")
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "", raw)
    return cleaned or time.strftime("dvd_%Y%m%d_%H%M%S")


def normalize_title(device: pathlib.Path) -> str:
    raw = raw_disc_title(device) or time.strftime("dvd_%Y%m%d_%H%M%S")
    return sanitize_title(raw)


def lookup_disc_metadata(cfg: Config, query: str) -> None:
    if not cfg.tmdb_api_key or not query:
        return
    params = {
        "api_key": cfg.tmdb_api_key,
        "query": query,
        "language": cfg.tmdb_language or "fr-FR",
    }
    if cfg.tmdb_year_hint:
        params["primary_release_year"] = cfg.tmdb_year_hint
    url = "https://api.themoviedb.org/3/search/movie?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        log(f"info: TMDb indisponible ({exc})")
        return

    results = data.get("results") or []
    if not results:
        log(f"info: TMDb n'a renvoyé aucun résultat pour '{query}'")
        return

    best = results[0]
    title = best.get("title") or best.get("original_title") or ""
    year = (best.get("release_date") or "")[:4]
    overview = (best.get("overview") or "").replace("\n", " ")
    if title:
        message = f"TMDb: {title}"
        if year:
            message += f" ({year})"
        if overview:
            message += f" — {overview[:160]}"
        log(message)
    else:
        log(f"info: TMDb aucun titre pertinent pour '{query}'")


def compute_disc_id(cfg: Config, title: str) -> str:
    md5 = hashlib.md5()
    md5.update(title.encode("utf-8"))
    try:
        with open(cfg.device, "rb", buffering=0) as device:
            device.seek(cfg.disc_hash_skip_sect * SECTOR_SIZE)
            to_read = cfg.disc_hash_count_sect * SECTOR_SIZE
            while to_read > 0:
                chunk = device.read(min(to_read, 1024 * 1024))
                if not chunk:
                    break
                md5.update(chunk)
                to_read -= len(chunk)
    except OSError as exc:
        raise RipError(f"lecture impossible sur {cfg.device}: {exc}") from exc

    digest = md5.hexdigest()
    if cfg.disc_hash_trim:
        return digest[: cfg.disc_hash_trim]
    return digest


def contains_mkv(path: pathlib.Path) -> bool:
    if not path.exists() or not path.is_dir():
        return False
    for item in path.iterdir():
        if item.is_file() and item.suffix.lower() == ".mkv":
            return True
    return False


def remove_empty_dir(path: pathlib.Path) -> None:
    try:
        path.rmdir()
    except OSError:
        pass


def build_makemkv_command(cfg: Config, output_dir: pathlib.Path) -> list[str]:
    cmd: list[str] = []
    if shutil.which("ionice") is not None:
        cmd.extend(["ionice", "-c", str(cfg.ionice_class), "-n", str(cfg.ionice_prio)])
    if shutil.which("nice") is not None:
        cmd.extend(["nice", "-n", str(cfg.nice_prio)])

    cmd.append("makemkvcon")
    cmd.extend(shlex.split(cfg.makemkv_opts))
    cmd.append(f'dev:"{cfg.device}"')
    cmd.append("all")
    cmd.append(str(output_dir))
    return cmd


def run_makemkv(cfg: Config, output_dir: pathlib.Path) -> int:
    cmd = build_makemkv_command(cfg, output_dir)
    log(f"Commande MakeMKV: {' '.join(cmd)}")
    if _log_handle is None:
        raise RuntimeError("log non initialisé")
    process = subprocess.Popen(
        cmd,
        stdout=_log_handle,
        stderr=_log_handle,
    )
    return process.wait()


def eject_device(device: pathlib.Path) -> None:
    if shutil.which("eject") is None:
        return
    run_command(["eject", str(device)], capture=False)


def main() -> int:
    cfg = Config()

    ensure_permissions(cfg.dest)
    init_logging(cfg.log)
    atexit.register(close_logging)

    log("Initialisation du rip DVD en Python")

    ensure_device(cfg.device)
    require_bins("dd", "md5sum", "makemkvcon")

    title = normalize_title(cfg.device)
    base_dir = cfg.dest / title
    ensure_permissions(base_dir)

    disc_id = compute_disc_id(cfg, title)
    out_dir = base_dir / disc_id
    log(f"Titre détecté: {title} ; DISC_ID={disc_id} ; Sortie: {out_dir}")

    lookup_disc_metadata(cfg, title)

    lock = out_dir / ".riplock"
    if lock.exists():
        log(f"Un rip est déjà en cours pour '{title}' (lock: {lock}). Abandon.")
        eject_device(cfg.device)
        return 0

    if contains_mkv(out_dir):
        log(f"Déjà rippé: {title} ({disc_id}) — MKV existants dans {out_dir}. Abandon.")
        eject_device(cfg.device)
        return 0

    ensure_permissions(out_dir)

    free_gb = check_free_space_gb(cfg.dest)
    if free_gb < cfg.min_free_gb:
        log_error(
            f"Espace insuffisant sur {cfg.dest}: {free_gb}GB libres, requis: {cfg.min_free_gb}GB"
        )
        remove_empty_dir(out_dir)
        eject_device(cfg.device)
        return 3
    log(f"Espace libre OK: {free_gb}GB (seuil: {cfg.min_free_gb}GB)")

    try:
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(str(int(time.time())), encoding="utf-8")
    except OSError as exc:
        raise RipError(f"création du lock impossible: {exc}") from exc

    def cleanup() -> None:
        if lock.exists():
            try:
                lock.unlink()
            except OSError:
                pass
        eject_device(cfg.device)

    try:
        status = run_makemkv(cfg, out_dir)
        if status != 0:
            log_error(f"Échec MakeMKV ({status}) pour {title} ({disc_id}).")
            if not contains_mkv(out_dir):
                remove_empty_dir(out_dir)
            return 2

        if not contains_mkv(out_dir):
            log_error(f"Aucun fichier .mkv trouvé dans {out_dir} alors que MakeMKV a terminé sans erreur.")
            return 4

        log(f"Rip terminé avec succès: {title} ({disc_id})")
        return 0
    finally:
        cleanup()


if __name__ == "__main__":
    try:
        exit_code = main()
    except RipError as err:
        if _log_handle is not None:
            log_error(str(err))
        else:
            sys.stderr.write(f"ERREUR: {err}\n")
        exit_code = 1
        eject_device(pathlib.Path(os.environ.get("DEVICE", "/dev/sr0")))
    except Exception as exc:  # pylint: disable=broad-except
        if _log_handle is not None:
            log_error(f"Exception inattendue: {exc}")
        else:
            sys.stderr.write(f"Exception inattendue: {exc}\n")
        exit_code = 1
        eject_device(pathlib.Path(os.environ.get("DEVICE", "/dev/sr0")))
    sys.exit(exit_code)
