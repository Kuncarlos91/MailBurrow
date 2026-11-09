"""Bounded, reporting-only Mach-O context. Never returns file-provided names/text."""
import struct


def native_format(data):
    """Fixed format labels; never interpolate binary-provided text."""
    return {
        b"\xcf\xfa\xed\xfe": "thin-macho64-little",
        b"\xfe\xed\xfa\xcf": "thin-macho64-big",
        b"\xca\xfe\xba\xbe": "universal-macho32-table-big",
        b"\xbe\xba\xfe\xca": "universal-macho32-table-little",
        b"\x7fELF": "elf-sections-unsupported",
    }.get(bytes(data[:4]), "unsupported-native-format")


def macho_sections(data):
    """Bounded thin 64-bit slices, optionally in a fat_arch wrapper.

    Wrapper layout follows Apple's EXTERNAL_HEADERS/mach-o/fat.h.
    Nested wrappers, overlaps and unsupported slices remain unknown.
    """
    endian = {b"\xca\xfe\xba\xbe": ">", b"\xbe\xba\xfe\xca": "<"}.get(bytes(data[:4]))
    if endian is None:
        return _thin_sections(data)
    if len(data) < 8:
        return None
    count = struct.unpack_from(endian + "I", data, 4)[0]
    if not 1 <= count <= 32 or 8 + count * 20 > len(data):
        return None
    ranges, sections = [], []
    for index in range(count):
        offset, size, alignment = struct.unpack_from(endian + "III", data, 8 + index * 20 + 8)
        if (offset < 8 + count * 20 or size < 32 or offset > len(data)
                or size > len(data) - offset or alignment > 30 or offset % (1 << alignment)):
            return None
        if any(start < offset + size and offset < end for start, end in ranges):
            return None
        ranges.append((offset, offset + size))
        parsed = _thin_sections(memoryview(data)[offset:offset + size])
        if parsed is None or len(sections) + len(parsed) > 4096:
            return None
        sections.extend((offset + start, offset + end, label) for start, end, label in parsed)
    return sections


def _thin_sections(data):
    """Parse thin 64-bit Mach-O section ranges; unsupported/malformed => None.

    Layout: Apple's EXTERNAL_HEADERS/mach-o/loader.h (mach_header_64,
    segment_command_64 and section_64). No names or payload bytes escape.
    """
    endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(data[:4])
    if endian is None or len(data) < 32:
        return None
    ncmds, size = struct.unpack_from(endian + "II", data, 16)
    if ncmds > 4096 or size > len(data) - 32:
        return None
    pos, end, sections = 32, 32 + size, []
    for _ in range(ncmds):
        if pos + 8 > end:
            return None
        cmd, length = struct.unpack_from(endian + "II", data, pos)
        if length < 8 or length % 8 or pos + length > end:
            return None
        if cmd == 0x19:  # LC_SEGMENT_64
            if length < 72:
                return None
            nsects = struct.unpack_from(endian + "I", data, pos + 64)[0]
            if nsects > 4096 or len(sections) + nsects > 4096 or 72 + nsects * 80 != length:
                return None
            for index in range(nsects):
                section = pos + 72 + index * 80
                size = struct.unpack_from(endian + "Q", data, section + 40)[0]
                offset = struct.unpack_from(endian + "I", data, section + 48)[0]
                flags = struct.unpack_from(endian + "I", data, section + 64)[0]
                kind = flags & 0xff
                if kind in (1, 0xc, 0x12):  # zero-fill sections occupy no file bytes
                    continue
                if offset > len(data) or size > len(data) - offset:
                    return None
                if flags & (0x80000000 | 0x400):
                    label = "instruction-section"
                elif kind == 2:
                    label = "cstring-section"
                elif kind in (3, 4, 0xe):
                    label = "literal-section"
                else:
                    label = "other-section"
                if size:
                    sections.append((offset, offset + size, label))
        pos += length
    if pos != end:
        return None
    return sections


def match_structure(data, match, sections):
    """Fixed labels and bucketed shape only; not a privacy classification."""
    if sections is None:
        location = "unsupported-or-malformed"
    else:
        overlaps = [(start, end, label) for start, end, label in sections
                    if start < match.end() and match.start() < end]
        if len(overlaps) == 1 and overlaps[0][0] <= match.start() and match.end() <= overlaps[0][1]:
            location = overlaps[0][2]
        elif overlaps:
            location = "ambiguous-or-cross-section"
        else:
            location = "outside-file-backed-sections"
    length = len(match.group())
    bucket = "1-16" if length <= 16 else "17-32" if length <= 32 else "33-64" if length <= 64 else "65-plus"
    numeric = any(48 <= value <= 57 for value in match.group(1))
    before_nul = match.start() > 0 and data[match.start() - 1] == 0
    after_nul = match.end() < len(data) and data[match.end()] == 0
    return (f"format={native_format(data)},location={location},length={bucket},domain-has-digit={int(numeric)},"
            f"preceded-by-nul={int(before_nul)},followed-by-nul={int(after_nul)}")
