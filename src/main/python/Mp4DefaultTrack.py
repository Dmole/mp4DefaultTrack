#!/usr/bin/env python3
import sys
import mmap
import json

# ----------------------------
#   Constants
# ----------------------------
# Comparing raw bytes is dramatically faster than string decoding
B_MOOV = b"moov"
B_TRAK = b"trak"
B_TKHD = b"tkhd"
B_MDIA = b"mdia"
B_MDHD = b"mdhd"
B_HDLR = b"hdlr"
B_MINF = b"minf"
B_STBL = b"stbl"
B_STSD = b"stsd"
B_VIDE = b"vide"
B_SOUN = b"soun"
B_SUBT = b"subt"
B_SBTL = b"sbtl"
B_TEXT = b"text"
B_FCD_ = b"fcd "

# ----------------------------
#   Helpers
# ----------------------------

def decode_language(bits):
    if bits == 0:
        return None
    return "".join(chr(((bits >> shift) & 0x1F) + 0x60) for shift in (10, 5, 0))

def iter_boxes(mm, start, end):
    """Yields (payload_offset, header_length, total_box_size, box_type_bytes)"""
    pos = start
    while pos + 8 <= end:
        # Native int.from_bytes is significantly faster than struct.unpack
        s = int.from_bytes(mm[pos:pos+4], 'big')
        typ = mm[pos+4:pos+8]
        box_size = s
        hdr_len = 8

        if s == 1:
            if pos + 16 > end:
                break
            box_size = int.from_bytes(mm[pos+8:pos+16], 'big')
            hdr_len = 16
        elif s == 0:
            box_size = end - pos

        if box_size < 8:
            break

        yield pos, hdr_len, box_size, typ
        pos += box_size

# ----------------------------
# TrackInfo
# ----------------------------

class Track:
    # __slots__ strictly bounds the memory footprint of the objects
    __slots__ = ['tkhd_offset', 'stsd_offset', 'mdhd_offset', 'track_id', 'default', 'forced', 'type', 'lang']

    def __init__(self):
        self.tkhd_offset = None
        self.stsd_offset = None
        self.mdhd_offset = None
        self.track_id = 0
        self.default = False
        self.forced = False
        self.type = None
        self.lang = None

# ----------------------------
# Main parsing
# ----------------------------

def parse_mp4(mm):
    tracks = []
    for pos, hdr, size, typ in iter_boxes(mm, 0, len(mm)):
        if typ == B_MOOV:
            parse_moov(mm, pos + hdr, pos + size, tracks)
    return tracks

def parse_moov(mm, start, end, tracks):
    for pos, hdr, size, typ in iter_boxes(mm, start, end):
        if typ == B_TRAK:
            t = parse_trak(mm, pos + hdr, pos + size)
            if t and t.track_id != 0:
                tracks.append(t)

def parse_trak(mm, start, end):
    t = Track()
    for pos, hdr, size, typ in iter_boxes(mm, start, end):
        if typ == B_TKHD:
            t.tkhd_offset = pos + hdr
            version = mm[t.tkhd_offset]
            flags = int.from_bytes(mm[t.tkhd_offset+1:t.tkhd_offset+4], 'big')
            t.default = bool(flags & 1)

            skip = 16 if version == 1 else 8
            id_pos = t.tkhd_offset + 4 + skip
            t.track_id = int.from_bytes(mm[id_pos:id_pos+4], 'big')

        elif typ == B_MDIA:
            parse_mdia(mm, pos + hdr, pos + size, t)
    return t

def parse_mdia(mm, start, end, t):
    for pos, hdr, size, typ in iter_boxes(mm, start, end):
        if typ == B_MDHD:
            t.mdhd_offset = pos + hdr
            version = mm[t.mdhd_offset]
            skip = 28 if version == 1 else 16
            lang_pos = t.mdhd_offset + 4 + skip
            lang_bits = int.from_bytes(mm[lang_pos:lang_pos+2], 'big')
            t.lang = decode_language(lang_bits)

        elif typ == B_HDLR:
            subtype = mm[pos + hdr + 8 : pos + hdr + 12]
            if subtype == B_VIDE:
                t.type = "video"
            elif subtype == B_SOUN:
                t.type = "audio"
            elif subtype in (B_SUBT, B_SBTL, B_TEXT):
                t.type = "subtitle"
            else:
                t.type = subtype.decode("ascii", errors="ignore")

        elif typ == B_MINF:
            parse_minf(mm, pos + hdr, pos + size, t)

def parse_minf(mm, start, end, t):
    for pos, hdr, size, typ in iter_boxes(mm, start, end):
        if typ == B_STBL:
            parse_stbl(mm, pos + hdr, pos + size, t)

def parse_stbl(mm, start, end, t):
    for pos, hdr, size, typ in iter_boxes(mm, start, end):
        if typ == B_STSD:
            t.stsd_offset = pos + hdr
            entry_start = t.stsd_offset + 8
            if entry_start + 8 <= pos + size:
                sample_type = mm[entry_start+4:entry_start+8].lower()
                t.forced = b"fcd" in sample_type

# ----------------------------
# Write operations
# ----------------------------

def patch_default_flag(mm, offset, value):
    flags = int.from_bytes(mm[offset+1:offset+4], 'big')
    if value:
        flags |= 1
    else:
        flags &= ~1
    mm[offset+1:offset+4] = flags.to_bytes(3, 'big')

def patch_forced_flag(mm, offset, value):
    # If unsetting, original string type is unknown, ignore safely
    if value:
        mm[offset+12:offset+16] = B_FCD_

# ----------------------------
# Commands
# ----------------------------

def cmd_list(path):
    with open(path, "rb") as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
            tracks = parse_mp4(mm)

    out = []
    for t in tracks:
        out.append({
            "id": t.track_id,
            "type": t.type,
            "lang": t.lang,
            "default": t.default,
            "forced": t.forced
        })

    # Mirrors original JSON spacing output but heavily optimized
    print("[")
    for i, obj in enumerate(out):
        line = json.dumps(obj)
        print(f"\t{line}{',' if i < len(out)-1 else ''}")
    print("]")


def cmd_setunset(path, track_id, flag, value):
    # Open once in r+b mode and map with ACCESS_WRITE to modify the file directly
    with open(path, "r+b") as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE) as mm:
            tracks = parse_mp4(mm)
            for t in tracks:
                if t.track_id == track_id:
                    if flag == "default":
                        patch_default_flag(mm, t.tkhd_offset, value)
                    elif flag == "forced":
                        patch_forced_flag(mm, t.stsd_offset, value)
                    else:
                        sys.exit("Unknown flag.")
                    return
    print("Track not found.")

# ----------------------------
# Entry point
# ----------------------------

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("Usage: mp4track.py <list|set|unset> <file> [trackId] [default|forced]")

    cmd = sys.argv[1]
    path = sys.argv[2]

    try:
        if cmd == "list":
            cmd_list(path)
            sys.exit(0)

        if cmd in ("set", "unset"):
            if len(sys.argv) < 5:
                sys.exit("Missing args: set/unset <file> <trackId> <default|forced>")

            tid = int(sys.argv[3])
            flag = sys.argv[4]
            val = (cmd == "set")
            cmd_setunset(path, tid, flag, val)
            sys.exit(0)

        sys.exit("Unknown command.")
    except FileNotFoundError:
        sys.exit("File not found.")
