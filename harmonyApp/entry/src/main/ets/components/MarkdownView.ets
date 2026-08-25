import { ThemeColors } from '../theme/Theme';
import measure from '@ohos.measure';
import { pasteboard } from '@kit.BasicServicesKit';

/**
 * 轻量 Markdown 渲染（对齐 Android Markdown.kt 蓝本的子集）：
 *  - 结构块原生渲染：``` 码块 / # 标题 / - 列表 / > 引用 / | 表格 / --- 分割线 / 独立图片行
 *  - 行内富文本：同步 Span 拼接 — 内容参与首次测量，气泡（wrap-content + maxWidth 约束）必然正确包裹。
 *    注意：不可用 TextController + StyledString.fromHtml 异步注入，首帧按空内容测量后不再重测量，
 *    文字会画到气泡背景外（横屏尤甚）。粗体/斜体/删除线/链接/行内码/数学/$提及$ 均同步降级着色。
 */

class MdBlock {
  kind: string = 'para';       // para|heading|code|list|quote|table|hr|image
  plain: string = '';          // 原始行内文本（渲染与复制源）
  level: number = 0;           // heading 1-4
  code: string = '';
  lang: string = '';
  url: string = '';
  alt: string = '';
  cells: string[][] = [];      // table 单元格（纯文本）
  aligns: string[] = [];       // table 每列对齐：start|center|end（解析自 :---/:---:/---: 分隔行）
  marker: string = '';         // 列表前缀
  indent: number = 0;          // 列表缩进层级
}

class MdSpan {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  strike: boolean = false;
  underline: boolean = false;
  color: string = '';
}

function isCjk(ch: string): boolean {
  const c = ch.charCodeAt(0);
  return (c >= 0x4e00 && c <= 0x9fa5) || (c >= 0x3000 && c <= 0x303f) || (c >= 0xff00 && c <= 0xffef);
}

function mentionOk(text: string, i: number): boolean {
  // @ 前不能是字母数字（排除邮箱）
  if (i > 0) {
    const p = text[i - 1];
    if ((p >= 'a' && p <= 'z') || (p >= 'A' && p <= 'Z') || (p >= '0' && p <= '9')) {
      return false;
    }
  }
  return true;
}

/** 行内 Markdown → Span 段列表（同步解析，测量随内容走） */
function parseInline(text: string, t: ThemeColors, bold: boolean, italic: boolean): MdSpan[] {
  const out: MdSpan[] = [];
  let buf = '';
  const flush = (): void => {
    if (buf.length > 0) {
      const s = new MdSpan();
      s.text = buf;
      s.bold = bold;
      s.italic = italic;
      out.push(s);
      buf = '';
    }
  };
  const pushStyled = (txt: string, color: string, strike: boolean, underline: boolean): void => {
    if (txt.length === 0) {
      return;
    }
    const s = new MdSpan();
    s.text = txt;
    s.color = color;
    s.bold = bold;
    s.italic = italic;
    s.strike = strike;
    s.underline = underline;
    out.push(s);
  };
  const pushAll = (sub: MdSpan[]): void => {
    for (const s of sub) {
      out.push(s);
    }
  };
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '`') {
      const close = text.indexOf('`', i + 1);
      if (close > i) {
        flush();
        pushStyled(text.substring(i + 1, close), t.primary, false, false);
        i = close + 1;
        continue;
      }
    }
    if (ch === '*' && text[i + 1] === '*') {
      const close = text.indexOf('**', i + 2);
      if (close > i + 1) {
        flush();
        pushAll(parseInline(text.substring(i + 2, close), t, true, italic));
        i = close + 2;
        continue;
      }
    }
    if (ch === '*' && text[i + 1] !== '*') {
      const close = text.indexOf('*', i + 1);
      if (close > i) {
        flush();
        pushAll(parseInline(text.substring(i + 1, close), t, bold, true));
        i = close + 1;
        continue;
      }
    }
    if (ch === '~' && text[i + 1] === '~') {
      const close = text.indexOf('~~', i + 2);
      if (close > i + 1) {
        flush();
        pushStyled(text.substring(i + 2, close), '', true, false);
        i = close + 2;
        continue;
      }
    }
    if (ch === '[') {
      const closeBracket = text.indexOf(']', i + 1);
      if (closeBracket > i && text[closeBracket + 1] === '(') {
        const closeParen = text.indexOf(')', closeBracket + 2);
        if (closeParen > closeBracket) {
          flush();
          pushStyled(text.substring(i + 1, closeBracket), t.accent, false, true);
          i = closeParen + 1;
          continue;
        }
      }
    }
    if (ch === '$' && text[i + 1] !== ' ' && text[i + 1] !== undefined) {
      const close = text.indexOf('$', i + 1);
      if (close > i + 1) {
        const inner = text.substring(i + 1, close);
        if (inner.indexOf(' ') < 0 || inner.length < 30) {
          flush();
          pushStyled(text.substring(i, close + 1), t.accent, false, false);
          i = close + 1;
          continue;
        }
      }
    }
    if (ch === '@' && mentionOk(text, i)) {
      let j = i + 1;
      while (j < text.length) {
        const c = text[j];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
          || c === '_' || c === '-' || c === '.' || c === '/' || isCjk(c)) {
          j++;
        } else {
          break;
        }
      }
      let end = j;
      while (end > i + 1 && (text[end - 1] === '.' || text[end - 1] === '-' || text[end - 1] === '/')) {
        end--;
      }
      const name = text.substring(i + 1, end);
      if (name.length >= 2) {
        flush();
        pushStyled('@' + name, t.primary, false, false);
        i = end;
        continue;
      }
    }
    buf += ch;
    i++;
  }
  flush();
  return out;
}

