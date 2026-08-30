#!/usr/bin/env python3
"""Patch the stable runtime core for FFmpeg/VMAF and nested-report correctness."""
from __future__ import annotations
import os, pathlib, sys

MARKER = "# HARDCORE_MEDIA_NESTED_FIX_V1"

def fail(label: str, count: int) -> None:
    print(f"Error: media/nested engine patch failed: {label}: expected one anchor, found {count}", file=sys.stderr)
    raise SystemExit(1)

def repl(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(label, count)
    return text.replace(old, new, 1)

def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2
    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8"); os.chmod(dst, 0o700); return 0

    # Embedded FFmpeg capability checks must consume their full tables under pipefail.
    old = '''has_encoder() { ffmpeg -hide_banner -encoders 2>/dev/null | awk 'NF >= 2 {print $2}' | grep -Fxq "$1"; }
has_filter() { ffmpeg -hide_banner -filters 2>/dev/null | awk 'NF >= 2 {print $2}' | grep -Fxq "$1"; }'''
    new = MARKER + '''
has_encoder() { ffmpeg -hide_banner -encoders 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }
has_filter() { ffmpeg -hide_banner -filters 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }'''
    text = repl(text, old, new, "embedded FFmpeg table detection")

    # FFmpeg 9 VAAPI: use standard quality control explicitly in CQP mode.
    pairs = (
        ('probe_encoder_synthetic av1_vaapi -qp 33', 'probe_encoder_synthetic av1_vaapi -rc_mode CQP -global_quality:v 33', 'AV1 synthetic quality'),
        ('probe_encoder_synthetic hevc_vaapi -qp 28', 'probe_encoder_synthetic hevc_vaapi -rc_mode CQP -global_quality:v 28', 'HEVC synthetic quality'),
        ('video_crf="QP ${AV1_CRF}"; video_preset=\'N/A\'; video_pix_fmt=\'vaapi\'\n            encoder_args=("-qp" "$AV1_CRF")', 'video_crf="CQP ${AV1_CRF}"; video_preset=\'N/A\'; video_pix_fmt=\'vaapi\'\n            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$AV1_CRF")', 'AV1 runtime quality'),
        ('video_crf="QP ${HEVC_CRF}"; video_preset=\'N/A\'; video_pix_fmt=\'vaapi\'\n            encoder_args=("-qp" "$HEVC_CRF")', 'video_crf="CQP ${HEVC_CRF}"; video_preset=\'N/A\'; video_pix_fmt=\'vaapi\'\n            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$HEVC_CRF")', 'HEVC runtime quality'),
        ('if test_real_encode av1_vaapi av1 -qp "$AV1_CRF"; then apply_encoder av1_vaapi', 'if test_real_encode av1_vaapi av1 -rc_mode CQP -global_quality:v "$AV1_CRF"; then apply_encoder av1_vaapi', 'AV1 real-file probe'),
        ('elif test_real_encode hevc_vaapi hevc -qp "$HEVC_CRF"; then apply_encoder hevc_vaapi', 'elif test_real_encode hevc_vaapi hevc -rc_mode CQP -global_quality:v "$HEVC_CRF"; then apply_encoder hevc_vaapi', 'HEVC real-file probe'),
    )
    for old, new, label in pairs:
        text = repl(text, old, new, label)

    # Parse pooled_metrics.vmaf.mean specifically. Feature metrics also have a
    # field named mean, but use a 0..1 scale and caused values like 0.964 to be
    # compared against the real 0..100 VMAF threshold.
    text = repl(text,
        '''    if ffmpeg -hide_banner -filters 2>/dev/null | grep '[[:space:]]libvmaf[[:space:]]' >/dev/null; then''',
        '''    if has_filter libvmaf; then''', "VMAF filter check")
    old_score = '''            score=$(grep -Eo '\"mean\"[[:space:]]*:[[:space:]]*[0-9]+([.][0-9]+)?' "$log_file" 2>/dev/null | head -n1 | grep -Eo '[0-9]+([.][0-9]+)?' || true)'''
    new_score = '''            score=$(python3 - "$log_file" <<'PYVMAF'
import json, math, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as handle:
        value = float(json.load(handle)['pooled_metrics']['vmaf']['mean'])
    if math.isfinite(value) and 0.0 <= value <= 100.0:
        print(f'{value:.6f}')
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    pass
PYVMAF
)'''
    text = repl(text, old_score, new_score, "pooled VMAF extraction")
    old_ssim = '''    output=$(ffmpeg -hide_banner -nostdin -v info \\
        -ss "$start" -t "$length" -i "$input" -i "$encoded" \\
        -filter_complex "[0:v:0]setpts=PTS-STARTPTS,scale=${width}:${height}:flags=lanczos,format=yuv420p[ref];[1:v:0]setpts=PTS-STARTPTS,format=yuv420p[dist];[dist][ref]ssim" \\
        -an -f null - 2>&1 || true)
    score=$(grep -Eo 'All:[0-9]+([.][0-9]+)?' <<< "$output" | tail -n1 | cut -d: -f2 || true)
    if [[ $score =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        MEASURED_QUALITY_KIND=SSIM
        MEASURED_QUALITY_SCORE=$score
        return 0
    fi
    return 1'''
    text = repl(text, old_ssim, '''    # Strict quality policy: VMAF failure is a preflight failure; SSIM is not a fallback.
    return 1''', "remove SSIM quality fallback")

    # Preserve the candidate size and a reason for every nested-archive decision.
    text = repl(text,
        '''    local relative input extracted child_archive normalized output_rel full_output original_size output_size depth rc
    local expanded files encrypted free max_expanded''',
        '''    local relative input extracted child_archive normalized output_rel full_output original_size output_size candidate_size depth rc reason
    local expanded files encrypted free max_expanded candidate_display''', "nested locals")
    old_size = '''        if (( rc == 0 )) && [[ -s $full_output ]]; then output_size=$(stat -c '%s' -- "$full_output"); else output_size=$original_size; fi
        if (( rc == 0 && output_size < original_size )); then'''
    new_size = '''        if [[ -s $full_output ]]; then candidate_size=$(stat -c '%s' -- "$full_output"); else candidate_size=0; fi
        output_size=$original_size
        case $rc in
            0)  if (( candidate_size < original_size )); then reason='candidate-smaller'; else reason='candidate-not-smaller'; fi ;;
            90) reason='max-depth-reached' ;;
            91) reason='source-extraction-failed' ;;
            92)
                if [[ ${encrypted:-0} == 1 ]]; then reason='encrypted-archive'
                elif (( ${files:-0} > 100000 )); then reason='entry-count-limit'
                elif (( ${expanded:-0} > ${max_expanded:-0} )); then reason='insufficient-safe-extraction-space'
                elif (( original_size > 0 && ${expanded:-0}/original_size > 1000 )); then reason='unsafe-expansion-ratio'
                else reason='unsafe-or-unsupported'; fi ;;
            93) reason='child-extraction-failed' ;;
            94) reason='candidate-build-failed' ;;
            95) reason='candidate-integrity-failed' ;;
            *)  reason="recursive-archive-failed-rc-${rc}" ;;
        esac
        if (( rc == 0 && candidate_size < original_size )); then
            output_size=$candidate_size'''
    text = repl(text, old_size, new_size, "nested result classification")
    text = repl(text,
        '''            printf 'repacked\\t%s\\t%s\\t%s\\t%s\\n' "$relative" "$output_rel" "$original_size" "$output_size" >> "$NESTED_RESULT_MANIFEST"''',
        '''            printf 'repacked\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$relative" "$output_rel" "$original_size" "$candidate_size" "$output_size" "$reason" >> "$NESTED_RESULT_MANIFEST"''', "nested repacked row")
    old_fallback = '''            printf 'original\\t%s\\t%s\\t%s\\t%s\\n' "$relative" "$relative" "$original_size" "$original_size" >> "$NESTED_RESULT_MANIFEST"
            ((NESTED_FALLBACK_COUNT+=1))
        fi
        rm -rf --one-file-system -- "$extracted" "$normalized"; rm -f -- "$child_archive"'''
    new_fallback = '''            printf 'original\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$relative" "$relative" "$original_size" "$candidate_size" "$original_size" "$reason" >> "$NESTED_RESULT_MANIFEST"
            ((NESTED_FALLBACK_COUNT+=1))
        fi
        if (( candidate_size > 0 )); then candidate_display=$(human_bytes "$candidate_size"); else candidate_display='not produced'; fi
        printf 'Nested decision: %s | original %s | candidate %s | %s (%s)\\n' \\
            "$relative" "$(human_bytes "$original_size")" "$candidate_display" \\
            "$([[ $reason == candidate-smaller ]] && printf 'REPACKED' || printf 'PRESERVED')" "$reason"
        rm -rf --one-file-system -- "$extracted" "$normalized"; rm -f -- "$child_archive"'''
    text = repl(text, old_fallback, new_fallback, "nested fallback row/report")
    text = repl(text,
        '''{ printf 'action\\toriginal path\\tarchived path\\toriginal bytes\\tarchived bytes\\n'; cat "$NESTED_RESULT_MANIFEST"; }''',
        '''{ printf 'action\\toriginal path\\tarchived path\\toriginal bytes\\tcandidate bytes\\tarchived bytes\\treason\\n'; cat "$NESTED_RESULT_MANIFEST"; }''', "nested embedded header")
    text = repl(text,
        '''    local file_size relative source_path action original archived original_size archived_size data_path hash''',
        '''    local file_size relative source_path action original archived original_size candidate_size archived_size reason data_path hash''', "nested hash locals")
    text = repl(text,
        '''    while IFS=$'\\t' read -r action original archived original_size archived_size; do
        [[ -n $archived ]] || continue
        printf '%s\\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$NESTED_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi''',
        '''    while IFS=$'\\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $archived ]] || continue
        printf '%s\\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$NESTED_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi''', "nested hash reader")
    report = '''        if [[ -s $NESTED_RESULT_MANIFEST ]]; then
            printf '\\n===== Nested archive decisions =====\\n'
            printf 'action\\toriginal path\\tarchived path\\toriginal bytes\\tcandidate bytes\\tarchived bytes\\treason\\n'
            cat -- "$NESTED_RESULT_MANIFEST"
        fi
'''
    text = repl(text, '''        if [[ -s $IMAGE_LOG ]]; then
''', report + '''        if [[ -s $IMAGE_LOG ]]; then
''', "success report nested decisions")

    dst.write_text(text, encoding="utf-8"); os.chmod(dst, 0o700); return 0

if __name__ == "__main__":
    raise SystemExit(main())
