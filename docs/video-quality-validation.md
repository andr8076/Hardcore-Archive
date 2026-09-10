# Completed-output video quality coverage

Hardcore Archive separates encoder calibration from acceptance of the completed video. Calibration remains a cheap search aid. Acceptance measures the actual completed output against the original with the existing source-display-resolution VMAF graph, timestamp normalization, color/range normalization, and nearest-frame synchronization policy.

## Requested coverage vs confirmed coverage

The sample plan describes **requested coverage** only. A planned four-second window does not become four seconds of quality evidence merely because FFmpeg exits successfully or creates a non-empty VMAF log.

For every selected window, completed-output validation independently inspects decoded video-frame timestamps and durations from both the original and completed output using `ffprobe`. The evaluator builds display intervals from those observations, intersects the original and candidate timelines, and checks the VMAF log against the candidate frame population. Only a window whose timeline evidence and VMAF frame evidence are consistent contributes to **confirmed coverage**. If evidence is incomplete or contradictory, that window contributes zero confirmed quality coverage and cannot authorize the transcode.

This specifically prevents a one-frame VMAF log from claiming that an hour-long requested window was measured. A genuine one-frame-per-hour video can still be valid if decoded timestamp/duration evidence shows that the frame really represents that interval and the VMAF frame evidence is consistent with it.

## Evidence checks

Each completed-output window requires all of the following:

- Decoded timestamp evidence from both original and completed output.
- Monotonic frame timestamps.
- Display intervals that cover the requested window without unexplained gaps.
- A contiguous VMAF `frameNum` sequence.
- A VMAF pooled mean consistent with the per-frame VMAF values.
- A VMAF frame count consistent with the completed-output frames selected for the requested interval.
- An exact score-to-presentation mapping before the sustained-low-quality rule may use that window.

Missing frames, premature stream termination, malformed records, failed probes, inconsistent frame counts, missing frame-display timing, or contradictory coverage evidence produce an evidence error. Evidence errors are not quality failures and therefore do not lower the VMAF target or trigger threshold relaxation. The existing pipeline preserves the original when evidence cannot authorize the completed output.

## Boundary tolerances

Video timestamps are discrete and container time bases can round seek/frame boundaries. The policy therefore uses small, explicit tolerances:

- **50 ms timeline-boundary tolerance** when deciding whether decoded display intervals establish the requested window start, an ordinary window end, or an internal continuity boundary.
- **100 ms stream-endpoint tolerance** only when the requested window reaches the declared source timeline endpoint.
- Before measurement, sampled window starts are snapped backward to an independently decoded candidate-frame PTS. This avoids input-seek rounding disagreements on rates such as 24000/1001 without assuming an average frame rate. If that evidence cannot be obtained, the original deterministic start is retained and the later exact-match check still fails closed on disagreement.
- The expected VMAF frame population is counted from candidate frame timestamps in the snapped half-open interval `[start, end)`, using only a **1 microsecond comparison epsilon** for floating-point representation. The wider 50 ms timeline tolerance is deliberately not used to count frames outside the requested window.
- The coverage check may still tolerate at most one boundary-frame count difference for windows containing at least 30 candidate frames, but the sustained-low-quality rule does **not** guess a timing alignment from that difference. If VMAF and candidate frame populations do not match exactly, sustained timing evidence is unavailable and the window cannot authorize the output.

These tolerances allow normal timestamp rounding without turning missing seconds into accepted coverage. Reported confirmed coverage is calculated from the actual intersected display intervals; the tolerance is used for acceptance decisions, not added to the reported coverage number.

Frame display duration is derived from the next decoded presentation timestamp when available, otherwise from FFmpeg's per-frame duration metadata. The probe starts shortly before each requested window and can retry once up to 60 seconds farther back when sparse or genuinely low-frame-rate material needs an earlier display frame to establish coverage. This is bounded and does not change quality thresholds.

## VMAF score timing alignment

The VMAF JSON used by this project does not provide a trustworthy presentation timestamp for each score. `frameNum` is treated only as a sequence index; it is never interpreted as a timestamp.

The production comparison graph feeds every completed-output frame to libvmaf (`n_subsample=1`) after converting both inputs to a common AVTB and resetting each sampled window to a zero-based local timeline. It does not insert an FPS conversion. Separately, `ffprobe` reads the completed file's presentation timestamps. The video stream's `start_time` is subtracted so those observations are expressed on the same source-relative timeline used by the sample plan.

For sustained-quality timing, VMAF sequence record `i` is associated with candidate presentation interval `i` only when all of the following hold:

1. The VMAF sequence is contiguous from zero.
2. The number of VMAF records exactly equals the number of candidate frames selected in the snapped `[start, end)` window.
3. Every selected candidate frame has a valid display interval from its next presentation timestamp or explicit duration metadata.
4. The candidate presentation intervals remain ordered and the surrounding coverage evidence is valid.

