"""Outils pour générer des fichiers NFO compatibles Jellyfin/Kodi."""
from __future__ import annotations

from pathlib import Path
import unicodedata

FORBIDDEN_CHARS = set('/\0<>:"\\|?*')


def _xml_escape(value: str) -> str:
    """Échappe les caractères XML réservés."""
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def sanitize(name: str, maxlen: int) -> str:
    """Nettoie un nom de fichier/dossier en respectant la longueur maximale."""
    text = unicodedata.normalize("NFC", (name or "").strip())
    text = text.replace("\n", " ").replace("\r", " ")
    cleaned = []
    for char in text:
        if char in FORBIDDEN_CHARS:
            cleaned.append("-")
        else:
            cleaned.append(char)
    text = "".join(cleaned)
    text = " ".join(text.split())
    text = text.rstrip(" .")
    if not text:
        text = "Sans titre"

    if maxlen > 0 and len(text) > maxlen:
        if "." in text:
            base, dot, ext = text.rpartition(".")
            if not base:
                text = text[:maxlen]
            else:
                available = maxlen - len(dot + ext)
                if available <= 0:
                    text = (base + dot + ext)[:maxlen]
                else:
                    text = base[:available].rstrip(" .") + dot + ext
        else:
            text = text[:maxlen].rstrip(" .")
        if not text:
            text = "Sans titre"
    return text


def movie_nfo(
    disc_uid: str,
    movie_title: str,
    year: int | None,
    minutes: int,
    language: str,
    premiered: str | None = None,
) -> str:
    """Construit le contenu XML d'un fichier NFO film."""
    year_text = str(year) if year else ""
    premiered_text = premiered or ""
    runtime_text = str(minutes) if minutes else ""
    language_text = language or ""
    title = _xml_escape(movie_title)
    return "\n".join(
        [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<movie>",
            f"  <title>{title}</title>",
            f"  <originaltitle>{title}</originaltitle>",
            f"  <sorttitle>{title}</sorttitle>",
            f"  <year>{_xml_escape(year_text)}</year>",
            f"  <premiered>{_xml_escape(premiered_text)}</premiered>",
            f"  <uniqueid type=\"disc_uid\" default=\"true\">{_xml_escape(disc_uid)}</uniqueid>",
            "  <plot></plot>",
            "  <outline></outline>",
            f"  <runtime>{_xml_escape(runtime_text)}</runtime>",
            "  <mpaa></mpaa>",
            "  <country></country>",
            "  <studio></studio>",
            "  <genre></genre>",
            f"  <tag>{_xml_escape(language_text)}</tag>",
            "</movie>",
            "",
        ]
    )


def tvshow_nfo(
    disc_uid: str,
    series_title: str,
    language: str,
    premiered_year: int | None = None,
) -> str:
    """Construit le contenu XML d'un fichier NFO série (tvshow.nfo)."""
    premiered_text = str(premiered_year) if premiered_year else ""
    title = _xml_escape(series_title)
    return "\n".join(
        [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<tvshow>",
            f"  <title>{title}</title>",
            f"  <sorttitle>{title}</sorttitle>",
            f"  <uniqueid type=\"disc_uid\" default=\"true\">{_xml_escape(disc_uid)}</uniqueid>",
            "  <plot></plot>",
            "  <mpaa></mpaa>",
            "  <studio></studio>",
            "  <genre></genre>",
            f"  <premiered>{_xml_escape(premiered_text)}</premiered>",
            f"  <tag>{_xml_escape(language)}</tag>",
            "</tvshow>",
            "",
        ]
    )


def episode_nfo(
    disc_uid: str,
    series_title: str,
    season: int,
    episode: int,
    ep_title: str,
    minutes: int,
    language: str,
    aired: str | None = None,
) -> str:
    """Construit le contenu XML d'un fichier NFO épisode."""
    aired_text = aired or ""
    runtime_text = str(minutes) if minutes else ""
    return "\n".join(
        [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<episodedetails>",
            f"  <title>{_xml_escape(ep_title)}</title>",
            f"  <season>{season}</season>",
            f"  <episode>{episode}</episode>",
            f"  <uniqueid type=\"disc_uid\" default=\"true\">{_xml_escape(disc_uid)}</uniqueid>",
            f"  <aired>{_xml_escape(aired_text)}</aired>",
            f"  <runtime>{_xml_escape(runtime_text)}</runtime>",
            "  <plot></plot>",
            f"  <showtitle>{_xml_escape(series_title)}</showtitle>",
            f"  <language>{_xml_escape(language)}</language>",
            "</episodedetails>",
            "",
        ]
    )


def write_text(path: Path, content: str) -> None:
    """Écrit le contenu UTF-8 sur disque en s'assurant de la présence du dossier parent."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


__all__ = [
    "sanitize",
    "movie_nfo",
    "tvshow_nfo",
    "episode_nfo",
    "write_text",
]
