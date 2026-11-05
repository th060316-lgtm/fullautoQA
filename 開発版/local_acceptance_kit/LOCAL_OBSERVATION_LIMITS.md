# Local acceptance observations

The existing RUN_FINAL_ACCEPTANCE.cmd remains the only launch operation. Keep all files of this kit beside the frozen Candidate ZIP or its frozen parts. No Python/PowerShell package installation, network probe, elevation request, firewall change, PATH change, or Registry write is added by the observer.

launch_final_series.ps1 begins observation before Candidate validation/JOIN/extraction. A finally block writes LOCAL_ACCEPTANCE_READBACK.json in the displayed acceptance output directory, including when validation, extraction, or the series fails. An unreadable output directory or unavailable PowerShell runtime can prevent all output; a missing readback is NOT_RUN, never a successful local acceptance.

The controller action exit code remains the CMD exit status. A successful local observation does not change the frozen Candidate, result archives, Management final acceptance, Human status, Stable or Release.

| Observation | Evidence | Meaning and limit |
| --- | --- | --- |
| Standard user | WindowsPrincipal token at launcher boundaries; phase3_environment member in each of three result archives bound to SERIES_RECORDS SHA | PASS only for successful completion with all five observed tokens standard. Tokens of every child/target process and mid-run elevation are not monitored and remain NOT_RUN. |
| Persistent PATH | CurrentUser Environment and LocalMachine Session Manager Environment PATH value before/after fingerprints | Selected boundary equality only. Does not exclude temporary writes later restored, writes under other views/keys, or other machines. Missing/unreadable keys remain NOT_RUN. |
| Registry selected values | Root values of those same two Environment keys before/after aggregate fingerprints | Only those root values and the Default Registry view. Subkeys, other Registry areas, continuous write tracking, and Program Files remain NOT_RUN. |
| Network | Passive counts grouped by interface type/operational state at two boundaries | No adapter name, address, MAC, DNS or username is recorded. Even every interface reporting down does not prove full offline. Full offline always remains NOT_RUN. |
| Human / Management final | Explicit NOT_RUN / HOLD fields | This helper does not perform human evaluation or automatically accept all Management gates. |

Raw Registry value data and value names are kept only in process memory while hashing. Evidence contains one per-scope SHA-256 aggregate with a fresh invocation nonce, count and measurement status. The nonce is shared between the two boundaries to permit comparison and changes across invocations. Error messages from Registry calls or the controller action are reduced to fixed codes; private values or exception details are not written by this collector. The observer does not rewrite other existing series evidence or logs.

Use a Windows standard-user session and physically arrange the desired offline environment before the one launch. Such preparation is a user action; a passive network snapshot cannot certify it. Full Registry write auditing and complete network isolation require additional independent evidence and are not claimed by this kit. No such uncollected item may be treated as PASS merely because the technical series succeeds.

Tests in tests/test_local_acceptance_observer.ps1 exercise privacy, denied/unknown/missing boundaries, detected changes, all-interface-down nonproof, runner identity binding, and exception/failure finalization. Their fixtures are not local user-PC acceptance. Windows CI runs both the Windows PowerShell 5.1 parser and executable tests; hosted execution does not itself establish standard-user/offline acceptance.
