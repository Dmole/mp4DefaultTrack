use std::env;
use std::fs::OpenOptions;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

#[derive(Default, Debug)]
struct Track {
    tkhd_offset: Option<u64>,
    stsd_offset: Option<u64>,
    mdhd_offset: Option<u64>,
    track_id: u32,
    default_flag: bool,
    forced_flag: bool,
    typ: Option<String>,
    lang: Option<String>,
}

fn read_u32<R: Read>(r: &mut R) -> io::Result<u32> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    Ok(u32::from_be_bytes(buf))
}

fn read_u16<R: Read>(r: &mut R) -> io::Result<u16> {
    let mut buf = [0u8; 2];
    r.read_exact(&mut buf)?;
    Ok(u16::from_be_bytes(buf))
}

fn read_u8<R: Read>(r: &mut R) -> io::Result<u8> {
    let mut buf = [0u8; 1];
    r.read_exact(&mut buf)?;
    Ok(buf[0])
}

fn read_type<R: Read>(r: &mut R) -> io::Result<String> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn decode_mp4_language(packed: u16) -> Option<String> {
    if packed == 0 {
        return None;
    }
    let a = (((packed >> 10) & 0x1F) as u8 + 0x60) as char;
    let b = (((packed >> 5) & 0x1F) as u8 + 0x60) as char;
    let c = ((packed & 0x1F) as u8 + 0x60) as char;
    Some(format!("{}{}{}", a, b, c))
}

fn parse_mp4(path: &Path) -> io::Result<Vec<Track>> {
    let mut f = OpenOptions::new().read(true).open(path)?;
    let file_len = f.seek(SeekFrom::End(0))?;
    f.seek(SeekFrom::Start(0))?;

    let mut tracks: Vec<Track> = Vec::new();

    while f.stream_position()? + 8 <= file_len {
        let start = f.stream_position()?;
        let size = read_u32(&mut f)? as u64;
        let typ = read_type(&mut f)?;
        let mut box_size = size;
        if box_size == 1 {
            // extended size
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)?;
            box_size = u64::from_be_bytes(buf);
        } else if box_size == 0 {
            box_size = file_len - start;
        }

        if typ == "moov" {
            parse_moov(&mut f, start, box_size, &mut tracks)?;
        }

        if box_size < 8 {
            break;
        } else {
            f.seek(SeekFrom::Start(start + box_size))?;
        }
    }

    Ok(tracks)
}

fn parse_moov(f: &mut (impl Read + Seek), start: u64, size: u64, tracks: &mut Vec<Track>) -> io::Result<()> {
    let end = start + size;
    f.seek(SeekFrom::Start(start + 8))?;
    while f.stream_position()? + 8 <= end {
        let pos = f.stream_position()?;
        let s = read_u32(f)? as u64;
        let typ = read_type(f)?;
        let mut box_size = s;
        if box_size == 1 {
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)?;
            box_size = u64::from_be_bytes(buf);
        } else if box_size == 0 {
            box_size = end - pos;
        }

        if typ == "trak" {
            if let Some(t) = parse_trak(f, pos, box_size)? {
                tracks.push(t);
            }
        }

        if box_size < 8 {
            break;
        } else {
            f.seek(SeekFrom::Start(pos + box_size))?;
        }
    }
    Ok(())
}

fn parse_trak(f: &mut (impl Read + Seek), trak_start: u64, trak_size: u64) -> io::Result<Option<Track>> {
    let mut info = Track::default();
    let end = trak_start + trak_size;
    f.seek(SeekFrom::Start(trak_start + 8))?;
    while f.stream_position()? + 8 <= end {
        let pos = f.stream_position()?;
        let s = read_u32(f)? as u64;
        let typ = read_type(f)?;
        let mut box_size = s;
        if box_size == 1 {
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)?;
            box_size = u64::from_be_bytes(buf);
        } else if box_size == 0 {
            box_size = end - pos;
        }

        if typ == "tkhd" {
            info.tkhd_offset = Some(pos + 8);
            f.seek(SeekFrom::Start(pos + 8))?;
            let version = read_u8(f)?;
            let flag1 = read_u8(f)?;
            let flag2 = read_u8(f)?;
            let flag3 = read_u8(f)?;
            let flags = ((flag1 as u32) << 16) | ((flag2 as u32) << 8) | (flag3 as u32);
            info.default_flag = (flags & 1) != 0;
            if version == 1 {
                // skip creation/modification (8 + 8), then track id
                f.seek(SeekFrom::Current(16))?;
            } else {
                f.seek(SeekFrom::Current(8))?;
            }
            // track id
            let mut buf = [0u8; 4];
            f.read_exact(&mut buf)?;
            info.track_id = u32::from_be_bytes(buf);
        } else if typ == "mdia" {
            parse_mdia(f, pos, box_size, &mut info)?;
        }

        if box_size < 8 {
            break;
        } else {
            f.seek(SeekFrom::Start(pos + box_size))?;
        }
    }

    if info.track_id == 0 {
        Ok(None)
    } else {
        Ok(Some(info))
    }
}

