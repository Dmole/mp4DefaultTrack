import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class Mp4DefaultTrack {

    // Precomputed FourCC codes as 32-bit integers for zero-allocation matching
    static final int MOOV = 0x6D6F6F76; // 'moov'
    static final int TRAK = 0x7472616B; // 'trak'
    static final int TKHD = 0x746B6864; // 'tkhd'
    static final int MDIA = 0x6D646961; // 'mdia'
    static final int MDHD = 0x6D646864; // 'mdhd'
    static final int HDLR = 0x68646C72; // 'hdlr'
    static final int MINF = 0x6D696E66; // 'minf'
    static final int STBL = 0x7374626C; // 'stbl'
    static final int STSD = 0x73747364; // 'stsd'
    static final int VIDE = 0x76696465; // 'vide'
    static final int SOUN = 0x736F756E; // 'soun'
    static final int SUBT = 0x73756274; // 'subt'
    static final int SBTL = 0x7362746C; // 'sbtl'
    static final int TEXT = 0x74657874; // 'text'
    static final int FCD  = 0x66636420; // 'fcd '

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: java Mp4DefaultTrack <list|set|unset> <file> [trackId] [default|forced]");
            return;
        }

        String cmd = args[0];
        File file = new File(args[1]);
        String flag = args.length >= 4 ? args[3] : "default";
        Integer trackId = (args.length >= 3 && args[2].matches("\\d+")) ? Integer.valueOf(args[2]) : null;

        if ("list".equals(cmd)) {
            try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
                listTracks(raf);
            }
        } else if ("set".equals(cmd) || "unset".equals(cmd)) {
            if (trackId == null) {
                throw new IllegalArgumentException("Missing trackId");
            }
            try (RandomAccessFile raf = new RandomAccessFile(file, "rw")) {
                setFlag(raf, trackId, flag, "set".equals(cmd));
            }
        } else {
            throw new IllegalArgumentException("Unknown command: " + cmd);
        }
    }

    static class TrackInfo {
        long tkhdOffset;
        long stsdOffset;
        int trackId;
        boolean defaultFlag;
        boolean forcedFlag;
        String type;
        String language;
    }

    static void listTracks(RandomAccessFile raf) throws IOException {
        List<TrackInfo> tracks = readTracks(raf);
        System.out.println("[");
        for (int i = 0; i < tracks.size(); i++) {
            TrackInfo t = tracks.get(i);
            System.out.printf("\t{\"id\": %d, \"type\": \"%s\", \"lang\": \"%s\", \"default\": %b, \"forced\": %b}%s%n",
                    t.trackId, t.type, t.language, t.defaultFlag, t.forcedFlag, (i == tracks.size() - 1 ? "" : ","));
        }
        System.out.println("]");
    }

    static void setFlag(RandomAccessFile raf, int id, String flag, boolean set) throws IOException {
        List<TrackInfo> tracks = readTracks(raf);
        for (TrackInfo t : tracks) {
            if (t.trackId == id) {
                if ("default".equals(flag)) {
                    patchTkhdFlag(raf, t.tkhdOffset, set);
                } else if ("forced".equals(flag)) {
                    patchStsdFlag(raf, t.stsdOffset, set);
                } else {
                    throw new IllegalArgumentException("Unknown flag: " + flag);
                }
                return; // Early exit once patched
            }
        }
    }

    static List<TrackInfo> readTracks(RandomAccessFile raf) throws IOException {
        List<TrackInfo> tracks = new ArrayList<>();
        byte[] buf = new byte[16]; // Shared buffer for zero-allocation I/O reads
        long fileLen = raf.length();
        raf.seek(0);

        while (raf.getFilePointer() + 8 <= fileLen) {
            long pos = raf.getFilePointer();
            raf.readFully(buf, 0, 8);
            long size = Integer.toUnsignedLong(readInt(buf, 0));
            int type = readInt(buf, 4);

            if (size == 1) {
                raf.readFully(buf, 8, 8);
                size = readLong(buf, 8);
            } else if (size == 0) {
                size = fileLen - pos;
            }

            if (type == MOOV) {
                parseMoov(raf, pos, size, tracks, buf);
            }

            if (size < 8) break;
            raf.seek(pos + size);
        }
        return tracks;
    }

    static void parseMoov(RandomAccessFile raf, long start, long size, List<TrackInfo> tracks, byte[] buf) throws IOException {
        long end = start + size;
        raf.seek(start + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            raf.readFully(buf, 0, 8);
            long boxSize = Integer.toUnsignedLong(readInt(buf, 0));
            int type = readInt(buf, 4);

            if (boxSize == 1) {
                raf.readFully(buf, 8, 8);
                boxSize = readLong(buf, 8);
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }

            if (type == TRAK) {
                TrackInfo info = parseTrak(raf, pos, boxSize, buf);
                if (info != null) tracks.add(info);
            }

            if (boxSize < 8) break;
            raf.seek(pos + boxSize);
        }
    }

    static TrackInfo parseTrak(RandomAccessFile raf, long trakStart, long trakSize, byte[] buf) throws IOException {
        TrackInfo info = new TrackInfo();
        long end = trakStart + trakSize;
        raf.seek(trakStart + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            raf.readFully(buf, 0, 8);
            long boxSize = Integer.toUnsignedLong(readInt(buf, 0));
            int type = readInt(buf, 4);

            if (boxSize == 1) {
                raf.readFully(buf, 8, 8);
                boxSize = readLong(buf, 8);
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }

            if (type == TKHD) {
                info.tkhdOffset = pos + 8;
                raf.seek(info.tkhdOffset);
                raf.readFully(buf, 0, 4);
                int vf = readInt(buf, 0);
                info.defaultFlag = (vf & 1) != 0;
                
                int version = vf >>> 24;
                raf.skipBytes((version == 1) ? 16 : 8);
                info.trackId = raf.readInt();
            } else if (type == MDIA) {
                parseMdia(raf, pos, boxSize, info, buf);
            }

            if (boxSize < 8) break;
            raf.seek(pos + boxSize);
        }
        return info.trackId == 0 ? null : info;
    }

    static void parseMdia(RandomAccessFile raf, long mdiaStart, long mdiaSize, TrackInfo info, byte[] buf) throws IOException {
        long end = mdiaStart + mdiaSize;
        raf.seek(mdiaStart + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            raf.readFully(buf, 0, 8);
            long boxSize = Integer.toUnsignedLong(readInt(buf, 0));
            int type = readInt(buf, 4);

            if (boxSize == 1) {
                raf.readFully(buf, 8, 8);
                boxSize = readLong(buf, 8);
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }

            if (type == MDHD) {
                raf.seek(pos + 8);
                int version = raf.readUnsignedByte();
                raf.skipBytes(3);
                raf.skipBytes((version == 1) ? 28 : 16);
                int langPacked = raf.readUnsignedShort();
                info.language = decodeMp4Language(langPacked);
            } else if (type == HDLR) {
                raf.seek(pos + 16); // skip header, version/flags, and predefined
                raf.readFully(buf, 0, 4);
                int subtype = readInt(buf, 0);
                if (subtype == VIDE) info.type = "video";
                else if (subtype == SOUN) info.type = "audio";
                else if (subtype == SUBT || subtype == SBTL || subtype == TEXT) info.type = "subtitle";
                else info.type = new String(buf, 0, 4, StandardCharsets.US_ASCII);
            } else if (type == MINF) {
                parseMinf(raf, pos, boxSize, info, buf);
            }

            if (boxSize < 8) break;
            raf.seek(pos + boxSize);
        }
    }

    static void parseMinf(RandomAccessFile raf, long minfStart, long minfSize, TrackInfo info, byte[] buf) throws IOException {
        long end = minfStart + minfSize;
        raf.seek(minfStart + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            raf.readFully(buf, 0, 8);
            long boxSize = Integer.toUnsignedLong(readInt(buf, 0));
            int type = readInt(buf, 4);

            if (boxSize == 1) {
                raf.readFully(buf, 8, 8);
                boxSize = readLong(buf, 8);
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }

            if (type == STBL) {
                parseStbl(raf, pos, boxSize, info, buf);
            }

            if (boxSize < 8) break;
            raf.seek(pos + boxSize);
        }
    }

    static void parseStbl(RandomAccessFile raf, long stblStart, long stblSize, TrackInfo info, byte[] buf) throws IOException {
        long end = stblStart + stblSize;
        raf.seek(stblStart + 8);
        while (raf.getFilePointer() + 8 <= end) {
            long pos = raf.getFilePointer();
            raf.readFully(buf, 0, 8);
            long boxSize = Integer.toUnsignedLong(readInt(buf, 0));
            int type = readInt(buf, 4);

            if (boxSize == 1) {
                raf.readFully(buf, 8, 8);
                boxSize = readLong(buf, 8);
            } else if (boxSize == 0) {
                boxSize = end - pos;
            }

            if (type == STSD) {
                info.stsdOffset = pos + 8;
                raf.seek(info.stsdOffset + 8); // skip version(1), flags(3), entryCount(4)
                raf.readFully(buf, 0, 8);
                int sampleType = readInt(buf, 4);
                // Fixed logic: Check directly against the 'fcd ' integer
                info.forcedFlag = (sampleType == FCD);
            }

            if (boxSize < 8) break;
            raf.seek(pos + boxSize);
        }
    }

    static void patchTkhdFlag(RandomAccessFile raf, long tkhdOffset, boolean set) throws IOException {
        raf.seek(tkhdOffset);
        byte[] buf = new byte[4];
        raf.readFully(buf);
        int vf = readInt(buf, 0);
        
        if (set) vf |= 1;
        else vf &= ~1;

        buf[0] = (byte) (vf >>> 24);
        buf[1] = (byte) (vf >>> 16);
        buf[2] = (byte) (vf >>> 8);
        buf[3] = (byte) vf;

        raf.seek(tkhdOffset);
        raf.write(buf);
    }

    static void patchStsdFlag(RandomAccessFile raf, long stsdOffset, boolean set) throws IOException {
        if (!set) return; // Unsetting requires knowing the original FourCC (which isn't stored). Avoid useless disk writes.
        raf.seek(stsdOffset + 12);
        raf.writeInt(FCD); 
    }

    static String decodeMp4Language(int packed) {
        if (packed == 0) return null;
        char c1 = (char) (((packed >> 10) & 0x1F) + 0x60);
        char c2 = (char) (((packed >> 5)  & 0x1F) + 0x60);
        char c3 = (char) ((packed & 0x1F) + 0x60);
        return "" + c1 + c2 + c3;
    }

    // Fast bitwise decoders to bypass ByteBuffer allocations
    static int readInt(byte[] buf, int off) {
        return ((buf[off] & 0xFF) << 24) |
               ((buf[off + 1] & 0xFF) << 16) |
               ((buf[off + 2] & 0xFF) << 8)  |
               (buf[off + 3] & 0xFF);
    }

    static long readLong(byte[] buf, int off) {
        return (((long) readInt(buf, off)) << 32) | (readInt(buf, off + 4) & 0xFFFFFFFFL);
    }
}
