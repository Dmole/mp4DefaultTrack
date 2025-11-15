#!/usr/bin/env node
// mp4track.js  Node.js in-place MP4 track flag tool
// Usage:
//   node mp4track.js list file.mp4
//   node mp4track.js set file.mp4 <trackId> default
//   node mp4track.js unset file.mp4 <trackId> forced

const fs = require('fs');
const path = require('path');

function readUInt32(fd, pos) {
  const buf = Buffer.allocUnsafe(4);
  const n = fs.readSync(fd, buf, 0, 4, pos);
  if (n !== 4) throw new Error('Short read');
  return buf.readUInt32BE(0);
}

function readUInt16(fd, pos) {
  const buf = Buffer.allocUnsafe(2);
  const n = fs.readSync(fd, buf, 0, 2, pos);
  if (n !== 2) throw new Error('Short read');
  return buf.readUInt16BE(0);
}

function readUInt8(fd, pos) {
  const buf = Buffer.allocUnsafe(1);
  const n = fs.readSync(fd, buf, 0, 1, pos);
  if (n !== 1) throw new Error('Short read');
  return buf.readUInt8(0);
}

function readType(fd, pos) {
  const buf = Buffer.allocUnsafe(4);
  const n = fs.readSync(fd, buf, 0, 4, pos);
  if (n !== 4) throw new Error('Short read');
  return buf.toString('ascii', 0, 4);
}

function readUInt64(fd, pos) {
  const buf = Buffer.allocUnsafe(8);
  const n = fs.readSync(fd, buf, 0, 8, pos);
  if (n !== 8) throw new Error('Short read');
  // return as Number if fits, else BigInt -> convert (best-effort)
  const hi = buf.readUInt32BE(0);
  const lo = buf.readUInt32BE(4);
  const val = hi * 0x100000000 + lo;
  return val;
}

function decodeMp4Language(packed) {
  if (!packed || packed === 0) return null;
  const a = String.fromCharCode(((packed >> 10) & 0x1F) + 0x60);
  const b = String.fromCharCode(((packed >> 5) & 0x1F) + 0x60);
  const c = String.fromCharCode((packed & 0x1F) + 0x60);
  return '' + a + b + c;
}

function parseMp4(filePath) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const stat = fs.fstatSync(fd);
    const fileLen = stat.size;
    const tracks = [];

    let pos = 0;
    while (pos + 8 <= fileLen) {
      const size = readUInt32(fd, pos);
      const type = readType(fd, pos + 4);
      let boxSize = size;
      let headerLen = 8;
      if (boxSize === 1) {
        boxSize = readUInt64(fd, pos + 8);
        headerLen = 16;
      } else if (boxSize === 0) {
        boxSize = fileLen - pos;
      }
      if (type === 'moov') {
        parseMoov(fd, pos, boxSize, tracks);
      }
      if (boxSize < 8) break;
      pos += boxSize;
    }

    return tracks;
  } finally {
    fs.closeSync(fd);
  }
}