fn parse_mdia(f: &mut (impl Read + Seek), mdia_start: u64, mdia_size: u64, info: &mut Track) -> io::Result<()> {
    let end = mdia_start + mdia_size;
    f.seek(SeekFrom::Start(mdia_start + 8))?;
    while f.stream_position()? + 8 <= end {
        let pos = f.stream_position()?;
        let s = read_u32(f)? as u64;
        let typ = read_type(f)?;
        let mut box_size = s;
        if box_size == 1 {
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)?;
            box_size = u64::from_be_bytes(buf);
        } else if box_size == 0 {
            box_size = end - pos;
        }

        if typ == "mdhd" {
            info.mdhd_offset = Some(pos + 8);
            f.seek(SeekFrom::Start(pos + 8))?;
            let version = read_u8(f)?;
            f.seek(SeekFrom::Current(3))?; // flags
            if version == 1 {
                f.seek(SeekFrom::Current(8 + 8))?; // creation + modification
            } else {
                f.seek(SeekFrom::Current(4 + 4))?;
            }
            // timescale
            f.seek(SeekFrom::Current(4))?;
            // duration
            if version == 1 {
                f.seek(SeekFrom::Current(8))?;
            } else {
                f.seek(SeekFrom::Current(4))?;
            }
            // language (packed)
            let lang_packed = read_u16(f)?;
            info.lang = decode_mp4_language(lang_packed);
        } else if typ == "hdlr" {
            // handler: skip version+flags(4) + pre-defined (4)
            f.seek(SeekFrom::Start(pos + 8 + 8))?; // pos + header + 8
            let mut hbuf = [0u8; 4];
            f.read_exact(&mut hbuf)?;
            let subtype = String::from_utf8_lossy(&hbuf).into_owned();
            if subtype == "vide" {
                info.typ = Some("video".to_string());
            } else if subtype == "soun" {
                info.typ = Some("audio".to_string());
            } else if subtype == "subt" || subtype == "sbtl" || subtype == "text" {
                info.typ = Some("subtitle".to_string());
            } else {
                info.typ = Some(subtype);
            }
        } else if typ == "minf" {
            parse_minf(f, pos, box_size, info)?;
        }

        if box_size < 8 {
            break;
        } else {
            f.seek(SeekFrom::Start(pos + box_size))?;
        }
    }
    Ok(())
}

fn parse_minf(f: &mut (impl Read + Seek), minf_start: u64, minf_size: u64, info: &mut Track) -> io::Result<()> {
    let end = minf_start + minf_size;
    f.seek(SeekFrom::Start(minf_start + 8))?;
    while f.stream_position()? + 8 <= end {
        let pos = f.stream_position()?;
        let s = read_u32(f)? as u64;
        let typ = read_type(f)?;
        let mut box_size = s;
        if box_size == 1 {
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)?;
            box_size = u64::from_be_bytes(buf);
        } else if box_size == 0 {
            box_size = end - pos;
        }

        if typ == "stbl" {
            parse_stbl(f, pos, box_size, info)?;
        }

        if box_size < 8 {
            break;
        } else {
            f.seek(SeekFrom::Start(pos + box_size))?;
        }
    }
    Ok(())
}

fn parse_stbl(f: &mut (impl Read + Seek), stbl_start: u64, stbl_size: u64, info: &mut Track) -> io::Result<()> {
    let end = stbl_start + stbl_size;
    f.seek(SeekFrom::Start(stbl_start + 8))?;
    while f.stream_position()? + 8 <= end {
        let pos = f.stream_position()?;
        let s = read_u32(f)? as u64;
        let typ = read_type(f)?;
        let mut box_size = s;
        if box_size == 1 {
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)?;
            box_size = u64::from_be_bytes(buf);
        } else if box_size == 0 {
            box_size = end - pos;
        }

        if typ == "stsd" {
            info.stsd_offset = Some(pos + 8);
            // read version+flags(4) and entry count(4)
            f.seek(SeekFrom::Start(pos + 8 + 8))?;
            let mut entry_header = [0u8; 8];
            if f.read_exact(&mut entry_header).is_ok() {
                let sample_type = String::from_utf8_lossy(&entry_header[4..8]).to_lowercase();
                if sample_type.contains("fcd") {
                    info.forced_flag = true;
                } else {
                    info.forced_flag = false;
                }
            }
        }

        if box_size < 8 {
            break;
        } else {
            f.seek(SeekFrom::Start(pos + box_size))?;
        }
    }
    Ok(())
}

