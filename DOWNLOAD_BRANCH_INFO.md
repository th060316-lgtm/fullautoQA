# FullAutoQA lightweight real-machine finalization update

Authoritative main:
`17f6f9ba21adcdfbbc689e312072cb9841ac8461`

Strategic route:
- Issue #1 = Definition of Done / acceptance checklist / historical evidence authority.
- Issue #25 = current completion-route strategy authority.
- PR #28 merged the one-pass real-machine finalization route.

## Purpose

This branch is a lightweight overlay for a **previous complete FullAutoQA download that already contains the preserved donor blocks**. It avoids re-downloading the large preserved donor payload while replacing the managed current trees from authoritative main.

Managed trees:
- `開発版/source`
- `開発版/acceptance_targets`
- `開発版/transfer`
- `開発版/rollback`

It also updates:
- `RUN_LOCAL_COMPLETION.ps1`
- `RUN_LOCAL_COMPLETION.cmd`
- `README_LOCAL_COMPLETION.md`

The updater verifies copied file hashes and exact managed-tree file sets. It does **not** delete the preserved donor block payload outside those managed trees.

## Real-machine route

After `UPDATE PASS`:

1. Disconnect external network access.
2. Use a normal non-admin Windows account/session.
3. Run `RUN_LOCAL_COMPLETION.cmd` once.
4. Do not manually stop after an individual sub-result unless the machine itself becomes unsafe/unusable.
5. Preserve the generated sibling `LOCAL_FINAL_ACCEPTANCE_<RunTag>` directory whether PASS or FAIL.

The normal CMD entrypoint requires offline evidence and executes:

1. preserved v0.3.3 donor reconstruction
2. current Source reconstruction + Candidate build
3. fresh Candidate bundled Source regression
4. fresh Candidate START_QA selftest
5. fresh PoliticsTrasport → codegeas → PoliticsTrasport
6. fresh preserved-predecessor rollback restore + START_QA selftest
7. final local environment readback and combined gate decision

A technical local PASS requires Candidate/selftest/A-B-A/rollback PASS, standard-user execution, unchanged persistent user/machine PATH, and no up non-loopback IP interfaces observed at start, during all three Final runs, and at end.

## Scope limits

- A technical PASS is not automatically Human/Product/Stable/Release PASS.
- The current standard-user runner does not claim a complete Registry-write audit.
- Previous local evidence remains historical evidence; changed Candidate bytes require new Final evidence.
