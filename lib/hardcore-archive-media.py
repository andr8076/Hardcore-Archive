#!/usr/bin/env python3
"""Inspect unusual media and validate FFmpeg's stream/metadata round trip."""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
from typing import Any


FFPROBE = os.environ.get("FFPROBE", "ffprobe")


def probe(path: str) -> dict[str, Any]:
    command = [
        FFPROBE,
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-show_chapters",
        "-of",
        "json",
        path,
    ]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        value = json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"FFprobe could not inspect {path!r}: {exc}") from exc
    if not isinstance(value, dict) or not isinstance(value.get("streams", []), list):
        raise RuntimeError(f"FFprobe returned invalid media data for {path!r}")
    return value


def disposition(stream: dict[str, Any], name: str) -> bool:
    return bool(stream.get("disposition", {}).get(name, 0))


def primary_videos(data: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        stream
        for stream in data.get("streams", [])
        if stream.get("codec_type") == "video" and not disposition(stream, "attached_pic")
    ]


def classify(path: str) -> int:
    try:
        data = probe(path)
    except RuntimeError as exc:
        # An uninspectable video is itself special.  Preserve-by-default policy
        # must still be able to handle it safely instead of aborting the scan.
        print(str(exc))
        return 0

    streams = data.get("streams", [])
    videos = primary_videos(data)
    reasons: list[str] = []

    if len(videos) != 1:
        reasons.append(f"{len(videos)} primary video streams")
    if any(stream.get("codec_type") == "data" for stream in streams):
        reasons.append("embedded data streams")
    if any(disposition(stream, "attached_pic") for stream in streams):
        reasons.append("attached cover-art video")

    for stream in streams:
        codec_type = str(stream.get("codec_type", ""))
        codec = str(stream.get("codec_name", "")).lower()
        profile = str(stream.get("profile", "")).lower()
        tags = {str(k).lower(): str(v) for k, v in stream.get("tags", {}).items()}
        side_data = stream.get("side_data_list", []) or []
        side_text = " ".join(
            str(item.get("side_data_type", "")) + " " + json.dumps(item, sort_keys=True)
            for item in side_data
            if isinstance(item, dict)
        ).lower()

        if codec_type == "video":
            transfer = str(stream.get("color_transfer", "")).lower()
            primaries = str(stream.get("color_primaries", "")).lower()
            if transfer in {"smpte2084", "arib-std-b67"} or primaries == "bt2020":
                reasons.append("HDR video")
            if (
                str(stream.get("codec_tag_string", "")).lower() in {"dvh1", "dvhe"}
                or "dolby vision" in side_text
                or "dovi" in side_text
            ):
                reasons.append("Dolby Vision metadata")
            pixel_format = str(stream.get("pix_fmt", "")).lower()
            if pixel_format.startswith(("yuva", "gbrap")) or pixel_format in {
                "rgba",
                "bgra",
                "argb",
                "abgr",
                "pal8",
            }:
                reasons.append("video alpha channel")
            field_order = str(stream.get("field_order", "")).lower()
            if field_order not in {"", "unknown", "progressive"}:
                reasons.append("interlaced video")
            rotation = tags.get("rotate", "0")
            try:
                rotated = not math.isclose(float(rotation), 0.0, abs_tol=0.01)
            except ValueError:
                rotated = True
            if rotated or "display matrix" in side_text and "rotation of 0.00" not in side_text:
                reasons.append("display rotation metadata")
            if "spherical" in side_text or "stereo 3d" in side_text:
                reasons.append("360/3D projection metadata")

        if codec_type == "audio":
            if codec in {
                "truehd",
                "mlp",
                "dts",
                "flac",
                "alac",
                "wavpack",
                "ape",
                "tak",
            } or codec.startswith("pcm_"):
                reasons.append(f"lossless/object audio ({codec or 'unknown'})")
            joined = " ".join((profile, str(stream.get("channel_layout", "")).lower(), side_text))
            if any(term in joined for term in ("atmos", "ambisonic", "object based")):
                reasons.append("object/ambisonic audio")

        if codec_type == "subtitle" and codec in {
            "mov_text",
            "eia_608",
            "eia_708",
            "dvb_teletext",
            "arib_caption",
            "bin_data",
        }:
            reasons.append(f"container-sensitive subtitles ({codec})")

    if reasons:
        print("; ".join(dict.fromkeys(reasons)))
    return 0


