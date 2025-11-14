package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"strings"
)

type TrackInfo struct {
	TkhdOffset int64
	StsdOffset int64
	MdhdOffset int64
	TrackId    int
	Default    bool
	Forced     bool
	Type       string
	Language   string
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: mp4GoTrack <list|set|unset> <file> [trackId] [default|forced]")
		return
	}

	cmd := os.Args[1]
	file := os.Args[2]

	var trackId int
	flag := "default"
	hasId := false

	if len(os.Args) >= 4 {
		if v, err := atoi(os.Args[3]); err == nil {
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

func atoi(s string) (int, error) {
	var v int
	_, err := fmt.Sscan(s, &v)
	return v, err
}

func doList(path string) {
	tracks, err := readTracks(path)
	if err != nil {
		panic(err)
	}

	fmt.Println("[")
	for i, t := range tracks {
		fmt.Printf("  {\"id\": %d, \"type\": \"%s\", \"lang\": \"%s\", \"default\": %t, \"forced\": %t}",
			t.TrackId, t.Type, t.Language, t.Default, t.Forced)
		if i != len(tracks)-1 {
			fmt.Println(",")
		} else {
			fmt.Println()
		}
	}
	fmt.Println("]")
}

func doSetUnset(path string, id int, flag string, val bool) {
	tracks, err := readTracks(path)
	if err != nil {
		panic(err)
	}

	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		panic(err)
	}
	defer f.Close()

	for _, t := range tracks {
		if t.TrackId != id {
			continue
		}

		if flag == "default" {
			patchTkhdFlag(f, t.TkhdOffset, val)
		} else if flag == "forced" {
			patchStsdFlag(f, t.StsdOffset, val)
		} else {
			panic("Unknown flag: " + flag)
		}
	}
}

func readTracks(path string) ([]*TrackInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	stat, _ := f.Stat()
	fileLen := stat.Size()

	var tracks []*TrackInfo

	var pos int64 = 0
	for pos+8 <= fileLen {
		size, _ := readU32At(f, pos)
		typ, _ := readTypeAt(f, pos+4)

		boxSize := int64(size)
		if size == 1 {
			ext, _ := readU64At(f, pos+8)
			boxSize = int64(ext)
		} else if size == 0 {
			boxSize = fileLen - pos
		}
		if typ == "moov" {
			parseMoov(f, pos, boxSize, &tracks)
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}

	return tracks, nil
}

func parseMoov(f *os.File, start int64, size int64, tracks *[]*TrackInfo) {
	end := start + size
	pos := start + 8

	for pos+8 <= end {
		sz, _ := readU32At(f, pos)
		typ, _ := readTypeAt(f, pos+4)

		boxSize := int64(sz)
		if sz == 1 {
			ext, _ := readU64At(f, pos+8)
			boxSize = int64(ext)
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "trak" {
			info := parseTrak(f, pos, boxSize)
			if info != nil {
				*tracks = append(*tracks, info)
			}
		}
		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseTrak(f *os.File, start int64, size int64) *TrackInfo {
	info := &TrackInfo{}
	end := start + size
	pos := start + 8

	for pos+8 <= end {
		sz, _ := readU32At(f, pos)
		typ, _ := readTypeAt(f, pos+4)

		boxSize := int64(sz)
		if sz == 1 {
			ext, _ := readU64At(f, pos+8)
			boxSize = int64(ext)
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "tkhd" {
			info.TkhdOffset = pos + 8
			parseTkhd(f, pos, boxSize, info)
		} else if typ == "mdia" {
			parseMdia(f, pos, boxSize, info)
		}

		if boxSize < 8 {
			break
		}
		pos += boxSize
	}

	if info.TrackId == 0 {
		return nil
	}
	return info
}

func parseTkhd(f *os.File, start int64, size int64, info *TrackInfo) {
	version, _ := readU8At(f, start+8)
	f1, _ := readU8At(f, start+9)
	f2, _ := readU8At(f, start+10)
	f3, _ := readU8At(f, start+11)
	flags := int((int(f1) << 16) | (int(f2) << 8) | int(f3))
	info.Default = (flags & 1) != 0

	offset := start + 12
	if version == 1 {
		offset += 16
	} else {
		offset += 8
	}
	id32, _ := readU32At(f, offset)
	info.TrackId = int(id32)
}

func parseMdia(f *os.File, start int64, size int64, info *TrackInfo) {
	end := start + size
	pos := start + 8

	for pos+8 <= end {
		sz, _ := readU32At(f, pos)
		typ, _ := readTypeAt(f, pos+4)

		boxSize := int64(sz)
		if sz == 1 {
			ext, _ := readU64At(f, pos+8)
			boxSize = int64(ext)
		} else if sz == 0 {
			boxSize = end - pos
		}

		if typ == "mdhd" {
			parseMdhd(f, pos, info)
		} else if typ == "hdlr" {
			parseHdlr(f, pos, info)
		} else if typ == "minf" {
			parseMinf(f, pos, boxSize, info)
		}

		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseMdhd(f *os.File, pos int64, info *TrackInfo) {
	info.MdhdOffset = pos + 8

	version, _ := readU8At(f, pos+8)
	_ = version

	// skip flags
	cur := pos + 12

	if version == 1 {
		cur += 16
	} else {
		cur += 8
	}
	cur += 4 // timescale
	if version == 1 {
		cur += 8
	} else {
		cur += 4
	}

	langBits, _ := readU16At(f, cur)
	info.Language = decodeLanguage(langBits)
}

func parseHdlr(f *os.File, pos int64, info *TrackInfo) {
	// version+flags+predefined = 8 bytes
	htype, _ := readTypeAt(f, pos+8+8)
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

func parseMinf(f *os.File, start int64, size int64, info *TrackInfo) {
	end := start + size
	pos := start + 8

	for pos+8 <= end {
		sz, _ := readU32At(f, pos)
		typ, _ := readTypeAt(f, pos+4)

		var boxSize int64
		if sz == 1 {
			ext, _ := readU64At(f, pos+8)
			boxSize = int64(ext)
		} else if sz == 0 {
			boxSize = end - pos
		} else {
			boxSize = int64(sz)
		}

		if typ == "stbl" {
			parseStbl(f, pos, boxSize, info)
		}

		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseStbl(f *os.File, start int64, size int64, info *TrackInfo) {
	end := start + size
	pos := start + 8

	for pos+8 <= end {
		sz, _ := readU32At(f, pos)
		typ, _ := readTypeAt(f, pos+4)

		var boxSize int64
		if sz == 1 {
			ext, _ := readU64At(f, pos+8)
			boxSize = int64(ext)
		} else if sz == 0 {
			boxSize = end - pos
		} else {
			boxSize = int64(sz)
		}

		if typ == "stsd" {
			info.StsdOffset = pos + 8
			parseStsd(f, info)
		}

		if boxSize < 8 {
			break
		}
		pos += boxSize
	}
}

func parseStsd(f *os.File, info *TrackInfo) {
	// skip version + flags + entryCount → 8 bytes offset
	sampleType, _ := readTypeAt(f, info.StsdOffset+8+4)

	lc := strings.ToLower(sampleType)
	info.Forced = strings.Contains(lc, "fcd") || strings.Contains(lc, "forced")
}

func patchTkhdFlag(f *os.File, offset int64, val bool) {
	f1, _ := readU8At(f, offset+1)
	f2, _ := readU8At(f, offset+2)
	f3, _ := readU8At(f, offset+3)

	flags := int(f1)<<16 | int(f2)<<8 | int(f3)

	if val {
		flags |= 1
	} else {
		flags &^= 1
	}

	f.Seek(offset+1, 0)
	f.Write([]byte{
		byte((flags >> 16) & 0xff),
		byte((flags >> 8) & 0xff),
		byte(flags & 0xff),
	})
}

func patchStsdFlag(f *os.File, offset int64, val bool) {
	curType, _ := readTypeAt(f, offset+12)
	if val {
		curType = "fcd "
	}
	f.Seek(offset+12, 0)
	f.Write([]byte(curType))
}

func decodeLanguage(bits uint16) string {
	if bits == 0 {
		return ""
	}
	c1 := ((bits>>10)&31 + 0x60)
	c2 := ((bits>>5)&31 + 0x60)
	c3 := ((bits)&31 + 0x60)
	return string([]byte{byte(c1), byte(c2), byte(c3)})
}

func readU8At(f *os.File, off int64) (uint8, error) {
	var b [1]byte
	_, err := f.ReadAt(b[:], off)
	return b[0], err
}

func readU16At(f *os.File, off int64) (uint16, error) {
	var b [2]byte
	_, err := f.ReadAt(b[:], off)
	return binary.BigEndian.Uint16(b[:]), err
}

func readU32At(f *os.File, off int64) (uint32, error) {
	var b [4]byte
	_, err := f.ReadAt(b[:], off)
	return binary.BigEndian.Uint32(b[:]), err
}

func readU64At(f *os.File, off int64) (uint64, error) {
	var b [8]byte
	_, err := f.ReadAt(b[:], off)
	return binary.BigEndian.Uint64(b[:]), err
}

func readTypeAt(f *os.File, off int64) (string, error) {
	var b [4]byte
	_, err := f.ReadAt(b[:], off)
	return string(b[:]), err
}

