from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("pydantic", minversion="2")

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCAN_DIR = PROJECT_ROOT / "dvd-archiver" / "bin" / "scan"
if str(SCAN_DIR) not in sys.path:
    sys.path.insert(0, str(SCAN_DIR))

import validator  # type: ignore  # noqa: E402

MKV_CONSUMER = PROJECT_ROOT / "dvd-archiver" / "bin" / "mkv_build_consumer.sh"


@pytest.fixture()
def fake_makemkv(tmp_path: Path) -> Path:
    script = tmp_path / "makemkv"
    script.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "out_dir=\"${@: -1}\"\n"
        "title=\"\"\n"
        "for arg in \"$@\"; do\n"
        "  case \"$arg\" in\n"
        "    title:*) title=\"${arg#title:}\" ;;\n"
        "  esac\n"
        "done\n"
        "if [[ -z \"$title\" ]]; then\n"
        "  echo 'title index manquant' >&2\n"
        "  exit 1\n"
        "fi\n"
        "mkdir -p \"$out_dir\"\n"
        "touch \"$out_dir/title_${title}.mkv\"\n",
        encoding="utf-8",
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script


@pytest.fixture()
def base_env(tmp_path: Path, fake_makemkv: Path) -> dict[str, str]:
    build_queue = tmp_path / "queue"
    build_logs = tmp_path / "logs"
    tmp_dir = tmp_path / "tmp"
    build_queue.mkdir()
    build_logs.mkdir()
    tmp_dir.mkdir()

    env = os.environ.copy()
    env.update(
        {
            "BUILD_QUEUE_DIR": str(build_queue),
            "BUILD_LOG_DIR": str(build_logs),
            "TMP_DIR": str(tmp_dir),
            "PYTHON_BIN": sys.executable,
            "RAW_BACKUP_DIR": "raw/VIDEO_TS_BACKUP",
            "MAKEMKV_BIN": str(fake_makemkv),
            "MAKEMKV_MKV_OPTS": "",
            "WRITE_NFO": "0",
            "SCAN_MODULE_DIR": str(SCAN_DIR),
        }
    )
    return env


def write_metadata(path: Path, payload: dict[str, object]) -> None:
    meta = validator.validate_payload(payload)
    path.write_text(validator.dumps(meta) + "\n", encoding="utf-8")


def prepare_disc(tmp_path: Path, name: str) -> Path:
    disc_dir = tmp_path / name
    (disc_dir / "meta").mkdir(parents=True)
    (disc_dir / "raw" / "VIDEO_TS_BACKUP").mkdir(parents=True)
    return disc_dir


def enqueue_job(queue_dir: Path, disc_dir: Path) -> Path:
    job = queue_dir / f"BUILD_{disc_dir.name}.job"
    job.write_text(f'DISC_DIR="{disc_dir}"\n', encoding="utf-8")
    return job


def run_consumer(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(MKV_CONSUMER)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def test_mkv_build_consumer_generates_files(tmp_path: Path, base_env: dict[str, str]) -> None:
    env = base_env.copy()
    queue_dir = Path(env["BUILD_QUEUE_DIR"])
    disc_dir = prepare_disc(tmp_path, "DISC_VALID")
    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    payload = {
        "disc_uid": disc_dir.name,
        "content_type": "film",
        "movie_title": "Film Exemple",
        "series_title": None,
        "language": "fr",
        "year": 2008,
        "items": [
            {
                "type": "main",
                "title_index": 1,
                "runtime_seconds": 7200,
                "audio_langs": ["fr"],
                "sub_langs": [],
            }
        ],
        "mapping": {"title_1": "Main Feature"},
        "confidence": 0.9,
        "sources": {"ocr": None, "tech_dump": None, "llm": {}},
    }
    write_metadata(metadata_path, payload)
    enqueue_job(queue_dir, disc_dir)

    result = run_consumer(env)
    assert result.returncode == 0
    done_files = list(queue_dir.glob("*.done"))
    assert done_files, f"stdout={result.stdout}\nstderr={result.stderr}"
    mkv_files = list((disc_dir / "mkv").glob("*.mkv"))
    assert len(mkv_files) == 1
    assert mkv_files[0].name == "Film Exemple (2008).mkv"


def test_mkv_build_consumer_blocks_invalid_json(tmp_path: Path, base_env: dict[str, str]) -> None:
    env = base_env.copy()
    queue_dir = Path(env["BUILD_QUEUE_DIR"])
    disc_dir = prepare_disc(tmp_path, "DISC_INVALID")
    metadata_path = disc_dir / "meta" / "metadata_ia.json"
    invalid_payload = {
        "disc_uid": disc_dir.name,
        "content_type": "film",
        "movie_title": None,
        "series_title": None,
        "language": "fr",
        "year": None,
        "items": [
            {
                "type": "main",
                "title_index": 1,
                "runtime_seconds": 7200,
                "audio_langs": ["fr"],
                "sub_langs": [],
            }
        ],
        "mapping": {},
        "confidence": 0.2,
        "sources": {"ocr": None, "tech_dump": None, "llm": {}},
    }
    metadata_path.write_text(json.dumps(invalid_payload), encoding="utf-8")
    enqueue_job(queue_dir, disc_dir)

    result = run_consumer(env)
    assert result.returncode == 0
    err_files = list(queue_dir.glob("*.err"))
    assert err_files, f"stdout={result.stdout}\nstderr={result.stderr}"
    mkv_files = list((disc_dir / "mkv").glob("*.mkv"))
    assert not mkv_files
