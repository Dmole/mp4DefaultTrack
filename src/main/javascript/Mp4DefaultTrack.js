#!/usr/bin/node

const fs = require('fs');

// Precomputed FourCC codes as 32-bit integers for zero-allocation matching
const MOOV = 0x6D6F6F76;
const TRAK = 0x7472616B;
const TKHD = 0x746B6864;
const MDIA = 0x6D646961;
const MDHD = 0x6D646864;
const HDLR = 0x68646C72;
const MINF = 0x6D696E66;
const STBL = 0x7374626C;
const STSD = 0x73747364;
const VIDE = 0x76696465;
const SOUN = 0x736F756E;
const SUBT = 0x73756274;
const SBTL = 0x7362746C;
const TEXT = 0x74657874;
const FCD_ = 0x66636420; // 'fcd '

// Shared buffer to eliminate Garbage Collection churn during heavy I/O scanning
const sharedBuf = Buffer.alloc(16);

function decodeMp4Language(packed) {
  if (!packed || packed === 0) return null;
  const a = String.fromCharCode(((packed >> 10) & 0x1F) + 0x60);
  const b = String.fromCharCode(((packed >> 5) & 0x1F) + 0x60);
  const c = String.fromCharCode((packed & 0x1F) + 0x60);
  return '' + a + b + c;
}

function parseMp4(fd, fileLen) {
  const tracks = [];
  let pos = 0;
  
  while (pos + 8 <= fileLen) {
    fs.readSync(fd, sharedBuf, 0, 8, pos);
    let boxSize = sharedBuf.readUInt32BE(0);
    const type = sharedBuf.readUInt32BE(4);

    if (boxSize === 1) {
      fs.readSync(fd, sharedBuf, 0, 8, pos + 8);
      boxSize = Number(sharedBuf.readBigUInt64BE(0));
    } else if (boxSize === 0) {
      boxSize = fileLen - pos;
    }

    if (type === MOOV) {
      parseMoov(fd, pos, boxSize, tracks);
    }
    if (boxSize < 8) break;
    pos += boxSize;
  }
  return tracks;
}

