# Local Final Completion

This entrypoint runs the current Source through Candidate rebuild, Source regression, fresh START_QA selftest, fresh PoliticsTrasport -> codegeas -> PoliticsTrasport, preserved-predecessor rollback qualification, and final environment readback on a standard Windows user session. GitHub-hosted checks are preflight only; this local run is the primary technical acceptance evidence.

## Run

1. Use a complete FullAutoQA download that contains the preserved donor blocks, or apply the lightweight download update pack to a previous complete download.
2. Do not run as administrator.
3. Disconnect external network access before starting. The standard CMD entrypoint now requires offline evidence; it does not treat an online run as final acceptance.
4. Run RUN_LOCAL_COMPLETION.cmd once. Do not manually stop after an individual sub-result: the runner gathers Candidate/selftest/A-B-A/rollback/environment evidence and makes the combined technical gate decision at the end.

The runner treats the repository as read-only input, creates a separate temporary physical workspace outside the repository, maps that workspace itself to a temporary free logical drive, and removes the mapping/workspace when the run ends. Preserved LOCAL_FINAL_ACCEPTANCE_<RunTag> evidence is written beside the repository rather than inside it. The download folder may remain where the user placed it; no manual relocation or fixed drive letter is required. It does not permanently change PATH or Registry values.

## Evidence

The visible LOCAL_FINAL_ACCEPTANCE_<RunTag> directory beside the repository contains the summary and logs. Large/deep transient trees stay in the separate temporary work area and are never repository inputs. The run also restores the preserved predecessor into a fresh temporary directory and executes its START_QA selftest; rollback evidence is preserved before cleanup. The runner exports compact evidence before cleanup:

- LOCAL_COMPLETION_SUMMARY.json
- Candidate build files under candidate_build/
- SELFTEST_RESULTS.zip when selftest results exist
- ABA_EVIDENCE.zip when series evidence exists
- three RunN_RESULT_FOR_CHATGPT.zip files after a complete A-B-A series
- rollback_predecessor/ qualification evidence and rollback result readback
- ROLLBACK_PREDECESSOR.log
- start/end network observations plus per-run network observations
- persistent user/machine PATH before/after comparison
- step logs

A local technical PASS now requires: standard-user execution, Candidate/source/selftest/A-B-A success, preserved-predecessor rollback selftest PASS, unchanged persistent user/machine PATH, and no up non-loopback IP interfaces observed at local-run start, throughout all three Final runs, and at local-run end. This is still not a complete Registry-write audit and does not automatically promote Human test, Product Acceptance, Stable, or Release.

If the run fails, keep the visible LOCAL_FINAL_ACCEPTANCE_<RunTag> directory and return it for diagnosis.