function splitTableLine(line: string): string[] {
  const t = line.trim();
  let body = t;
  if (t.startsWith('|')) {
    body = t.substring(1);
  }
  if (body.endsWith('|')) {
    body = body.substring(0, body.length - 1);
  }
  const parts = body.split('|');
  const out: string[] = [];
  for (const p of parts) {
    out.push(p.trim());
  }
  return out;
}

function isTableSeparator(line: string): boolean {
  const t = line.trim();
  if (t.length < 3) {
    return false;
  }
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (c !== '|' && c !== '-' && c !== ':' && c !== ' ') {
      return false;
    }
  }
  return t.indexOf('-') >= 0;
}

function parseBlocks(md: string, t: ThemeColors): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = md.split('\n');
  let i = 0;
  const mk = (): MdBlock => new MdBlock();
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      i++;
      continue;
    }
    // ``` 围栏码块
    if (trimmed.startsWith('```')) {
      const b = mk();
      b.kind = 'code';
      b.lang = trimmed.substring(3).trim();
      b.code = '';
      i++;
      while (i < lines.length && lines[i].trim().indexOf('```') !== 0) {
        b.code += lines[i] + '\n';
        i++;
      }
      i++;
      blocks.push(b);
      continue;
    }
    // 标题
    if (trimmed.startsWith('#')) {
      let level = 0;
      while (level < trimmed.length && trimmed[level] === '#') {
        level++;
      }
      if (level <= 6 && trimmed[level] === ' ') {
        const b = mk();
        b.kind = 'heading';
        b.level = level > 4 ? 4 : level;
        b.plain = trimmed.substring(level + 1);
        blocks.push(b);
        i++;
        continue;
      }
    }
    // hr
    if ((trimmed.startsWith('---') || trimmed.startsWith('***') || trimmed.startsWith('___'))
      && trimmed.length >= 3) {
      let all = true;
      for (let k = 0; k < trimmed.length; k++) {
        if (trimmed[k] !== trimmed[0]) {
          all = false;
          break;
        }
      }
      if (all) {
        const b = mk();
        b.kind = 'hr';
        blocks.push(b);
        i++;
        continue;
      }
    }
    // 引用
    if (trimmed.startsWith('>')) {
      const b = mk();
      b.kind = 'quote';
      let body = trimmed.substring(1).trim();
      i++;
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        body += '\n' + lines[i].trim().substring(1).trim();
        i++;
      }
      b.plain = body;
      blocks.push(b);
      continue;
    }
    // 列表项（支持 2 级缩进）
    const listMatch = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (listMatch !== null) {
      const b = mk();
      b.kind = 'list';
      const indentSpaces = listMatch[1].length;
      b.indent = Math.floor(indentSpaces / 2);
      const bullet = listMatch[2];
      b.marker = (bullet === '-' || bullet === '*' || bullet === '+') ? '•' : bullet;
      b.plain = listMatch[3];
      blocks.push(b);
      i++;
      continue;
    }
    // 表格
    if (trimmed.startsWith('|') && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const b = mk();
      b.kind = 'table';
      b.cells = [];
      b.cells.push(splitTableLine(lines[i]));
      b.aligns = splitTableLine(lines[i + 1]).map((seg: string) => {
        const s = seg.trim();
        if (s.startsWith(':') && s.endsWith(':') && s.length > 1) {
          return 'center';
        }
        if (s.endsWith(':')) {
          return 'end';
        }
        return 'start';
      });
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        b.cells.push(splitTableLine(lines[i]));
        i++;
      }
      blocks.push(b);
      continue;
    }
    // 独立图片行
    const imgMatch = /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(trimmed);
    if (imgMatch !== null) {
      const b = mk();
      b.kind = 'image';
      b.alt = imgMatch[1];
      b.url = imgMatch[2];
      blocks.push(b);
      i++;
      continue;
    }
    // 普通段落（连续普通行合并；CJK 之间不加空格）
    const b = mk();
    b.kind = 'para';
    let body = trimmed;
    i++;
    while (i < lines.length) {
      const next = lines[i];
      const nt = next.trim();
      if (nt.length === 0 || nt.startsWith('```') || nt.startsWith('#') || nt.startsWith('>')
        || nt.startsWith('|') || nt.startsWith('---') || nt.startsWith('***')
        || /^(\s*)([-*+]|\d+[.)])\s+/.test(next) || /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.test(nt)) {
        break;
      }
      const lastCh = body.length > 0 ? body[body.length - 1] : '';
      const firstCh = nt.length > 0 ? nt[0] : '';
      if (lastCh.length > 0 && firstCh.length > 0 && !isCjk(lastCh) && !isCjk(firstCh)) {
        body += ' ' + nt;
      } else {
        body += nt;
      }
      i++;
    }
    b.plain = body;
    blocks.push(b);
  }
  return blocks;
}

