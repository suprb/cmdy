import hashlib
import unittest
from paste_protocol import (BARCODE_COLUMNS, END, PAYLOAD_BYTES, START, ExactPasteReceiver,
                            expected_receipt, off_probe, paste_payload, row_symbols, wire_bytes)

TOKEN = "0123456789abcdef0123456789abcdef"


class PasteProtocolTests(unittest.TestCase):
    def test_fixed_exact_utf8_payloads_have_no_shell_controls(self):
        hashes = set()
        for sequence in range(1, 43):
            data = paste_payload(TOKEN, sequence)
            self.assertEqual(len(data), PAYLOAD_BYTES)
            text = data.decode("utf-8")
            self.assertIn("λ世界🙂", text)
            self.assertTrue(all(value >= 32 for value in data))
            hashes.add(hashlib.sha256(data).hexdigest())
        self.assertEqual(len(hashes), 42)

    def test_all_120_cells_participate_in_generated_response(self):
        self.assertEqual(BARCODE_COLUMNS, 120)
        for row in range(1000):
            codes = row_symbols(TOKEN, row)
            self.assertEqual(len(codes), 120)
            self.assertEqual((codes[0], codes[-1]), (-1, -2))
            self.assertEqual(codes[1:41], codes[41:81])

    def test_fragmentation_preserves_every_utf8_byte_and_bracket(self):
        for sequence in (0, 1, 42):
            data = wire_bytes(TOKEN, sequence)
            receiver = ExactPasteReceiver(TOKEN, sequence)
            for start in range(0, len(data), 97):
                complete = receiver.feed(data[start:start + 97])
                self.assertEqual(complete, start + 97 >= len(data))
            self.assertEqual(receiver.count, len(data))
            with self.assertRaises(ValueError):
                receiver.feed(b"x")

    def test_wrong_brackets_wrong_nonce_truncation_and_raw_type_rejected(self):
        for data in (paste_payload(TOKEN, 1), START + paste_payload(TOKEN, 1) + b"x",
                     wire_bytes("f" * 32, 1), wire_bytes(TOKEN, 2), wire_bytes(TOKEN, 1) + b"x"):
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                ExactPasteReceiver(TOKEN, 1).feed(data)
        off = off_probe(TOKEN)
        with self.assertRaises(ValueError):
            ExactPasteReceiver(TOKEN, 0).feed(START + off + END)
        self.assertFalse(ExactPasteReceiver(TOKEN, 1).feed(wire_bytes(TOKEN, 1)[:-1]))
        self.assertEqual(expected_receipt(TOKEN, 42)["responseFirstRow"], 41)

    def test_sequence_and_nonce_are_bounded(self):
        for sequence in (False, -1, 0, 43, 1.0):
            with self.assertRaises(ValueError):
                paste_payload(TOKEN, sequence)
        for token in ("", "f" * 31, "F" * 32, "x" * 32):
            with self.assertRaises(ValueError):
                paste_payload(token, 1)


if __name__ == "__main__":
    unittest.main()
