"""Contract for the fail-closed offline observation.

The offline observation used to fail open.  The adapter address query ran
with ``-ErrorAction SilentlyContinue`` and with an ``Int32`` interface index,
which Windows PowerShell 5.1 rejects with "Argument types do not match".  The
silenced failure produced an empty address list, an empty address list was
counted as "no external address", and the machine was reported as offline
although nothing had been observed.

The rules under test:

* an address query that failed is NOT an offline machine;
* a machine with a non-loopback address on an Up adapter is not offline;
* the observation is reported with its own scope.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE_ROOT / 'CORE'))

import phase3_run_evidence  # noqa: E402

REPO_ROOT = SOURCE_ROOT.parents[1]
RUNNER = REPO_ROOT / 'RUN_LOCAL_COMPLETION.ps1'


def _observer_script():
    source = Path(phase3_run_evidence.__file__).read_text(encoding='utf-8')
    match = re.search(r'script = r"""(.*?)"""', source, re.S)
    assert match, 'the embedded observer script was not found'
    return match.group(1)


class OfflineObserverFailClosedTests(unittest.TestCase):
    def test_the_interface_index_is_cast_for_windows_powershell_51(self):
        script = _observer_script()
        self.assertIn('[uint32]$adapter.ifIndex', script,
                      'Windows PowerShell 5.1 rejects -InterfaceIndex with an Int32 value')

    def test_the_address_query_is_not_silenced(self):
        script = _observer_script()
        self.assertNotIn('Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue',
                         script)
        self.assertIn('Get-NetIPAddress -InterfaceIndex $index -ErrorAction Stop', script)

    def test_a_failed_address_query_is_reported(self):
        script = _observer_script()
        self.assertIn('ADDRESS_QUERY_FAILED', script)
        self.assertIn('ObjectNotFound', script,
                      'only a genuine "no address on this interface" may be tolerated')

    def test_the_python_wrapper_reports_not_measured_on_failure(self):
        source = Path(phase3_run_evidence.__file__).read_text(encoding='utf-8')
        self.assertIn('NETWORK_ADDRESS_QUERY_FAILED', source)
        self.assertIn('"status": "NOT_MEASURED"', source)

    def test_the_offline_signal_requires_a_measured_observation(self):
        source = Path(phase3_run_evidence.__file__).read_text(encoding='utf-8')
        self.assertIn('network.get("status") == "MEASURED"', source)
        self.assertIn('network.get("up_adapter_count") == 0', source)

    @unittest.skipIf(not RUNNER.is_file(),
                     'the repository checkout is not present (prepared Source tree)')
    def test_the_runner_observer_is_fail_closed_too(self):
        text = RUNNER.read_text(encoding='utf-8')
        self.assertIn('[uint32]$adapter.ifIndex', text)
        self.assertIn('Get-NetIPAddress -InterfaceIndex $index -ErrorAction Stop', text)
        self.assertIn('ADDRESS_QUERY_FAILED', text)
        self.assertIn("status='NOT_MEASURED'", text)
        self.assertNotIn('Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue',
                         text)


if __name__ == '__main__':
    unittest.main()