/**
 * 表格（GFM/GitHub 布局语义）：
 *  - 全表共享列宽：measureText 预量每列最长单元格宽度作为该列宽度，所有行用同一组列宽 → 列列对齐
 *  - auto 列宽（等价 table-layout:auto）：列宽贴合内容，不拉满容器
 *  - 总宽超容器时横向滚动兜底；长 token BREAK_ALL 硬换行（等价 GitHub word-wrap:break-word）
 *  - 每列对齐解析自 :--- / :---: / ---: 分隔行，默认左对齐
 */
@Component
struct MdTable {
  /** JSON 序列化传入：@Prop 深拷贝对二维数组支持不稳，拍平成字符串传输 */
  @Prop @Watch('onDataChange') cellsJson: string = '[]';
  @Prop @Watch('onDataChange') alignsJson: string = '[]';
  @Prop theme: ThemeColors = new ThemeColors();
  @State rows: string[][] = [];
  @State aligns: string[] = [];
  private cachedW: number[] = [];
  private cachedKey: string = '';

  aboutToAppear(): void {
    this.onDataChange();
  }

  onDataChange(): void {
    try {
      const rows = JSON.parse(this.cellsJson) as string[][];
      this.rows = rows.map((r: string[]) => r.slice());
      this.aligns = JSON.parse(this.alignsJson) as string[];
    } catch (_e) {
      this.rows = [];
      this.aligns = [];
    }
    this.cachedKey = '';
  }

