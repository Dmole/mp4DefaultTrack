#include <iostream>
#include <vector>
#include <string>
#include <stdexcept>
#include <cstdint>
#include <cstring>
#include <cctype>

// Cross-platform OS headers for Memory Mapping
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

// ---------------------------------------------------------
// 1. Cross-Platform Memory Mapped File Wrapper
// ---------------------------------------------------------
class MmapFile {
public:
    uint8_t* data = nullptr;
    size_t size = 0;

    MmapFile(const char* path, bool write_access) {
#ifdef _WIN32
        DWORD access = write_access ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ;
        DWORD share = FILE_SHARE_READ | (write_access ? 0 : FILE_SHARE_WRITE);
        HANDLE hFile = CreateFileA(path, access, share, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile == INVALID_HANDLE_VALUE) throw std::runtime_error("Failed to open file");
        
        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(hFile, &fileSize)) {
            CloseHandle(hFile);
            throw std::runtime_error("Failed to get file size");
        }
        size = fileSize.QuadPart;

        DWORD protect = write_access ? PAGE_READWRITE : PAGE_READONLY;
        hMap = CreateFileMappingA(hFile, NULL, protect, 0, 0, NULL);
        if (!hMap) {
            CloseHandle(hFile);
            throw std::runtime_error("Failed to map file");
        }

        DWORD mapAccess = write_access ? FILE_MAP_ALL_ACCESS : FILE_MAP_READ;
        data = (uint8_t*)MapViewOfFile(hMap, mapAccess, 0, 0, 0);
        CloseHandle(hFile); // Safe to close file handle after mapping
        
        if (!data) throw std::runtime_error("Failed to view map");
#else
        int flags = write_access ? O_RDWR : O_RDONLY;
        fd = open(path, flags);
        if (fd < 0) throw std::runtime_error("Failed to open file");

        struct stat st;
        if (fstat(fd, &st) < 0) {
            close(fd);
            throw std::runtime_error("Failed to stat file");
        }
        size = st.st_size;

        int prot = PROT_READ | (write_access ? PROT_WRITE : 0);
        data = (uint8_t*)mmap(nullptr, size, prot, MAP_SHARED, fd, 0);
        if (data == MAP_FAILED) {
            close(fd);
            throw std::runtime_error("Failed to mmap file");
        }
#endif
    }

    ~MmapFile() {
#ifdef _WIN32
        if (data) UnmapViewOfFile(data);
        if (hMap) CloseHandle(hMap);
#else
        if (data && data != MAP_FAILED) munmap(data, size);
        if (fd >= 0) close(fd);
#endif
    }

private:
#ifdef _WIN32
    HANDLE hMap = NULL;
#else
    int fd = -1;
#endif
};


// ---------------------------------------------------------
// 2. Optimized POD Data Structures & Core Utilities
// ---------------------------------------------------------
struct TrackInfo {
    uint64_t tkhdOffset = 0;
    uint64_t stsdOffset = 0;
    uint32_t trackId = 0;
    char type[10] = "unknown"; // Fixed array (no heap allocation)
    char lang[4] = {0};        // 3 chars + null terminator
    bool defaultFlag = false;
    bool forcedFlag = false;
    bool valid = false;        // Replaces std::optional
};

struct Box {
    uint32_t size32;
    char type[5];
    uint64_t hdrLen;
    uint64_t boxSize;
};

static inline uint32_t read_u32(const uint8_t* data) {
    return (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) | (uint32_t(data[2]) << 8) | uint32_t(data[3]);
}

static inline uint64_t read_u64(const uint8_t* data) {
    return (uint64_t(read_u32(data)) << 32) | read_u32(data + 4);
}

static bool read_box_header(const uint8_t* data, uint64_t pos, uint64_t fileLen, Box& out) {
    if (pos + 8 > fileLen) return false;
    out.size32 = read_u32(data + pos);
    
    for(int i = 0; i < 4; ++i) out.type[i] = (char)data[pos + 4 + i];
    out.type[4] = '\0';
    
    out.hdrLen = 8;
    out.boxSize = out.size32;

    if (out.size32 == 1) {
        if (pos + 16 > fileLen) return false;
        out.boxSize = read_u64(data + pos + 8);
        out.hdrLen = 16;
    } else if (out.size32 == 0) {
        out.boxSize = fileLen - pos;
    }
    return true;
}

static void decode_mp4_lang(uint16_t packed, char out[4]) {
    if (packed == 0 || packed == 0x7FFF) { 
        out[0] = '\0'; return; 
    }
    out[0] = (char)(((packed >> 10) & 0x1F) + 0x60);
    out[1] = (char)(((packed >> 5)  & 0x1F) + 0x60);
    out[2] = (char)((packed & 0x1F) + 0x60);
    out[3] = '\0';
}


// ---------------------------------------------------------
// 3. High-Speed Zero-Copy Parsing Logic
// ---------------------------------------------------------

