# FullAutoQA lightweight download branch

This branch carries the current local final-acceptance update without the large donor block payload.

Snapshot source main:
16bcf4e209c4b65ca98273eb43ee47ab38dbae11

## Use

1. Download this branch as ZIP and extract it.
2. Run APPLY_UPDATE.cmd.
3. Enter the folder you want to update.
4. The updater only requires that the folder exists and is not the update package itself. It copies the current payload and SHA-256 verifies every copied file.
5. Run RUN_LOCAL_COMPLETION.cmd in the updated folder.

The local runner itself is responsible for discovering and validating the donor blocks, Source, acceptance bundle, Candidate integrity, selftest, and A-B-A requirements. The updater does not reject a folder based on guessed repository structure.

This branch intentionally omits complete_v033/blocks to keep the download small. A local run still needs those preserved donor blocks to exist in the updated folder because Candidate reconstruction actually consumes them.

Main remains authoritative. This branch is transport-only.
