#!/usr/bin/env bash

# Versioned process boundary between Hardcore Archive and AV1Encode.
# Hardcore Archive supplies semantic requirements; encoder recipes remain
# private to AV1Encode and are never parsed here.
[[ ${HARDCORE_AV1ENCODE_DEPENDENCY_LOADED:-0} == 1 ]] && return 0
HARDCORE_AV1ENCODE_DEPENDENCY_LOADED=1

readonly HARDCORE_AV1ENCODE_PROTOCOL=2
HARDCORE_AV1ENCODE_COMMAND=()
HARDCORE_AV1ENCODE_ERROR=''
HARDCORE_AV1ENCODE_AUTO_ENCODER=''
HARDCORE_AV1ENCODE_AUTO_CLASS=''
HARDCORE_AV1ENCODE_SELECTED_ENCODER=''
HARDCORE_AV1ENCODE_SELECTED_CLASS=''
HARDCORE_AV1ENCODE_TOOL_VERSION=''
HARDCORE_AV1ENCODE_PLAN_ID=''
HARDCORE_AV1ENCODE_PLAN_ENCODER=''
HARDCORE_AV1ENCODE_PLAN_CLASS=''
HARDCORE_AV1ENCODE_PREDICTED_BYTES=''
HARDCORE_AV1ENCODE_PREDICTED_SECONDS=''
HARDCORE_AV1ENCODE_PREDICTED_QUALITY=''

hardcore_av1encode_resolve() {
    local root script path_prefix='' directory
    HARDCORE_AV1ENCODE_COMMAND=()
    HARDCORE_AV1ENCODE_ERROR=''
    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    script=${HARDCORE_ARCHIVE_AV1ENCODE:-$root/vendor/AV1Encode/AV1Encode.sh}
    if [[ ! -x $script ]]; then
        HARDCORE_AV1ENCODE_ERROR="AV1Encode dependency is missing or not executable: $script"
        return 1
    fi

    # The archive's managed FFmpeg is optimized for VMAF and may deliberately
    # lack a host GPU decoder. AV1Encode must probe and execute with the saved
    # host encoder runtime. Its own comparator still selects its verified VMAF
    # runtime when required.
    for directory in \
        "${HARDCORE_ARCHIVE_SYSTEM_FFMPEG:+$(dirname -- "$HARDCORE_ARCHIVE_SYSTEM_FFMPEG")}" \
        "${HARDCORE_ARCHIVE_SYSTEM_FFPROBE:+$(dirname -- "$HARDCORE_ARCHIVE_SYSTEM_FFPROBE")}"; do
        [[ -n $directory && -d $directory ]] || continue
        case :$path_prefix: in *":$directory:"*) ;; *) path_prefix="${path_prefix:+$path_prefix:}$directory" ;; esac
    done
    HARDCORE_AV1ENCODE_COMMAND=(env "PATH=${path_prefix:+$path_prefix:}$PATH" "$script")
}

hardcore_av1encode_negotiate() {
    local response parsed
    hardcore_av1encode_resolve || return 1
    if ! response=$("${HARDCORE_AV1ENCODE_COMMAND[@]}" --machine-negotiate "$HARDCORE_AV1ENCODE_PROTOCOL" 2>&1); then
        HARDCORE_AV1ENCODE_ERROR="AV1Encode protocol negotiation failed: $response"
        return 1
    fi
    parsed=$(python3 -c '
import json, sys
try:
    value=json.load(sys.stdin)
    ok=(value.get("schema")=="av1encode.negotiation" and value.get("compatible") is True and value.get("selected_protocol_version")==2)
except (ValueError, TypeError):
    ok=False
raise SystemExit(0 if ok else 1)
' <<< "$response" 2>/dev/null) || {
        HARDCORE_AV1ENCODE_ERROR='AV1Encode does not support required protocol version 2.'
        return 1
    }
}

hardcore_av1encode_probe() {
    local requested=${1:-} report parsed
    HARDCORE_AV1ENCODE_AUTO_ENCODER=''
    HARDCORE_AV1ENCODE_AUTO_CLASS=''
    HARDCORE_AV1ENCODE_SELECTED_ENCODER=''
    HARDCORE_AV1ENCODE_SELECTED_CLASS=''
    HARDCORE_AV1ENCODE_TOOL_VERSION=''
    hardcore_av1encode_negotiate || return 1
    if ! report=$("${HARDCORE_AV1ENCODE_COMMAND[@]}" --machine-probe 2>&1); then
        HARDCORE_AV1ENCODE_ERROR="AV1Encode capability probe failed: $report"
        return 1
    fi
    parsed=$(python3 -c '
import json, sys
try:
    value=json.load(sys.stdin)
    assert value.get("schema")=="av1encode.capabilities"
    assert 2 in value.get("supported_protocol_versions", [])
    name=value.get("auto_encoder") or ""
    records={item.get("name"): item for item in value.get("encoders", []) if isinstance(item, dict)}
    record=records.get(name, {})
    assert not name or (record.get("usable") is True and record.get("class")=="hardware" and record.get("auto_eligible") is True)
    requested=sys.argv[1]
    selected=records.get(requested, {}) if requested else record
    if requested:
        assert selected.get("usable") is True
    version=(value.get("tool") or {}).get("version", "")
    print("\x1f".join((str(name), str(record.get("class", "")), str(version),
                       str(requested or name), str(selected.get("class", "")))))
except (AssertionError, TypeError, ValueError):
    raise SystemExit(1)
' "$requested" <<< "$report" 2>/dev/null) || {
        HARDCORE_AV1ENCODE_ERROR='AV1Encode returned an invalid capability document.'
        return 1
    }
    IFS=$'\x1f' read -r HARDCORE_AV1ENCODE_AUTO_ENCODER HARDCORE_AV1ENCODE_AUTO_CLASS \
        HARDCORE_AV1ENCODE_TOOL_VERSION HARDCORE_AV1ENCODE_SELECTED_ENCODER \
        HARDCORE_AV1ENCODE_SELECTED_CLASS <<< "$parsed"
    if [[ -z $requested && -z $HARDCORE_AV1ENCODE_AUTO_ENCODER ]]; then
        HARDCORE_AV1ENCODE_ERROR='AV1Encode found no proven hardware AV1 encoder; CPU fallback remains disabled.'
        return 1
    fi
}

