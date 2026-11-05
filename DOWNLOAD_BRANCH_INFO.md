# FullAutoQA lightweight local final-acceptance update

Authoritative Source/main base:
`dcad269b21c81eb901d1965280264ce98b564a2c`

Local runner tactical candidate:
`PR #23 / 285f46c88c25c9d3a35c54a89a047d37fbf3a633`

This branch is the transport surface for the open PR #23 real-machine tactical acceptance. It intentionally omits the large preserved donor block payload.

## Current PR #23 real-machine corrections

The previous real-machine cycle passed donor reconstruction, Candidate build/integrity and Source regression, then reached fresh START_QA selftest and launched Godot. The returned evidence exposed three connected Windows runtime/evidence-boundary defects plus one observation dependency:

- preserve the short logical repository spelling through CORE while proving containment through resolved filesystem identity;
- tolerate disappearance only for transient archive-ineligible WORK files during size/inventory scans, while genuine I/O and certified-evidence failures remain fatal;
- preserve certified selftest Result ZIP/readback and build diagnostic selftest archives without descending into volatile WORK/video_frames;
- remove the undeclared psutil dependency from Windows network observation; failed observation remains NOT_MEASURED.

These changes were independently reviewed by external Grok and then reworked/strengthened by the internal Production/Management/Sales review. The external patch was not applied verbatim.

## Validation state

GitHub-hosted jobs for the current head are presently failing at runner startup before workflow steps execute; job step data is absent and log retrieval returns BlobNotFound. Therefore those hosted results are not represented as Source test failures or PASS. The meaningful next validation is the Windows real-machine route using this transport package.

`APPLY_UPDATE.cmd` itself is unchanged from the previously Windows-validated updater. It replaces only the managed Source/acceptance/transfer trees and runner files while preserving the donor block payload.

After `UPDATE PASS`, run `RUN_LOCAL_COMPLETION.cmd`. Keep large Candidate/selftest/full-series archives locally and return `CHATGPT_EVIDENCE.zip`; its compact readback now includes selftest certified-result metadata as well as final-series readback.

Human/Product/Stable remain separate Issue #1 gates and are not certified by this update.