fn patch_tkhd_flag(path: &Path, tkhd_offset: u64, set: bool) -> io::Result<()> {
    let mut f = OpenOptions::new().read(true).write(true).open(path)?;
    // flags are bytes 1..3 of tkhd (we are at tkhd payload start)
    f.seek(SeekFrom::Start(tkhd_offset + 1))?;
    let mut b = [0u8; 3];
    f.read_exact(&mut b)?;
    let mut flags = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32);
    if set {
        flags |= 1;
    } else {
        flags &= !1;
    }
    let out = [( (flags >> 16) & 0xff) as u8, ((flags >> 8) & 0xff) as u8, (flags & 0xff) as u8];
    f.seek(SeekFrom::Start(tkhd_offset + 1))?;
    f.write_all(&out)?;
    Ok(())
}

fn patch_stsd_forced(path: &Path, stsd_offset: u64, set: bool) -> io::Result<()> {
    let mut f = OpenOptions::new().read(true).write(true).open(path)?;
    // seek to first sample entry header (stsd_offset + 8 is start of version+flags+entryCount)
    // after that comes sample entry header: 4 bytes size, 4 bytes type
    let entry_header_pos = stsd_offset + 8 + 8;
    f.seek(SeekFrom::Start(entry_header_pos))?;
    let mut header = [0u8; 8];
    f.read_exact(&mut header)?;
    // let sample_type = [header[4], header[5], header[6], header[7]];
    // let sample_str = String::from_utf8_lossy(&sample_type).into_owned();
    if set {
        // write "fcd " as marker if possible
        let new = b"fcd ";
        f.seek(SeekFrom::Start(entry_header_pos + 4))?;
        f.write_all(new)?;
    } else {
        // don't know original; best-effort: if it's "fcd " leave as-is, otherwise do nothing
        // (we could store original somewhere; left simple)
        // do nothing
    }
    Ok(())
}

fn print_list(tracks: &[Track]) {
    println!("[");
    for (i, t) in tracks.iter().enumerate() {
        let typ = match &t.typ {
            Some(s) => s.clone(),
            None => "unknown".to_string(),
        };
        let lang = match &t.lang {
            Some(s) => format!("\"{}\"", s),
            None => "null".to_string(),
        };
        println!("\t{{\"id\": {}, \"type\": \"{}\", \"lang\": {}, \"default\": {}, \"forced\": {}}}{}",
                 t.track_id,
                 typ,
                 lang,
                 if t.default_flag { "true" } else { "false" },
                 if t.forced_flag { "true" } else { "false" },
                 if i + 1 == tracks.len() { "" } else { "," });
    }
    println!("]");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: {} <list|set|unset> <file> [trackId] [default|forced]", args[0]);
        std::process::exit(2);
    }

    let cmd = &args[1];
    let path = Path::new(&args[2]);

    if cmd == "list" {
        match parse_mp4(path) {
            Ok(tracks) => {
                print_list(&tracks);
                std::process::exit(0);
            }
            Err(e) => {
                eprintln!("Error parsing file: {}", e);
                std::process::exit(1);
            }
        }
    }

    // set/unset require more args
    if args.len() < 5 {
        eprintln!("Usage: {} set|unset <file> <trackId> <default|forced>", args[0]);
        std::process::exit(2);
    }

    let tid: u32 = match args[3].parse() {
        Ok(n) => n,
        Err(_) => {
            eprintln!("Invalid trackId: {}", args[3]);
            std::process::exit(2);
        }
    };
    let flag = &args[4];
    let set_flag = cmd == "set";

    let tracks = match parse_mp4(path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error parsing file: {}", e);
            std::process::exit(1);
        }
    };

    let mut found = false;
    for t in &tracks {
        if t.track_id == tid {
            found = true;
            if flag == "default" {
                if let Some(off) = t.tkhd_offset {
                    if let Err(e) = patch_tkhd_flag(path, off, set_flag) {
                        eprintln!("Error patching tkhd: {}", e);
                        std::process::exit(1);
                    }
                } else {
                    eprintln!("No tkhd offset for track {}", tid);
                    std::process::exit(1);
                }
            } else if flag == "forced" {
                if let Some(off) = t.stsd_offset {
                    if let Err(e) = patch_stsd_forced(path, off, set_flag) {
                        eprintln!("Error patching stsd: {}", e);
                        std::process::exit(1);
                    }
                } else {
                    eprintln!("No stsd offset for track {}", tid);
                    std::process::exit(1);
                }
            } else {
                eprintln!("Unknown flag: {}", flag);
                std::process::exit(2);
            }
            break;
        }
    }

    if !found {
        eprintln!("Track {} not found", tid);
        std::process::exit(1);
    }

    std::process::exit(0);
}
