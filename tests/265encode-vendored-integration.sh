#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ENCODER=$ROOT/vendor/265Encode/265Encode.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-265encode-vendored.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

[[ -x $ENCODER ]] || {
    printf '265Encode submodule is not initialized.\n' >&2
    exit 1
}
[[ $("$ENCODER" --interface-version) == 2 ]] || {
    printf 'Vendored 265Encode does not expose protocol 2.\n' >&2
    exit 1
}
"$ENCODER" --machine-negotiate 2 |
    python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["compatible"] is True and value["selected_protocol_version"] == 2'

command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || {
    printf 'ffmpeg and ffprobe are required for the vendored integration test.\n' >&2
    exit 1
}
ffmpeg -hide_banner -encoders 2>/dev/null |
    awk 'NF >= 2 && $2 == "libx265" {found=1} END {exit(found ? 0 : 1)}' || {
        printf 'The CI FFmpeg build must provide libx265.\n' >&2
        exit 1
    }

"$ENCODER" --machine-probe | python3 -c '
import json, sys
value=json.load(sys.stdin)
assert value["schema"] == "encode265.capabilities"
assert 2 in value["supported_protocol_versions"]
assert value["codec"] == "hevc"
features=value["features"]
required={
    "semantic_planning", "opaque_plan_id", "fingerprint_invalidation",
    "sampled_predictions", "semantic_requested_encoder", "semantic_quality_off",
    "semantic_scaling", "semantic_denoise", "semantic_audio_optimize",
    "preserve_all", "full_decode_validation", "legacy_intel_protocol2",
    "legacy_intel_auto_transparent",
}
assert all(features.get(name) is True for name in required)
records={item["name"]: item for item in value["encoders"]}
software=records["libx265"]
assert software["class"] == "software"
assert software["auto_eligible"] is False
assert software["usable"] is True
auto=value.get("auto_encoder")
assert auto is None or (
    records[auto]["class"] == "hardware" and records[auto]["usable"] is True
)
'

printf '1\n00:00:00,000 --> 00:00:00,800\nHEVC integration subtitle\n' > "$TMP/subtitle.srt"
printf 'attachment payload\n' > "$TMP/attachment.txt"
printf ';FFMETADATA1\ntitle=Vendored 265Encode integration\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=800\ntitle=Opening\n' > "$TMP/metadata.ffmeta"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=1' \
    -f lavfi -i 'sine=frequency=440:duration=1' \
    -f lavfi -i 'sine=frequency=880:duration=1' \
    -f srt -i "$TMP/subtitle.srt" \
    -f ffmetadata -i "$TMP/metadata.ffmeta" \
    -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:s:0 -map_chapters 4 -map_metadata 4 \
    -c:v ffv1 -c:a pcm_s16le -c:s srt \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=dan \
    -attach "$TMP/attachment.txt" -metadata:s:t mimetype=text/plain \
    "$TMP/source.mkv"

cat > "$TMP/requirements.json" <<JSON
{
  "schema": "encode265.requirements",
  "protocol_version": 2,
  "input": "$TMP/source.mkv",
  "output": "$TMP/output.mkv",
  "hardware_policy": "manual_software",
  "requested_encoder": "libx265",
  "quality": {
    "mode": "off",
    "metric": "vmaf",
    "target": 0,
    "p10_minimum": 0,
    "sustained_floor": 0,
    "maximum_sustained_seconds": 1
  },
  "optimization": {"primary": "smallest_output", "secondary": "fastest_encoding"},
  "video": {"maximum_height": 144, "denoise": "never"},
  "preservation": {"streams": "all", "chapters": true, "metadata": true},
  "audio": {"mode": "copy_all"},
  "evaluation": {"sample_seconds": 1}
}
JSON

"$ENCODER" --machine-evaluate "$TMP/requirements.json" --plan-json "$TMP/plan.json" >/dev/null
python3 - "$TMP/plan.json" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["protocol_version"] == 2
assert plan["selection"]["encoder"] == "libx265"
assert plan["selection"]["class"] == "software"
assert plan["execution"]["state"] == "ready"
assert plan["recipe"]["resolution"]["height"] == 144
assert plan["prediction"]["quality"]["metric"] == "disabled"
PY

"$ENCODER" --execute-plan "$TMP/plan.json" --result-json "$TMP/result.json" >/dev/null
[[ -s $TMP/output.mkv ]]

python3 - "$TMP/source.mkv" "$TMP/output.mkv" <<'PY'
import json, subprocess, sys

def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_chapters",
        "-show_format", "-of", "json", path,
    ], text=True))

source, output = map(probe, sys.argv[1:])
def counts(value):
    result={}
    for stream in value["streams"]:
        kind=stream["codec_type"]
        result[kind]=result.get(kind, 0)+1
    return result

assert counts(output) == counts(source)
primary=next(stream for stream in output["streams"] if stream["codec_type"] == "video")
assert primary["codec_name"] == "hevc" and primary["height"] == 144
audio=[stream for stream in output["streams"] if stream["codec_type"] == "audio"]
assert len(audio) == 2 and all(stream["codec_name"] == "pcm_s16le" for stream in audio)
assert [stream.get("tags",{}).get("language") for stream in audio] == ["eng", "dan"]
assert len(output.get("chapters", [])) == 1
assert output.get("format",{}).get("tags",{}).get("title") == "Vendored 265Encode integration"
PY

version=$("$ENCODER" --version)
printf 'Vendored 265Encode protocol-2 integration test passed for %s.\n' "$version"
