import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class Mp4DefaultTrack {

	public static void main(String[] args) throws Exception {
		if (args.length < 2) {
			System.err.println("Usage: java Mp4TrackFlagTool <list|set|unset> <file> [trackId] [default|forced]");
			return;
		}

		String cmd = args[0];
		File file = new File(args[1]);
		String flag = args.length >= 4 ? args[3] : "default";
		Integer trackId = (args.length >= 3 && args[2].matches("\\d+")) ? Integer.valueOf(args[2]) : null;

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
		System.out.println("[");
		for (int i = 0; i < tracks.size(); i++) {
			TrackInfo t = tracks.get(i);
			System.out.printf("	{\"id\": %d, \"type\": \"%s\", \"lang\": \"%s\", \"default\": %s, \"forced\": %s}%s%n",
					t.trackId, t.type, t.language, t.defaultFlag, t.forcedFlag, (i == tracks.size() - 1 ? "" : ","));
		}
		System.out.println("]");
	}

	static void setFlag(File f, int id, String flag, boolean val) throws IOException {
		List<TrackInfo> tracks = readTracks(f);
		RandomAccessFile raf = new RandomAccessFile(f, "rw");
		try {
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
		} finally {
			raf.close();
		}
	}

	static long readUInt32(RandomAccessFile raf) throws IOException {
		return raf.readInt() & 0xffffffffL;
	}

	static String readType(RandomAccessFile raf) throws IOException {
		byte[] typeBytes = new byte[4];
		raf.readFully(typeBytes);
		return new String(typeBytes, StandardCharsets.US_ASCII);
	}

	static List<TrackInfo> readTracks(File f) throws IOException {
		List<TrackInfo> tracks = new ArrayList<TrackInfo>();
		RandomAccessFile raf = new RandomAccessFile(f, "r");
		try {
			long fileLen = raf.length();
			while (raf.getFilePointer() + 8 <= fileLen) {
				long pos = raf.getFilePointer();
				long size = readUInt32(raf);
				String type = readType(raf);
				if (size == 1) {
					size = raf.readLong();
				} else if (size == 0) {
					size = fileLen - pos;
				}
				if ("moov".equals(type)) {
					parseMoov(raf, pos, size, tracks);
				}
				if (size < 8) {
					break;
				} else {
					raf.seek(pos + size);
				}
			}
		} finally {
			raf.close();
		}
		return tracks;
	}

	static void parseMoov(RandomAccessFile raf, long start, long size, List<TrackInfo> tracks) throws IOException {
		long end = start + size;
		raf.seek(start + 8);
		while (raf.getFilePointer() + 8 <= end) {
			long pos = raf.getFilePointer();
			long boxSize = readUInt32(raf);
			String type = readType(raf);
			if (boxSize == 1) {
				boxSize = raf.readLong();
			} else if (boxSize == 0) {
				boxSize = end - pos;
			}
			if ("trak".equals(type)) {
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
			String type = readType(raf);
			if (boxSize == 1) {
				boxSize = raf.readLong();
			} else if (boxSize == 0) {
				boxSize = end - pos;
			}
			if ("tkhd".equals(type)) {
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
			} else if ("mdia".equals(type)) {
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

	// Safe way to find next valid MP4 atom header (skip padding or junk)
	static boolean skipToNextBox(RandomAccessFile raf, long fileLen) throws IOException {
		long p = raf.getFilePointer();
		while (p + 8 <= fileLen) {
			raf.seek(p);
			int size = raf.readInt();
			int c1 = raf.read();
			int c2 = raf.read();
			int c3 = raf.read();
			int c4 = raf.read();
			if (size >= 8 && c1 >= 32 && c1 < 127 && c2 >= 32 && c2 < 127 && c3 >= 32 && c3 < 127 && c4 >= 32
					&& c4 < 127) {
				raf.seek(p);
				return true;
			}
			p++;
		}
		return false;
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
			String type = new String(header, 4, 4, StandardCharsets.US_ASCII);
			if (size < 8) {
				break;
			}
			if ("mdhd".equals(type)) {
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
			} else if ("hdlr".equals(type)) {
				raf.skipBytes(8); // version+flags+predefined
				byte[] htype = new byte[4];
				raf.readFully(htype);
				String subtype = new String(htype, StandardCharsets.US_ASCII);
				if ("vide".equals(subtype)) {
					info.type = "video";
				} else if ("soun".equals(subtype)) {
					info.type = "audio";
				} else if ("subt".equals(subtype) || "sbtl".equals(subtype) || "text".equals(subtype)) {
					info.type = "subtitle";
				} else {
					info.type = subtype;
				}
			} else if ("minf".equals(type)) {
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
			String type = new String(header, 4, 4, StandardCharsets.US_ASCII);
			if (size < 8) {
				break;
			}
			if ("stbl".equals(type)) {
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
			String type = new String(header, 4, 4, StandardCharsets.US_ASCII);
			if (size < 8) {
				break;
			}
			if ("stsd".equals(type)) {
				info.stsdOffset = pos + 8;
				raf.seek(info.stsdOffset + 8); // skip version+flags+entryCount
				byte[] entryHeader = new byte[8];
				if (raf.read(entryHeader) == 8) {
					String sampleType = new String(entryHeader, 4, 4, StandardCharsets.US_ASCII);
					info.forcedFlag = sampleType.toLowerCase().contains("forced");
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
