# FullAutoQA lightweight download branch

This branch is an update pack for the local final-acceptance run.

Snapshot source main:
ed15668b339f7f29053ebaa780f80097c0f393e9

Purpose:
- Avoid downloading the ~1.1 GB main tree again.
- Reuse the heavy payload already present in a previous full download.
- Update the current Source, acceptance targets, recovery source archive, JOIN metadata, and local completion entrypoint.

This branch intentionally does NOT contain the large complete_v033/blocks payload.
It is therefore not standalone.

## Use

1. Download this branch as ZIP and extract it.
2. Keep your previous full download of fullautoQA; do not delete its complete_v033/blocks directory.
3. Run APPLY_UPDATE.cmd from this update pack.
   - If exactly one suitable previous full download exists beside this folder, it is selected automatically.
   - Otherwise drag the previous full download folder onto APPLY_UPDATE.cmd, or enter its path when prompted.
4. The updater copies files only and verifies copied bytes by SHA-256. It does not delete files from the target.
5. After UPDATE PASS, use RUN_LOCAL_COMPLETION.cmd inside the updated previous full download.
6. If the offline condition is being tested, disconnect external network access before starting RUN_LOCAL_COMPLETION.cmd.

The authoritative development state remains main. This branch is only a lightweight transport/update surface.
