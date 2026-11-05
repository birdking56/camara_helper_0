"""Regression checks for the telemetry mistakes that hid the frozen source."""
import contextlib
import io
import unittest

import dgc3_decode as decoder


def snapshot(fid=100, capture=106, underflow=639):
    s = decoder.Snapshot()
    for label, value in decoder.SELF_TEST:
        s.add(label, value)
    s.add("M", "%04X%04X003C0000" % (fid, capture))
    s.add("G", "00000000%04XE9AE" % underflow)
    s.add("V", "0FF0000000800FF0")
    return s


def report(s, prev=None):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        decoder.describe(s, prev)
    return output.getvalue()


class TelemetryTests(unittest.TestCase):
    def test_repeated_source_with_live_capture_is_visible(self):
        text = report(snapshot(), snapshot(capture=105))
        self.assertIn("M0 source fid", text)
        self.assertIn("SOURCE REPEAT while capture advances", text)
        self.assertIn("STALE SOURCE FRAME", text)
        self.assertIn("no new reader underflow", text)

    def test_new_underflow_uses_the_counter_delta(self):
        text = report(snapshot(underflow=642), snapshot())
        self.assertIn("3 new reader underflow(s)", text)
        self.assertNotIn("no new reader underflow", text)

    def test_single_snapshot_cannot_date_latched_starvation(self):
        text = report(snapshot())
        self.assertIn("is historical; compare G2", text)
        self.assertNotIn("new reader underflow(s)", text)

    def test_source_fid_wrap_preserves_age_and_progress(self):
        text = report(snapshot(fid=0, capture=1), snapshot(fid=65535, capture=0))
        self.assertIn("+1 fid, +1 capture allocations", text)
        self.assertNotIn("STALE SOURCE FRAME", text)

    def test_zero_starvation_location_is_ambiguous(self):
        current = snapshot(underflow=640)
        current.add("V", "0726070800000726")
        text = report(current, snapshot())
        self.assertIn("1 new reader underflow(s)", text)
        self.assertIn("zero is ambiguous", text)
        self.assertNotIn("gap_max", text)

    def test_live_acquire_does_not_imply_a_start_handling_fault(self):
        current = snapshot(fid=106, capture=108, underflow=640)
        current.add("K", "2828416A5CB00000")
        text = report(current, snapshot())
        self.assertIn("compare job runtime and display deadlines", text)
        self.assertNotIn("loss is in pend/start handling", text)


if __name__ == "__main__":
    unittest.main()
