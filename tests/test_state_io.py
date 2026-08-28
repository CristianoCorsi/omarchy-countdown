import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "state_io.py"
SPEC = importlib.util.spec_from_file_location("countdown_state_io", MODULE_PATH)
state_io = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(state_io)


def sample_state(label="Release 1.0"):
    return {
        "state": {"current_index": 0},
        "countdowns": [
            {
                "label": label,
                "start": "2030-01-01",
                "end": "2030-03-31",
                "format": "days",
            }
        ],
    }


class SecureStateIoTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_path = Path(self.temp_dir.name) / "state" / "countdown.json"

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_round_trip_uses_private_regular_file(self):
        expected = sample_state()
        self.assertEqual(state_io.write_state(str(self.state_path), expected), expected)
        self.assertEqual(state_io.read_state(str(self.state_path)), expected)

        file_stat = self.state_path.stat()
        self.assertTrue(self.state_path.is_file())
        self.assertEqual(file_stat.st_uid, os.getuid())
        self.assertEqual(file_stat.st_mode & 0o777, 0o600)

    def test_read_rejects_symlink_without_reading_target(self):
        target = Path(self.temp_dir.name) / "target.json"
        target.write_text(json.dumps(sample_state()), encoding="utf-8")
        self.state_path.parent.mkdir(mode=0o700)
        self.state_path.symlink_to(target)

        with self.assertRaises(state_io.StateError):
            state_io.read_state(str(self.state_path))

    def test_read_rejects_fifo_without_blocking(self):
        self.state_path.parent.mkdir(mode=0o700)
        os.mkfifo(self.state_path, 0o600)

        with self.assertRaises(state_io.StateError):
            state_io.read_state(str(self.state_path))

    def test_read_rejects_oversized_file(self):
        self.state_path.parent.mkdir(mode=0o700)
        self.state_path.write_bytes(b" " * (state_io.MAX_STATE_BYTES + 1))

        with self.assertRaisesRegex(state_io.StateError, "exceeds"):
            state_io.read_state(str(self.state_path))

    def test_normalization_rejects_unbounded_records(self):
        raw = {"state": {}, "countdowns": sample_state()["countdowns"] * (state_io.MAX_COUNTDOWNS + 1)}

        with self.assertRaisesRegex(state_io.StateError, "records"):
            state_io.normalize_state(raw)

    def test_normalization_rejects_unbounded_label(self):
        with self.assertRaisesRegex(state_io.StateError, "characters"):
            state_io.normalize_state(sample_state("x" * (state_io.MAX_LABEL_CHARS + 1)))

    def test_atomic_write_replaces_symlink_without_touching_target(self):
        target = Path(self.temp_dir.name) / "target.json"
        target.write_text("private target", encoding="utf-8")
        self.state_path.parent.mkdir(mode=0o700)
        self.state_path.symlink_to(target)

        expected = sample_state()
        state_io.write_state(str(self.state_path), expected)

        self.assertFalse(self.state_path.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), "private target")
        self.assertEqual(state_io.read_state(str(self.state_path)), expected)


if __name__ == "__main__":
    unittest.main()
