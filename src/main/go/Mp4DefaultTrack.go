package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
)

type TrackInfo struct {
	TkhdOffset int64
	StsdOffset int64
	MdhdOffset int64
	TrackId    uint32
	Type       string
	Language   string
	Default    bool
	Forced     bool
	Valid      bool
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: mp4GoTrack <list|set|unset> <file> [trackId] [default|forced]")
		return
	}

	cmd := os.Args[1]
	file := os.Args[2]

	var trackId uint32
	flag := "default"
	hasId := false

	if len(os.Args) >= 4 {
		var v uint32
		if _, err := fmt.Sscan(os.Args[3], &v); err == nil {
			trackId = v
			hasId = true
		}
	}
	if len(os.Args) >= 5 {
		flag = os.Args[4]
	}

	switch cmd {
	case "list":
		doList(file)
	case "set":
		if !hasId {
			panic("Missing trackId")
		}
		doSetUnset(file, trackId, flag, true)
	case "unset":
		if !hasId {
			panic("Missing trackId")
		}
		doSetUnset(file, trackId, flag, false)
	default:
		panic("Unknown command: " + cmd)
	}
}

// ---------------------------------------------------------
// Fast-Path Binary Decoders 
// ---------------------------------------------------------

func readU16(b []byte, off int64) uint16 {
	b = b[off : off+2]
	_ = b[1]
	return uint16(b[0])<<8 | uint16(b[1])
}

func readU32(b []byte, off int64) uint32 {
	b = b[off : off+4]
	_ = b[3]
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

func readU64(b []byte, off int64) uint64 {
	b = b[off : off+8]
	_ = b[7]
	return uint64(b[0])<<56 | uint64(b[1])<<48 | uint64(b[2])<<40 | uint64(b[3])<<32 |
		uint64(b[4])<<24 | uint64(b[5])<<16 | uint64(b[6])<<8 | uint64(b[7])
}

func decodeLanguage(bits uint16) string {
	if bits == 0 || bits == 0x7FFF {
		return ""
	}
	c1 := (bits>>10)&31 + 0x60
	c2 := (bits>>5)&31 + 0x60
	c3 := bits&31 + 0x60
	return string([]byte{byte(c1), byte(c2), byte(c3)})
}

// ---------------------------------------------------------
// High-Speed Zero-Copy Parsers
// ---------------------------------------------------------

func doList(path string) {
	data, unmap, err := mapFile(path)
	if err != nil {
		panic(err)
	}
	defer unmap()

	tracks := readTracks(data)

	fmt.Println("[")
	for i, t := range tracks {
		fmt.Printf("\t{\"id\": %d, \"type\": \"%s\", \"lang\": \"%s\", \"default\": %t, \"forced\": %t}",
			t.TrackId, t.Type, t.Language, t.Default, t.Forced)
		if i != len(tracks)-1 {
			fmt.Println(",")
		} else {
			fmt.Println()
		}
	}
	fmt.Println("]")
}

func doSetUnset(path string, id uint32, flag string, val bool) {
	data, unmap, err := mapFile(path)
	if err != nil {
		panic(err)
	}
	
	tracks := readTracks(data)
	unmap() // Unmap immediately so we safely write to the file below

	var target *TrackInfo
	for i := range tracks {
		if tracks[i].TrackId == id {
			target = &tracks[i]
			break
		}
	}

	if target == nil {
		panic("Track not found")
	}

	// Open file synchronously for atomic 3-byte writes.
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		panic(err)
	}
	defer f.Close()

	if flag == "default" {
		patchTkhdFlag(f, target.TkhdOffset, val)
	} else if flag == "forced" {
		patchStsdFlag(f, target.StsdOffset, val)
	} else {
		panic("Unknown flag: " + flag)
	}
	
	f.Sync() // Guarantee changes hit disk before test md5 runs
}

