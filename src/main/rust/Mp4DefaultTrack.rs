use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::convert::TryInto;

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

/// Reads the next MP4 box header: returns (box_size, type_bytes, header_size).
fn read_header(f: &mut File, max_size: u64) -> io::Result<Option<(u64, [u8; 4], u64)>> {
    let mut header = [0u8; 8];
    match f.read_exact(&mut header) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    
    let mut box_size = u32::from_be_bytes(header[0..4].try_into().unwrap()) as u64;
    let typ: [u8; 4] = header[4..8].try_into().unwrap();
    let mut hdr_size = 8;

    if box_size == 1 {
        let mut ext = [0u8; 8];
        f.read_exact(&mut ext)?;
        box_size = u64::from_be_bytes(ext);
        hdr_size = 16;
    } else if box_size == 0 {
        box_size = max_size; // Extends to end of file/parent container
    }

    Ok(Some((box_size, typ, hdr_size)))
}

fn decode_mp4_language(packed: u16) -> Option<String> {
    if packed == 0 {
        return None;
    }
    let bytes = [
        ((packed >> 10) & 0x1F) as u8 + 0x60,
        ((packed >> 5) & 0x1F) as u8 + 0x60,
        (packed & 0x1F) as u8 + 0x60,
    ];
    String::from_utf8(bytes.to_vec()).ok()
}

fn parse_mp4(f: &mut File) -> io::Result<Vec<Track>> {
    let file_len = f.seek(SeekFrom::End(0))?;
    let mut tracks = Vec::new();
    let mut offset = 0;

    while offset + 8 <= file_len {
        f.seek(SeekFrom::Start(offset))?;
        let Some((box_size, typ, hdr_size)) = read_header(f, file_len - offset)? else { break };
        if box_size < hdr_size { break; }

        if typ == *b"moov" {
            parse_moov(f, offset + hdr_size, offset + box_size, &mut tracks)?;
        }
        offset += box_size;
    }

    Ok(tracks)
}

fn parse_moov(f: &mut File, mut offset: u64, limit: u64, tracks: &mut Vec<Track>) -> io::Result<()> {
    while offset + 8 <= limit {
        f.seek(SeekFrom::Start(offset))?;
        let Some((box_size, typ, hdr_size)) = read_header(f, limit - offset)? else { break };
        if box_size < hdr_size { break; }

        if typ == *b"trak" {
            if let Some(t) = parse_trak(f, offset + hdr_size, offset + box_size)? {
                tracks.push(t);
            }
        }
        offset += box_size;
    }
    Ok(())
}

fn parse_trak(f: &mut File, mut offset: u64, limit: u64) -> io::Result<Option<Track>> {
    let mut info = Track::default();
    
    while offset + 8 <= limit {
        f.seek(SeekFrom::Start(offset))?;
        let Some((box_size, typ, hdr_size)) = read_header(f, limit - offset)? else { break };
        if box_size < hdr_size { break; }

        if typ == *b"tkhd" {
            info.tkhd_offset = Some(offset + hdr_size);
            f.seek(SeekFrom::Start(offset + hdr_size))?;
            
            let mut tkhd_data = [0u8; 4];
            f.read_exact(&mut tkhd_data)?;
            let version = tkhd_data[0];
            let flags = ((tkhd_data[1] as u32) << 16) | ((tkhd_data[2] as u32) << 8) | (tkhd_data[3] as u32);
            info.default_flag = (flags & 1) != 0;

            if version == 1 {
                f.seek(SeekFrom::Current(16))?; // Skip creation/mod
            } else {
                f.seek(SeekFrom::Current(8))?;
            }
            
            let mut track_id_buf = [0u8; 4];
            f.read_exact(&mut track_id_buf)?;
            info.track_id = u32::from_be_bytes(track_id_buf);
            
        } else if typ == *b"mdia" {
            parse_mdia(f, offset + hdr_size, offset + box_size, &mut info)?;
        }
        
        offset += box_size;
    }

    if info.track_id != 0 { Ok(Some(info)) } else { Ok(None) }
}

fn parse_mdia(f: &mut File, mut offset: u64, limit: u64, info: &mut Track) -> io::Result<()> {
    while offset + 8 <= limit {
        f.seek(SeekFrom::Start(offset))?;
        let Some((box_size, typ, hdr_size)) = read_header(f, limit - offset)? else { break };
        if box_size < hdr_size { break; }

        if typ == *b"mdhd" {
            info.mdhd_offset = Some(offset + hdr_size);
            f.seek(SeekFrom::Start(offset + hdr_size))?;
            
            let mut ver = [0u8; 1];
            f.read_exact(&mut ver)?;
            f.seek(SeekFrom::Current(3))?; // Skip flags
            
            if ver[0] == 1 {
                f.seek(SeekFrom::Current(16 + 4 + 8))?; // ctime + mtime + timescale + duration
            } else {
                f.seek(SeekFrom::Current(8 + 4 + 4))?;
            }
            
            let mut lang_buf = [0u8; 2];
            f.read_exact(&mut lang_buf)?;
            info.lang = decode_mp4_language(u16::from_be_bytes(lang_buf));
            
        } else if typ == *b"hdlr" {
            f.seek(SeekFrom::Start(offset + hdr_size + 8))?; // pos + version+flags(4) + pre-defined(4)
            let mut hbuf = [0u8; 4];
            f.read_exact(&mut hbuf)?;
            info.typ = Some(match &hbuf {
                b"vide" => "video".to_string(),
                b"soun" => "audio".to_string(),
                b"subt" | b"sbtl" | b"text" => "subtitle".to_string(),
                _ => String::from_utf8_lossy(&hbuf).into_owned(),
            });
            
        } else if typ == *b"minf" {
            parse_minf(f, offset + hdr_size, offset + box_size, info)?;
        }
        offset += box_size;
    }
    Ok(())
}

