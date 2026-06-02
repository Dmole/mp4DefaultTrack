import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public final class Mp4DefaultTrack {

    // MP4 box types as big-endian FourCC ints.
    static final int MOOV = ('m' << 24) | ('o' << 16) | ('o' << 8) | 'v';
    static final int TRAK = ('t' << 24) | ('r' << 16) | ('a' << 8) | 'k';
    static final int TKHD = ('t' << 24) | ('k' << 16) | ('h' << 8) | 'd';
    static final int MDIA = ('m' << 24) | ('d' << 16) | ('i' << 8) | 'a';
    static final int MDHD = ('m' << 24) | ('d' << 16) | ('h' << 8) | 'd';
    static final int HDLR = ('h' << 24) | ('d' << 16) | ('l' << 8) | 'r';
    static final int MINF = ('m' << 24) | ('i' << 16) | ('n' << 8) | 'f';
    static final int STBL = ('s' << 24) | ('t' << 16) | ('b' << 8) | 'l';
    static final int STSD = ('s' << 24) | ('t' << 16) | ('s' << 8) | 'd';
    // hdlr handler subtypes
    static final int VIDE = ('v' << 24) | ('i' << 16) | ('d' << 8) | 'e';
    static final int SOUN = ('s' << 24) | ('o' << 16) | ('u' << 8) | 'n';
    static final int SUBT = ('s' << 24) | ('u' << 16) | ('b' << 8) | 't';
    static final int SBTL = ('s' << 24) | ('b' << 16) | ('t' << 8) | 'l';
    static final int TEXT = ('t' << 24) | ('e' << 16) | ('x' << 8) | 't';

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: java Mp4TrackFlagTool <list|set|unset> <file> [trackId] [default|forced]");
            return;
        }

        String cmd = args[0];
        File file = new File(args[1]);
        String flag = args.length >= 4 ? args[3] : "default";
        Integer trackId = (args.length >= 3 && isAllDigits(args[2])) ? Integer.valueOf(args[2]) : null;

        if ("list".equals(cmd)) {
            listTracks(file);
        } else if ("set".equals(cmd)) {
            if (trackId == null) {
                throw new IllegalArgumentException("Missing trackId");
            }
            setFlag(file, trackId, flag, true);
        } else if ("unset".equals(cmd)) {
            if (trackId == null) {
                throw new IllegalArgumentException("Missing trackId");
            }
            setFlag(file, trackId, flag, false);
        } else {
            throw new IllegalArgumentException("Unknown command: " + cmd);
        }
    }

    static boolean isAllDigits(String s) {
        if (s == null || s.isEmpty()) {
            return false;
        }
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    static class TrackInfo {
        long tkhdOffset;
        long stsdOffset;
        long mdhdOffset;
        int trackId;
        boolean defaultFlag;
        boolean forcedFlag;
        String type;
        String language;
    }

    static void listTracks(File f) throws IOException {
        List<TrackInfo> tracks = readTracks(f);
        StringBuilder sb = new StringBuilder(64 + tracks.size() * 80);
        sb.append("[\n");
        for (int i = 0; i < tracks.size(); i++) {
            TrackInfo t = tracks.get(i);
            sb.append("	{\"id\": ")
                    .append(t.trackId)
                    .append(", \"type\": \"")
                    .append(t.type)
                    .append("\", \"lang\": \"")
                    .append(t.language)
                    .append("\", \"default\": ")
                    .append(t.defaultFlag)
                    .append(", \"forced\": ")
                    .append(t.forcedFlag)
                    .append('}');
            if (i != tracks.size() - 1) {
                sb.append(',');
            }
            sb.append('\n');
        }
        sb.append("]\n");
        System.out.print(sb);
    }

    static void setFlag(File f, int id, String flag, boolean val) throws IOException {
        List<TrackInfo> tracks = readTracks(f);
        try (RandomAccessFile raf = new RandomAccessFile(f, "rw")) {
            for (TrackInfo t : tracks) {
                if (t.trackId != id) {
                    continue;
                }
                if ("default".equals(flag)) {
                    patchTkhdFlag(raf, t.tkhdOffset, val);
                } else if ("forced".equals(flag)) {
                    patchStsdFlag(raf, t.stsdOffset, val);
                } else {
                    throw new IllegalArgumentException("Unknown flag: " + flag);
                }
            }
        }
    }

    static long readUInt32(RandomAccessFile raf) throws IOException {
        return raf.readInt() & 0xffffffffL;
    }

    static List<TrackInfo> readTracks(File f) throws IOException {
        List<TrackInfo> tracks = new ArrayList<>();
        try (RandomAccessFile raf = new RandomAccessFile(f, "r")) {
            long fileLen = raf.length();
            while (raf.getFilePointer() + 8 <= fileLen) {
                long pos = raf.getFilePointer();
                long size = readUInt32(raf);
                int type = raf.readInt();
                if (size == 1) {
                    size = raf.readLong();
                } else if (size == 0) {
                    size = fileLen - pos;
                }
                if (type == MOOV) {
                    parseMoov(raf, pos, size, tracks);
                }
                if (size < 8) {
                    break;
                } else {
                    raf.seek(pos + size);
                }
            }
        }
        return tracks;
    }

    static void parseMoov(RandomAccessFile raf, long start, long size, List<TrackInfo> tracks) throws IOException {
        long end = start + size;
        raf.seek(start + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            long boxSize = readUInt32(raf);
            int type = raf.readInt();
            if (boxSize == 1) {
                boxSize = raf.readLong();
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }
            if (type == TRAK) {
                TrackInfo info = parseTrak(raf, pos, boxSize);
                if (info != null) {
                    tracks.add(info);
                }
            }
            if (boxSize < 8) {
                break;
            } else {
                raf.seek(pos + boxSize);
            }
        }
    }

    static TrackInfo parseTrak(RandomAccessFile raf, long trakStart, long trakSize) throws IOException {
        TrackInfo info = new TrackInfo();
        long end = trakStart + trakSize;
        raf.seek(trakStart + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            long boxSize = readUInt32(raf);
            int type = raf.readInt();
            if (boxSize == 1) {
                boxSize = raf.readLong();
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }
            if (type == TKHD) {
                info.tkhdOffset = pos + 8;
                raf.seek(info.tkhdOffset);
                int version = raf.readUnsignedByte();
                int flag1 = raf.readUnsignedByte();
                int flag2 = raf.readUnsignedByte();
                int flag3 = raf.readUnsignedByte();
                int flags = (flag1 << 16) | (flag2 << 8) | flag3;
                info.defaultFlag = (flags & 1) != 0;
                if (version == 1) {
                    raf.skipBytes(16);
                } else {
                    raf.skipBytes(8);
                }
                info.trackId = raf.readInt();
                raf.seek(pos + boxSize);
            } else if (type == MDIA) {
                parseMdia(raf, pos, boxSize, info);
            } else {
                raf.seek(pos + boxSize);
            }
        }
        if (info.trackId == 0) {
            return null;
        } else {
            return info;
        }
    }

    static String decodeMp4Language(int packed) {
        if (packed == 0) {
            return null;
        }
        char c1 = (char) (((packed >> 10) & 0x1F) + 0x60);
        char c2 = (char) (((packed >> 5) & 0x1F) + 0x60);
        char c3 = (char) ((packed & 0x1F) + 0x60);
        return "" + c1 + c2 + c3;
    }

    static void parseMdia(RandomAccessFile raf, long mdiaStart, long mdiaSize, TrackInfo info) throws IOException {
        byte[] header = new byte[8];
        long end = mdiaStart + mdiaSize;
        raf.seek(mdiaStart + 8);
        while (raf.getFilePointer() + 8 < end) {
            long pos = raf.getFilePointer();
            if (raf.read(header) != 8) {
                break;
            }
            int size = readInt(header, 0);
            int type = readInt(header, 4);
            if (size < 8) {
                break;
            }
            if (type == MDHD) {
                info.mdhdOffset = pos + 8;
                raf.seek(info.mdhdOffset);
                int version = raf.readUnsignedByte(); // 1 byte
                raf.skipBytes(3); // skip remaining flags (3 bytes)
                long creationTime = (version == 1) ? raf.readLong() : raf.readInt();
                long modificationTime = (version == 1) ? raf.readLong() : raf.readInt();
                int timescale = raf.readInt();
                long duration = (version == 1) ? raf.readLong() : raf.readInt();
                int langPacked = raf.readUnsignedShort(); // 2 bytes for ISO-639-2/T code
                info.language = decodeMp4Language(langPacked);
            } else if (type == HDLR) {
                raf.skipBytes(8); // version+flags+predefined
                byte[] htype = new byte[4];
                raf.readFully(htype);
                int subtype = readInt(htype, 0);
                if (subtype == VIDE) {
                    info.type = "video";
                } else if (subtype == SOUN) {
                    info.type = "audio";
                } else if (subtype == SUBT || subtype == SBTL || subtype == TEXT) {
                    info.type = "subtitle";
                } else {
                    info.type = new String(htype, StandardCharsets.US_ASCII);
                }
            } else if (type == MINF) {
                parseMinf(raf, pos, size, info);
            }
            raf.seek(pos + size);
        }
    }

    static void parseMinf(RandomAccessFile raf, long minfStart, int minfSize, TrackInfo info) throws IOException {
        byte[] header = new byte[8];
        long end = minfStart + minfSize;
        raf.seek(minfStart + 8);
        while (raf.getFilePointer() + 8 < end) {
            long pos = raf.getFilePointer();
            if (raf.read(header) != 8) {
                break;
            }
            int size = readInt(header, 0);
            int type = readInt(header, 4);
            if (size < 8) {
                break;
            }
            if (type == STBL) {
                parseStbl(raf, pos, size, info);
            }
            raf.seek(pos + size);
        }
    }

    static void parseStbl(RandomAccessFile raf, long stblStart, int stblSize, TrackInfo info) throws IOException {
        byte[] header = new byte[8];
        long end = stblStart + stblSize;
        raf.seek(stblStart + 8);
        while (raf.getFilePointer() + 8 < end) {
            long pos = raf.getFilePointer();
            if (raf.read(header) != 8) {
                break;
            }
            int size = readInt(header, 0);
            int type = readInt(header, 4);
            if (size < 8) {
                break;
            }
            if (type == STSD) {
                info.stsdOffset = pos + 8;
                raf.seek(info.stsdOffset + 8); // skip version+flags+entryCount
                byte[] entryHeader = new byte[8];
                if (raf.read(entryHeader) == 8) {
                    String sampleType = new String(entryHeader, 4, 4, StandardCharsets.US_ASCII);
                    info.forcedFlag = sampleType.toLowerCase(java.util.Locale.ROOT).contains("forced");
                }
            }
            raf.seek(pos + size);
        }
    }

    static void patchTkhdFlag(RandomAccessFile raf, long tkhdOffset, boolean set) throws IOException {
        raf.seek(tkhdOffset + 1);
        int f1 = raf.readUnsignedByte(), f2 = raf.readUnsignedByte(), f3 = raf.readUnsignedByte();
        int flags = (f1 << 16) | (f2 << 8) | f3;
        if (set) {
            flags |= 1;
        } else {
            flags &= ~1;
        }
        raf.seek(tkhdOffset + 1);
        raf.writeByte((flags >> 16) & 0xff);
        raf.writeByte((flags >> 8) & 0xff);
        raf.writeByte(flags & 0xff);
    }

    static void patchStsdFlag(RandomAccessFile raf, long stsdOffset, boolean set) throws IOException {
        raf.seek(stsdOffset + 8);
        byte[] entryHeader = new byte[8];
        raf.read(entryHeader);
        String type = new String(entryHeader, 4, 4, StandardCharsets.US_ASCII);
        if (set && !type.endsWith("fcd ")) {
            type = "fcd ";
        }
        raf.seek(stsdOffset + 12);
        raf.write(type.getBytes(StandardCharsets.US_ASCII), 0, 4);
    }

    static String decodeLang(int bits) {
        char a = (char) (((bits >> 10) & 31) + 0x60);
        char b = (char) (((bits >> 5) & 31) + 0x60);
        char c = (char) ((bits & 31) + 0x60);
        return "" + a + b + c;
    }

    static int readInt(byte[] buf, int off) {
        return ((buf[off] & 0xff) << 24) | ((buf[off + 1] & 0xff) << 16) | ((buf[off + 2] & 0xff) << 8)
                | (buf[off + 3] & 0xff);
    }
}
