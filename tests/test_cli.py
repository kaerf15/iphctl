"""Protocol regression checks that do not focus or operate the phone."""

import json
import os
import fcntl
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1) if len(sys.argv) > 1 else "iphctl").resolve())
CONTROL = tempfile.TemporaryDirectory(prefix="iphone-ct-protocol-")
ENV = {**os.environ, "IPHONE_CT_CONTROL_DIR": CONTROL.name}


def run(*args, input=None):
    return subprocess.run([BINARY, *args], input=input, capture_output=True, text=True, timeout=10, env=ENV)


class ProtocolTests(unittest.TestCase):
    def test_capabilities_and_help_work_without_phone(self):
        result = run("capabilities")
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["capabilities"]["swipe_vertical"]["status"], "unsupported")
        self.assertEqual(response["capabilities"]["scroll_vertical"]["status"], "conditional")
        self.assertEqual(response["capabilities"]["scroll_vertical"]["requires"], ["x", "y"])
        self.assertEqual(response["coordinate_space"], "window_screenshot_pixels")
        self.assertEqual(run("--help").returncode, 0)

    def test_vertical_swipes_fail_without_input_events(self):
        for direction in ("up", "down"):
            with self.subTest(direction=direction):
                result = run("swipe", direction)
                self.assertEqual(result.returncode, 1)
                response = json.loads(result.stdout)
                self.assertFalse(response["ok"])
                self.assertEqual(response["code"], "unsupported_gesture")
                self.assertFalse(response["event_sent"])

    def test_reject_invalid_coordinates_before_focusing(self):
        for args in (
            ("click", "-1", "10"),
            ("click", "nan", "10"),
            ("click", "10", "inf"),
            ("swipe", "left"),
            ("swipe", "right", "--y", "-1"),
            ("swipe", "left", "--y", "nan"),
            ("swipe", "left", "--y", "100", "--amount", "inf"),
            ("swipe", "left", "--y", "100", "--amount", "-1"),
            ("swipe", "left", "--y"),
            ("swipe", "left", "--amount", "oops"),
        ):
            with self.subTest(args=args):
                result = run(*args)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(json.loads(result.stdout)["ok"])

    def test_ndjson_recovers_from_bad_requests_and_blank_lines(self):
        requests = [
            {"id": "能力", "cmd": "capabilities"},
            {"id": 7, "cmd": "swipe", "direction": "up"},
            {"id": "bad-y", "cmd": "swipe", "direction": "left"},
            {"id": "last", "cmd": "capabilities"},
        ]
        payload = "\n" + json.dumps(requests[0]) + "\n\nnot json\n"
        payload += "\n".join(json.dumps(request) for request in requests[1:]) + "\n"
        result = run("agent", input=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 5)
        self.assertEqual(responses[0]["id"], "能力")
        self.assertFalse(responses[1]["ok"])
        self.assertEqual(responses[2]["id"], 7)
        self.assertEqual(responses[2]["code"], "unsupported_gesture")
        self.assertFalse(responses[3]["ok"])
        self.assertEqual(responses[3]["id"], "bad-y")
        self.assertTrue(responses[4]["ok"])
        self.assertEqual(responses[4]["id"], "last")

    def test_agent_keeps_ids_for_invalid_commands_and_parameters(self):
        requests = [
            {"id": "missing-cmd"},
            {"id": "invalid-y", "cmd": "swipe", "direction": "left", "y": "oops"},
            {"id": "invalid-amount", "cmd": "swipe", "direction": "left", "amount": "oops"},
            {"id": "numeric-string", "cmd": "swipe", "direction": "left", "y": "-1"},
        ]
        result = run("agent", input="\n".join(json.dumps(request) for request in requests))
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), len(requests))
        for request, response in zip(requests, responses):
            self.assertEqual(response["id"], request["id"])
            self.assertFalse(response["ok"])

    def test_scroll_rejects_bad_input_without_wheel_events(self):
        for params in (
            (), ("up",), ("up", "--x", "10"), ("up", "--x", "10", "--y"),
            ("sideways", "--x", "10", "--y", "10"),
            ("down", "--x", "-1", "--y", "10"),
            ("down", "--x", "nan", "--y", "10"),
            ("down", "--x", "10", "--y", "inf"),
            ("up", "--x", "10", "--y", "10", "--amount", "0"),
            ("up", "--x", "10", "--y", "10", "--amount", "-1"),
            ("up", "--x", "10", "--y", "10", "--amount", "8193"),
            ("up", "--x", "10", "--y", "10", "--amount", "nan"),
            ("up", "--x", "10", "--y", "10", "--amount", "oops"),
            ("up", "--x", "10", "--y", "10", "--amount"),
            ("up", "--x", "10", "--y", "10", "--unknown", "1"),
            ("up", "--x", "10", "--y", "10", "--x", "20"),
        ):
            with self.subTest(params=params):
                result = run("scroll", *params)
                self.assertEqual(result.returncode, 1)
                response = json.loads(result.stdout)
                self.assertFalse(response["ok"])
                self.assertFalse(response["event_sent"])
                self.assertEqual(response["reports"], 0)
                self.assertFalse(response["verified"])

    def test_agent_scroll_errors_preserve_ids_and_continue(self):
        requests = [
            {"id": "missing-y", "cmd": "scroll", "direction": "up", "x": 10},
            {"id": "invalid-x", "cmd": "scroll", "direction": "up", "x": "nan", "y": 10},
            {"id": "bool", "cmd": "scroll", "direction": "up", "x": True, "y": 10},
            {"id": "large-amount", "cmd": "scroll", "direction": "up", "x": 10, "y": 10, "amount": 1e100},
            {"id": "last", "cmd": "capabilities"},
        ]
        result = run("agent", input="\n".join(json.dumps(request) for request in requests))
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), len(requests))
        for request, response in zip(requests[:-1], responses[:-1]):
            self.assertEqual(response["id"], request["id"])
            self.assertFalse(response["ok"])
            self.assertFalse(response["event_sent"])
            self.assertEqual(response["reports"], 0)
        self.assertEqual(responses[-1]["id"], "last")
        self.assertTrue(responses[-1]["ok"])

    def test_pause_blocks_all_input_commands_before_operating_phone(self):
        try:
            self.assertTrue(json.loads(run("pause").stdout)["paused"])
            for args in (
                ("click", "10", "20"), ("swipe", "left", "--y", "100"),
                ("scroll", "up", "--x", "10", "--y", "20"),
                ("paste", "test"), ("key", "return"), ("home",),
                ("open", "test"), ("connect",),
            ):
                with self.subTest(args=args):
                    response = json.loads(run(*args).stdout)
                    self.assertEqual(response["code"], "paused")
                    self.assertFalse(response["event_sent"])
        finally:
            self.assertFalse(json.loads(run("resume").stdout)["paused"])

    def test_external_process_lock_refuses_input_and_does_not_block_cancel(self):
        with open(Path(CONTROL.name) / "input.lock", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            response = json.loads(run("key", "return").stdout)
            self.assertEqual(response["code"], "busy")
            self.assertFalse(response["event_sent"])
            self.assertTrue(json.loads(run("cancel").stdout)["ok"])

    def test_control_commands_preserve_request_ids(self):
        requests = [{"id": command, "cmd": command} for command in ("pause", "cancel", "resume")]
        result = run("agent", input="\n".join(json.dumps(r) for r in requests))
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([r["id"] for r in responses], [r["id"] for r in requests])
        self.assertTrue(all(r["ok"] and not r["event_sent"] for r in responses))
        self.assertFalse(responses[-1]["paused"])

    def test_simultaneous_first_launch_creates_private_control_state(self):
        with tempfile.TemporaryDirectory(prefix="iphone-ct-startup-") as parent:
            folder = Path(parent) / "control"
            env = {**ENV, "IPHONE_CT_CONTROL_DIR": str(folder)}
            processes = [subprocess.Popen([BINARY, "cancel"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
                         for _ in range(12)]
            for process in processes:
                output, error = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, error or output)
                self.assertTrue(json.loads(output)["ok"])
            self.assertEqual(json.loads((folder / "state.json").read_text())["generation"], 12)
            self.assertEqual(folder.stat().st_mode & 0o777, 0o700)

    def test_shared_parser_and_snapshot_reject_invalid_input(self):
        for args in (
            ("click", "1", "2", "--snapshot"), ("click", "1", "2", "--unknown", "x"),
            ("swipe", "left", "--y", "100", "--snapshot", ""),
            ("scroll", "up", "--x", "1", "--y", "2", "--invert", "--invert"),
            ("shot", "--out"), ("pause", "unexpected"),
        ):
            with self.subTest(args=args):
                response = json.loads(run(*args).stdout)
                self.assertFalse(response["ok"])
                self.assertFalse(response["event_sent"])
        requests = [
            {"cmd": "click", "x": True, "y": 2},
            {"cmd": "click", "x": 1, "y": 2, "snapshot_id": 9},
            {"cmd": "scroll", "direction": "up", "x": 1, "y": 2, "invert": "yes"},
        ]
        result = run("agent", input="\n".join(json.dumps(r) for r in requests))
        for line in result.stdout.splitlines():
            response = json.loads(line)
            self.assertFalse(response["ok"])
            self.assertFalse(response["event_sent"])


if __name__ == "__main__":
    unittest.main()
