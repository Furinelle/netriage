import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "compare-evidence.py"
SPEC = importlib.util.spec_from_file_location("compare_evidence", SCRIPT)
COMPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARE)
BEFORE = (Path(__file__).parent / "fixtures" / "iperf-window-before.log").read_text()
AFTER = (BEFORE.replace("1788220800", "1788220860")
         .replace("00:00:00 GMT", "00:01:00 GMT")
         .replace("20000000", "25000000").replace('"bytes": 25000000', '"bytes": 31250000')
         .replace("tx_bytes_delta=31000000", "tx_bytes_delta=40000000")
         .replace("total_interface_bytes_delta=31100000", "total_interface_bytes_delta=40100000")
         .replace('"local_port": 41000', '"local_port": 42000'))


def replace_json(text, edit):
    offset = text.index("{")
    value, end = json.JSONDecoder().raw_decode(text[offset:])
    edit(value)
    return text[:offset] + json.dumps(value) + text[offset + end:]


class CompareEvidenceTests(unittest.TestCase):
    def test_explicit_bound_source_route_uses_from_without_src(self):
        def bound(text):
            return (text.replace("route_source=<kernel-selected>", "route_source=192.0.2.10")
                    .replace("198.51.100.20 via", "198.51.100.20 from 192.0.2.10 via")
                    .replace(" src 192.0.2.10", ""))

        before, after = bound(BEFORE), bound(AFTER)
        self.assertTrue(COMPARE.compare(before, after)["comparable"])
        for text in (
            after.replace("from 192.0.2.10", "from 192.0.2.11"),
            after.replace("from 192.0.2.10", "from 192.0.2.10 src 192.0.2.11"),
            after.replace("route_source=192.0.2.10", "route_source=192.0.2.11"),
            after.replace(" from 192.0.2.10", ""),
        ):
            with self.subTest(route=text[:230]):
                report = COMPARE.compare(before, text)
                self.assertFalse(report["comparable"])
                self.assertNotIn("receiver_throughput", report)

    def test_kernel_fq_pacing_must_be_known_consistent_and_unchanged(self):
        def paced(data, rate=20000000):
            data["start"]["test_start"]["fqrate"] = rate
            data["start"]["fq_rate"] = rate

        self.assertTrue(COMPARE.compare(replace_json(BEFORE, lambda data: paced(data, 30000000)),
                                       replace_json(AFTER, lambda data: paced(data, 30000000)))["comparable"])
        for text in (
            replace_json(AFTER, paced),
            replace_json(AFTER, lambda data: data["start"]["test_start"].pop("fqrate")),
            replace_json(AFTER, lambda data: data["start"].pop("fq_rate")),
            replace_json(AFTER, lambda data: data["start"]["test_start"].update(fqrate=20000000)),
            replace_json(AFTER, lambda data: data["start"].update(fq_rate=20000000)),
            replace_json(AFTER, lambda data: data["start"].update(target_bitrate=20000000)),
        ):
            report = COMPARE.compare(BEFORE, text)
            self.assertFalse(report["comparable"])
            self.assertNotIn("receiver_throughput", report)

    def test_native_bidir_flag_must_explicitly_be_zero(self):
        for text in (
            replace_json(AFTER, lambda data: data["start"]["test_start"].pop("bidir")),
            replace_json(AFTER, lambda data: data["start"]["test_start"].update(bidir=1)),
        ):
            self.assertFalse(COMPARE.compare(BEFORE, text)["comparable"])

    def test_same_path_compares_receiver_rate_and_exposes_time_gap(self):
        report = COMPARE.compare(BEFORE, AFTER)
        self.assertTrue(report["comparable"])
        self.assertEqual(report["receiver_throughput"], {
            "unit": "bits_per_second", "before": 20000000, "after": 25000000,
            "delta": 5000000, "change_percent": 25,
        })
        self.assertEqual(report["sample_gap_seconds"], 60)
        self.assertEqual(report["identity"]["direction"], "send")
        self.assertEqual(report["host_counter_deltas"]["tcp_retrans_segs_delta"], {"before": 2, "after": 2})

    def test_changed_known_context_never_returns_a_percentage(self):
        variants = [
            AFTER.replace("host_id=relay-example", "host_id=other-host"),
            AFTER.replace("198.51.100.20", "198.51.100.21"),
            AFTER.replace("192.0.2.10", "192.0.2.11"),
            AFTER.replace("eth0", "eth1"),
            AFTER.replace('"remote_port": 5201', '"remote_port": 5202'),
            AFTER.replace('"reverse": 0', '"reverse": 1'),
            AFTER.replace('"omit": 2', '"omit": 0'),
            AFTER.replace('"duration": 10', '"duration": 5'),
            AFTER.replace('"target_bitrate": 30000000', '"target_bitrate": 40000000'),
            AFTER.replace('"protocol": "TCP"', '"protocol": "UDP"'),
            AFTER.replace('"bits_per_second":', '"bytes_per_second":'),
            AFTER.replace('"version": "iperf 3.17.1"', '"version": "iperf 3.18"'),
        ]
        for text in variants:
            with self.subTest(text=text[:100]):
                report = COMPARE.compare(BEFORE, text)
                self.assertFalse(report["comparable"])
                self.assertTrue(report["reasons"])
                self.assertNotIn("receiver_throughput", report)

    def test_incomplete_drifting_reset_and_failed_windows_are_rejected(self):
        variants = [
            AFTER.replace("host_id=relay-example\n", ""),
            AFTER.replace("sample_valid=yes", "sample_valid=no"),
            AFTER.replace("test_exit_status=0", "test_exit_status=1"),
            AFTER.replace("tc_topology_after_checksum=123456:25", "tc_topology_after_checksum=999999:25"),
            AFTER.replace("tc_topology_unchanged=yes", "tc_topology_unchanged=no"),
            AFTER.replace("route_after=198.51.100.20 via 192.0.2.1", "route_after=198.51.100.20 via 192.0.2.2"),
            AFTER.replace("rx_bytes_delta=100000", "rx_bytes_delta=-100000"),
            AFTER.replace("total_interface_bytes_delta=40100000", "total_interface_bytes_delta=1"),
            AFTER.replace("duration_seconds=12", "duration_seconds=-1"),
            AFTER.replace("duration_seconds=12", "duration_seconds=0"),
            AFTER.replace("1788220860", "1788220700"),
        ]
        for text in variants:
            with self.subTest(text=text[:100]):
                self.assertFalse(COMPARE.compare(BEFORE, text)["comparable"])

    def test_truncated_duplicate_and_error_json_are_rejected(self):
        offset = AFTER.index("{")
        value, end = json.JSONDecoder().raw_decode(AFTER[offset:])
        truncated = AFTER[:offset + end - 4] + AFTER[offset + end:]
        repeated = AFTER[:offset + end] + "\n" + json.dumps(value) + AFTER[offset + end:]
        failed = replace_json(AFTER, lambda data: data.update(error="test failed"))
        for text in (truncated, repeated, failed):
            self.assertFalse(COMPARE.compare(BEFORE, text)["comparable"])

    def test_streams_and_missing_pacing_metadata_are_rejected(self):
        def two_streams(data):
            data["start"]["test_start"]["num_streams"] = 2
            data["start"]["connected"].append(copy.deepcopy(data["start"]["connected"][0]))

        for text in (
            replace_json(AFTER, two_streams),
            replace_json(AFTER, lambda data: data["start"]["test_start"].pop("target_bitrate")),
            replace_json(AFTER, lambda data: data["end"]["sum_received"].update(bits_per_second=float("nan"))),
            replace_json(AFTER, lambda data: data["end"]["sum_received"].update(bits_per_second=10**1000)),
        ):
            self.assertFalse(COMPARE.compare(BEFORE, text)["comparable"])

    def test_zero_baseline_does_not_invent_percentage(self):
        before = replace_json(BEFORE, lambda data: data["end"]["sum_received"].update(bits_per_second=0))
        report = COMPARE.compare(before, AFTER)
        self.assertTrue(report["comparable"])
        self.assertIsNone(report["receiver_throughput"]["change_percent"])

    def test_percentage_overflow_is_not_a_valid_report(self):
        before = replace_json(BEFORE, lambda data: data["end"]["sum_received"].update(bits_per_second=1e-308))
        after = replace_json(AFTER, lambda data: data["end"]["sum_received"].update(bits_per_second=1e308))
        self.assertFalse(COMPARE.compare(before, after)["comparable"])

    def test_cli_uses_saved_files_and_returns_three_for_noncomparable(self):
        with tempfile.TemporaryDirectory() as temporary:
            before, after = Path(temporary) / "before.log", Path(temporary) / "after.log"
            before.write_text(BEFORE)
            after.write_text(AFTER)
            command = [sys.executable, str(SCRIPT), str(before), str(after)]
            valid = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertTrue(json.loads(valid.stdout)["comparable"])
            after.write_text("incomplete evidence")
            invalid = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(invalid.returncode, 3)
            self.assertFalse(json.loads(invalid.stdout)["comparable"])


if __name__ == "__main__":
    unittest.main()