static void parse_stbl(const uint8_t* data, uint64_t start, uint64_t boxSize, uint64_t fileLen, TrackInfo& info) {
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end && pos < fileLen) {
        Box b;
        if (!read_box_header(data, pos, fileLen, b)) break;
        
        if (memcmp(b.type, "stsd", 4) == 0) {
            uint64_t payload = pos + b.hdrLen;
            info.stsdOffset = payload;
            if (payload + 16 <= fileLen) {
                uint64_t entryHeader = payload + 8;
                char sampleType[5];
                for(int i=0; i<4; ++i) sampleType[i] = (char)tolower(data[entryHeader + 4 + i]);
                if (sampleType[0] == 'f' && sampleType[1] == 'c' && sampleType[2] == 'd') {
                    info.forcedFlag = true;
                }
            }
        }
        if (b.boxSize < 8) break;
        pos += b.boxSize;
    }
}

static void parse_minf(const uint8_t* data, uint64_t start, uint64_t boxSize, uint64_t fileLen, TrackInfo& info) {
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end && pos < fileLen) {
        Box b;
        if (!read_box_header(data, pos, fileLen, b)) break;
        if (memcmp(b.type, "stbl", 4) == 0) parse_stbl(data, pos, b.boxSize, fileLen, info);
        if (b.boxSize < 8) break;
        pos += b.boxSize;
    }
}

static void parse_mdia(const uint8_t* data, uint64_t start, uint64_t boxSize, uint64_t fileLen, TrackInfo& info) {
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    while (pos + 8 <= end && pos < fileLen) {
        Box b;
        if (!read_box_header(data, pos, fileLen, b)) break;
        
        if (memcmp(b.type, "mdhd", 4) == 0) {
            uint64_t payload = pos + b.hdrLen;
            if (payload + 4 <= fileLen) {
                uint8_t v = data[payload];
                uint64_t offset = payload + 4; // Skip version and flags
                offset += (v == 1) ? 16 : 8;   // Skip creation & modification time
                offset += 4;                   // Skip timescale
                offset += (v == 1) ? 8 : 4;    // Skip duration
                
                if (offset + 2 <= fileLen) {
                    uint16_t packed = (uint16_t(data[offset]) << 8) | data[offset+1];
                    decode_mp4_lang(packed, info.lang);
                }
            }
        } else if (memcmp(b.type, "hdlr", 4) == 0) {
            uint64_t handlerTypePos = pos + b.hdrLen + 8;
            if (handlerTypePos + 4 <= fileLen) {
                const uint8_t* sub = data + handlerTypePos;
                if (memcmp(sub, "vide", 4) == 0) strcpy(info.type, "video");
                else if (memcmp(sub, "soun", 4) == 0) strcpy(info.type, "audio");
                else if (memcmp(sub, "subt", 4) == 0 || memcmp(sub, "sbtl", 4) == 0 || memcmp(sub, "text", 4) == 0) {
                    strcpy(info.type, "subtitle");
                } else {
                    memcpy(info.type, sub, 4);
                    info.type[4] = '\0';
                }
            }
        } else if (memcmp(b.type, "minf", 4) == 0) {
            parse_minf(data, pos, b.boxSize, fileLen, info);
        }
        
        if (b.boxSize < 8) break;
        pos += b.boxSize;
    }
}

static TrackInfo parse_trak(const uint8_t* data, uint64_t start, uint64_t boxSize, uint64_t fileLen) {
    TrackInfo info;
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    
    while (pos + 8 <= end && pos < fileLen) {
        Box b;
        if (!read_box_header(data, pos, fileLen, b)) break;
        
        if (memcmp(b.type, "tkhd", 4) == 0) {
            uint64_t payload = pos + b.hdrLen;
            info.tkhdOffset = payload;
            if (payload + 4 <= fileLen) {
                uint8_t v = data[payload];
                uint32_t flags = (uint32_t(data[payload+1]) << 16) | (uint32_t(data[payload+2]) << 8) | data[payload+3];
                info.defaultFlag = (flags & 1) != 0;
                
                uint64_t idOffset = payload + 4 + ((v == 1) ? 16 : 8);
                if (idOffset + 4 <= fileLen) {
                    info.trackId = read_u32(data + idOffset);
                }
            }
        } else if (memcmp(b.type, "mdia", 4) == 0) {
            parse_mdia(data, pos, b.boxSize, fileLen, info);
        }
        
        if (b.boxSize < 8) break;
        pos += b.boxSize;
    }
    
    if (info.trackId != 0) info.valid = true;
    return info;
}

