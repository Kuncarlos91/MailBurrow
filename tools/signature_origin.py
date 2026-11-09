"""Reporting-only provenance check for Mach-O CodeDirectory page hashes.

Format references: Apple's mach-o/loader.h, mach-o/fat.h and kern/cs_blobs.h.
No binary-provided strings or raw hashes are returned. This never clears findings.
"""
import hashlib
import struct
from artifact_structure import macho_sections


def signature_origin(data, match):
    if macho_sections(data) is None:
        return "unknown-native-layout"
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        endian = ">" if magic == b"\xca\xfe\xba\xbe" else "<"
        count = struct.unpack_from(endian + "I", data, 4)[0]
        slices = [struct.unpack_from(endian + "II", data, 16 + index * 20) for index in range(count)]
    else:
        slices = [(0, len(data))]
    candidates = []
    for base, size in slices:
        endian = "<" if data[base:base + 4] == b"\xcf\xfa\xed\xfe" else ">"
        commands = struct.unpack_from(endian + "I", data, base + 16)[0]
        pos = base + 32
        regions = []
        for _ in range(commands):
            cmd, length = struct.unpack_from(endian + "II", data, pos)
            if cmd == 0x1d:  # LC_CODE_SIGNATURE / linkedit_data_command
                if length != 16:
                    return "unknown-signature-layout"
                offset, length_data = struct.unpack_from(endian + "II", data, pos + 8)
                if offset > size or length_data > size - offset:
                    return "unknown-signature-layout"
                regions.append((offset, length_data))
            pos += length
        if len(regions) > 1:
            return "unknown-signature-layout"
        for offset, length_data in regions:
            start = base + offset
            if start <= match.start() and match.end() <= start + length_data:
                candidates.append((base, size, offset, length_data))
    if not candidates:
        return "outside-code-signature"
    if len(candidates) != 1:
        return "unknown-signature-layout"
    base, size, offset, length_data = candidates[0]
    start = base + offset
    if length_data < 12:
        return "code-signature-unverified"
    magic, length, count = struct.unpack_from(">III", data, start)
    if magic != 0xfade0cc0 or not 12 <= length <= length_data or count > 64 or 12 + count * 8 > length:
        return "code-signature-unverified"
    blobs = []
    for index in range(count):
        kind, relative = struct.unpack_from(">II", data, start + 12 + index * 8)
        if relative < 12 + count * 8 or relative + 8 > length:
            return "code-signature-unverified"
        blob_magic, blob_size = struct.unpack_from(">II", data, start + relative)
        if blob_size < 8 or relative + blob_size > length:
            return "code-signature-unverified"
        if any(a < relative + blob_size and relative < b for a, b, _, _ in blobs):
            return "code-signature-unverified"
        blobs.append((relative, relative + blob_size, blob_magic, kind))
    for a, b, magic, kind in blobs:
        if magic != 0xfade0c02 or b - a < 44 or kind not in (0, 0x1000, 0x1001, 0x1002, 0x1003, 0x1004):
            continue
        cd = start + a
        version = struct.unpack_from(">I", data, cd + 8)[0]
        if not 0x20001 <= version <= 0x20600:
            continue
        minimum = 44
        for threshold, required in ((0x20100, 48), (0x20200, 52), (0x20300, 64), (0x20400, 88), (0x20500, 96), (0x20600, 108)):
            if version >= threshold:
                minimum = required
        if b - a < minimum:
            continue
        hash_offset, ident_offset, special, slots, limit = struct.unpack_from(">IIIII", data, cd + 16)
        if version >= 0x20300:
            limit64 = struct.unpack_from(">Q", data, cd + 56)[0]
            limit = limit64 or limit
        hash_size, hash_type, _, page_power = struct.unpack_from(">4B", data, cd + 36)
        if (hash_size != 32 or hash_type != 2 or not 1 <= page_power <= 16 or limit > offset
                or not minimum <= ident_offset < hash_offset - special * hash_size
                or hash_offset - special * hash_size < minimum
                or hash_offset + slots * hash_size > b - a):
            continue
        # Unknown/scattered/extended ranges stay unverified rather than guessed.
        if version >= 0x20100 and (b - a < 48 or struct.unpack_from(">I", data, cd + 44)[0] != 0):
            continue
        page_size = 1 << page_power
        if slots != (limit + page_size - 1) // page_size:
            continue
        first = cd + hash_offset
        if not first <= match.start() < first + slots * 32:
            continue
        slot = (match.start() - first) // 32
        if match.end() > first + (slot + 1) * 32:
            continue
        page_start = base + slot * page_size
        page_end = base + min((slot + 1) * page_size, limit)
        stored = data[first + slot * 32:first + (slot + 1) * 32]
        if hashlib.sha256(data[page_start:page_end]).digest() == stored:
            return "verified-sha256-code-page-hash"
    return "code-signature-unverified"
