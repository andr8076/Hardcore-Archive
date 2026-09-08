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

Missing frames, premature stream termination, malformed records, failed probes, inconsistent frame counts, or contradictory coverage evidence produce an evidence error. Evidence errors are not quality failures and therefore do not lower the VMAF target or trigger threshold relaxation. The existing pipeline preserves the original when evidence cannot authorize the completed output.

## Boundary tolerances

Video timestamps are discrete and container time bases can round seek/frame boundaries. The policy therefore uses small, explicit tolerances:

- **50 ms timeline-boundary tolerance** when deciding whether decoded display intervals establish the requested window start, an ordinary window end, or an internal continuity boundary.
- **100 ms stream-endpoint tolerance** only when the requested window reaches the declared source timeline endpoint.
- The expected VMAF frame population itself is counted from candidate frame timestamps in the requested half-open interval `[start, end)`, using only a **1 microsecond comparison epsilon** for floating-point representation. The wider 50 ms timeline tolerance is deliberately not used to count frames outside the requested window.
- **At most one frame VMAF-count tolerance** for a boundary-frame difference between independent `ffprobe` evidence and FFmpeg/libvmaf framesync, and only when the candidate window contains at least 30 frames. Sparse/low-frame-rate windows require an exact frame-count match.

These tolerances allow normal timestamp rounding without turning missing seconds into accepted coverage. Reported confirmed coverage is calculated from the actual intersected display intervals; the tolerance is used for acceptance decisions, not added to the reported coverage number.

Frame display duration is derived from the next decoded timestamp when available, otherwise from FFmpeg's per-frame duration metadata. The probe starts shortly before each requested window and can retry once up to 60 seconds farther back when sparse or genuinely low-frame-rate material needs an earlier display frame to establish coverage. This is bounded and does not change quality thresholds.

## Variable and low frame rates

Coverage does not assume 24, 30, 60, or any other fixed frame rate. It uses decoded timestamps and frame durations. Variable-frame-rate material can therefore have irregular frame spacing while still proving complete window coverage. Genuine low-frame-rate material is also supported when its timestamp/duration evidence shows how long each decoded frame is displayed.

The sustained-low-quality duration uses actual candidate frame display durations when the VMAF and candidate frame populations match exactly. If the only difference is an allowed single boundary frame, it falls back to the confirmed-window duration divided across scored frames; this is conservative boundary handling rather than a fixed-FPS assumption.

## Sampled vs full mode

In sampled mode, every selected window must independently establish complete evidence. The report shows both requested sampling coverage and confirmed quality coverage. Unsampled timeline regions remain unsampled.

In full mode, the sample plan requests the complete timeline, but the report only shows full confirmed coverage after decoded timestamp/duration evidence and VMAF frame evidence establish that the complete requested timeline was actually measured. Full mode remains substantially more expensive than sampled mode.

## Remaining limitations

`ffprobe` and libvmaf do not expose a shared per-score timestamp directly in the VMAF JSON used by this project. The evaluator therefore cross-checks libvmaf's contiguous frame sequence and count against independently decoded candidate-frame evidence. A one-frame boundary difference is tolerated only for windows with at least 30 candidate frames because seeking and time-base rounding can select one adjacent edge frame differently. Sparse windows require an exact count; larger differences always invalidate the window.

Very sparse media whose preceding display frame is more than 60 seconds before a sampled window and lacks usable frame-duration metadata may fail evidence validation conservatively. In that case the original is preserved rather than assuming coverage that cannot be demonstrated.
