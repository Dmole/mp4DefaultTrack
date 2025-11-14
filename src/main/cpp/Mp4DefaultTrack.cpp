// mp4track.cpp
// g++ -std=c++17 -O2 -o mp4track mp4track.cpp
// Usage:
//   ./mp4track list file.mp4
//   ./mp4track set file.mp4 <trackId> <default|forced>
//   ./mp4track unset file.mp4 <trackId> <default|forced>

#include <bits/stdc++.h>
using namespace std;

struct TrackInfo {
    uint64_t tkhdOffset = 0;   // payload start (version byte)
    uint64_t stsdOffset = 0;   // payload start (version byte)
    uint64_t mdhdOffset = 0;
    uint32_t trackId = 0;
    bool defaultFlag = false;
    bool forcedFlag = false;
    string type = "unknown";
    optional<string> lang;     // nullopt when unknown
};

static uint32_t read_u32(ifstream &f, uint64_t pos) {
    f.seekg(pos);
    uint8_t b[4];
    f.read((char*)b, 4);
    if (f.gcount() != 4) throw runtime_error("short read u32");
    return (uint32_t(b[0]) << 24) | (uint32_t(b[1]) << 16) | (uint32_t(b[2]) << 8) | uint32_t(b[3]);
}

static uint64_t read_u64(ifstream &f, uint64_t pos) {
    f.seekg(pos);
    uint8_t b[8];
    f.read((char*)b, 8);
    if (f.gcount() != 8) throw runtime_error("short read u64");
    uint64_t hi = (uint64_t(b[0])<<24) | (uint64_t(b[1])<<16) | (uint64_t(b[2])<<8) | uint64_t(b[3]);
    uint64_t lo = (uint64_t(b[4])<<24) | (uint64_t(b[5])<<16) | (uint64_t(b[6])<<8) | uint64_t(b[7]);
    return (hi << 32) | lo;
}

static string read_type(ifstream &f, uint64_t pos) {
    f.seekg(pos);
    char t[4];
    f.read(t,4);
    if (f.gcount() != 4) throw runtime_error("short read type");
    return string(t, 4);
}

static string decode_mp4_lang(int packed) {
    if (packed == 0) return string();
    char a = char(((packed >> 10) & 0x1F) + 0x60);
    char b = char(((packed >> 5)  & 0x1F) + 0x60);
    char c = char((packed & 0x1F) + 0x60);
    string s;
    s.push_back(a);
    s.push_back(b);
    s.push_back(c);
    return s;
}

static uint64_t file_size(ifstream &f) {
    f.seekg(0, ios::end);
    return (uint64_t)f.tellg();
}

// forward declares
static vector<TrackInfo> read_tracks(const string &path);
static vector<TrackInfo> parse_moov(ifstream &f, uint64_t start, uint64_t boxSize, uint64_t fileLen);
static optional<TrackInfo> parse_trak(ifstream &f, uint64_t start, uint64_t boxSize, uint64_t fileLen);
static void parse_mdia(ifstream &f, uint64_t start, uint64_t boxSize, TrackInfo &t, uint64_t fileLen);
static void parse_minf(ifstream &f, uint64_t start, uint64_t boxSize, TrackInfo &t, uint64_t fileLen);
static void parse_stbl(ifstream &f, uint64_t start, uint64_t boxSize, TrackInfo &t, uint64_t fileLen);

static tuple<uint32_t,string,uint64_t,uint64_t> read_box_header(ifstream &f, uint64_t pos, uint64_t fileLen) {
    // returns (size32, type, headerLen, boxSize)
    if (pos + 8 > fileLen) throw runtime_error("box header out of range");
    uint32_t size32 = read_u32(f, pos);
    string type = read_type(f, pos+4);
    uint64_t headerLen = 8;
    uint64_t boxSize = size32;
    if (size32 == 1) {
        // extended size at pos+8
        boxSize = read_u64(f, pos+8);
        headerLen = 16;
    } else if (size32 == 0) {
        boxSize = fileLen - pos;
    }
    return {size32, type, headerLen, boxSize};
}

vector<TrackInfo> read_tracks(const string &path) {
    ifstream f(path, ios::binary);
    if (!f) throw runtime_error("open failed");
    uint64_t fileLen = file_size(f);
    vector<TrackInfo> tracks;
    uint64_t pos = 0;
    while (pos + 8 <= fileLen) {
        uint32_t size32; string type; uint64_t hdrLen, boxSize;
        tie(size32, type, hdrLen, boxSize) = read_box_header(f, pos, fileLen);
        if (type == "moov") {
            auto t = parse_moov(f, pos, boxSize, fileLen);
            tracks.insert(tracks.end(), t.begin(), t.end());
        }
        if (boxSize < 8) break;
        pos += boxSize;
    }
    return tracks;
}

