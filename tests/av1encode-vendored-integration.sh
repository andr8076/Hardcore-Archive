#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ENCODER=$ROOT/vendor/AV1Encode/AV1Encode.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-av1encode-vendored.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

[[ -x $ENCODER ]] || {
    printf 'AV1Encode submodule is not initialized.\n' >&2
    exit 1
}
[[ $("$ENCODER" --version) == 'AV1Encode.sh 1.5.0' ]] || {
    printf 'Hardcore Archive is not pinned to the required AV1Encode 1.5.0 release.\n' >&2
    exit 1
}
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || {
    printf 'ffmpeg and ffprobe are required for the vendored integration test.\n' >&2
    exit 1
}
ffmpeg -hide_banner -encoders 2>/dev/null |
    awk 'NF >= 2 && $2 == "libsvtav1" {found=1} END {exit(found ? 0 : 1)}' || {
        printf 'The CI FFmpeg build must provide libsvtav1.\n' >&2
        exit 1
    }

printf '1\n00:00:00,000 --> 00:00:00,800\nIntegration subtitle\n' > "$TMP/subtitle.srt"
printf 'attachment payload\n' > "$TMP/attachment.txt"
printf ';FFMETADATA1\ntitle=Vendored integration\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=800\ntitle=Opening\n' > "$TMP/metadata.ffmeta"

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

export HARDCORE_ARCHIVE_ROOT=$ROOT
source "$ROOT/lib/av1encode-dependency.sh"

hardcore_av1encode_probe libsvtav1
[[ $HARDCORE_AV1ENCODE_SELECTED_ENCODER == libsvtav1 ]]
[[ $HARDCORE_AV1ENCODE_SELECTED_CLASS == software ]]
[[ $HARDCORE_AV1ENCODE_TOOL_VERSION == 1.5.0 ]]

requirements=$TMP/requirements.json
plan=$TMP/plan.json
result=$TMP/result.json
output=$TMP/output.mkv
hardcore_av1encode_write_requirements "$requirements" "$TMP/source.mkv" "$output" \
    manual_software 0 144 required 1 archive_optimize libsvtav1 off
hardcore_av1encode_evaluate "$requirements" "$plan"
[[ $HARDCORE_AV1ENCODE_PLAN_ENCODER == libsvtav1 ]]
[[ $HARDCORE_AV1ENCODE_PLAN_CLASS == software ]]

python3 - "$plan" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["selection"] == {
    "encoder":"libsvtav1", "class":"software", "policy_owner":"AV1Encode",
}
assert plan["recipe"]["resolution"]["height"] == 144
assert plan["recipe"]["denoise"]["mode"] == "hqdn3d"
assert plan["recipe"]["audio"]["mode"] == "archive_optimize"
assert plan["prediction"]["quality"]["metric"] == "disabled"
PY

hardcore_av1encode_execute "$plan" "$result" "$output"
[[ -s $output ]]

python3 - "$TMP/source.mkv" "$output" <<'PY'
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
assert primary["codec_name"] == "av1" and primary["height"] == 144
audio=[stream for stream in output["streams"] if stream["codec_type"] == "audio"]
assert len(audio) == 2 and all(stream["codec_name"] == "opus" for stream in audio)
assert [stream.get("tags",{}).get("language") for stream in audio] == ["eng", "dan"]
assert len(output.get("chapters", [])) == 1
assert output.get("format",{}).get("tags",{}).get("title") == "Vendored integration"
PY

printf 'Vendored AV1Encode protocol-2 integration test passed.\n'
