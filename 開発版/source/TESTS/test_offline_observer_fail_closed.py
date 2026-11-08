"""Contract for the fail-closed offline observation.

A local-only or virtual adapter can keep a non-loopback IP address while the
machine has no external/default route. Offline acceptance must therefore
measure external routability rather than reject every local address.

The rules under test:

* an external-route query failure is NOT an offline machine;
* an UP interface with a usable default gateway is not offline;
* a local-only interface without a gateway does not fail offline acceptance;
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
    def test_observer_measures_default_gateway_not_local_ip_presence(self):
        script = _observer_script()
        self.assertIn('NetworkInterface]::GetAllNetworkInterfaces()', script)
        self.assertIn('GatewayAddresses', script)
        self.assertNotIn('Get-NetIPAddress', script)
        self.assertNotIn('UnicastAddresses', script)

    def test_a_failed_gateway_query_is_reported(self):
        self.assertIn('GATEWAY_QUERY_FAILED', _observer_script())

    def test_the_python_wrapper_reports_not_measured_on_failure(self):
        source = Path(phase3_run_evidence.__file__).read_text(encoding='utf-8')
        self.assertIn('NETWORK_GATEWAY_QUERY_FAILED', source)
        self.assertIn('"status": "NOT_MEASURED"', source)

    def test_the_offline_signal_requires_a_measured_route_observation(self):
        source = Path(phase3_run_evidence.__file__).read_text(encoding='utf-8')
        self.assertIn('network.get("status") == "MEASURED"', source)
        self.assertIn('network.get("external_route_count") == 0', source)
        self.assertIn('"scope": "no_external_default_route_observed"', source)

    @unittest.skipIf(not RUNNER.is_file(),
                     'the repository checkout is not present (prepared Source tree)')
    def test_the_runner_observer_uses_the_same_route_boundary(self):
        text = RUNNER.read_text(encoding='utf-8')
        self.assertIn('GatewayAddresses', text)
        self.assertIn('NetworkExternalRouteObserved', text)
        self.assertIn('NETWORK_GATEWAY_QUERY_FAILED', text)
        self.assertIn("status='NOT_MEASURED'", text)
        self.assertNotIn('NetworkAddressObserved', text)
        self.assertNotIn('UP_INTERFACE_WITH_NONLOOPBACK_ADDRESS_OBSERVED', text)


if __name__ == '__main__':
    unittest.main()
