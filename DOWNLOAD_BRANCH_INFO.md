# FullAutoQA lightweight local final-acceptance update

Authoritative main snapshot:
`dcad269b21c81eb901d1965280264ce98b564a2c`

This branch is a small transport/update surface. It intentionally omits the large preserved donor block payload.

## Update behavior

`APPLY_UPDATE.cmd` updates an existing complete FullAutoQA download. It discovers the packaged Source, acceptance bundle and transfer tree from their structural marker files, removes only the corresponding destination trees, recreates them from this package, and verifies copied bytes. This prevents files removed from the current Source from surviving in an older local copy.

The preserved donor block payload is outside those managed trees and is retained. The updater does not require a particular drive letter, username, or localized directory literal in its PowerShell logic.

After `UPDATE PASS`, run `RUN_LOCAL_COMPLETION.cmd` from the updated complete download. Keep the large Candidate and per-run Result archives locally; upload `CHATGPT_EVIDENCE.zip` for review.

If the same run is intended to establish the offline condition, disconnect external network interfaces before starting the local runner. The runner only claims the locally observed network state actually recorded by the final runs.