MEANINGFUL_TAGS = {
    "language",
    "title",
    "filename",
    "mimetype",
    "artist",
    "album",
    "album_artist",
    "date",
    "year",
    "comment",
    "description",
    "copyright",
    "genre",
    "creation_time",
    "rotate",
}


def normalized_tags(value: dict[str, Any]) -> dict[str, str]:
    return {
        str(key).lower(): str(item)
        for key, item in value.get("tags", {}).items()
        if str(key).lower() in MEANINGFUL_TAGS
    }


def normalized_disposition(stream: dict[str, Any]) -> dict[str, int]:
    return {
        str(key): int(bool(value))
        for key, value in stream.get("disposition", {}).items()
        if value
    }


def grouped(data: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    groups = {"primary_video": [], "attached_video": [], "audio": [], "subtitle": [], "data": [], "attachment": []}
    for stream in data.get("streams", []):
        kind = stream.get("codec_type")
        if kind == "video":
            groups["attached_video" if disposition(stream, "attached_pic") else "primary_video"].append(stream)
        elif kind in groups:
            groups[kind].append(stream)
        else:
            groups.setdefault(str(kind), []).append(stream)
    return groups


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def validate(source_path: str, output_path: str) -> int:
    try:
        source = probe(source_path)
        output = probe(output_path)
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1

    source_groups = grouped(source)
    output_groups = grouped(output)
    errors: list[str] = []
    ordered_groups = ("primary_video", "attached_video", "audio", "subtitle", "data", "attachment")

    for name in ordered_groups:
        before = source_groups.get(name, [])
        after = output_groups.get(name, [])
        require(len(before) == len(after), f"{name} count changed ({len(before)} -> {len(after)})", errors)
        for index, (left, right) in enumerate(zip(before, after), start=1):
            label = f"{name} stream {index}"
            # The first primary video is intentionally transcoded.  Every
            # auxiliary video and non-audio stream must remain stream-copy.
            codec_may_change = name == "primary_video" and index == 1
            audio_may_change = name == "audio"
            if not codec_may_change and not audio_may_change:
                require(
                    left.get("codec_name") == right.get("codec_name"),
                    f"{label} codec changed ({left.get('codec_name')} -> {right.get('codec_name')})",
                    errors,
                )
            if name == "audio":
                require(left.get("channels") == right.get("channels"), f"{label} channel count changed", errors)
            if name == "primary_video" and index == 1:
                for field in ("color_range", "color_space", "color_transfer", "color_primaries", "chroma_location"):
                    before_value = left.get(field)
                    if before_value not in (None, "", "unknown"):
                        require(before_value == right.get(field), f"{label} {field} changed", errors)
            require(normalized_tags(left) == normalized_tags(right), f"{label} metadata changed", errors)
            require(
                normalized_disposition(left) == normalized_disposition(right),
                f"{label} dispositions changed",
                errors,
            )

    source_chapters = source.get("chapters", []) or []
    output_chapters = output.get("chapters", []) or []
    require(len(source_chapters) == len(output_chapters), "chapter count changed", errors)
    for index, (left, right) in enumerate(zip(source_chapters, output_chapters), start=1):
        require(normalized_tags(left) == normalized_tags(right), f"chapter {index} metadata changed", errors)
        for field in ("start_time", "end_time"):
            try:
                difference = abs(float(left.get(field, 0)) - float(right.get(field, 0)))
            except (TypeError, ValueError):
                difference = float("inf")
            require(difference <= 0.05, f"chapter {index} {field} changed", errors)

    require(normalized_tags(source.get("format", {})) == normalized_tags(output.get("format", {})), "global metadata changed", errors)

    if errors:
        print("Media preservation audit failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("Media preservation audit passed: streams, chapters, dispositions, and copyable metadata retained.")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] not in {"classify", "validate"}:
        print("usage: hardcore-archive-media.py classify FILE | validate SOURCE OUTPUT", file=sys.stderr)
        return 2
    if argv[1] == "classify" and len(argv) == 3:
        return classify(argv[2])
    if argv[1] == "validate" and len(argv) == 4:
        return validate(argv[2], argv[3])
    print("invalid arguments", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
