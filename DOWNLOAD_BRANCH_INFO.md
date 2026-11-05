# FullAutoQA lightweight local final-acceptance update

Authoritative Source/main snapshot:
`dcad269b21c81eb901d1965280264ce98b564a2c`

Local runner tactical candidate:
`PR #23 / 298d124da38400c5ee08cd655da42a08386c8b88`

This branch is the transport surface for the open PR #23 real-machine tactical acceptance. It intentionally omits the large preserved donor block payload.

## Update behavior

`APPLY_UPDATE.cmd` updates an existing complete FullAutoQA download. It discovers the packaged Source, acceptance bundle and transfer tree from structural marker files, removes only the corresponding destination trees, recreates them from this package, and verifies copied bytes.

The preserved donor block payload is outside those managed trees and is retained. The runner change in PR #23 fixes native child-process exit-code capture under Windows PowerShell 5.1 and adds a contract test; it does not alter donor bytes, Source Required coverage, or the A-B-A contract.

After `UPDATE PASS`, run `RUN_LOCAL_COMPLETION.cmd` from the updated complete download. Keep the large Candidate and per-run Result archives locally; upload `CHATGPT_EVIDENCE.zip` for review.

If the same run is intended to establish the offline condition, disconnect external network interfaces before starting the local runner. The runner only claims the locally observed network state actually recorded by the final runs.

PR #23 remains open until the tactical real-machine acceptance objective is evaluated from returned evidence.