static std::vector<TrackInfo> parse_moov(const uint8_t* data, uint64_t start, uint64_t boxSize, uint64_t fileLen) {
    std::vector<TrackInfo> tracks;
    uint64_t end = start + boxSize;
    uint64_t pos = start + 8;
    
    while (pos + 8 <= end && pos < fileLen) {
        Box b;
        if (!read_box_header(data, pos, fileLen, b)) break;
        
        if (memcmp(b.type, "trak", 4) == 0) {
            TrackInfo t = parse_trak(data, pos, b.boxSize, fileLen);
            if (t.valid) tracks.push_back(t);
        }
        
        if (b.boxSize < 8) break;
        pos += b.boxSize;
    }
    return tracks;
}

static std::vector<TrackInfo> read_tracks(const uint8_t* data, uint64_t fileLen) {
    std::vector<TrackInfo> tracks;
    uint64_t pos = 0;
    while (pos + 8 <= fileLen) {
        Box b;
        if (!read_box_header(data, pos, fileLen, b)) break;
        if (memcmp(b.type, "moov", 4) == 0) {
            auto t = parse_moov(data, pos, b.boxSize, fileLen);
            tracks.insert(tracks.end(), t.begin(), t.end());
        }
        if (b.boxSize < 8) break;
        pos += b.boxSize;
    }
    return tracks;
}


// ---------------------------------------------------------
// 4. In-Memory Direct Patching 
// ---------------------------------------------------------
// Because the file is mapped with MAP_SHARED / PAGE_READWRITE, 
// modifying the pointer's memory instantly syncs to the disk.

static void patch_tkhd_flag(uint8_t* data, uint64_t tkhdOffset, bool set) {
    uint32_t flags = (uint32_t(data[tkhdOffset+1]) << 16) | 
                     (uint32_t(data[tkhdOffset+2]) << 8)  | 
                     uint32_t(data[tkhdOffset+3]);
    if (set) flags |= 1; 
    else flags &= ~1u;
    
    data[tkhdOffset+1] = (flags >> 16) & 0xFF;
    data[tkhdOffset+2] = (flags >> 8)  & 0xFF;
    data[tkhdOffset+3] = flags & 0xFF;
}

static void patch_stsd_forced(uint8_t* data, uint64_t stsdOffset, bool set) {
    if (set) {
        uint64_t target = stsdOffset + 8 + 4;
        data[target]   = 'f';
        data[target+1] = 'c';
        data[target+2] = 'd';
        data[target+3] = ' ';
    }
    // Unsetting remains a no-op as the original codec is overwritten.
}


// ---------------------------------------------------------
// Main Entry
// ---------------------------------------------------------
int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "Usage: " << argv[0] << " list|set|unset <file> [trackId] [default|forced]\n";
        return 2;
    }
    std::string cmd = argv[1];
    const char* file = argv[2];

    try {
        if (cmd == "list") {
            // Read-Only Map
            MmapFile mmap(file, false);
            auto tracks = read_tracks(mmap.data, mmap.size);
            
            std::cout << "[\n";
            for (size_t i = 0; i < tracks.size(); ++i) {
                auto &t = tracks[i];
                std::cout << "\t{\"id\": " << t.trackId
                          << ", \"type\": \"" << t.type << "\""
                          << ", \"lang\": ";
                if (t.lang[0] != '\0') std::cout << "\"" << t.lang << "\"";
                else std::cout << "null";
                std::cout << ", \"default\": " << (t.defaultFlag ? "true" : "false")
                          << ", \"forced\": " << (t.forcedFlag ? "true" : "false")
                          << "}";
                if (i + 1 < tracks.size()) std::cout << ",";
                std::cout << "\n";
            }
            std::cout << "]\n";
            return 0;
            
        } else if (cmd == "set" || cmd == "unset") {
            if (argc < 5) {
                std::cerr << "Usage: " << argv[0] << " " << cmd << " <file> <trackId> <default|forced>\n";
                return 2;
            }
            uint32_t tid = (uint32_t)std::stoi(argv[3]);
            std::string flag = argv[4];
            bool set_flag = (cmd == "set");
            
            // Read/Write Map
            MmapFile mmap(file, true); 
            auto tracks = read_tracks(mmap.data, mmap.size);
            
            bool found = false;
            for (auto &t : tracks) {
                if (t.trackId == tid) {
                    found = true;
                    if (flag == "default") {
                        if (t.tkhdOffset == 0) throw std::runtime_error("no tkhd for track");
                        patch_tkhd_flag(mmap.data, t.tkhdOffset, set_flag);
                    } else if (flag == "forced") {
                        if (t.stsdOffset == 0) throw std::runtime_error("no stsd for track");
                        patch_stsd_forced(mmap.data, t.stsdOffset, set_flag);
                    } else {
                        throw std::runtime_error("unknown flag");
                    }
                    break;
                }
            }
            if (!found) {
                std::cerr << "track not found\n";
                return 1;
            }
            return 0;
        } else {
            std::cerr << "unknown command\n";
            return 2;
        }
    } catch (const std::exception &e) {
        std::cerr << "error: " << e.what() << "\n";
        return 1;
    }
}