  private colWidths(): number[] {
    const key = this.rows.map((r: string[]) => r.join('\u0001')).join('\u0002');
    if (key === this.cachedKey) {
      return this.cachedW;
    }
    const n = this.rows.length > 0 ? this.rows[0].length : 0;
    const ws: number[] = [];
    for (let c = 0; c < n; c++) {
      let w = 56;
      for (let r = 0; r < this.rows.length; r++) {
        const t = this.rows[r][c] ?? '';
        const mw = measure.measureText({ textContent: t, fontSize: '11fp' });
        const safe = isNaN(mw) ? 0 : Math.ceil(mw);
        w = Math.max(w, safe + 20);
      }
      ws.push(Math.min(w, 220));
    }
    this.cachedKey = key;
    this.cachedW = ws;
    return ws;
  }

  private alignOf(cIdx: number): TextAlign {
    const a = this.aligns[cIdx] ?? 'start';
    if (a === 'center') {
      return TextAlign.Center;
    }
    if (a === 'end') {
      return TextAlign.End;
    }
    return TextAlign.Start;
  }

  /** 每列宽度 = 该列最长单元格内容宽（auto 列宽，等价 GitHub table-layout:auto）；总宽超容器时横向滚动兜底 */

  build() {
    Scroll() {
      Column({ space: 0 }) {
        ForEach(this.rows, (row: string[], rIdx: number) => {
          Row() {
            ForEach(row, (cell: string, cIdx: number) => {
              Text(cell)
                .fontSize('11fp')
                .fontColor(rIdx === 0 ? this.theme.textPrimary : this.theme.textSecondary)
                .fontWeight(rIdx === 0 ? FontWeight.Bold : FontWeight.Normal)
                .wordBreak(WordBreak.BREAK_ALL)
                .textAlign(this.alignOf(cIdx))
                .width(this.colWidths()[cIdx])
                .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            }, (cell: string, cIdx: number) => rIdx + '_' + cIdx + '_' + cell)
          }
          .border({ width: { bottom: 0.5 }, color: this.theme.divider })
        }, (row: string[], rIdx: number) => 'row_' + rIdx + '_' + row.length)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
  }
}

/** 富文本段：同步 Span 拼接，首次布局即携带全部内容（修复横屏文字溢出气泡） */
@Component
struct MdRich {
  @Prop @Watch('onSrcChange') src: string = '';
  @Prop fontSize: number = 15;
  @Prop color: string = '#f2f2f7';
  @Prop bold: boolean = false;
  @Prop theme: ThemeColors = new ThemeColors();
  @State segs: MdSpan[] = [];

  aboutToAppear(): void {
    this.segs = parseInline(this.src, this.theme, this.bold, false);
  }

  onSrcChange(): void {
    this.segs = parseInline(this.src, this.theme, this.bold, false);
  }

  build() {
    Text() {
      ForEach(this.segs, (s: MdSpan, idx: number) => {
        Span(s.text)
          .fontSize(this.fontSize)
          .fontColor(s.color.length > 0 ? s.color : this.color)
          .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration({
            type: s.strike ? TextDecorationType.LineThrough
              : (s.underline ? TextDecorationType.Underline : TextDecorationType.None)
          })
      }, (s: MdSpan, idx: number) => idx + '_' + s.text.length + '_' + s.color)
    }
    .fontSize(this.fontSize)
    .fontColor(this.color)
    .lineHeight(Math.round(this.fontSize * 1.55))
  }
}

/** A5 代码高亮段：关键字 accent / 注释 textHint+斜体 / 字符串 success / 数字 warning / 其余 textPrimary */
class CodeSeg {
  text: string = '';
  color: string = '';
  italic: boolean = false;
}

/** A5 语言关键字表（对齐 Android codeKeywords，三端观感一致；json 无关键字） */
function codeKeywords(lang: string): Set<string> {
  const l = lang.toLowerCase();
  if (l === 'kotlin' || l === 'kt') {
    return new Set<string>([
      'fun', 'val', 'var', 'class', 'object', 'interface', 'return', 'if', 'else', 'when',
      'for', 'while', 'import', 'package', 'private', 'public', 'internal', 'data', 'sealed',
      'suspend', 'companion', 'override', 'null', 'true', 'false', 'this', 'is', 'in', 'as',
      'try', 'catch', 'finally', 'throw', 'init', 'constructor', 'by', 'lazy',
    ]);
  }
  if (l === 'java') {
    return new Set<string>([
      'class', 'interface', 'public', 'private', 'protected', 'static', 'final', 'void',
      'return', 'if', 'else', 'for', 'while', 'new', 'import', 'package', 'extends',
      'implements', 'null', 'true', 'false', 'this', 'try', 'catch', 'finally', 'throw',
      'throws', 'int', 'long', 'double', 'boolean', 'char', 'byte', 'short', 'float',
    ]);
  }
  if (l === 'ts' || l === 'typescript' || l === 'js' || l === 'javascript') {
    return new Set<string>([
      'function', 'const', 'let', 'var', 'return', 'if', 'else', 'for', 'while', 'class',
      'interface', 'type', 'import', 'export', 'from', 'async', 'await', 'new', 'null',
      'undefined', 'true', 'false', 'this', 'try', 'catch', 'finally', 'throw', 'extends',
      'implements', 'public', 'private', 'readonly', 'enum', 'switch', 'case', 'break',
      'default', 'of', 'in',
    ]);
  }
  if (l === 'py' || l === 'python') {
    return new Set<string>([
      'def', 'class', 'return', 'if', 'elif', 'else', 'for', 'while', 'import', 'from',
      'as', 'pass', 'None', 'True', 'False', 'try', 'except', 'finally', 'raise', 'with',
      'lambda', 'yield', 'global', 'nonlocal', 'in', 'is', 'and', 'or', 'not', 'async', 'await',
    ]);
  }
  if (l === 'json') {
    return new Set<string>();
  }
  if (l === 'bash' || l === 'sh' || l === 'shell' || l === 'zsh') {
    return new Set<string>([
      'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'do', 'done', 'case', 'esac',
      'in', 'function', 'return', 'local', 'export', 'echo', 'cd', 'ls', 'grep', 'cat',
    ]);
  }
  return new Set<string>([
    'fun', 'val', 'var', 'class', 'return', 'if', 'else', 'for', 'while', 'import',
    'function', 'const', 'let', 'def', 'null', 'true', 'false', 'this',
  ]);
}

/** A5 token 正则（对齐 Android CODE_TOKEN_RE）：行注释/块注释/# 注释/单双引号字符串（含转义）/数字。
 *  模块级共享，每次调用前重置 lastIndex。 */
const CODE_TOKEN_RE =
  /(\/\/[^\n]*|\/\*[\s\S]*?\*\/|#[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|\b\d+(?:\.\d+)?\b)/g;

function isCodeWordStart(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_';
}

function isCodeWordChar(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c === '_';
}

/** A5 代码 → 高亮段列表（对齐 Android highlightCode + appendPlainSegment）：
 *  正则 token 化（注释/字符串/数字直接着色）+ token 间纯文本扫关键字；相邻同色段合并压 Span 组件数；
 *  超长代码（>20000 字符）降级单色，防 Span 爆炸。 */
function highlightCode(code: string, lang: string, t: ThemeColors): CodeSeg[] {
  const out: CodeSeg[] = [];
  if (code.length === 0) {
    return out;
  }
  if (code.length > 20000) {
    const whole = new CodeSeg();
    whole.text = code;
    whole.color = t.textPrimary;
    out.push(whole);
    return out;
  }
  const keywords = codeKeywords(lang);
  const mk = (txt: string, color: string, italic: boolean): void => {
    if (txt.length === 0) {
      return;
    }
    const n = out.length;
    if (n > 0) {
      const lastSeg = out[n - 1];
      if (lastSeg.color === color && lastSeg.italic === italic) {
        lastSeg.text += txt;
        return;
      }
    }
    const s = new CodeSeg();
    s.text = txt;
    s.color = color;
    s.italic = italic;
    out.push(s);
  };
  const pushPlain = (seg: string): void => {
    if (seg.length === 0) {
      return;
    }
    if (keywords.size === 0) {
      mk(seg, t.textPrimary, false);
      return;
    }
    let i = 0;
    let plain = '';
    while (i < seg.length) {
      if (isCodeWordStart(seg[i])) {
        let j = i + 1;
        while (j < seg.length && isCodeWordChar(seg[j])) {
          j++;
        }
        const word = seg.substring(i, j);
        if (keywords.has(word)) {
          mk(plain, t.textPrimary, false);
          plain = '';
          mk(word, t.accent, false);
        } else {
          plain += word;
        }
        i = j;
      } else {
        plain += seg[i];
        i++;
      }
    }
    mk(plain, t.textPrimary, false);
  };
  CODE_TOKEN_RE.lastIndex = 0;
  let m = CODE_TOKEN_RE.exec(code);
  let last = 0;
  while (m !== null) {
    const tok = m[0];
    const start = m.index;
    if (start > last) {
      pushPlain(code.substring(last, start));
    }
    let color = t.textPrimary;
    let italic = false;
    if (tok.startsWith('//') || tok.startsWith('/*') || tok.startsWith('#')) {
      color = t.textHint;
      italic = true;
    } else if (tok.startsWith('"') || tok.startsWith('\'')) {
      color = t.success;
    } else {
      const c0 = tok.charCodeAt(0);
      if (c0 >= 48 && c0 <= 57) {
        color = t.warning;
      }
    }
    mk(tok, color, italic);
    last = start + tok.length;
    m = CODE_TOKEN_RE.exec(code);
  }
  if (last < code.length) {
    pushPlain(code.substring(last));
  }
  return out;
}

/** 代码块：右上角 lang 标签 + 复制按钮（copied 1.2s 自动复位，对齐 iOS/Android CodeBlock） */
@Component
struct MdCode {
  @Prop @Watch('onCodeChange') code: string = '';
  @Prop @Watch('onCodeChange') lang: string = '';
  @Prop theme: ThemeColors = new ThemeColors();
  @State copied: boolean = false;
  /** A5 高亮段（code/lang 变化即重算；流式追加的码块每回合重高亮一次） */
  @State segs: CodeSeg[] = [];

  aboutToAppear(): void {
    this.segs = highlightCode(this.code, this.lang, this.theme);
  }

  onCodeChange(): void {
    this.segs = highlightCode(this.code, this.lang, this.theme);
  }

  private doCopy(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.code);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copied = true;
        setTimeout(() => {
          this.copied = false;
        }, 1200);
      }).catch(() => {
      });
    } catch (_e) {
    }
  }

  build() {
    Column({ space: 3 }) {
      if (this.lang.length > 0 || this.code.length > 0) {
        Row() {
          if (this.lang.length > 0) {
            Text(this.lang).fontSize('9fp').fontColor(this.theme.textHint)
              .layoutWeight(1)
          }
          Text(this.copied ? '已复制' : '复制').fontSize('10fp')
            .fontColor(this.copied ? this.theme.primary : this.theme.textHint)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(this.theme.surfaceElevated)
            .onClick(() => {
              this.doCopy();
            })
        }
        .width('100%')
      }
      Scroll() {
        Text() {
          ForEach(this.segs, (s: CodeSeg, idx: number) => {
            Span(s.text)
              .fontColor(s.color)
              .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
          }, (s: CodeSeg, idx: number) => idx + '_' + s.text.length + '_' + s.color)
        }
        .fontSize('12fp')
        .fontFamily('monospace')
        .fontColor(this.theme.textPrimary)
        .lineHeight(17)
      }
      .constraintSize({ maxHeight: 300 })
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)
    }
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(8)
    .backgroundColor(this.theme.background)
    .border({ width: 0.5, color: this.theme.divider })
  }
}