fn parse_minf(f: &mut File, mut offset: u64, limit: u64, info: &mut Track) -> io::Result<()> {
    while offset + 8 <= limit {
        f.seek(SeekFrom::Start(offset))?;
        let Some((box_size, typ, hdr_size)) = read_header(f, limit - offset)? else { break };
        if box_size < hdr_size { break; }

        if typ == *b"stbl" {
            parse_stbl(f, offset + hdr_size, offset + box_size, info)?;
        }
        offset += box_size;
    }
    Ok(())
}

fn parse_stbl(f: &mut File, mut offset: u64, limit: u64, info: &mut Track) -> io::Result<()> {
    while offset + 8 <= limit {
        f.seek(SeekFrom::Start(offset))?;
        let Some((box_size, typ, hdr_size)) = read_header(f, limit - offset)? else { break };
        if box_size < hdr_size { break; }

        if typ == *b"stsd" {
            info.stsd_offset = Some(offset + hdr_size);
            f.seek(SeekFrom::Start(offset + hdr_size + 8))?; // Skip version+flags + entry count
            
            let mut entry_header = [0u8; 8];
            if f.read_exact(&mut entry_header).is_ok() {
                let sample_type = &entry_header[4..8];
                // Zero allocation forced-flag check
                info.forced_flag = sample_type[0..3].eq_ignore_ascii_case(b"fcd") 
                                || sample_type[1..4].eq_ignore_ascii_case(b"fcd");
            }
        }
        offset += box_size;
    }
    Ok(())
}

fn patch_tkhd_flag(f: &mut File, tkhd_offset: u64, set: bool) -> io::Result<()> {
    f.seek(SeekFrom::Start(tkhd_offset + 1))?;
    let mut b = [0u8; 3];
    f.read_exact(&mut b)?;
    let mut flags = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32);
    
    if set { flags |= 1; } else { flags &= !1; }
    
    let out = [((flags >> 16) & 0xff) as u8, ((flags >> 8) & 0xff) as u8, (flags & 0xff) as u8];
    f.seek(SeekFrom::Start(tkhd_offset + 1))?;
    f.write_all(&out)?;
    Ok(())
}

fn patch_stsd_forced(f: &mut File, stsd_offset: u64, set: bool) -> io::Result<()> {
    if set {
        let entry_header_pos = stsd_offset + 16;
        f.seek(SeekFrom::Start(entry_header_pos + 4))?;
        f.write_all(b"fcd ")?;
    }
    Ok(())
}

fn print_list(tracks: &[Track]) {
    println!("[");
    let len = tracks.len();
    for (i, t) in tracks.iter().enumerate() {
        let typ = t.typ.as_deref().unwrap_or("unknown");
        let lang = match &t.lang {
            Some(s) => format!("\"{}\"", s),
            None => "null".to_string(),
        };
        let comma = if i + 1 == len { "" } else { "," };
        println!("\t{{\"id\": {}, \"type\": \"{}\", \"lang\": {}, \"default\": {}, \"forced\": {}}}{}",
                 t.track_id, typ, lang, t.default_flag, t.forced_flag, comma);
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
    let is_list = cmd == "list";
    let set_flag = cmd == "set";

    let mut file = match OpenOptions::new().read(true).write(!is_list).open(path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("Error opening file: {}", e);
            std::process::exit(1);
        }
    };

    let tracks = match parse_mp4(&mut file) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error parsing file: {}", e);
            std::process::exit(1);
        }
    };

    if is_list {
        print_list(&tracks);
        std::process::exit(0);
    }

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

    let mut found = false;
    for t in tracks {
        if t.track_id == tid {
            found = true;
            if flag == "default" {
                if let Some(off) = t.tkhd_offset {
                    if let Err(e) = patch_tkhd_flag(&mut file, off, set_flag) {
                        eprintln!("Error patching tkhd: {}", e);
                        std::process::exit(1);
                    }
                }
            } else if flag == "forced" {
                if let Some(off) = t.stsd_offset {
                    if let Err(e) = patch_stsd_forced(&mut file, off, set_flag) {
                        eprintln!("Error patching stsd: {}", e);
                        std::process::exit(1);
                    }
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
}