If any of these conditions is missing, there is **no average frame rate** substituted for the missing timing. Hardcore Archive does not use a global average FPS or `window_length / frame_count`; the measurement fails closed and the original is preserved through the existing acceptance path.

## Sustained low quality on VFR footage

The configured VMAF threshold and sustained-low-quality settings are unchanged. A frame is locally low when its VMAF score is below `target - VIDEO_QUALITY_SUSTAINED_DELTA`; rejection still occurs when that degradation is sustained for at least `VIDEO_QUALITY_SUSTAINED_SECONDS`.

What changed is the clock used to measure that run. Each low VMAF score contributes its actual candidate frame display interval, not an average frame duration. This handles cases where a few frames remain on screen for a long time as well as bursts containing many rapidly displayed frames.

Sustained timing is evaluated across all confirmed sampled windows on the source-relative presentation timeline:

- Low-quality intervals that meet at an exactly shared sampled-window boundary join into one continuous run.
- An unsampled gap always breaks continuity; it is never filled by an average rate or boundary tolerance.
- Overlapping sampled windows are unioned as timeline intervals, so the same degraded time is not double-counted.
- An isolated low-scoring frame contributes only its actual display duration.

This means ten degraded frames can correctly represent two seconds on a VFR timeline even inside a 300-frame, ten-second measurement, while a much larger number of degraded frames can remain below the sustained rejection duration if they are displayed rapidly.

## Variable and low frame rates

Coverage and sustained-quality timing do not assume 24, 30, 60, or any other fixed frame rate. Both use decoded presentation timestamps and frame display durations. Variable-frame-rate material can therefore have irregular frame spacing while still proving complete window coverage. Genuine low-frame-rate material is also supported when its timestamp/duration evidence shows how long each decoded frame is displayed.

## Sampled vs full mode

In sampled mode, every selected window must independently establish complete evidence. The report shows both requested sampling coverage and confirmed quality coverage. Unsampled timeline regions remain unsampled.

In full mode, the sample plan requests the complete timeline, but the report only shows full confirmed coverage after decoded timestamp/duration evidence and VMAF frame evidence establish that the complete requested timeline was actually measured. Full mode remains substantially more expensive than sampled mode.

## Hosted CI validation

The `video-quality-integration` CI lane is intentionally stricter than the developer-facing unit suites. Each Linux and macOS hosted runner activates Hardcore Archive's checksum-verified downloaded media runtime, then verifies its `runtime-manifest.txt` against the FFmpeg and VMAF pins in `packaging/media-runtime/versions.env`. CI explicitly probes `ffmpeg`, `ffprobe`, the `libvmaf` filter, the fixture filters/encoder, and both production-selected legacy model families (`vmaf_v0.6.1` and `vmaf_4k_v0.6.1`) before real tests begin. A missing capability or a skipped required integration test fails that job.

The strict fixtures are deliberately small and software-generated. FFV1 is used only to create deterministic source/candidate media; it is **not** a production encoding fallback. The real-media suite calls the production completed-output comparison and acceptance functions and covers:

- faithful output acceptance;
- visible resolution degradation rejection on the source-display canvas;
- localized degradation in the 30% sampled window, outside the cheap 10/50/90% calibration positions;
- incomplete candidate/measurement rejection;
- variable-frame-rate presentation timing and sustained-low-quality rejection.

Passing this hosted CI lane demonstrates the CPU-side comparison, libvmaf models, timestamp/frame-evidence logic, sampling plan, and completed-output acceptance policy on standard GitHub Linux and macOS runners. It does **not** demonstrate vendor GPU drivers, hardware decoder/scaler behavior, VAAPI/NVENC/QSV/VideoToolbox encoder execution, device selection, or GPU-specific quality/performance. Those paths remain covered by policy/mocked tests in standard CI and require hardware-backed validation to prove real device behavior. The production hardware-only encoding policy is unchanged.

The ordinary `video-quality-performance.py` and `video-final-quality.py` suites retain conditional real-media skips so contributors can still run the broader test suite without downloading the managed media runtime. Strict no-skip behavior is confined to the dedicated CI integration lane.

## Remaining limitations

`ffprobe` and libvmaf do not expose a shared per-score timestamp directly in the VMAF JSON used by this project. The sustained rule therefore relies on a validated one-to-one sequence mapping between libvmaf records and independently decoded candidate presentation intervals. When an edge-frame disagreement prevents an exact mapping, the validator rejects the evidence conservatively instead of inventing timing from an average FPS.

Very sparse media whose preceding display frame is more than 60 seconds before a sampled window and lacks usable frame-duration metadata may fail evidence validation conservatively. In that case the original is preserved rather than assuming coverage or sustained-quality timing that cannot be demonstrated.