vector<TrackInfo> parse_moov(ifstream &f, uint64_t start, uint64_t boxSize, uint64_t fileLen) {
    vector<TrackInfo> tracks;
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end) {
        uint32_t size32; string type; uint64_t hdrLen, innerSize;
        tie(size32, type, hdrLen, innerSize) = read_box_header(f, pos, fileLen);
        if (type == "trak") {
            try {
                auto maybe = parse_trak(f, pos, innerSize, fileLen);
                if (maybe) tracks.push_back(*maybe);
            } catch (exception &e) {
                cerr << "warning: parse_trak failed at " << pos << ": " << e.what() << "\n";
            }
        }
        if (innerSize < 8) break;
        pos += innerSize;
    }
    return tracks;
}

optional<TrackInfo> parse_trak(ifstream &f, uint64_t start, uint64_t boxSize, uint64_t fileLen) {
    TrackInfo info;
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end) {
        uint32_t size32; string type; uint64_t hdrLen, innerSize;
        tie(size32, type, hdrLen, innerSize) = read_box_header(f, pos, fileLen);
        if (type == "tkhd") {
            uint64_t payload = pos + hdrLen;
            info.tkhdOffset = payload;
            f.seekg(payload);
            uint8_t v;
            f.read((char*)&v, 1);
            uint8_t f1,f2,f3;
            f.read((char*)&f1,1); f.read((char*)&f2,1); f.read((char*)&f3,1);
            uint32_t flags = (uint32_t(f1)<<16)|(uint32_t(f2)<<8)|uint32_t(f3);
            info.defaultFlag = (flags & 1) != 0;
            if (v == 1) {
                // skip creation/mod (8+8)
                f.seekg(16, ios::cur);
            } else {
                f.seekg(8, ios::cur);
            }
            uint8_t idbuf[4];
            f.read((char*)idbuf, 4);
            info.trackId = (uint32_t(idbuf[0])<<24)|(uint32_t(idbuf[1])<<16)|(uint32_t(idbuf[2])<<8)|uint32_t(idbuf[3]);
        } else if (type == "mdia") {
            parse_mdia(f, pos, innerSize, info, fileLen);
        }
        if (innerSize < 8) break;
        pos += innerSize;
    }
    if (info.trackId == 0) return {};
    return info;
}

void parse_mdia(ifstream &f, uint64_t start, uint64_t boxSize, TrackInfo &info, uint64_t fileLen) {
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end) {
        uint32_t size32; string type; uint64_t hdrLen, innerSize;
        tie(size32, type, hdrLen, innerSize) = read_box_header(f, pos, fileLen);
        if (type == "mdhd") {
            uint64_t payload = pos + hdrLen;
            info.mdhdOffset = payload;
            f.seekg(payload);
            uint8_t v; f.read((char*)&v,1);
            // skip remaining 3 flag bytes already consumed
            f.seekg(3, ios::cur);
            if (v == 1) {
                f.seekg(16, ios::cur); // creation + mod
            } else {
                f.seekg(8, ios::cur);
            }
            // timescale
            f.seekg(4, ios::cur);
            // duration
            if (v == 1) f.seekg(8, ios::cur);
            else f.seekg(4, ios::cur);
            // language: 2 bytes
            uint8_t lb[2];
            f.read((char*)lb, 2);
            int packed = (int(lb[0])<<8) | int(lb[1]);
            string s = decode_mp4_lang(packed);
            if (s.empty()) info.lang = nullopt;
            else info.lang = s;
        } else if (type == "hdlr") {
            // handler: at payload + 8 (version+flags(4)+pre_defined(4)), handler_type next 4 bytes
            uint64_t handlerTypePos = pos + hdrLen + 8;
            if (handlerTypePos + 4 <= fileLen) {
                string subtype = read_type(f, handlerTypePos);
                if (subtype == "vide") info.type = "video";
                else if (subtype == "soun") info.type = "audio";
                else if (subtype == "subt" || subtype == "sbtl" || subtype == "text") info.type = "subtitle";
                else info.type = subtype;
            }
        } else if (type == "minf") {
            parse_minf(f, pos, innerSize, info, fileLen);
        }
        if (innerSize < 8) break;
        pos += innerSize;
    }
}

void parse_minf(ifstream &f, uint64_t start, uint64_t boxSize, TrackInfo &info, uint64_t fileLen) {
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end) {
        uint32_t size32; string type; uint64_t hdrLen, innerSize;
        tie(size32, type, hdrLen, innerSize) = read_box_header(f, pos, fileLen);
        if (type == "stbl") {
            parse_stbl(f, pos, innerSize, info, fileLen);
        }
        if (innerSize < 8) break;
        pos += innerSize;
    }
}

