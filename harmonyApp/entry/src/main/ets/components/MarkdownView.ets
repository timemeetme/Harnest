import { ThemeColors } from '../theme/Theme';
import measure from '@ohos.measure';

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
      Column({ space: 3 }) {
        if (b.lang.length > 0) {
          Text(b.lang).fontSize('9fp').fontColor(this.theme.textHint)
        }
        Scroll() {
          Text(b.code)
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
      Column({ space: 3 }) {
        Image(b.url)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .constraintSize({ maxHeight: 260 })
        if (b.alt.length > 0) {
          Text(b.alt).fontSize('10fp').fontColor(this.theme.textHint)
        }
      }
    } else {
      MdRich({ src: b.plain, fontSize: this.fontSize, color: this.theme.textPrimary, theme: this.theme })
    }
  }
}
