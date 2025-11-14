#!/usr/bin/env python3
import sys
import struct

# ----------------------------
#   Helpers
# ----------------------------

def read_u32(f):
    return struct.unpack(">I", f.read(4))[0]

def read_type(f):
    return f.read(4).decode("ascii")

def decode_language(bits):
    if bits == 0:
        return None
    return "".join(chr(((bits >> shift) & 0x1F) + 0x60)
                   for shift in (10, 5, 0))

# ----------------------------
# TrackInfo
# ----------------------------

class Track:
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

def parse_mp4(file_path):
    tracks = []
    with open(file_path, "rb") as f:
        file_len = f.seek(0, 2)
        f.seek(0)

        while f.tell() + 8 <= file_len:
            pos = f.tell()
            size = read_u32(f)
            typ  = read_type(f)

            if size == 1:
                size = struct.unpack(">Q", f.read(8))[0]
            elif size == 0:
                size = file_len - pos

            if typ == "moov":
                parse_moov(f, pos, size, tracks)

            if size < 8:
                break
            f.seek(pos + size)

    return tracks


def parse_moov(f, start, size, tracks):
    end = start + size
    f.seek(start + 8)

    while f.tell() + 8 <= end:
        pos = f.tell()
        s = read_u32(f)
        typ = read_type(f)
        if s == 1:
            s = struct.unpack(">Q", f.read(8))[0]
        elif s == 0:
            s = end - pos

        if typ == "trak":
            t = parse_trak(f, pos, s)
            if t:
                tracks.append(t)

        if s < 8:
            break
        f.seek(pos + s)


def parse_trak(f, start, size):
    end = start + size
    t = Track()

    f.seek(start + 8)
    while f.tell() + 8 <= end:
        pos = f.tell()
        s = read_u32(f)
        typ = read_type(f)
        if s == 1:
            s = struct.unpack(">Q", f.read(8))[0]
        elif s == 0:
            s = end - pos

        if typ == "tkhd":
            t.tkhd_offset = pos + 8
            f.seek(t.tkhd_offset)
            version = f.read(1)[0]
            flags = struct.unpack(">I", b'\x00' + f.read(3))[0]
            t.default = bool(flags & 1)

            if version == 1:
                f.seek(16, 1)
            else:
                f.seek(8, 1)

            t.track_id = struct.unpack(">I", f.read(4))[0]

        elif typ == "mdia":
            parse_mdia(f, pos, s, t)

        if s < 8:
            break
        f.seek(pos + s)

    return t if t.track_id != 0 else None


def parse_mdia(f, start, size, t):
    end = start + size
    f.seek(start + 8)

    while f.tell() + 8 <= end:
        pos = f.tell()
        s = read_u32(f)
        typ = read_type(f)

        if s < 8:
            break

        if typ == "mdhd":
            t.mdhd_offset = pos + 8
            f.seek(t.mdhd_offset)
            version = f.read(1)[0]
            f.seek(3, 1)
            if version == 1:
                f.seek(8 + 8, 1)
            else:
                f.seek(4 + 4, 1)
            f.seek(4, 1)
            duration = None
            if version == 1:
                f.seek(8, 1)
            else:
                f.seek(4, 1)
            lang_bits = struct.unpack(">H", f.read(2))[0]
            t.lang = decode_language(lang_bits)

        elif typ == "hdlr":
            f.seek(pos + 16)
            subtype = f.read(4).decode("ascii")
            if subtype == "vide":
                t.type = "video"
            elif subtype == "soun":
                t.type = "audio"
            elif subtype in ("subt", "sbtl", "text"):
                t.type = "subtitle"
            else:
                t.type = subtype

        elif typ == "minf":
            parse_minf(f, pos, s, t)

        f.seek(pos + s)


def parse_minf(f, start, size, t):
    end = start + size
    f.seek(start + 8)

    while f.tell() + 8 <= end:
        pos = f.tell()
        s = read_u32(f)
        typ = read_type(f)

        if typ == "stbl":
            parse_stbl(f, pos, s, t)

        f.seek(pos + s)


def parse_stbl(f, start, size, t):
    end = start + size
    f.seek(start + 8)

    # find stsd
    while f.tell() + 8 <= end:
        pos = f.tell()
        s = read_u32(f)
        typ = read_type(f)

        if typ == "stsd":
            t.stsd_offset = pos + 8
            f.seek(t.stsd_offset + 8)
            entry = f.read(8)
            if len(entry) == 8:
                sample_type = entry[4:8].decode("ascii").lower()
                t.forced = "fcd" in sample_type

        f.seek(pos + s)


# ----------------------------
# Write operations
# ----------------------------

def patch_default_flag(path, offset, value):
    with open(path, "r+b") as f:
        f.seek(offset + 1)
        b1, b2, b3 = f.read(3)
        flags = (b1 << 16) | (b2 << 8) | b3
        if value:
            flags |= 1
        else:
            flags &= ~1
        f.seek(offset + 1)
        f.write(bytes([(flags >> 16) & 0xFF,
                       (flags >> 8) & 0xFF,
                       flags & 0xFF]))


def patch_forced_flag(path, offset, value):
    with open(path, "r+b") as f:
        f.seek(offset + 8)
        entry = f.read(8)
        sample = entry[4:8].decode("ascii")
        if value:
            sample = "fcd "
        f.seek(offset + 12)
        f.write(sample.encode("ascii"))


# ----------------------------
# Commands
# ----------------------------

def cmd_list(path):
    tracks = parse_mp4(path)
    print("[")
    for i, t in enumerate(tracks):
        print(f'  {{"id": {t.track_id}, "type": "{t.type}", '
              f'"lang": "{t.lang}", "default": {str(t.default).lower()}, '
              f'"forced": {str(t.forced).lower()}}}{"," if i < len(tracks)-1 else ""}')
    print("]")


def cmd_setunset(path, track_id, flag, value):
    tracks = parse_mp4(path)
    for t in tracks:
        if t.track_id == track_id:
            if flag == "default":
                patch_default_flag(path, t.tkhd_offset, value)
            elif flag == "forced":
                patch_forced_flag(path, t.stsd_offset, value)
            else:
                sys.exit("Unknown flag.")
            return
    print("Track not found.")


# ----------------------------
# Entry point
# ----------------------------

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: mp4track.py <list|set|unset> <file> [trackId] [default|forced]")
        sys.exit(1)

    cmd = sys.argv[1]
    path = sys.argv[2]

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

