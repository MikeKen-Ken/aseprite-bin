#!/usr/bin/env python3
"""Check that one or more TrueType fonts cover the CJK translation characters."""

from __future__ import annotations

import struct
import sys
from pathlib import Path


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from(">H", data, offset)[0]


def i16(data: bytes, offset: int) -> int:
    return struct.unpack_from(">h", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def is_cjk(codepoint: int) -> bool:
    return (
        0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or 0x20000 <= codepoint <= 0x2FA1F
    )


class Cmap:
    def __init__(self, data: bytes, offset: int) -> None:
        self.data = data
        self.offset = offset
        self.format = u16(data, offset)

    def has_glyph(self, codepoint: int) -> bool:
        if self.format == 4:
            return self._format4_has_glyph(codepoint)
        if self.format == 12:
            return self._format12_has_glyph(codepoint)
        return False

    def _format4_has_glyph(self, codepoint: int) -> bool:
        if codepoint > 0xFFFF:
            return False

        offset = self.offset
        length = u16(self.data, offset + 2)
        seg_count = u16(self.data, offset + 6) // 2
        end_codes = offset + 14
        start_codes = end_codes + seg_count * 2 + 2
        deltas = start_codes + seg_count * 2
        range_offsets = deltas + seg_count * 2

        for index in range(seg_count):
            end_code = u16(self.data, end_codes + index * 2)
            if codepoint > end_code:
                continue

            start_code = u16(self.data, start_codes + index * 2)
            if codepoint < start_code:
                return False

            delta = i16(self.data, deltas + index * 2)
            range_offset_address = range_offsets + index * 2
            range_offset = u16(self.data, range_offset_address)
            if range_offset == 0:
                return ((codepoint + delta) & 0xFFFF) != 0

            glyph_address = (
                range_offset_address
                + range_offset
                + 2 * (codepoint - start_code)
            )
            if glyph_address + 2 > offset + length:
                return False
            glyph = u16(self.data, glyph_address)
            return glyph != 0 and ((glyph + delta) & 0xFFFF) != 0

        return False

    def _format12_has_glyph(self, codepoint: int) -> bool:
        offset = self.offset
        group_count = u32(self.data, offset + 12)
        low = 0
        high = group_count - 1
        groups = offset + 16

        while low <= high:
            middle = (low + high) // 2
            group = groups + middle * 12
            start = u32(self.data, group)
            end = u32(self.data, group + 4)
            if codepoint < start:
                high = middle - 1
            elif codepoint > end:
                low = middle + 1
            else:
                first_glyph = u32(self.data, group + 8)
                return first_glyph + codepoint - start != 0
        return False


def load_unicode_cmaps(font_path: Path) -> list[Cmap]:
    data = font_path.read_bytes()
    table_count = u16(data, 4)
    cmap_offset = None

    for index in range(table_count):
        table = 12 + index * 16
        if data[table : table + 4] == b"cmap":
            cmap_offset = u32(data, table + 8)
            break

    if cmap_offset is None:
        raise ValueError("font has no cmap table")

    subtable_count = u16(data, cmap_offset + 2)
    cmaps: list[Cmap] = []
    seen_offsets: set[int] = set()
    for index in range(subtable_count):
        record = cmap_offset + 4 + index * 8
        platform = u16(data, record)
        encoding = u16(data, record + 2)
        subtable_offset = cmap_offset + u32(data, record + 4)
        if platform == 0 or (platform == 3 and encoding in (1, 10)):
            if subtable_offset not in seen_offsets:
                cmap = Cmap(data, subtable_offset)
                if cmap.format in (4, 12):
                    cmaps.append(cmap)
                    seen_offsets.add(subtable_offset)

    if not cmaps:
        raise ValueError("font has no supported Unicode cmap format")
    return cmaps


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: check-font-coverage.py FONT.ttf [FALLBACK.ttf ...] TRANSLATION.ini",
            file=sys.stderr,
        )
        return 2

    font_paths = [Path(argument) for argument in sys.argv[1:-1]]
    translation_path = Path(sys.argv[-1])
    cmaps = [cmap for font_path in font_paths for cmap in load_unicode_cmaps(font_path)]
    translation = translation_path.read_text(encoding="utf-8-sig")
    required = sorted({ord(character) for character in translation if is_cjk(ord(character))})
    missing = [codepoint for codepoint in required if not any(cmap.has_glyph(codepoint) for cmap in cmaps)]

    print(
        f"CJK glyph coverage across {len(font_paths)} font(s): "
        f"{len(required) - len(missing)}/{len(required)}"
    )
    if missing:
        preview = " ".join(f"{chr(codepoint)}(U+{codepoint:04X})" for codepoint in missing[:40])
        print(f"Missing {len(missing)} CJK glyphs: {preview}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