function parseMoov(fd, start, size, tracks) {
  const end = start + size;
  let p = start + 8;
  
  while (p + 8 <= end) {
    fs.readSync(fd, sharedBuf, 0, 8, p);
    let boxSize = sharedBuf.readUInt32BE(0);
    const type = sharedBuf.readUInt32BE(4);

    if (boxSize === 1) {
      fs.readSync(fd, sharedBuf, 0, 8, p + 8);
      boxSize = Number(sharedBuf.readBigUInt64BE(0));
    } else if (boxSize === 0) {
      boxSize = end - p;
    }

    if (type === TRAK) {
      const info = parseTrak(fd, p, boxSize);
      if (info) tracks.push(info);
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
}

function parseTrak(fd, trakStart, trakSize) {
  const info = {
    tkhdOffset: null,
    stsdOffset: null,
    trackId: 0,
    defaultFlag: false,
    forcedFlag: false,
    type: 'unknown',
    language: null
  };
  
  const end = trakStart + trakSize;
  let p = trakStart + 8;
  
  while (p + 8 <= end) {
    fs.readSync(fd, sharedBuf, 0, 8, p);
    let boxSize = sharedBuf.readUInt32BE(0);
    const type = sharedBuf.readUInt32BE(4);

    if (boxSize === 1) {
      fs.readSync(fd, sharedBuf, 0, 8, p + 8);
      boxSize = Number(sharedBuf.readBigUInt64BE(0));
    } else if (boxSize === 0) {
      boxSize = end - p;
    }

    if (type === TKHD) {
      info.tkhdOffset = p + 8;
      // Read 4 bytes: version (1) + flags (3)
      fs.readSync(fd, sharedBuf, 0, 4, info.tkhdOffset);
      const vf = sharedBuf.readUInt32BE(0);
      const version = vf >>> 24;
      info.defaultFlag = (vf & 1) !== 0;
      
      const trackIdOffset = info.tkhdOffset + 4 + (version === 1 ? 16 : 8);
      fs.readSync(fd, sharedBuf, 0, 4, trackIdOffset);
      info.trackId = sharedBuf.readUInt32BE(0);
    } else if (type === MDIA) {
      parseMdia(fd, p, boxSize, info);
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
  return info.trackId === 0 ? null : info;
}

function parseMdia(fd, mdiaStart, mdiaSize, info) {
  const end = mdiaStart + mdiaSize;
  let p = mdiaStart + 8;
  
  while (p + 8 <= end) {
    fs.readSync(fd, sharedBuf, 0, 8, p);
    let boxSize = sharedBuf.readUInt32BE(0);
    const type = sharedBuf.readUInt32BE(4);

    if (boxSize === 1) {
      fs.readSync(fd, sharedBuf, 0, 8, p + 8);
      boxSize = Number(sharedBuf.readBigUInt64BE(0));
    } else if (boxSize === 0) {
      boxSize = end - p;
    }

    if (type === MDHD) {
      const payload = p + 8;
      fs.readSync(fd, sharedBuf, 0, 1, payload);
      const version = sharedBuf.readUInt8(0);
      
      const langOffset = payload + 4 + (version === 1 ? 28 : 16);
      fs.readSync(fd, sharedBuf, 0, 2, langOffset);
      info.language = decodeMp4Language(sharedBuf.readUInt16BE(0));
    } else if (type === HDLR) {
      const subPos = p + 16;
      fs.readSync(fd, sharedBuf, 0, 4, subPos);
      const subtype = sharedBuf.readUInt32BE(0);
      
      if (subtype === VIDE) info.type = 'video';
      else if (subtype === SOUN) info.type = 'audio';
      else if (subtype === SUBT || subtype === SBTL || subtype === TEXT) info.type = 'subtitle';
      else info.type = sharedBuf.toString('ascii', 0, 4);
    } else if (type === MINF) {
      parseMinf(fd, p, boxSize, info);
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
}

function parseMinf(fd, minfStart, minfSize, info) {
  const end = minfStart + minfSize;
  let p = minfStart + 8;
  
  while (p + 8 <= end) {
    fs.readSync(fd, sharedBuf, 0, 8, p);
    let boxSize = sharedBuf.readUInt32BE(0);
    const type = sharedBuf.readUInt32BE(4);

    if (boxSize === 1) {
      fs.readSync(fd, sharedBuf, 0, 8, p + 8);
      boxSize = Number(sharedBuf.readBigUInt64BE(0));
    } else if (boxSize === 0) {
      boxSize = end - p;
    }

    if (type === STBL) {
      parseStbl(fd, p, boxSize, info);
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
}

function parseStbl(fd, stblStart, stblSize, info) {
  const end = stblStart + stblSize;
  let p = stblStart + 8;
  
  while (p + 8 <= end) {
    fs.readSync(fd, sharedBuf, 0, 8, p);
    let boxSize = sharedBuf.readUInt32BE(0);
    const type = sharedBuf.readUInt32BE(4);

    if (boxSize === 1) {
      fs.readSync(fd, sharedBuf, 0, 8, p + 8);
      boxSize = Number(sharedBuf.readBigUInt64BE(0));
    } else if (boxSize === 0) {
      boxSize = end - p;
    }

    if (type === STSD) {
      info.stsdOffset = p + 8;
      const entryHeaderPos = info.stsdOffset + 8;
      // Read 4 bytes of sample entry format type directly
      fs.readSync(fd, sharedBuf, 0, 4, entryHeaderPos + 4);
      const sampleType = sharedBuf.readUInt32BE(0);
      info.forcedFlag = (sampleType === FCD_);
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
}

// Patches directly using the active file descriptor
function patchTkhdFlag(fd, tkhdOffset, set) {
  fs.readSync(fd, sharedBuf, 0, 4, tkhdOffset);
  let vf = sharedBuf.readUInt32BE(0);
  if (set) vf |= 1; else vf &= ~1;
  sharedBuf.writeUInt32BE(vf, 0);
  fs.writeSync(fd, sharedBuf, 0, 4, tkhdOffset);
}

function patchStsdForced(fd, stsdOffset, set) {
  if (!stsdOffset || !set) return; // Cannot safely unset without original type
  sharedBuf.writeUInt32BE(FCD_, 0); // 'fcd '
  fs.writeSync(fd, sharedBuf, 0, 4, stsdOffset + 12);
}

function cmdList(fd, fileLen) {
  const tracks = parseMp4(fd, fileLen);
  const out = tracks.map(t => ({
    id: t.trackId,
    type: t.type || 'unknown',
    lang: t.language === null ? null : t.language,
    default: !!t.defaultFlag,
    forced: !!t.forcedFlag
  }));
  
  let fo = JSON.stringify(out, null, "\t")
    .replace(/\n\t+/g, ' ')
    .replace(/ \{/g, "\n\t{")
    .replace(/\{ /g, '{')
    .replace(/ \}/g, '}');
  console.log(fo);
}

function cmdSetUnset(fd, fileLen, cmd, tidStr, flag) {
  const tid = parseInt(tidStr, 10);
  if (isNaN(tid)) {
    console.error('Invalid trackId');
    process.exit(2);
  }
  
  const tracks = parseMp4(fd, fileLen);
  for (const t of tracks) {
    if (t.trackId === tid) {
      if (flag === 'default') {
        patchTkhdFlag(fd, t.tkhdOffset, cmd === 'set');
      } else if (flag === 'forced') {
        patchStsdForced(fd, t.stsdOffset, cmd === 'set');
      } else {
        console.error('Unknown flag:', flag);
        process.exit(2);
      }
      return; // Exit on success
    }
  }
  
  console.error('Track not found');
  process.exit(1);
}

function main(argv) {
  if (argv.length < 3) {
    console.error('Usage: node mp4track.js <list|set|unset> <file> [trackId] [default|forced]');
    process.exit(2);
  }
  
  const cmd = argv[2];
  const filePath = argv[3];
  
  if (!filePath || !fs.existsSync(filePath)) {
    console.error('File missing or not found:', filePath);
    process.exit(2);
  }

  // Open file strictly once
  const mode = cmd === 'list' ? 'r' : 'r+';
  const fd = fs.openSync(filePath, mode);
  
  try {
    const fileLen = fs.fstatSync(fd).size;
    if (cmd === 'list') {
      cmdList(fd, fileLen);
    } else if (cmd === 'set' || cmd === 'unset') {
      if (argv.length < 6) {
        console.error('Usage: node mp4track.js set|unset <file> <trackId> <default|forced>');
        process.exit(2);
      }
      cmdSetUnset(fd, fileLen, cmd, argv[4], argv[5]);
    } else {
      console.error('Unknown command:', cmd);
      process.exit(2);
    }
  } finally {
    fs.closeSync(fd);
  }
}

if (require.main === module) {
  main(process.argv);
}
