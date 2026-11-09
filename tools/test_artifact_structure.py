import struct
import unittest
from artifact_structure import macho_sections, match_structure, native_format
from privacy_check import artifact_context, inspect, EMAIL


SAMPLE = b"owner@" + b"unlisted-domain.org"
PATH = "Payload/Synthetic.app/Frameworks/App.framework/App"


def binary(flags=2, endian="<", name=b"private-section", payload=SAMPLE):
    magic = b"\xcf\xfa\xed\xfe" if endian == "<" else b"\xfe\xed\xfa\xcf"
    header = magic + struct.pack(endian + "7I", 0x100000c, 0, 6, 1, 152, 0, 0)
    segment = struct.pack(endian + "II16sQQQQiiII", 0x19, 152, name, 0, 4096, 184, len(payload), 7, 5, 1, 0)
    section = struct.pack(endian + "16s16sQQ8I", name, name, 0, len(payload), 184, 0, 0, 0, flags, 0, 0, 0)
    return header + segment + section + payload + b"\0"


class StructuralContextTests(unittest.TestCase):
    def test_section_labels_and_endianness(self):
        for endian in ("<", ">"):
            for flags, label in ((2, "cstring-section"), (0x80000400, "instruction-section"), (3, "literal-section"), (0, "other-section")):
                with self.subTest(endian=endian, flags=flags):
                    data = binary(flags, endian)
                    sections = macho_sections(data)
                    self.assertEqual(sections, [(184, 184 + len(SAMPLE), label)])
                    self.assertIn("location=" + label, artifact_context(PATH, data))
                    self.assertIn("email-address-review", inspect(data, PATH, False, True))

    def test_zero_fill_does_not_claim_file_bytes(self):
        for flags in (1, 0xc, 0x12):
            data = binary(flags)
            self.assertEqual(macho_sections(data), [])
            self.assertIn("outside-file-backed-sections", artifact_context(PATH, data))

    def test_malformed_and_unsupported_are_safe(self):
        valid = binary()
        cases = [b"", b"\x7fELF" + SAMPLE, b"\xca\xfe\xba\xbe" + SAMPLE]
        cases.extend(valid[:n] for n in range(184))
        for offset, value in ((16, 5000), (20, 0xffffffff), (36, 0), (36, 151), (96, 5000), (152, 0xffffffff)):
            data = bytearray(valid)
            struct.pack_into("<I", data, offset, value)
            cases.append(bytes(data))
        for data in cases:
            with self.subTest(length=len(data)):
                self.assertIsNone(macho_sections(data))

    def test_ambiguous_and_crossing_ranges_remain_unknown(self):
        data = binary()
        match = EMAIL.search(data)
        self.assertIn("ambiguous-or-cross-section", match_structure(data, match, [(184, 190, "cstring-section")]))
        self.assertIn("ambiguous-or-cross-section", match_structure(data, match, [(184, len(data), "cstring-section")] * 2))

    def test_no_match_name_path_or_nearby_secret_disclosed(self):
        secret = b"ma_" + b"q" * 43
        data = binary(payload=b"\0" + SAMPLE + b"\0" + secret)
        context = artifact_context(PATH, data)
        for value in (SAMPLE, secret, b"private-section", PATH.encode()):
            self.assertNotIn(value.decode(), context)
        self.assertIn("preceded-by-nul=1,followed-by-nul=1", context)
        self.assertIn("mail-archiver-key-shaped", inspect(data, PATH, False, True))
        for path in ("other.bin", "Payload/Synthetic.app/Frameworks/Flutter.framework/Flutter"):
            self.assertIn("structural context (first 16): none", artifact_context(path, data))

    def test_structural_output_is_bounded(self):
        payload = b"\0".join((b"person" + str(n).encode() + b"@unlisted-domain.org") for n in range(30))
        context = artifact_context(PATH, binary(payload=payload))
        self.assertEqual(context.count("location="), 16)


class UniversalStructureTests(unittest.TestCase):
    @staticmethod
    def wrapper(slices, endian=">", offsets=None):
        magic = b"\xca\xfe\xba\xbe" if endian == ">" else b"\xbe\xba\xfe\xca"
        start = 8 + 20 * len(slices)
        entries, payload = [], b""
        for index, item in enumerate(slices):
            offset = start + len(payload) if offsets is None else offsets[index]
            entries.append(struct.pack(endian + "5I", 0x100000c, 0, offset, len(item), 0))
            payload += item
        return magic + struct.pack(endian + "I", len(slices)) + b"".join(entries) + payload

    def test_thin_slices_in_both_wrapper_orders(self):
        for endian in (">", "<"):
            for inner in (">", "<"):
                data = self.wrapper([binary(endian=inner)], endian)
                self.assertEqual(macho_sections(data), [(212, 212 + len(SAMPLE), "cstring-section")])
                report = artifact_context(PATH, data)
                self.assertIn("location=cstring-section", report)
                self.assertIn("format=universal-macho32-table-", report)
                self.assertNotIn(SAMPLE.decode(), report)
                self.assertIn("email-address-review", inspect(data, PATH, False, True))

    def test_multiple_slices_have_absolute_section_ranges(self):
        first, second = binary(), binary(flags=0x80000400)
        data = self.wrapper([first, second])
        self.assertEqual(macho_sections(data), [(48 + 184, 48 + 184 + len(SAMPLE), "cstring-section"),
            (48 + len(first) + 184, 48 + len(first) + 184 + len(SAMPLE), "instruction-section")])

    def test_invalid_wrappers_and_nested_or_unknown_slices(self):
        valid = self.wrapper([binary()])
        cases = [valid[:n] for n in range(28)]
        cases += [valid[:-2], self.wrapper([b"X" * 64]), self.wrapper([valid]),
                  self.wrapper([binary()], offsets=[0]), self.wrapper([binary(), binary()], offsets=[48,48])]
        for offset, value in ((4,0), (4,33), (16,0xffffffff), (20,0xffffffff), (24,31), (24,14)):
            data = bytearray(valid); struct.pack_into(">I", data, offset, value); cases.append(bytes(data))
        for data in cases:
            self.assertIsNone(macho_sections(data))

    def test_format_label_is_independent_of_parser_success(self):
        self.assertEqual(native_format(b"\xca\xfe\xba\xbe"), "universal-macho32-table-big")
        self.assertIsNone(macho_sections(b"\xca\xfe\xba\xbe"))
        self.assertEqual(native_format(b"\x7fELF"), "elf-sections-unsupported")
        self.assertEqual(native_format(b"private"), "unsupported-native-format")
