/* sandbox-prelude: QuickJS 兼容的纯 JS 沙箱预置库
 * 模块: base64 / utf8 / crc32 / zipPack(STORE) / zipUnpack(inflate) / makeXlsx / makeDocx / makePptx / readXlsx / readDocxText / readBytes / writeBytes
 * 宿主约定: __sbReadB64(path) -> "{ok,dataBase64|error}" JSON 字符串或 throw; __sbWriteB64(path,b64) -> "{ok|error}"
 */
(function () {
  'use strict';

  // ---------- base64 ----------
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64R = {};
  for (var bi = 0; bi < 64; bi++) B64R[B64.charAt(bi)] = bi;
  function b64Encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      var n = (b0 << 16) | (b1 << 8) | b2;
      out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63);
      out += i + 1 < bytes.length ? B64.charAt((n >> 6) & 63) : '=';
      out += i + 2 < bytes.length ? B64.charAt(n & 63) : '=';
    }
    return out;
  }
  function b64Decode(str) {
    var s = String(str).replace(/[^A-Za-z0-9+/=]/g, '');
    var bytes = [];
    for (var i = 0; i < s.length; i += 4) {
      var c0 = B64R[s.charAt(i)] | 0, c1 = B64R[s.charAt(i + 1)] | 0;
      var c2 = s.charAt(i + 2) === '=' ? 0 : (B64R[s.charAt(i + 2)] | 0);
      var c3 = s.charAt(i + 3) === '=' ? 0 : (B64R[s.charAt(i + 3)] | 0);
      var n = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
      bytes.push((n >> 16) & 255);
      if (s.charAt(i + 2) !== '=') bytes.push((n >> 8) & 255);
      if (s.charAt(i + 3) !== '=') bytes.push(n & 255);
    }
    return new Uint8Array(bytes);
  }

  // ---------- utf8 ----------
  function utf8Encode(str) {
    str = String(str);
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
        var lo = str.charCodeAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
          i++;
        }
      }
      if (code < 0x80) bytes.push(code);
      else if (code < 0x800) { bytes.push(0xC0 | (code >> 6), 0x80 | (code & 63)); }
      else if (code < 0x10000) { bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63)); }
      else { bytes.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63)); }
    }
    return new Uint8Array(bytes);
  }
  function utf8Decode(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length;) {
      var b = bytes[i];
      if (b < 0x80) { s += String.fromCharCode(b); i += 1; }
      else if (b < 0xE0) { s += String.fromCharCode(((b & 31) << 6) | (bytes[i + 1] & 63)); i += 2; }
      else if (b < 0xF0) { s += String.fromCharCode(((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63)); i += 3; }
      else {
        var cp = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63);
        cp -= 0x10000;
        s += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 1023));
        i += 4;
      }
    }
    return s;
  }

  // ---------- crc32 ----------
  var CRCT = (function () {
    var t = new Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) c = CRCT[(c ^ bytes[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  // ---------- zip pack (STORE only) ----------
  function u16(v) { return [v & 255, (v >> 8) & 255]; }
  function u32(v) { return [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >>> 24) & 255]; }
  function zipPack(entries) {
    // entries: [{name, data(Uint8Array)}]
    var out = [], central = [];
    for (var e = 0; e < entries.length; e++) {
      var ent = entries[e];
      var nameB = utf8Encode(ent.name);
      var data = ent.data;
      var crc = crc32(data);
      var offset = out.length;
      var local = [80, 75, 3, 4].concat(u16(20), u16(0x0800), u16(0), u16(0), u16(0), u32(crc), u32(data.length), u32(data.length), u16(nameB.length), u16(0));
      for (var li = 0; li < local.length; li++) out.push(local[li]);
      for (var ni = 0; ni < nameB.length; ni++) out.push(nameB[ni]);
      for (var di = 0; di < data.length; di++) out.push(data[di]);
      var cent = [80, 75, 1, 2].concat(u16(20), u16(20), u16(0x0800), u16(0), u16(0), u16(0), u32(crc), u32(data.length), u32(data.length), u16(nameB.length), u16(0), u16(0), u16(0), u16(0), u32(0), u32(offset));
      for (var ci2 = 0; ci2 < cent.length; ci2++) central.push(cent[ci2]);
      for (var cn = 0; cn < nameB.length; cn++) central.push(nameB[cn]);
    }
    var cdStart = out.length;
    for (var cj = 0; cj < central.length; cj++) out.push(central[cj]);
    var cdLen = out.length - cdStart;
    var eocd = [80, 75, 5, 6].concat(u16(0), u16(0), u16(entries.length), u16(entries.length), u32(cdLen), u32(cdStart), u16(0));
    for (var ei = 0; ei < eocd.length; ei++) out.push(eocd[ei]);
    return new Uint8Array(out);
  }

  // ---------- inflate (fixed + dynamic Huffman) ----------
  function BitReader(bytes, pos) {
    return {
      bytes: bytes, pos: pos || 0, bit: 0,
      read: function (n) {
        var v = 0;
        for (var i = 0; i < n; i++) {
          if (this.pos >= this.bytes.length) throw new Error('inflate: eof');
          v |= ((this.bytes[this.pos] >> this.bit) & 1) << i;
          this.bit++;
          if (this.bit === 8) { this.bit = 0; this.pos++; }
        }
        return v;
      }
    };
  }
  function buildHuff(lengths) {
    var MAX = 15;
    var blCount = new Array(MAX + 1);
    var i;
    for (i = 0; i <= MAX; i++) blCount[i] = 0;
    for (i = 0; i < lengths.length; i++) blCount[lengths[i]]++;
    blCount[0] = 0;
    var nextCode = new Array(MAX + 1);
    var code = 0;
    for (i = 1; i <= MAX; i++) { code = (code + blCount[i - 1]) << 1; nextCode[i] = code; }
    var codes = {};
    for (i = 0; i < lengths.length; i++) {
      var len = lengths[i];
      if (len > 0) { codes[len + ':' + nextCode[len]] = i; nextCode[len]++; }
    }
    return { lengths: lengths, codes: codes };
  }
  function huffDecode(br, huff) {
    var code = 0;
    for (var len = 1; len <= 15; len++) {
      code = (code << 1) | br.read(1);
      var k = len + ':' + code;
      if (huff.codes[k] !== undefined && huff.lengths[huff.codes[k]] === len) return huff.codes[k];
    }
    throw new Error('inflate: bad huffman code');
  }
  var LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  var LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  var DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
  var DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  function inflateBlock(br, out, litHuff, distHuff) {
    for (;;) {
      var sym = huffDecode(br, litHuff);
      if (sym < 256) { out.push(sym); continue; }
      if (sym === 256) break;
      var li = sym - 257;
      if (li >= LEN_BASE.length) throw new Error('inflate: bad length sym');
      var len = LEN_BASE[li] + br.read(LEN_EXTRA[li]);
      var dsym = huffDecode(br, distHuff);
      if (dsym >= DIST_BASE.length) throw new Error('inflate: bad dist sym');
      var dist = DIST_BASE[dsym] + br.read(DIST_EXTRA[dsym]);
      if (dist > out.length) throw new Error('inflate: dist too far');
      for (var k = 0; k < len; k++) out.push(out[out.length - dist]);
    }
  }
  function inflate(bytes) {
    var br = BitReader(bytes);
    var out = [];
    for (;;) {
      var bfinal = br.read(1);
      var btype = br.read(2);
      if (btype === 0) {
        if (br.bit !== 0) { br.bit = 0; br.pos++; }
        var nlen = br.bytes[br.pos] | (br.bytes[br.pos + 1] << 8);
        br.pos += 4;
        for (var s = 0; s < nlen; s++) out.push(br.bytes[br.pos + s]);
        br.pos += nlen;
      } else if (btype === 1) {
        var litL = new Array(288), distL = new Array(30);
        var i;
        for (i = 0; i < 288; i++) litL[i] = i < 144 ? 8 : (i < 256 ? 9 : (i < 280 ? 7 : 8));
        for (i = 0; i < 30; i++) distL[i] = 5;
        inflateBlock(br, out, buildHuff(litL), buildHuff(distL));
      } else if (btype === 2) {
        var hlit = br.read(5) + 257, hdist = br.read(5) + 1, hclen = br.read(4) + 4;
        var ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
        var clL = new Array(19);
        for (i = 0; i < 19; i++) clL[i] = 0;
        for (i = 0; i < hclen; i++) clL[ORDER[i]] = br.read(3);
        var clHuff = buildHuff(clL);
        var allL = [];
        while (allL.length < hlit + hdist) {
          var cs = huffDecode(br, clHuff);
          if (cs < 16) allL.push(cs);
          else if (cs === 16) {
            var rep = 3 + br.read(2);
            var prev = allL[allL.length - 1];
            for (i = 0; i < rep; i++) allL.push(prev);
          } else if (cs === 17) {
            var z1 = 3 + br.read(3);
            for (i = 0; i < z1; i++) allL.push(0);
          } else {
            var z2 = 11 + br.read(7);
            for (i = 0; i < z2; i++) allL.push(0);
          }
        }
        inflateBlock(br, out, buildHuff(allL.slice(0, hlit)), buildHuff(allL.slice(hlit)));
      } else throw new Error('inflate: bad btype');
      if (bfinal) break;
    }
    return new Uint8Array(out);
  }

  // ---------- zip unpack ----------
  function zipUnpack(bytes) {
    var eocdPos = -1;
    for (var i = bytes.length - 22; i >= 0 && i >= bytes.length - 65558; i--) {
      if (bytes[i] === 80 && bytes[i + 1] === 75 && bytes[i + 2] === 5 && bytes[i + 3] === 6) { eocdPos = i; break; }
    }
    if (eocdPos < 0) throw new Error('zip: EOCD not found');
    var r16 = function (p) { return bytes[p] | (bytes[p + 1] << 8); };
    var r32 = function (p) { return (bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16) | (bytes[p + 3] << 24)) >>> 0; };
    var count = r16(eocdPos + 10);
    var cdOff = r32(eocdPos + 16);
    var files = {};
    var p = cdOff;
    for (var f = 0; f < count; f++) {
      if (!(bytes[p] === 80 && bytes[p + 1] === 75 && bytes[p + 2] === 1 && bytes[p + 3] === 2)) throw new Error('zip: bad central header');
      var method = r16(p + 10);
      var compSize = r32(p + 20);
      var nameLen = r16(p + 28), extraLen = r16(p + 30), commentLen = r16(p + 32);
      var localOff = r32(p + 42);
      var name = utf8Decode(bytes.subarray(p + 46, p + 46 + nameLen));
      var lNameLen = r16(localOff + 26), lExtraLen = r16(localOff + 28);
      var dataOff = localOff + 30 + lNameLen + lExtraLen;
      var raw = bytes.subarray(dataOff, dataOff + compSize);
      var data;
      if (method === 0) data = raw;
      else if (method === 8) data = inflate(raw);
      else throw new Error('zip: unsupported method ' + method);
      files[name] = data;
      p += 46 + nameLen + extraLen + commentLen;
    }
    return files;
  }

  // ---------- xml escape ----------
  function xmlEscape(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  // ---------- ooxml writers ----------
  var CT_XML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  var RELS_NS = 'xmlns="http://schemas.openxmlformats.org/package/2006/relationships"';

  function colName(n) {
    var s = '';
    n = n + 1;
    while (n > 0) { var r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = (n - r - 1) / 26; }
    return s;
  }
  function makeXlsx(spec) {
    // spec: {sheets:[{name, rows:[[cell,...]]}], sharedStrings 自动构建}
    var ss = [], ssIndex = {};
    var sheets = spec.sheets || [{ name: 'Sheet1', rows: [] }];
    var sheetXml = [];
    for (var si = 0; si < sheets.length; si++) {
      var sh = sheets[si];
      var rowsXml = '';
      for (var r = 0; r < (sh.rows || []).length; r++) {
        var cellsXml = '';
        for (var c = 0; c < sh.rows[r].length; c++) {
          var v = sh.rows[r][c];
          var ref = colName(c) + (r + 1);
          if (typeof v === 'number' && isFinite(v)) {
            cellsXml += '<c r="' + ref + '"><v>' + v + '</v></c>';
          } else if (v === null || v === undefined) {
            continue;
          } else {
            var sv = String(v);
            if (ssIndex[sv] === undefined) { ssIndex[sv] = ss.length; ss.push(sv); }
            cellsXml += '<c r="' + ref + '" t="s"><v>' + ssIndex[sv] + '</v></c>';
          }
        }
        rowsXml += '<row r="' + (r + 1) + '">' + cellsXml + '</row>';
      }
      sheetXml.push(rowsXml);
    }
    var sstXml = CT_XML + '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="' + ss.length + '" uniqueCount="' + ss.length + '">';
    for (var st = 0; st < ss.length; st++) sstXml += '<si><t>' + xmlEscape(ss[st]) + '</t></si>';
    sstXml += '</sst>';
    var wbSheets = '', wbRels = '', ctOverrides = '';
    var entries = [];
    entries.push({ name: '[Content_Types].xml', data: null });
    for (si = 0; si < sheets.length; si++) {
      wbSheets += '<sheet name="' + xmlEscape(sheets[si].name || ('Sheet' + (si + 1))) + '" sheetId="' + (si + 1) + '" r:id="rId' + (si + 1) + '"/>';
      wbRels += '<Relationship Id="rId' + (si + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + (si + 1) + '.xml"/>';
      ctOverrides += '<Override PartName="/xl/worksheets/sheet' + (si + 1) + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>';
    }
    wbRels += '<Relationship Id="rId' + (sheets.length + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>';
    var ct = CT_XML + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' + ctOverrides + '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>';
    entries[0].data = utf8Encode(ct);
    entries.push({ name: '_rels/.rels', data: utf8Encode(CT_XML + '<Relationships ' + RELS_NS + '><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>') });
    entries.push({ name: 'xl/workbook.xml', data: utf8Encode(CT_XML + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>' + wbSheets + '</sheets></workbook>') });
    entries.push({ name: 'xl/_rels/workbook.xml.rels', data: utf8Encode(CT_XML + '<Relationships ' + RELS_NS + '>' + wbRels + '</Relationships>') });
    entries.push({ name: 'xl/sharedStrings.xml', data: utf8Encode(sstXml) });
    for (si = 0; si < sheets.length; si++) {
      entries.push({ name: 'xl/worksheets/sheet' + (si + 1) + '.xml', data: utf8Encode(CT_XML + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + sheetXml[si] + '</sheetData></worksheet>') });
    }
    return zipPack(entries);
  }

  function makeDocx(spec) {
    // spec: {paragraphs:[string | {text, bold, italic}], heading 支持 {text, heading:1..6}}
    var paras = spec.paragraphs || [];
    var body = '';
    for (var i = 0; i < paras.length; i++) {
      var p = paras[i];
      if (typeof p === 'string') p = { text: p };
      var pPr = '';
      if (p.heading) pPr = '<w:pPr><w:pStyle w:val="Heading' + p.heading + '"/></w:pPr>';
      var rPr = '';
      if (p.bold) rPr += '<w:b/>';
      if (p.italic) rPr += '<w:i/>';
      body += '<w:p>' + pPr + '<w:r>' + (rPr ? '<w:rPr>' + rPr + '</w:rPr>' : '') + '<w:t xml:space="preserve">' + xmlEscape(p.text || '') + '</w:t></w:r></w:p>';
    }
    var docXml = CT_XML + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body + '</w:body></w:document>';
    var ct = CT_XML + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>';
    return zipPack([
      { name: '[Content_Types].xml', data: utf8Encode(ct) },
      { name: '_rels/.rels', data: utf8Encode(CT_XML + '<Relationships ' + RELS_NS + '><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>') },
      { name: 'word/document.xml', data: utf8Encode(docXml) }
    ]);
  }

  function makePptx(spec) {
    // spec: {slides:[{title, bullets:[string]}]}
    var slides = spec.slides || [];
    var entries = [];
    var ctOverrides = '', presSldIds = '', presRels = '';
    var ct = CT_XML + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>';
    for (var i = 0; i < slides.length; i++) {
      var n = i + 1;
      ctOverrides += '<Override PartName="/ppt/slides/slide' + n + '.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>';
      presSldIds += '<p:sldId id="' + (255 + n) + '" r:id="rId' + n + '"/>';
      presRels += '<Relationship Id="rId' + n + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide' + n + '.xml"/>';
      var sl = slides[i];
      var bodyParas = '';
      var bullets = sl.bullets || [];
      for (var b = 0; b < bullets.length; b++) {
        bodyParas += '<a:p><a:r><a:rPr lang="zh-CN"/><a:t>' + xmlEscape(bullets[b]) + '</a:t></a:r></a:p>';
      }
      var slideXml = CT_XML +
        '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:cSld><p:spTree>' +
        '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN"/><a:t>' + xmlEscape(sl.title || '') + '</a:t></a:r></a:p></p:txBody></p:sp>' +
        '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Content"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="685800" y="1524000"/><a:ext cx="7772400" cy="4419600"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>' + (bodyParas || '<a:p/>') + '</p:txBody></p:sp>' +
        '</p:spTree></p:cSld><p:clrMapOvr><a:overrideClrMapping bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/></p:clrMapOvr></p:sld>';
      entries.push({ name: 'ppt/slides/slide' + n + '.xml', data: utf8Encode(slideXml) });
      entries.push({ name: 'ppt/slides/_rels/slide' + n + '.xml.rels', data: utf8Encode(CT_XML + '<Relationships ' + RELS_NS + '/>') });
    }
    ct += ctOverrides + '</Types>';
    var presXml = CT_XML + '<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldSz cx="9144000" cy="6858000" type="screen4x3"/><p:sldIdLst>' + presSldIds + '</p:sldIdLst></p:presentation>';
    var out = [
      { name: '[Content_Types].xml', data: utf8Encode(ct) },
      { name: '_rels/.rels', data: utf8Encode(CT_XML + '<Relationships ' + RELS_NS + '><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>') },
      { name: 'ppt/presentation.xml', data: utf8Encode(presXml) },
      { name: 'ppt/_rels/presentation.xml.rels', data: utf8Encode(CT_XML + '<Relationships ' + RELS_NS + '>' + presRels + '</Relationships>') }
    ];
    for (i = 0; i < entries.length; i++) out.push(entries[i]);
    return zipPack(out);
  }

  // ---------- ooxml readers ----------
  function stripTags(xml) {
    return String(xml).replace(/<[^>]+>/g, '');
  }
  function xmlUnescape(s) {
    return String(s).replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  }
  function matchAll(re, str) {
    var out = [], m;
    re.lastIndex = 0;
    while ((m = re.exec(str)) !== null) out.push(m);
    return out;
  }
  function readXlsx(bytes) {
    var files = zipUnpack(bytes);
    var sst = [];
    if (files['xl/sharedStrings.xml']) {
      var sstXml = utf8Decode(files['xl/sharedStrings.xml']);
      var sis = matchAll(/<si>([\s\S]*?)<\/si>/g, sstXml);
      for (var i = 0; i < sis.length; i++) {
        var ts = matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g, sis[i][1]);
        var combined = '';
        for (var j = 0; j < ts.length; j++) combined += ts[j][1];
        sst.push(xmlUnescape(combined));
      }
    }
    var wb = files['xl/workbook.xml'] ? utf8Decode(files['xl/workbook.xml']) : '';
    var nameMatches = matchAll(/<sheet[^>]*name="([^"]*)"[^>]*\/>/g, wb);
    var result = { sheets: [] };
    var sheetNames = Object.keys(files).filter(function (k) { return /^xl\/worksheets\/sheet\d+\.xml$/.test(k); }).sort();
    for (i = 0; i < sheetNames.length; i++) {
      var xml = utf8Decode(files[sheetNames[i]]);
      var rows = [];
      var rowMs = matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g, xml);
      for (var r = 0; r < rowMs.length; r++) {
        var cells = [];
        var cellMs = matchAll(/<c([^>]*)>([\s\S]*?)<\/c>|<c([^>]*)\/>/g, rowMs[r][1]);
        for (var c = 0; c < cellMs.length; c++) {
          var attrs = cellMs[c][1] || cellMs[c][3] || '';
          var inner = cellMs[c][2] || '';
          var vM = /<v>([\s\S]*?)<\/v>/.exec(inner);
          if (!vM) { cells.push(null); continue; }
          if (/t="s"/.test(attrs)) cells.push(sst[parseInt(vM[1], 10)] || '');
          else cells.push(parseFloat(vM[1]));
        }
        rows.push(cells);
      }
      result.sheets.push({ name: nameMatches[i] ? xmlUnescape(nameMatches[i][1]) : sheetNames[i], rows: rows });
    }
    return result;
  }
  function readDocxText(bytes) {
    var files = zipUnpack(bytes);
    if (!files['word/document.xml']) throw new Error('docx: word/document.xml missing');
    var xml = utf8Decode(files['word/document.xml']);
    var paras = matchAll(/<w:p[ >][\s\S]*?<\/w:p>/g, xml);
    var out = [];
    for (var i = 0; i < paras.length; i++) {
      var ts = matchAll(/<w:t[^>]*>([\s\S]*?)<\/w:t>/g, paras[i][0]);
      var line = '';
      for (var j = 0; j < ts.length; j++) line += ts[j][1];
      out.push(xmlUnescape(line));
    }
    return out.join('\n');
  }

  // ---------- host binary bridge ----------
  function parseEnvelope(raw, op) {
    // 鸿蒙 throw 直接上抛;iOS/Android 返回 JSON envelope
    var r;
    try { r = JSON.parse(raw); } catch (e) { throw new Error(op + ': bad envelope'); }
    if (!r.ok) throw new Error(op + ': ' + (r.error || 'unknown'));
    return r;
  }
  function readBytes(path) {
    var raw = globalThis.__sbReadB64(String(path));
    var r = parseEnvelope(raw, 'readBytes');
    return b64Decode(r.dataBase64 || '');
  }
  function writeBytes(path, bytes) {
    var raw = globalThis.__sbWriteB64(String(path), b64Encode(bytes));
    parseEnvelope(raw, 'writeBytes');
  }

  globalThis.Prelude = {
    b64Encode: b64Encode, b64Decode: b64Decode,
    utf8Encode: utf8Encode, utf8Decode: utf8Decode,
    crc32: crc32,
    zipPack: zipPack, zipUnpack: zipUnpack, inflate: inflate,
    makeXlsx: makeXlsx, makeDocx: makeDocx, makePptx: makePptx,
    readXlsx: readXlsx, readDocxText: readDocxText
  };
  globalThis.readBytes = readBytes;
  globalThis.writeBytes = writeBytes;
})();