hardcore_av1encode_write_requirements() {
    local destination=$1 input=$2 output=$3 hardware_policy=$4 quality_target=$5
    local maximum_height=$6 denoise=$7 sample_seconds=${8:-3}
    python3 - "$destination" "$input" "$output" "$hardware_policy" "$quality_target" \
        "$maximum_height" "$denoise" "$sample_seconds" <<'PY'
import json, sys
path, source, output, hardware, target, maximum, denoise, seconds = sys.argv[1:]
target = float(target)
document = {
    "schema": "av1encode.requirements",
    "protocol_version": 2,
    "input": source,
    "output": output,
    "hardware_policy": hardware,
    "quality": {
        "metric": "vmaf",
        "target": target,
        "p10_minimum": max(0.0, target - 4.0),
        "sustained_floor": max(0.0, target - 6.0),
        "maximum_sustained_seconds": 1.0,
    },
    "optimization": {"primary": "smallest_output", "secondary": "fastest_encoding"},
    "video": {"maximum_height": None if maximum == "null" else int(maximum), "denoise": denoise},
    "preservation": {"streams": "all", "chapters": True, "metadata": True},
    "audio": {"mode": "copy_all"},
    "evaluation": {"sample_seconds": float(seconds)},
}
with open(path, "x", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

hardcore_av1encode_evaluate() {
    local requirements=$1 plan=$2 response parsed
    HARDCORE_AV1ENCODE_PLAN_ID=''
    hardcore_av1encode_negotiate || return 1
    if ! response=$("${HARDCORE_AV1ENCODE_COMMAND[@]}" --machine-evaluate "$requirements" --plan-json "$plan" 2>&1); then
        HARDCORE_AV1ENCODE_ERROR="AV1Encode evaluation failed: $response"
        return 1
    fi
    parsed=$(python3 - "$plan" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value=json.load(handle)
    assert value.get("schema")=="av1encode.plan" and value.get("protocol_version")==2
    assert (value.get("execution") or {}).get("state")=="ready"
    plan_id=value.get("plan_id", "")
    selection=value.get("selection") or {}
    prediction=value.get("prediction") or {}
    quality=prediction.get("quality") or {}
    size=prediction.get("size") or {}
    speed=prediction.get("speed") or {}
    assert plan_id.startswith("av1p_") and selection.get("class") in ("hardware", "software")
    print("\x1f".join(map(str, (
        plan_id, selection.get("encoder", ""), selection.get("class", ""),
        size.get("predicted_output_bytes", ""), speed.get("predicted_encode_seconds", ""),
        quality.get("predicted_score", ""),
    ))))
except (AssertionError, OSError, TypeError, ValueError):
    raise SystemExit(1)
PY
    ) || {
        HARDCORE_AV1ENCODE_ERROR='AV1Encode did not produce a valid executable protocol-v2 plan.'
        return 1
    }
    IFS=$'\x1f' read -r HARDCORE_AV1ENCODE_PLAN_ID HARDCORE_AV1ENCODE_PLAN_ENCODER \
        HARDCORE_AV1ENCODE_PLAN_CLASS HARDCORE_AV1ENCODE_PREDICTED_BYTES \
        HARDCORE_AV1ENCODE_PREDICTED_SECONDS HARDCORE_AV1ENCODE_PREDICTED_QUALITY <<< "$parsed"
}

hardcore_av1encode_execute() {
    local plan=$1 result=$2 expected_output=$3 response
    hardcore_av1encode_negotiate || return 1
    if ! response=$("${HARDCORE_AV1ENCODE_COMMAND[@]}" --execute-plan "$plan" --result-json "$result" 2>&1); then
        HARDCORE_AV1ENCODE_ERROR="AV1Encode execution failed: $response"
        return 1
    fi
    python3 - "$result" "$HARDCORE_AV1ENCODE_PLAN_ID" "$expected_output" <<'PY' || {
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value=json.load(handle)
    assert value.get("schema")=="av1encode.plan-result"
    assert value.get("protocol_version")==2 and value.get("status")=="ok"
    assert value.get("plan_id")==sys.argv[2]
    assert os.path.realpath(value.get("output", ""))==os.path.realpath(sys.argv[3])
    assert os.path.isfile(sys.argv[3]) and os.path.getsize(sys.argv[3])>0
except (AssertionError, OSError, TypeError, ValueError):
    raise SystemExit(1)
PY
        HARDCORE_AV1ENCODE_ERROR='AV1Encode returned an invalid execution result.'
        return 1
    }
}
