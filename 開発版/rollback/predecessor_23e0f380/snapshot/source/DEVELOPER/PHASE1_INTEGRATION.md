# Phase 1 source integration — 2026-11-02

Verdict: COMPLETE for the source integration scope. Issue #1 remains OPEN.
Product Acceptance / Stable remain HOLD; real-game acceptance remains 0/3.

## Resulting behavior

- Windows target runs freeze the manifest, capability requirements and target identities under the run lock before creating any target Session.
- Required capability absence blocks target execution. The frozen contract returns detached values rather than mutable shared dictionaries.
- Finalization verifies manifest, profile/source/config fingerprints, generation ledger and any prior result binding before report, evidence manifest or ZIP creation.
- Multiple identities serialize as a deterministic mapping. Frozen targets without an executed Session produce REQUIRED NOT_RUN.
- Regression checkpoint export/load carries the target identity and checks baseline lineage, including A→B→A replacement.
- The finalization refresh callback updates headquarters after cleanup/evidence/report failures. Diagnostic recovery archives retain headquarters/contract/identity payloads and never certify completion.
- Production results, management NOT_RUN and sales NOT_RUN remain independent. Completion certification stays false while management/sales are unevaluated.
- Dedicated fixture/adhoc functional certification is preserved while real-target and completion certification stay false. A fixture/selftest profile cannot be relabelled as a real target by its manifest.
- HTML/SUMMARY distinguish processing completion, target QA, headquarters completion and Product/Stable HOLD.

## Validation

From repository root:

```text
python -m unittest discover -s 開発版/source/TESTS -v
```

Final execution: 228 tests, 228 PASS, 0 failures, 0 errors, 0 skips (2.457 seconds).
This includes 21 new pipeline integration tests using synthetic temporary targets;
these tests do not establish real-game or Windows acceptance.

The first final full run reported 227 successful tests and one VIDEO_TIMING_INVALID
error in the existing, unchanged streaming-video test. Its isolated re-execution
passed (1 test), followed by the final full run above. The transient timing failure
is retained as a recording/reproducibility risk for full-candidate validation;
no recording threshold or integrity check was relaxed.

`python -m compileall -q 開発版/source/CORE 開発版/source/TESTS` passed.
`git diff --check` passed after preserving original bytes for unchanged files.

### Source test material

The repository source directory is a code-view subset. For the full suite, missing
original validation profiles, fixtures, baseline and manifests were restored locally
from `開発版/transfer/FullAutoQA_Recovery_Source_20261102.zip` without overwriting
existing source files. The ZIP's Git blob SHA was verified as
`5f5ea465e400e5e85c602c7ee19540698d6170e3`, matching the repository transfer.
The supplemental material is not duplicated in this commit.

To reproduce, extract that original ZIP to a separate temporary directory, overlay
the current `開発版/source/` contents onto it, and run unittest discovery against its
TESTS directory. This is a source test workspace, not a runnable full Candidate.
Do not regenerate or bypass CORE integrity checks merely to run the subset.

## Audit

Production implementation and QA were separate agents. Management performed a
read-only code/evidence audit; sales performed a model audit of report readability.
Findings about stale result rebinding, ledger corruption, unexecuted targets,
fixture functional certification and hidden NOT_RUN display were corrected.
This is not external-service QA or a human product test.

## NOT_RUN / pending for Issue #1

- Windows desktop E2E, JOIN_COMPLETE and fresh-extraction acceptance: NOT_RUN.
- Full runtime/payload Candidate rebuild and updated integrity manifests: PENDING.
- Actual game three-run acceptance: 0/3; actual A→B→A game E2E: NOT_RUN.
- Full management/sales evaluators, browser backend, observational agent learning,
  game-side storage QA and product-quality acceptance remain later Issue #1 work.
- The original v0.3.3 complete Candidate and its manifests were not rebuilt.
- main and 安定版 were not changed; PR #2 stays draft and unmerged.