void parse_stbl(ifstream &f, uint64_t start, uint64_t boxSize, TrackInfo &info, uint64_t fileLen) {
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end) {
        uint32_t size32; string type; uint64_t hdrLen, innerSize;
        tie(size32, type, hdrLen, innerSize) = read_box_header(f, pos, fileLen);
        if (type == "stsd") {
            uint64_t payload = pos + hdrLen;
            info.stsdOffset = payload;
            // sample entry header starts at payload + 8 (version+flags+entryCount)
            uint64_t entryHeader = payload + 8;
            // read 8 bytes sample-entry header (size + type)
            try {
                string sampleType = read_type(f, entryHeader + 4);
                string s = sampleType;
                for (auto &c : s) c = char(tolower(c));
                info.forcedFlag = (s.find("fcd") != string::npos);
            } catch (...) {
                // ignore
            }
        }
        if (innerSize < 8) break;
        pos += innerSize;
    }
}

// patch tkhd flags: write 3 bytes at tkhdOffset+1..+3
static void patch_tkhd_flag(const string &path, uint64_t tkhdOffset, bool set) {
    fstream f(path, ios::in | ios::out | ios::binary);
    if (!f) throw runtime_error("open for patch failed");
    f.seekg(tkhdOffset + 1);
    uint8_t buf[3];
    f.read((char*)buf, 3);
    if (f.gcount() != 3) throw runtime_error("short read tkhd flags");
    unsigned flags = (unsigned(buf[0])<<16)|(unsigned(buf[1])<<8)|unsigned(buf[2]);
    if (set) flags |= 1; else flags &= ~1u;
    uint8_t out[3] = { uint8_t((flags>>16)&0xff), uint8_t((flags>>8)&0xff), uint8_t(flags&0xff) };
    f.seekp(tkhdOffset + 1);
    f.write((char*)out, 3);
    f.flush();
}

// patch stsd sample entry type to "fcd " at (stsdOffset + 8) + 4
static void patch_stsd_forced(const string &path, uint64_t stsdOffset, bool set) {
    fstream f(path, ios::in | ios::out | ios::binary);
    if (!f) throw runtime_error("open for patch failed");
    uint64_t entryHeaderPos = stsdOffset + 8;
    // sample entry header type is at entryHeaderPos + 4
    if (set) {
        f.seekp(entryHeaderPos + 4);
        const char m[4] = {'f','c','d',' '};
        f.write(m, 4);
        f.flush();
    } else {
        // cannot restore original without storing it; do nothing
    }
}

int main_entry(int argc, char **argv) {
    if (argc < 3) {
        cerr << "Usage: " << argv[0] << " list|set|unset <file> [trackId] [default|forced]\n";
        return 2;
    }
    string cmd = argv[1];
    string file = argv[2];

    try {
        if (cmd == "list") {
            auto tracks = read_tracks(file);
            // print JSON
            cout << "[\n";
            for (size_t i = 0; i < tracks.size(); ++i) {
                auto &t = tracks[i];
                cout << "\t{\"id\": " << t.trackId
                     << ", \"type\": \"" << t.type << "\""
                     << ", \"lang\": ";
                if (t.lang) cout << "\"" << *t.lang << "\"";
                else cout << "null";
                cout << ", \"default\": " << (t.defaultFlag ? "true" : "false")
                     << ", \"forced\": " << (t.forcedFlag ? "true" : "false")
                     << "}";
                if (i+1 < tracks.size()) cout << ",";
                cout << "\n";
            }
            cout << "]\n";
            return 0;
        } else if (cmd == "set" || cmd == "unset") {
            if (argc < 5) {
                cerr << "Usage: " << argv[0] << " " << cmd << " <file> <trackId> <default|forced>\n";
                return 2;
            }
            uint32_t tid = (uint32_t)stoi(argv[3]);
            string flag = argv[4];
            bool set = (cmd == "set");
            auto tracks = read_tracks(file);
            bool found = false;
            for (auto &t : tracks) {
                if (t.trackId == tid) {
                    found = true;
                    if (flag == "default") {
                        if (t.tkhdOffset == 0) throw runtime_error("no tkhd for track");
                        patch_tkhd_flag(file, t.tkhdOffset, set);
                    } else if (flag == "forced") {
                        if (t.stsdOffset == 0) throw runtime_error("no stsd for track");
                        patch_stsd_forced(file, t.stsdOffset, set);
                    } else {
                        throw runtime_error("unknown flag");
                    }
                    break;
                }
            }
            if (!found) {
                cerr << "track not found\n";
                return 1;
            }
            return 0;
        } else {
            cerr << "unknown command\n";
            return 2;
        }
    } catch (exception &e) {
        cerr << "error: " << e.what() << "\n";
        return 1;
    }
}

int main(int argc, char **argv) {
    return main_entry(argc, argv);
}