/** A6 Markdown 网络图片三态（对齐 Android MarkdownImage）：加载中占位 / 失败回退文本 / 成功出图。
 *  Image 必须常驻挂载才会发起网络加载（卸掉就死锁），故 Stack 常驻 + 占位层覆盖切态；
 *  成功态 FillWidth 语义（宽撑满 + 320 封顶）+ alt 说明；ArkUI Image 自带内存缓存。 */
@Component
struct MdImage {
  @Prop url: string = '';
  @Prop alt: string = '';
  @Prop theme: ThemeColors = new ThemeColors();
  @State loadState: string = 'loading'; // loading|ok|fail

  build() {
    Column({ space: 2 }) {
      if (this.loadState === 'fail') {
        Text('🖼 图片加载失败 · ' + this.url)
          .fontSize('11fp')
          .fontColor(this.theme.textHint)
      } else {
        Stack() {
          Image(this.url)
            .objectFit(ImageFit.Cover)
            .width('100%')
            .constraintSize({ maxHeight: 320 })
            .borderRadius(8)
            .backgroundColor(this.theme.surface)
            .interpolation(ImageInterpolation.High)
            .onComplete(() => {
              this.loadState = 'ok';
            })
            .onError(() => {
              this.loadState = 'fail';
            })
          if (this.loadState === 'loading') {
            Column() {
              Text('🖼 加载中…')
                .fontSize('11fp')
                .fontColor(this.theme.textHint)
            }
            .width('100%')
            .height(120)
            .borderRadius(8)
            .backgroundColor(this.theme.surface)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .alignContent(Alignment.Center)
      }
      if (this.alt.length > 0 && this.loadState === 'ok') {
        Text(this.alt)
          .fontSize('10fp')
          .fontColor(this.theme.textHint)
      }
    }
    .alignItems(HorizontalAlign.Start)
  }
}

/** Markdown 渲染入口（对齐 Android MarkdownBody） */
@Component
export struct MarkdownView {
  @Prop @Watch('onTextChange') text: string = '';
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop fontSize: number = 15;
  @State blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.blocks = parseBlocks(this.text, this.theme);
  }

  onTextChange(): void {
    this.blocks = parseBlocks(this.text, this.theme);
  }

  build() {
    Column({ space: 7 }) {
      ForEach(this.blocks, (b: MdBlock, idx: number) => {
        Column() {
          this.blockBody(b)
        }
        .alignItems(HorizontalAlign.Start)
      }, (b: MdBlock, idx: number) => idx + '_' + b.kind + '_' + b.plain.length)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  blockBody(b: MdBlock) {
    if (b.kind === 'code') {
      MdCode({ code: b.code, lang: b.lang, theme: this.theme })
    } else if (b.kind === 'heading') {
      MdRich({
        src: b.plain,
        fontSize: b.level === 1 ? 19 : (b.level === 2 ? 17 : (b.level === 3 ? 15.5 : 14.5)),
        color: this.theme.textPrimary, bold: true, theme: this.theme
      })
    } else if (b.kind === 'list') {
      Row({ space: 6 }) {
        Text(b.marker)
          .fontSize('14fp')
          .fontColor(this.theme.primary)
        MdRich({ src: b.plain, fontSize: this.fontSize, color: this.theme.textPrimary, theme: this.theme })
          .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .padding({ left: b.indent * 14 })
    } else if (b.kind === 'quote') {
      Column({ space: 2 }) {
        ForEach(b.plain.split('\n'), (line: string, li: number) => {
          MdRich({ src: line, fontSize: this.fontSize, color: this.theme.textSecondary, theme: this.theme })
        }, (line: string, li: number) => li + '_' + line)
      }
      .alignItems(HorizontalAlign.Start)
      .border({ width: { left: 2 }, color: this.theme.accent })
      .padding({ left: 8 })
    } else if (b.kind === 'table') {
      MdTable({ cellsJson: JSON.stringify(b.cells), alignsJson: JSON.stringify(b.aligns), theme: this.theme })
    } else if (b.kind === 'hr') {
      Divider().strokeWidth(0.5).color(this.theme.divider).width(160)
    } else if (b.kind === 'image') {
      MdImage({ url: b.url, alt: b.alt, theme: this.theme })
    } else {
      MdRich({ src: b.plain, fontSize: this.fontSize, color: this.theme.textPrimary, theme: this.theme })
    }
  }
}
