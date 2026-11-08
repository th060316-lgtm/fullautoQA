# Local Final Completion

This entrypoint runs the current Source through Candidate rebuild, Source regression, fresh START_QA selftest, fresh PoliticsTrasport -> codegeas -> PoliticsTrasport, preserved-predecessor rollback qualification, and final environment readback on a standard Windows user session. GitHub-hosted checks are preflight only; this local run is the primary technical acceptance evidence.

## Run

1. Use a **fresh extraction of one complete self-contained FullAutoQA freeze** that contains the preserved donor blocks, transfer manifest, current Source, acceptance targets and rollback files. Do not overlay an update pack onto an older FullAutoQA tree and do not reuse a previously failed runnable tree.
2. Do not run as administrator.
3. Disconnect external network access before starting. The standard CMD entrypoint requires offline evidence; it does not treat an online run as final acceptance.
4. Run RUN_LOCAL_COMPLETION.cmd once. Do not manually stop after an individual sub-result: the runner gathers Candidate/selftest/A-B-A/rollback/environment evidence and makes the combined technical gate decision at the end.

The first optional argument is **not a single review JSON**. It is a schema-v1 series-review manifest used by the Sales headquarters:

    RUN_LOCAL_COMPLETION.cmd C:\path\to\series_reviews.json

The manifest may contain one review for A and one for B; the repeated final A exists for stale-state/reproducibility checking and does not invent a third duplicate human-playtest requirement. Each review entry is bound to its Final-series index/target key and must carry the exact frozen `target_fingerprint` and `game_id`. `candidate_sha256` is optional additional provenance; when supplied it must match the actual Candidate. Review attachment paths are relative to the manifest directory and are copied into the corresponding Run evidence before the Sales verdict is evaluated.

A minimal shape is:

```json
{
  "schema_version": 1,
  "series_reviews": [
    {
      "index": 1,
      "target_key": "A",
      "target_fingerprint": "<exact frozen A fingerprint>",
      "game_id": "<A game_id>",
      "review": {
        "schema_version": 1,
        "reviewer": {"kind": "human", "id": "<reviewer id>"},
        "human_test_performed": true,
        "sessions": [{
          "cold_start": true,
          "provenance": {"source": "human playtest"},
          "phases": {
            "first_30_seconds": {"status": "PASS", "evidence": ["evidence/a_30s.mp4"]},
            "first_5_minutes": {"status": "PASS", "evidence": ["evidence/a_5m.mp4"]},
            "product_shelf_test": {"status": "PASS", "evidence": ["evidence/a_shelf.png"]},
            "communication_readability": {"status": "PASS", "evidence": ["evidence/a_readability.txt"]}
          }
        }]
      }
    }
  ]
}
```

This is only the input contract; the example does not claim that any Human review has occurred. For Issue #1 completion, each distinct Final target must have valid Sales/Human coverage. Missing, malformed, cross-target or attachment-missing review evidence leaves the Sales/Human gate non-PASS and does not get converted into technical A-B-A PASS evidence. The exact supplied manifest is preserved in the series evidence, and the actual review/attachment bytes used by a Run are sealed inside that Run's `RESULT_FOR_CHATGPT.zip`.

The runner treats the repository as read-only input, creates a separate temporary physical workspace outside the repository, maps that workspace itself to a temporary free logical drive, and removes the mapping/workspace when the run ends. Preserved LOCAL_FINAL_ACCEPTANCE_<RunTag> evidence is written beside the repository rather than inside it. The download folder may remain where the user placed it; no manual relocation or fixed drive letter is required. The route does not intentionally require persistent PATH or Registry changes; acceptance of the stronger "no persistent change" claims depends on the recorded environment evidence and is never inferred from design intent alone.

## Handoff preflight

Before anything is built, step 0/8 resolves every declared input through one shared entry contract (`source/scripts/REPOSITORY_ENTRY.ps1`) and performs an aggregate handoff check. It verifies that the declared files/directories exist, that the Recovery Source SHA-256 matches the transfer manifest, that donor size/SHA/block-count declarations agree with the donor manifest, and that every declared donor block exists with its declared size:

- the donor complete set and its JOIN script,
- the recovery source archive and its declared SHA-256,
- the prepare, rebuild and fingerprint scripts,
- the acceptance plan and series controller,
- the rollback entrypoint.

The contract reads `transfer/TRANSFER_MANIFEST.json` explicitly as UTF-8 and resolves every path relative to the repository root, refusing any path that leaves it. The source-root directory is discovered structurally rather than by its name, because Windows PowerShell 5.1 reads a BOM-less script with the system ANSI code page: a non-ASCII directory name written literally inside a script is mojibake on a real machine while the same script still passes under PowerShell 7 in hosted CI. Every `.ps1` the route executes is therefore ASCII-only, and the source test suite enforces that invariant.

The expensive SHA-256 scan of all donor blocks and of the reconstructed large donor archive is deliberately not duplicated in step 0; `JOIN_COMPLETE.ps1` remains the authoritative implementation of those byte-identity checks immediately afterward.

If the preflight fails, `handoff_preflight` never becomes PASS and nothing is built.

## Evidence

