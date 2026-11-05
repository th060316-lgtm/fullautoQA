# FullAutoQA lightweight download branch

This branch is an update pack for the local final-acceptance run.

Snapshot source main:
16bcf4e209c4b65ca98273eb43ee47ab38dbae11

Purpose:
- Avoid downloading the large main tree again.
- Reuse the preserved donor blocks already present in a previous complete download.
- Update the current Source, acceptance targets, recovery source archive, JOIN metadata, and local completion entrypoint.

This branch intentionally does not contain complete_v033/blocks and is not standalone.

## Use

1. Download this branch as ZIP and extract it.
2. Keep the previous complete FullAutoQA download that contains the donor blocks.
3. Run APPLY_UPDATE.cmd from this update pack.
4. After UPDATE PASS, run RUN_LOCAL_COMPLETION.cmd inside the updated complete download.
5. To validate offline operation at the same time, disconnect external network access before starting the local completion runner.

The local completion runner now creates and removes its own temporary logical workspace, so the user does not need to move the download folder to shorten build paths.

Main remains authoritative. This branch is transport-only.
