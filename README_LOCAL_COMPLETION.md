# Local Final Completion

This entrypoint runs the current frozen Source through Candidate rebuild, Source regression, START_QA selftest, and fresh PoliticsTrasport -> codegeas -> PoliticsTrasport on a standard Windows user session.

## Run

1. Use a complete FullAutoQA download that contains the preserved donor blocks, or apply the lightweight download update pack to a previous complete download.
2. Do not run as administrator.
3. To validate offline operation at the same time, disconnect external network access before starting.
4. Run RUN_LOCAL_COMPLETION.cmd once.

The runner treats the repository as read-only input, creates a separate temporary physical workspace outside the repository, maps that workspace itself to a temporary free logical drive, and removes the mapping/workspace when the run ends. Preserved LOCAL_FINAL_ACCEPTANCE_<RunTag> evidence is written beside the repository rather than inside it. The download folder may remain where the user placed it; no manual relocation or fixed drive letter is required. It does not permanently change PATH or Registry values.

## Evidence

The visible LOCAL_FINAL_ACCEPTANCE_<RunTag> directory beside the repository contains the summary and logs. Large/deep transient trees stay in the separate temporary work area and are never repository inputs. The runner exports compact evidence before cleanup:

- LOCAL_COMPLETION_SUMMARY.json
- Candidate build files under candidate_build/
- SELFTEST_RESULTS.zip when selftest results exist
- ABA_EVIDENCE.zip when series evidence exists
- three RunN_RESULT_FOR_CHATGPT.zip files after a complete A-B-A series
- step logs

A technical series PASS does not automatically promote Human test, Product Acceptance, Stable, or Release.

If the run fails, keep the visible LOCAL_FINAL_ACCEPTANCE_<RunTag> directory and return it for diagnosis.