func readTracks(data []byte) []TrackInfo {
	var tracks []TrackInfo
	var pos int64 = 0
	fileLen := int64(len(data))

	for pos+8 <= fileLen {
		sz := readU32(data, pos)
		typ := string(data[pos+4 : pos+8]) // Go compiler zero-allocates this equality check

		boxSize := int64(sz)
		if sz == 1 {
			boxSize = int64(readU64(data, pos+8))
		} else if sz == 0 {
			boxSize = fileLen - pos
		}

		if typ == "moov" {
			parseMoov(data, pos, boxSize, &tracks)
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
	return tracks
}

func parseMoov(data []byte, start, size int64, tracks *[]TrackInfo) {
	end := start + size
	pos := start + 8
	for pos+8 <= end {
		sz := readU32(data, pos)
		typ := string(data[pos+4 : pos+8])
		boxSize := int64(sz)
		if sz == 1 {
			boxSize = int64(readU64(data, pos+8))
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "trak" {
			info := parseTrak(data, pos, boxSize)
			if info.Valid {
				*tracks = append(*tracks, info)
			}
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseTrak(data []byte, start, size int64) TrackInfo {
	var info TrackInfo
	end := start + size
	pos := start + 8

	for pos+8 <= end {
		sz := readU32(data, pos)
		typ := string(data[pos+4 : pos+8])
		boxSize := int64(sz)
		if sz == 1 {
			boxSize = int64(readU64(data, pos+8))
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "tkhd" {
			info.TkhdOffset = pos + 8
			parseTkhd(data, pos, &info)
		} else if typ == "mdia" {
			parseMdia(data, pos, boxSize, &info)
		}

		if boxSize < 8 {
			break
		}
		pos += boxSize
	}

	if info.TrackId != 0 {
		info.Valid = true
	}
	return info
}

func parseTkhd(data []byte, start int64, info *TrackInfo) {
	version := data[start+8]
	f1, f2, f3 := data[start+9], data[start+10], data[start+11]
	flags := uint32(f1)<<16 | uint32(f2)<<8 | uint32(f3)
	info.Default = (flags & 1) != 0

	offset := start + 12
	if version == 1 {
		offset += 16
	} else {
		offset += 8
	}
	info.TrackId = readU32(data, offset)
}

func parseMdia(data []byte, start, size int64, info *TrackInfo) {
	end := start + size
	pos := start + 8
	for pos+8 <= end {
		sz := readU32(data, pos)
		typ := string(data[pos+4 : pos+8])
		boxSize := int64(sz)
		if sz == 1 {
			boxSize = int64(readU64(data, pos+8))
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "mdhd" {
			parseMdhd(data, pos, info)
		} else if typ == "hdlr" {
			parseHdlr(data, pos, info)
		} else if typ == "minf" {
			parseMinf(data, pos, boxSize, info)
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseMdhd(data []byte, pos int64, info *TrackInfo) {
	info.MdhdOffset = pos + 8
	version := data[pos+8]
	cur := pos + 12

	if version == 1 {
		cur += 16 
	} else {
		cur += 8
	}
	cur += 4 
	if version == 1 {
		cur += 8 
	} else {
		cur += 4
	}

	langBits := readU16(data, cur)
	info.Language = decodeLanguage(langBits)
}

func parseHdlr(data []byte, pos int64, info *TrackInfo) {
	htype := string(data[pos+16 : pos+20])
	switch htype {
	case "vide":
		info.Type = "video"
	case "soun":
		info.Type = "audio"
	case "subt", "sbtl", "text":
		info.Type = "subtitle"
	default:
		info.Type = htype
	}
}

func parseMinf(data []byte, start, size int64, info *TrackInfo) {
	end := start + size
	pos := start + 8
	for pos+8 <= end {
		sz := readU32(data, pos)
		typ := string(data[pos+4 : pos+8])
		boxSize := int64(sz)
		if sz == 1 {
			boxSize = int64(readU64(data, pos+8))
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "stbl" {
			parseStbl(data, pos, boxSize, info)
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseStbl(data []byte, start, size int64, info *TrackInfo) {
	end := start + size
	pos := start + 8
	for pos+8 <= end {
		sz := readU32(data, pos)
		typ := string(data[pos+4 : pos+8])
		boxSize := int64(sz)
		if sz == 1 {
			boxSize = int64(readU64(data, pos+8))
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "stsd" {
			info.StsdOffset = pos + 8
			if info.StsdOffset+16 <= int64(len(data)) {
				sampleType := string(data[info.StsdOffset+12 : info.StsdOffset+16])
				lc := strings.ToLower(sampleType)
				info.Forced = strings.Contains(lc, "fcd") || strings.Contains(lc, "forced")
			}
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

// ---------------------------------------------------------
// Synchronous File Patchers
// ---------------------------------------------------------

func patchTkhdFlag(f *os.File, offset int64, val bool) {
	var b [3]byte
	f.ReadAt(b[:], offset+1)
	
	flags := uint32(b[0])<<16 | uint32(b[1])<<8 | uint32(b[2])

	if val {
		flags |= 1
	} else {
		flags &^= 1
	}

	b[0] = byte(flags >> 16)
	b[1] = byte(flags >> 8)
	b[2] = byte(flags)
	
	f.WriteAt(b[:], offset+1)
}

func patchStsdFlag(f *os.File, offset int64, val bool) {
	var b [4]byte
	f.ReadAt(b[:], offset+12)
	curType := string(b[:])
	
	if val {
		curType = "fcd "
	}
	f.WriteAt([]byte(curType), offset+12)
}

// ---------------------------------------------------------
// POSIX Read-Only Mmap Wrapper
// ---------------------------------------------------------

func mapFile(path string) ([]byte, func(), error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return nil, nil, err
	}
	size := stat.Size()
	if size == 0 {
		return nil, nil, fmt.Errorf("file is empty")
	}

	// Always map as PROT_READ. It's incredibly fast and completely prevents page syncing bugs.
	data, err := syscall.Mmap(int(f.Fd()), 0, int(size), syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return nil, nil, err
	}

	unmap := func() {
		syscall.Munmap(data)
	}
	return data, unmap, nil
}
