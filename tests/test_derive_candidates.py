import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "derive-candidates.py"
SPEC = importlib.util.spec_from_file_location("derive_candidates", SCRIPT)
assert SPEC and SPEC.loader
CALCULATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CALCULATOR
SPEC.loader.exec_module(CALCULATOR)


BASE_ARGS = [
    "--bandwidth-mbps",
    "1000",
    "--rtt-ms",
    "100",
    "--ram-mib",
    "1024",
    "--concurrency",
    "8",
    "--workload",
    "proxy",
    "--page-size",
    "4096",
]


def args_for(*extra: str):
    return CALCULATOR.parser().parse_args([*BASE_ARGS, *extra])


class DeriveCandidatesTests(unittest.TestCase):
    def test_target_page_size_and_concurrency_budget(self):
        report = CALCULATOR.derive(args_for())

        self.assertEqual(report.concurrency, 8)
        self.assertEqual(report.workload, "proxy")
        self.assertEqual(report.page_size_bytes, 4096)
        self.assertEqual(report.ram_quarter_budget_bytes, 256 * CALCULATOR.MIB)
        self.assertEqual(report.ram_quarter_budget_per_socket_bytes, 32 * CALCULATOR.MIB)
        self.assertEqual(report.ram_per_socket_cap_bytes, 32 * CALCULATOR.MIB)
        self.assertEqual(report.tcp_mem_candidate_pages, (16384, 32768, 65536))
        self.assertEqual(report.socket_max_candidate_bytes, 25_000_000)
        self.assertEqual(
            report.tcpfit_v0_5_7_competing_candidate_bytes,
            25_000_000 + 2 * CALCULATOR.MIB,
        )

    def test_explicit_concurrency_changes_the_per_socket_budget(self):
        for concurrency, expected_cap_mib in ((4, 64), (16, 16)):
            with self.subTest(concurrency=concurrency):
                argv = [*BASE_ARGS]
                argv[argv.index("--concurrency") + 1] = str(concurrency)
                report = CALCULATOR.derive(CALCULATOR.parser().parse_args(argv))
                self.assertEqual(
                    report.ram_per_socket_cap_bytes,
                    expected_cap_mib * CALCULATOR.MIB,
                )

    def test_nonfinite_bandwidth_and_rtt_are_rejected(self):
        for option in ("--bandwidth-mbps", "--rtt-ms"):
            for value in ("nan", "inf", "-inf"):
                with self.subTest(option=option, value=value):
                    argv = [*BASE_ARGS]
                    argv[argv.index(option) + 1] = value
                    with contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit):
                            CALCULATOR.parser().parse_args(argv)

    def test_unsupported_bdp_and_zero_per_socket_budget_are_rejected(self):
        bdp_argv = [*BASE_ARGS]
        bdp_argv[bdp_argv.index("--bandwidth-mbps") + 1] = "1e308"
        bdp_argv[bdp_argv.index("--rtt-ms") + 1] = "1e308"
        with self.assertRaisesRegex(ValueError, "unsupported BDP"):
            CALCULATOR.derive(CALCULATOR.parser().parse_args(bdp_argv))

        budget_argv = [*BASE_ARGS]
        budget_argv[budget_argv.index("--ram-mib") + 1] = "1"
        budget_argv[budget_argv.index("--concurrency") + 1] = "1000000"
        with self.assertRaisesRegex(ValueError, "at least one byte"):
            CALCULATOR.derive(CALCULATOR.parser().parse_args(budget_argv))

    def test_non_divisible_sweep_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "evenly divisible"):
            CALCULATOR.derive(
                args_for(
                    "--sweep-from",
                    "100",
                    "--sweep-to",
                    "250",
                    "--sweep-step",
                    "100",
                )
            )

    def test_legacy_role_alias_is_accepted_as_a_workload_class(self):
        argv = [*BASE_ARGS]
        argv[argv.index("--workload")] = "--role"
        self.assertEqual(CALCULATOR.parser().parse_args(argv).workload, "proxy")

    def test_sweep_payload_uses_the_complete_arithmetic_series(self):
        report = CALCULATOR.derive(
            args_for(
                "--sweep-from",
                "100",
                "--sweep-to",
                "300",
                "--sweep-step",
                "100",
                "--sweep-duration",
                "10",
                "--sweep-repeats",
                "2",
            )
        )

        self.assertEqual(report.sweep_step_count, 3)
        self.assertEqual(report.sweep_payload_estimate_gib, 1.397)


if __name__ == "__main__":
    unittest.main()
