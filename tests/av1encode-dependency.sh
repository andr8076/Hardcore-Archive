#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-av1encode-dependency.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

cat > "$TMP/AV1Encode.sh" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
    --machine-negotiate)
        if [[ ${FAKE_INCOMPATIBLE:-0} == 1 ]]; then
            printf '{"schema":"av1encode.negotiation","supported_protocol_versions":[1],"selected_protocol_version":null,"compatible":false}\n'
        else
            printf '{"schema":"av1encode.negotiation","supported_protocol_versions":[1,2],"selected_protocol_version":2,"compatible":true}\n'
        fi
        ;;
    --machine-probe)
        if [[ ${FAKE_NO_HARDWARE:-0} == 1 ]]; then auto=null; usable=false
        else auto='"av1_vaapi"'; usable=true
        fi
        printf '%s\n' "{\"schema\":\"av1encode.capabilities\",\"protocol_version\":2,\"supported_protocol_versions\":[1,2],\"tool\":{\"name\":\"AV1Encode\",\"version\":\"test-2\"},\"auto_encoder\":$auto,\"encoders\":[{\"name\":\"av1_vaapi\",\"class\":\"hardware\",\"auto_eligible\":true,\"usable\":$usable},{\"name\":\"libsvtav1\",\"class\":\"software\",\"auto_eligible\":false,\"usable\":true}]}"
        ;;
    --machine-evaluate)
        python3 - "$2" "$4" <<'PY'
import json, sys
requirements=json.load(open(sys.argv[1], encoding="utf-8"))
plan={
    "schema":"av1encode.plan", "protocol_version":2, "plan_id":"av1p_test",
    "requirements":requirements,
    "selection":{"encoder":"av1_vaapi","class":"hardware","policy_owner":"AV1Encode"},
    "prediction":{"size":{"predicted_output_bytes":12345},"speed":{"predicted_encode_seconds":6.5},"quality":{"predicted_score":97.25}},
    "execution":{"state":"ready","reason":None},
}
json.dump(plan, open(sys.argv[2], "w", encoding="utf-8"))
PY
        printf '{"schema":"av1encode.plan-reference","protocol_version":2,"plan_id":"av1p_test"}\n'
        ;;
    --execute-plan)
        python3 - "$2" "$4" <<'PY'
import json, os, sys
plan=json.load(open(sys.argv[1], encoding="utf-8"))
output=plan["requirements"]["output"]
open(output, "wb").write(b"validated-av1")
result={"schema":"av1encode.plan-result","protocol_version":2,"plan_id":plan["plan_id"],"status":"ok","exit_code":0,"output":os.path.realpath(output)}
json.dump(result, open(sys.argv[2], "w", encoding="utf-8"))
PY
        printf '{"schema":"av1encode.plan-result","status":"ok"}\n'
        ;;
    *) exit 2 ;;
esac
FAKE
chmod +x "$TMP/AV1Encode.sh"
: > "$TMP/source.mkv"

export HARDCORE_ARCHIVE_ROOT=$ROOT
export HARDCORE_ARCHIVE_AV1ENCODE=$TMP/AV1Encode.sh
source "$ROOT/lib/av1encode-dependency.sh"

hardcore_av1encode_negotiate
hardcore_av1encode_probe
[[ $HARDCORE_AV1ENCODE_AUTO_ENCODER == av1_vaapi ]]
[[ $HARDCORE_AV1ENCODE_AUTO_CLASS == hardware ]]
[[ $HARDCORE_AV1ENCODE_TOOL_VERSION == test-2 ]]
hardcore_av1encode_probe libsvtav1
[[ $HARDCORE_AV1ENCODE_SELECTED_ENCODER == libsvtav1 ]]
[[ $HARDCORE_AV1ENCODE_SELECTED_CLASS == software ]]
FAKE_NO_HARDWARE=1 hardcore_av1encode_probe libsvtav1
[[ -z $HARDCORE_AV1ENCODE_AUTO_ENCODER ]]
[[ $HARDCORE_AV1ENCODE_SELECTED_ENCODER == libsvtav1 ]]
[[ $HARDCORE_AV1ENCODE_SELECTED_CLASS == software ]]

requirements=$TMP/requirements.json
plan=$TMP/plan.json
result=$TMP/result.json
output=$TMP/output.mkv
hardcore_av1encode_write_requirements "$requirements" "$TMP/source.mkv" "$output" auto_hardware_only 92 null never 3
python3 - "$requirements" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
assert value["schema"] == "av1encode.requirements"
assert value["protocol_version"] == 2
assert value["hardware_policy"] == "auto_hardware_only"
assert value["quality"] == {
    "metric":"vmaf", "target":92.0, "p10_minimum":88.0,
    "sustained_floor":86.0, "maximum_sustained_seconds":1.0,
}
assert value["preservation"] == {"streams":"all", "chapters":True, "metadata":True}
assert value["audio"] == {"mode":"copy_all"}
assert value["video"] == {"maximum_height":None, "denoise":"never"}
PY

hardcore_av1encode_evaluate "$requirements" "$plan"
[[ $HARDCORE_AV1ENCODE_PLAN_ID == av1p_test ]]
[[ $HARDCORE_AV1ENCODE_PLAN_ENCODER == av1_vaapi ]]
[[ $HARDCORE_AV1ENCODE_PREDICTED_BYTES == 12345 ]]
[[ $HARDCORE_AV1ENCODE_PREDICTED_SECONDS == 6.5 ]]
[[ $HARDCORE_AV1ENCODE_PREDICTED_QUALITY == 97.25 ]]
hardcore_av1encode_execute "$plan" "$result" "$output"
[[ -s $output ]]

if FAKE_INCOMPATIBLE=1 hardcore_av1encode_negotiate; then
    printf 'Incompatible AV1Encode protocol was accepted.\n' >&2
    exit 1
fi
[[ $HARDCORE_AV1ENCODE_ERROR == *'protocol version 2'* ]]

# The final doctor override delegates AV1 only and preserves the existing HEVC
# probe implementation byte-for-byte at its process boundary.
(
    probe_hardware_encoder() { [[ $1 == hevc && $2 == hevc_vaapi ]]; }
    probe_software_encoder() { [[ $1 == hevc && $2 == libx265 ]]; }
    hardcore_video_encoder_class() {
        case $1 in av1_vaapi|hevc_vaapi) printf hardware ;; libsvtav1|libx265) printf software ;; *) return 1 ;; esac
    }
    source "$ROOT/lib/hardcore-archive-doctor-av1encode.sh"
    probe_hardware_encoder av1 av1_vaapi
    [[ $HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID == av1encode-test-2 ]]
    probe_software_encoder av1 libsvtav1
    probe_hardware_encoder hevc hevc_vaapi
    probe_software_encoder hevc libx265
)

printf 'AV1Encode dependency protocol tests passed.\n'
