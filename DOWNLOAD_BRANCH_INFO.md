# FullAutoQA lightweight local final-acceptance update

Authoritative main base:
`dcad269b21c81eb901d1965280264ce98b564a2c`

Open tactical PR:
`PR #23`

## 2026-11-06 repository-discovery correction

A new real-machine run stopped at stage 1/6 while preserving the previous failed run. The error path belonged to the earlier `.fqa_work_20261105T133102Z_d018dc3c/.../WORK/.../shader_cache` tree, not to the new donor reconstruction.

Root cause in the local runner: `Find-RepositoryFile` used repository-wide `Get-ChildItem -Recurse` and only filtered `.fqa_work_*` / `LOCAL_FINAL_ACCEPTANCE_*` after enumeration. PowerShell therefore entered the preserved old WORK tree before the exclusion could run and failed on a vanished Godot shader-cache path.

The runner now performs directory-by-directory discovery and prunes `.fqa_work_*`, `LOCAL_FINAL_ACCEPTANCE_*`, `.git`, and reparse directories before recursion. Previous failure evidence is preserved and must not need manual deletion for the next run.

A repository-discovery contract mode also verifies that authoritative markers win while duplicate markers inside preserved work/evidence trees are ignored. The previous case-insensitive filename matching behavior is retained.

The production fix does not change donor bytes, target repositories, Required gates, Evidence semantics, Candidate identity rules, or the frozen A->B->A contract.

`APPLY_UPDATE.ps1` and `APPLY_UPDATE.cmd` are intentionally unchanged from the previously Windows-validated updater. Their package-root traversal is not the observed target-repository failure path; changing the accepted updater without executable CI evidence would add risk at this stage.

GitHub-hosted jobs are still terminating before workflow steps execute (`steps=null`), so the new runner payload remains a real-machine acceptance candidate rather than a CI-validated PASS.

After `UPDATE PASS`, run `RUN_LOCAL_COMPLETION.cmd` from the updated complete local tree. Keep prior `LOCAL_FINAL_ACCEPTANCE_*` and `.fqa_work_*` evidence; the corrected runner is required to coexist with them.