function parseMoov(fd, start, size, tracks) {
  const end = start + size;
  let p = start + 8;
  while (p + 8 <= end) {
    const size32 = readUInt32(fd, p);
    const type = readType(fd, p + 4);
    let boxSize = size32;
    let headerLen = 8;
    if (boxSize === 1) {
      boxSize = readUInt64(fd, p + 8);
      headerLen = 16;
    } else if (boxSize === 0) {
      boxSize = end - p;
    }
    if (type === 'trak') {
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
    mdhdOffset: null,
    trackId: 0,
    defaultFlag: false,
    forcedFlag: false,
    type: 'unknown',
    language: null
  };
  const end = trakStart + trakSize;
  let p = trakStart + 8;
  while (p + 8 <= end) {
    const size32 = readUInt32(fd, p);
    const type = readType(fd, p + 4);
    let boxSize = size32;
    if (boxSize === 1) {
      boxSize = readUInt64(fd, p + 8);
    } else if (boxSize === 0) {
      boxSize = end - p;
    }
    if (type === 'tkhd') {
      const tkhdPayload = p + 8;
      info.tkhdOffset = tkhdPayload;
      const version = readUInt8(fd, tkhdPayload);
      // flags: bytes tkhdPayload+1..+3
      const f1 = readUInt8(fd, tkhdPayload + 1);
      const f2 = readUInt8(fd, tkhdPayload + 2);
      const f3 = readUInt8(fd, tkhdPayload + 3);
      const flags = (f1 << 16) | (f2 << 8) | f3;
      info.defaultFlag = (flags & 1) !== 0;
      let after = tkhdPayload + 4;
      if (version === 1) {
        after += 16; // creation/modification (8+8)
      } else {
        after += 8; // creation/modification (4+4)
      }
      // track id at after
      const trackId = readUInt32(fd, after);
      info.trackId = trackId;
    } else if (type === 'mdia') {
      parseMdia(fd, p, boxSize, info);
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
  if (info.trackId === 0) return null;
  return info;
}

function parseMdia(fd, mdiaStart, mdiaSize, info) {
  const end = mdiaStart + mdiaSize;
  let p = mdiaStart + 8;
  while (p + 8 <= end) {
    const size32 = readUInt32(fd, p);
    const type = readType(fd, p + 4);
    let boxSize = size32;
    if (boxSize === 1) {
      boxSize = readUInt64(fd, p + 8);
    } else if (boxSize === 0) {
      boxSize = end - p;
    }
    if (type === 'mdhd') {
      const payload = p + 8;
      info.mdhdOffset = payload;
      const version = readUInt8(fd, payload);
      // skip flags (3 bytes)
      let cursor = payload + 4;
      if (version === 1) {
        cursor += 16; // creation + modification (8+8)
      } else {
        cursor += 8; // creation + modification (4+4)
      }
      cursor += 4; // timescale
      if (version === 1) {
        cursor += 8;
      } else {
        cursor += 4;
      }
      // language stored at cursor (2 bytes)
      const langPacked = readUInt16(fd, cursor);
      info.language = decodeMp4Language(langPacked);
    } else if (type === 'hdlr') {
      // handler: skip version+flags+predefined (8 bytes)
      const subPos = p + 8 + 8;
      const subtype = readType(fd, subPos);
      if (subtype === 'vide') info.type = 'video';
      else if (subtype === 'soun') info.type = 'audio';
      else if (subtype === 'subt' || subtype === 'sbtl' || subtype === 'text') info.type = 'subtitle';
      else info.type = subtype;
    } else if (type === 'minf') {
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
    const size32 = readUInt32(fd, p);
    const type = readType(fd, p + 4);
    let boxSize = size32;
    if (boxSize === 1) {
      boxSize = readUInt64(fd, p + 8);
    } else if (boxSize === 0) {
      boxSize = end - p;
    }
    if (type === 'stbl') {
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
    const size32 = readUInt32(fd, p);
    const type = readType(fd, p + 4);
    let boxSize = size32;
    if (boxSize === 1) {
      boxSize = readUInt64(fd, p + 8);
    } else if (boxSize === 0) {
      boxSize = end - p;
    }
    if (type === 'stsd') {
      info.stsdOffset = p + 8;
      // sample entry header starts after version+flags(4)+entryCount(4) -> offset +8
      const entryHeaderPos = info.stsdOffset + 8;
      // read sample entry header (size + type)
      const sampleType = readType(fd, entryHeaderPos + 4).toLowerCase();
      info.forcedFlag = sampleType.includes('fcd');
    }
    if (boxSize < 8) break;
    p += boxSize;
  }
}

// patch tkhd default bit (3 bytes at tkhdOffset+1..+3)
function patchTkhdFlag(filePath, tkhdOffset, set) {
  const fd = fs.openSync(filePath, 'r+');
  try {
    const buf = Buffer.allocUnsafe(3);
    fs.readSync(fd, buf, 0, 3, tkhdOffset + 1);
    let flags = (buf[0] << 16) | (buf[1] << 8) | (buf[2]);
    if (set) flags |= 1; else flags &= ~1;
    const out = Buffer.from([ (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff ]);
    fs.writeSync(fd, out, 0, 3, tkhdOffset + 1);
  } finally {
    fs.closeSync(fd);
  }
}

// patch stsd sample entry type to "fcd " at offset entryHeaderPos+4
function patchStsdForced(filePath, stsdOffset, set) {
  if (!stsdOffset) return;
  const fd = fs.openSync(filePath, 'r+');
  try {
    const entryHeaderPos = stsdOffset + 8;
    const buf = Buffer.allocUnsafe(8);
    fs.readSync(fd, buf, 0, 8, entryHeaderPos);
    const sampleType = buf.toString('ascii', 4, 8);
    if (set) {
      const out = Buffer.from('fcd ');
      fs.writeSync(fd, out, 0, 4, entryHeaderPos + 4);
    } else {
      // we don't know original; do nothing
    }
  } finally {
    fs.closeSync(fd);
  }
}

// CLI handlers
function cmdList(filePath) {
  const tracks = parseMp4(filePath);
  const out = tracks.map(t => ({
    id: t.trackId,
    type: t.type || 'unknown',
    lang: t.language === null ? null : t.language,
    default: !!t.defaultFlag,
    forced: !!t.forcedFlag
  }));
  let fo = JSON.stringify(out, null, "\t");
  fo = fo.replace(/\n\t+/g, ' ');
  fo = fo.replace(/ \{/g, "\n\t{");
  fo = fo.replace(/\{ /g, '{');
  fo = fo.replace(/ \}/g, '}');
  console.log(fo);
}

function cmdSetUnset(cmd, filePath, tidStr, flag) {
  const tid = parseInt(tidStr, 10);
  if (isNaN(tid)) {
    console.error('Invalid trackId');
    process.exit(2);
  }
  const tracks = parseMp4(filePath);
  let found = false;
  for (const t of tracks) {
    if (t.trackId === tid) {
      found = true;
      if (flag === 'default') {
        patchTkhdFlag(filePath, t.tkhdOffset, cmd === 'set');
      } else if (flag === 'forced') {
        patchStsdForced(filePath, t.stsdOffset, cmd === 'set');
      } else {
        console.error('Unknown flag', flag);
        process.exit(2);
      }
      break;
    }
  }
  if (!found) {
    console.error('Track not found');
    process.exit(1);
  }
}

// Entrypoint
function main(argv) {
  if (argv.length < 3) {
    console.error('Usage: node mp4track.js <list|set|unset> <file> [trackId] [default|forced]');
    process.exit(2);
  }
  const cmd = argv[2];
  const filePath = argv[3];
  if (!filePath) {
    console.error('Missing file');
    process.exit(2);
  }
  if (!fs.existsSync(filePath)) {
    console.error('File not found:', filePath);
    process.exit(2);
  }
  if (cmd === 'list') {
    cmdList(filePath);
    return;
  }
  if (cmd === 'set' || cmd === 'unset') {
    if (argv.length < 6) {
      console.error('Usage: set|unset <file> <trackId> <default|forced>');
      process.exit(2);
    }
    const tid = argv[4];
    const flag = argv[5];
    cmdSetUnset(cmd, filePath, tid, flag);
    return;
  }
  console.error('Unknown command', cmd);
  process.exit(2);
}

if (require.main === module) {
  main(process.argv);
}