The visible LOCAL_FINAL_ACCEPTANCE_<RunTag> directory beside the repository contains the summary and logs. Large/deep transient trees stay in the separate temporary work area and are never repository inputs. The run also rebuilds the last verified predecessor Candidate from the preserved historical Source/acceptance snapshot plus the byte-identical donor, restores that rebuilt predecessor into a fresh temporary directory, and executes its START_QA selftest; rollback evidence is preserved before cleanup. The raw donor is not called the predecessor Candidate, and a rebuilt ZIP is not called byte-identical to the historical ZIP unless its recorded size/SHA actually match. The runner exports compact evidence before cleanup:

- LOCAL_COMPLETION_SUMMARY.json
- Candidate build files under candidate_build/
- SELFTEST_RESULTS.zip when selftest results exist
- ABA_EVIDENCE.zip when series evidence exists
- three RunN_RESULT_FOR_CHATGPT.zip files after a complete A-B-A series
- rollback_predecessor/ qualification evidence and rollback result readback
- ROLLBACK_PREDECESSOR.log
- start/end and per-run network observations, plus ENVIRONMENT_CHANGE_MONITOR.json for continuous local-run network observation
- persistent user/machine PATH before/after comparison
- continuous HKCU/HKLM Registry subtree change notification and recursive Program Files filesystem monitoring
- SERIES_HQ_READBACK.json and the bounded ENVIRONMENT_AUDIT.json under series/
- step logs

A local technical PASS now requires: standard-user execution, Candidate/source/selftest/A-B-A success, preserved-predecessor rollback selftest PASS, unchanged persistent user/machine PATH, no Registry change notification anywhere under HKCU/HKLM for the monitored local-completion interval, no recursive Program Files change event or watcher error, and no external/default route observed by both the checkpoint evidence and the continuous network monitor. Local-only or virtual adapters may retain local addresses; those addresses alone are not treated as external connectivity. Monitor setup/readback failure is NOT_MEASURED and blocks the local technical PASS. None of these technical observations automatically promotes Human test, Product Acceptance, Stable, or Release.

## What the summary reports, and what it does not

`LOCAL_COMPLETION_SUMMARY.json` carries the technical verdict plus three groups of observations that are deliberately *not* folded into that verdict:

- `management_gate` and `sales_gate`: the verdicts of the Management and Sales headquarters, evaluated over the complete A-B-A series. The Management gate needs evidence that the *same target* behaved reproducibly across two independent fresh extractions; a single run can only observe its own seed replay, and the evaluator still refuses that narrower scope. The Sales gate stays NOT_RUN unless a review was ingested; a proxy review adds observations but never sets the human test.
- `independent_hq_final_verdict`: the combined series-level verdict of those two domains.
- `registry_write_audit` and `program_files_write_audit`: the unqualified Issue #1 claims from the continuous local-run monitor. Registry monitoring uses `RegNotifyChangeKeyValue` with subtree monitoring on HKCU and HKLM; Program Files monitoring uses recursive filesystem notifications on every discovered Program Files root. A monitor that cannot start, reports an error/buffer failure, or cannot be read back remains `NOT_MEASURED` and cannot satisfy the final local gate.
- `offline_continuous_audit`: the continuous network observation. It combines network-change events with 250 ms local interface sampling and fails if an up interface exposes a usable default gateway/external route. It does not fail merely because a local-only or virtual adapter retains a local IP address. It is required in addition to the existing start/per-run/end checkpoints when `-RequireOffline` is used.
- `registry_environment_audit` and `program_files_top_level_audit`: independent bounded before/after corroboration. The Registry observation covers the per-user/machine Environment keys and the Program Files observation covers only the top level of each Program Files root. Their exact scope is recorded in `environment_audit_scope`; these bounded fields never substitute for the continuous full-scope fields above.

`product_acceptance` and `stable` remain `HOLD` throughout this pre-freeze route. `human_test` remains `NOT_RUN` unless validated review evidence identifies a real human reviewer, records a cold-start session with provenance, and the Sales evaluator accepts that evidence. A model/proxy review can never set `human_test=PASS`.

## Offline observation

Offline acceptance is fail-closed in two independent layers. The checkpoint query inspects UP interfaces for usable default gateways; a query that fails is `NOT_MEASURED`, never "offline". In parallel, the local-completion process subscribes to network-change events and samples all local interfaces every 250 ms for the entire monitored interval. Any observed usable default gateway/external route fails the continuous audit, while a local-only address without such a route does not. The final local gate requires both the checkpoint sequence and the continuous audit when offline execution is requested.

## Source-tree identity

The prepared Source tree is identified by one canonical fingerprint (ordinal path order, LF-joined rows, UTF-8, SHA-256), computed by `source/scripts/SOURCE_TREE_FINGERPRINT.ps1`. The runner binds the baseline and the Candidate builder re-hashes the same tree with the same script, and the baseline is taken *after* the acceptance bundle is overlaid, because that is the tree the builder hashes. The summary declares the algorithm in `source_tree_fingerprint_algorithm`, and the hosted Windows PowerShell 5.1 job compares the PowerShell and Python implementations byte for byte.

## If the run fails

Keep the visible LOCAL_FINAL_ACCEPTANCE_<RunTag> directory and return it for diagnosis.
