import SwiftUI

/// k6 手写 Markdown 渲染（零外部依赖 — 纯 SwiftUI）。
/// 对齐 androidApp Markdown.kt：标题 / 加粗 / 斜体 / 删除线 / 行内码 /
/// 围栏码块（轻量语法高亮）/ 列表（无序/有序/任务）/ 链接 / 分割线 /
/// 管道表格 / 引用 / KaTeX（$...$/$$...$$ 降级为等宽斜体排版 — 无原生 math 布局）。
/// 网络图片走 AsyncImage（URLSession 系统缓存，等价 Android okhttp+LruCache）。

// MARK: - 模型

private enum MdBlock {
    case heading(level: Int, spans: [MdSpan])
    case para(spans: [MdSpan])
    case code(lang: String, code: String)
    case quote(spans: [MdSpan])
    case ul(items: [(String, [MdSpan])])   // marker + spans
    case ol(items: [(Int, [MdSpan])])      // number + spans
    case hr
    case table(header: [[MdSpan]], rows: [[[MdSpan]]], aligns: [TextAlignment])
}

private indirect enum MdSpan {
    case text(String)
    case bold([MdSpan])
    case italic([MdSpan])
    case strike([MdSpan])
    case code(String)
    case link([MdSpan], url: String)
    case image(alt: String, url: String)
    case math(tex: String, display: Bool)
    case mention(String) // k8 产物/资源 @提及高亮
}

/// 单元格纯文本（表格列宽预量用）：递归摊平 MdSpan 树
private func spanText(_ spans: [MdSpan]) -> String {
    spans.map { s -> String in
        switch s {
        case .text(let t): return t
        case .bold(let sub), .italic(let sub), .strike(let sub), .link(let sub, _):
            return spanText(sub)
        case .code(let c): return c
        case .image(let alt, _): return alt
        case .math(let tex, _): return tex
        case .mention(let n): return "@" + n
        }
    }.joined()
}

// MARK: - 解析器（逐行/逐字符 — 与 Android 蓝本同构）

private enum MdParser {

    static func parseBlocks(_ text: String) -> [MdBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MdBlock] = []
        var i = 0
        var para: [String] = []
        var ul: [(String, [MdSpan])] = []
        var ol: [(Int, [MdSpan])] = []

        func flushPara() {
            if !para.isEmpty {
                let joined = para.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { blocks.append(.para(spans: parseInline(joined))) }
                para = []
            }
        }
        func flushLists() {
            if !ul.isEmpty { blocks.append(.ul(items: ul)); ul = [] }
            if !ol.isEmpty { blocks.append(.ol(items: ol)); ol = [] }
        }
        func flushAll() { flushPara(); flushLists() }

        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)

            // 围栏码块：消费到闭合围栏（无闭合则吃到结尾）
            if isFenceLine(t) {
                flushAll()
                let lang = fenceLang(t)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !isFenceLine(lines[i].trimmingCharacters(in: .whitespaces)) {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // 跳过闭合围栏
                blocks.append(.code(lang: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            if t.isEmpty {
                flushAll()
                i += 1
                continue
            }

            // 管道表格：表头行 + 分隔行（---|---）→ 吃到非表格行
            if t.hasPrefix("|") && t.hasSuffix("|") && t.count >= 2,
               i + 1 < lines.count, isTableDivider(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushAll()
                let aligns = tableAligns(lines[i + 1])
                let header = tableCells(t).map { parseInline($0) }
                var rows: [[[MdSpan]]] = []
                i += 2
                while i < lines.count {
                    let rt = lines[i].trimmingCharacters(in: .whitespaces)
                    if rt.hasPrefix("|") && rt.hasSuffix("|") && rt.count >= 2 {
                        rows.append(tableCells(rt).map { parseInline($0) })
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.table(header: header, rows: rows, aligns: aligns))
                continue
            }

            if t == "---" || t == "***" || t == "___" {
                flushAll()
                blocks.append(.hr)
                i += 1
                continue
            }

            if let (level, content) = matchHeading(t) {
                flushAll()
                blocks.append(.heading(level: level, spans: parseInline(content)))
                i += 1
                continue
            }

            if t.hasPrefix(">") {
                flushAll()
                let inner = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(spans: parseInline(inner)))
                i += 1
                continue
            }

            // 行级展示数学：整行 $$...$$ → 居中大字等宽行
            if t.hasPrefix("$$") && t.hasSuffix("$$") && t.count > 4 {
                flushAll()
                let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.para(spans: [.math(tex: inner, display: true)]))
                i += 1
                continue
            }

            if let (marker, spans) = matchUlItem(t) {
                flushPara()
                ul.append((marker, spans))
                i += 1
                continue
            }

            if let (num, spans) = matchOlItem(t) {
                flushPara()
                ol.append((num, spans))
                i += 1
                continue
            }

            flushLists()
            para.append(t)
            i += 1
        }
        flushAll()
        return blocks
    }

    static func parseInline(_ text: String) -> [MdSpan] {
        let chars = Array(text)
        var out: [MdSpan] = []
        var buf = ""
        var i = 0
        let escapable: Set<Character> = [
            "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")",
            "#", "+", "-", ".", "!", "|", ">", "~", "$",
        ]

        func flush() {
            if !buf.isEmpty {
                out.append(.text(buf))
                buf = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            // 反斜杠转义：\x → 字面 x
            if c == "\\", i + 1 < chars.count, escapable.contains(chars[i + 1]) {
                buf.append(chars[i + 1])
                i += 2
                continue
            }

            // **粗体**
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                if let e = indexOf(chars, "**", from: i + 2), e > i + 2 {
                    flush()
                    out.append(.bold(parseInline(String(chars[(i + 2)..<e]))))
                    i = e + 2
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // ~~删除线~~
            if c == "~", i + 1 < chars.count, chars[i + 1] == "~" {
                if let e = indexOf(chars, "~~", from: i + 2), e > i + 2 {
                    flush()
                    out.append(.strike(parseInline(String(chars[(i + 2)..<e]))))
                    i = e + 2
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // $$...$$ 行内展示数学
            if c == "$", i + 1 < chars.count, chars[i + 1] == "$" {
                if let e = indexOf(chars, "$$", from: i + 2), e > i + 2 {
                    flush()
                    let tex = String(chars[(i + 2)..<e]).trimmingCharacters(in: .whitespaces)
                    out.append(.math(tex: tex, display: false))
                    i = e + 2
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // *斜体*
            if c == "*" {
                if let e = indexOf(chars, "*", from: i + 1), e > i + 1 {
                    flush()
                    out.append(.italic(parseInline(String(chars[(i + 1)..<e]))))
                    i = e + 1
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // `行内码`
            if c == "`" {
                if let e = indexOf(chars, "`", from: i + 1), e > i + 1 {
                    flush()
                    out.append(.code(String(chars[(i + 1)..<e])))
                    i = e + 1
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // $行内数学$
            if c == "$" {
                if let e = indexOf(chars, "$", from: i + 1), e > i + 1 {
                    flush()
                    let tex = String(chars[(i + 1)..<e]).trimmingCharacters(in: .whitespaces)
                    out.append(.math(tex: tex, display: false))
                    i = e + 1
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // ![alt](url)
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[" {
                if let closeB = indexOf(chars, "]", from: i + 2),
                   closeB > i + 1, closeB + 1 < chars.count, chars[closeB + 1] == "(" {
                    if let closeP = indexOf(chars, ")", from: closeB + 2), closeP > closeB {
                        flush()
                        let alt = String(chars[(i + 2)..<closeB])
                        let url = String(chars[(closeB + 2)..<closeP]).trimmingCharacters(in: .whitespaces)
                        out.append(.image(alt: alt, url: url))
                        i = closeP + 1
                        continue
                    }
                }
                buf.append(c); i += 1
                continue
            }

            // @mention：@ 前不能是字母数字（排除邮箱）；尾部的 . - / 归还正文
            if c == "@" {
                let prevOk = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
                var j = i + 1
                while j < chars.count {
                    let ch = chars[j]
                    if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." || ch == "/" || isCjk(ch) {
                        j += 1
                    } else {
                        break
                    }
                }
                let raw = String(chars[(i + 1)..<j])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".-/"))
                if prevOk && raw.count >= 2 {
                    flush()
                    out.append(.mention(raw))
                    i = i + 1 + raw.count
                    continue
                }
                buf.append(c); i += 1
                continue
            }

            // [label](url)
            if c == "[" {
                if let closeB = indexOf(chars, "]", from: i + 1),
                   closeB > i, closeB + 1 < chars.count, chars[closeB + 1] == "(" {
                    if let closeP = indexOf(chars, ")", from: closeB + 2), closeP > closeB {
                        flush()
                        let label = String(chars[(i + 1)..<closeB])
                        let url = String(chars[(closeB + 2)..<closeP]).trimmingCharacters(in: .whitespaces)
                        out.append(.link(parseInline(label), url: url))
                        i = closeP + 1
                        continue
                    }
                }
                buf.append(c); i += 1
                continue
            }

            buf.append(c)
            i += 1
        }
        flush()
        return out
    }

    // ── 行级匹配辅助 ─────────────────────────────────────────

    private static func isFenceLine(_ t: String) -> Bool {
        t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    private static func fenceLang(_ t: String) -> String {
        String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableDivider(_ t: String) -> Bool {
        guard t.hasPrefix("|") && t.hasSuffix("|") && t.count >= 2 else { return false }
        return t.contains("-") && t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        let esc = line.replacingOccurrences(of: "\\|", with: "\u{00A6}PIPE\u{00A6}")
            .trimmingCharacters(in: .whitespaces)
        var body = esc
        if body.hasPrefix("|") { body = String(body.dropFirst()) }
        if body.hasSuffix("|") { body = String(body.dropLast()) }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{00A6}PIPE\u{00A6}", with: "|")
        }
    }

    /// 表格对齐解析（GFM）：:---: 居中 / ---: 右 / 其余左
    private static func tableAligns(_ divider: String) -> [TextAlignment] {
        tableCells(divider).map { seg in
            let s = seg.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(":") && s.hasSuffix(":") && s.count > 1 { return .center }
            if s.hasSuffix(":") { return .trailing }
            return .leading
        }
    }

    private static func matchHeading(_ t: String) -> (Int, String)? {
        let chars = Array(t)
        var level = 0
        while level < chars.count && chars[level] == "#" && level < 6 { level += 1 }
        guard level >= 1, level <= 6, level < chars.count, chars[level] == " " else { return nil }
        let content = String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces)
        return (level, content)
    }

    private static func matchUlItem(_ t: String) -> (String, [MdSpan])? {
        let chars = Array(t)
        guard let markerChar = chars.first, markerChar == "*" || markerChar == "-" || markerChar == "+",
              chars.count >= 3, chars[1] == " " else { return nil }
        var body = String(chars[2...]).trimmingCharacters(in: .whitespaces)
        var marker = "•"
        if body.hasPrefix("[ ]") || body.hasPrefix("[x]") || body.hasPrefix("[X]") {
            let bodyChars = Array(body)
            marker = bodyChars[1] == " " ? "☐" : "☑"
            body = String(bodyChars[3...]).trimmingCharacters(in: .whitespaces)
        }
        return (marker, parseInline(body))
    }

    private static func matchOlItem(_ t: String) -> (Int, [MdSpan])? {
        let chars = Array(t)
        var numEnd = 0
        while numEnd < chars.count && chars[numEnd].isNumber { numEnd += 1 }
        guard numEnd >= 1, numEnd + 1 < chars.count,
              chars[numEnd] == "." || chars[numEnd] == ")",
              chars[numEnd + 1] == " " else { return nil }
        let num = Int(String(chars[0..<numEnd])) ?? 1
        let body = String(chars[(numEnd + 2)...]).trimmingCharacters(in: .whitespaces)
        return (num, parseInline(body))
    }

    private static func isCjk(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x4E00 && scalar.value <= 0x9FA5
    }

    /// 字符数组中从 from 起查找子串，返回起始下标（找不到返回 nil）。
    private static func indexOf(_ chars: [Character], _ needle: String, from: Int) -> Int? {
        let n = Array(needle)
        guard !n.isEmpty, from >= 0, from <= chars.count else { return nil }
        var k = max(from, 0)
        while k + n.count <= chars.count {
            if chars[k..<(k + n.count)].elementsEqual(n) { return k }
            k += 1
        }
        return nil
    }
}

// MARK: - 行内渲染（SwiftUI Text 拼接）

private enum MdInline {

    /// 递归渲染 span 树为单个 Text（叶子各自带字体/颜色）。
    static func render(_ spans: [MdSpan], size: CGFloat, color: Color) -> Text {
        var result: Text? = nil
        for s in spans {
            let piece = renderSpan(s, size: size, color: color)
            result = result == nil ? piece : result! + piece
        }
        return result ?? Text("")
    }

    private static func renderSpan(_ s: MdSpan, size: CGFloat, color: Color) -> Text {
        switch s {
        case .text(let t):
            return Text(t)
                .font(.system(size: size))
                .foregroundColor(color)
        case .bold(let inner):
            return render(inner, size: size, color: color).bold()
        case .italic(let inner):
            return render(inner, size: size, color: color).italic()
        case .strike(let inner):
            return render(inner, size: size, color: color).strikethrough()
        case .code(let code):
            return Text(code)
                .font(.system(size: size * 0.88, design: .monospaced))
                .foregroundColor(Theme.accent)
        case .link(let inner, let url):
            var attr = AttributedString(renderPlain(inner))
            attr.font = .system(size: size)
            attr.foregroundColor = Theme.primary
            attr.underlineStyle = .single
            if let u = URL(string: url) { attr.link = u }
            return Text(attr)
        case .image(let alt, let url):
            let label = alt.isEmpty ? url : alt
            return Text("[图: \(label)]")
                .font(.system(size: size))
                .foregroundColor(color)
        case .math(let tex, _):
            return Text(tex)
                .font(.system(size: size * 0.92, design: .monospaced))
                .italic()
                .foregroundColor(Theme.accent)
        case .mention(let name):
            return Text("@\(name)")
                .font(.system(size: size * 0.9, design: .monospaced))
                .foregroundColor(Theme.primary)
        }
    }

    /// 链接标签降级取纯文本（AttributedString 无法由 SwiftUI Text 递归构造）。
    private static func renderPlain(_ spans: [MdSpan]) -> String {
        var out = ""
        for s in spans {
            switch s {
            case .text(let t): out += t
            case .bold(let inner), .italic(let inner), .strike(let inner):
                out += renderPlain(inner)
            case .code(let code): out += code
            case .link(let inner, _): out += renderPlain(inner)
            case .image(let alt, _): out += alt
            case .math(let tex, _): out += tex
            case .mention(let name): out += "@\(name)"
            }
        }
        return out
    }
}

// MARK: - 码块轻量语法高亮

private enum MdHighlight {

    static let tokenRe = try! NSRegularExpression(
        pattern: #"//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|\b\d+(?:\.\d+)?\b"#
    )

    static func keywords(lang: String) -> Set<String> {
        switch lang.lowercased() {
        case "kotlin", "kt":
            return ["fun", "val", "var", "class", "object", "interface", "return", "if", "else", "when",
                    "for", "while", "import", "package", "private", "public", "internal", "data", "sealed",
                    "suspend", "companion", "override", "null", "true", "false", "this", "is", "in", "as",
                    "try", "catch", "finally", "throw", "init", "constructor", "by", "lazy"]
        case "java":
            return ["class", "interface", "public", "private", "protected", "static", "final", "void",
                    "return", "if", "else", "for", "while", "new", "import", "package", "extends",
                    "implements", "null", "true", "false", "this", "try", "catch", "finally", "throw",
                    "throws", "int", "long", "double", "boolean", "char", "byte", "short", "float"]
        case "ts", "typescript", "js", "javascript":
            return ["function", "const", "let", "var", "return", "if", "else", "for", "while", "class",
                    "interface", "type", "import", "export", "from", "async", "await", "new", "null",
                    "undefined", "true", "false", "this", "try", "catch", "finally", "throw", "extends",
                    "implements", "public", "private", "readonly", "enum", "switch", "case", "break",
                    "default", "of", "in"]
        case "py", "python":
            return ["def", "class", "return", "if", "elif", "else", "for", "while", "import", "from",
                    "as", "pass", "None", "True", "False", "try", "except", "finally", "raise", "with",
                    "lambda", "yield", "global", "nonlocal", "in", "is", "and", "or", "not", "async", "await"]
        case "json":
            return []
        case "bash", "sh", "shell", "zsh":
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                    "in", "function", "return", "local", "export", "echo", "cd", "ls", "grep", "cat"]
        default:
            return ["fun", "val", "var", "class", "return", "if", "else", "for", "while", "import",
                    "function", "const", "let", "def", "null", "true", "false", "this"]
        }
    }

    /// 词法着色 → 单个 Text（注释灰斜体 / 字符串绿 / 数字黄 / 关键词青 / 其余正文色）。
    static func highlight(_ code: String, lang: String) -> Text {
        let kws = keywords(lang: lang)
        let ns = code as NSString
        var result: Text? = nil
        var last = 0

        func append(_ piece: Text) {
            result = result == nil ? piece : result! + piece
        }
        func appendPlain<S: StringProtocol>(_ seg: S) {
            if seg.isEmpty { return }
            if kws.isEmpty {
                append(Text(String(seg)).foregroundColor(Theme.textPrimary))
                return
            }
            var word = ""
            func flushWord() {
                if word.isEmpty { return }
                if kws.contains(word) {
                    append(Text(word).foregroundColor(Theme.accent))
                } else {
                    append(Text(word).foregroundColor(Theme.textPrimary))
                }
                word = ""
            }
            for ch in seg {
                if ch.isLetter || ch == "_" {
                    word.append(ch)
                } else {
                    flushWord()
                    append(Text(String(ch)).foregroundColor(Theme.textPrimary))
                }
            }
            flushWord()
        }

        let matches = tokenRe.matches(in: code, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let r = m.range
            if r.location > last {
                appendPlain(ns.substring(with: NSRange(location: last, length: r.location - last)))
            }
            let tok = ns.substring(with: r)
            let tokText = Text(tok)
            if tok.hasPrefix("//") || tok.hasPrefix("/*") || tok.hasPrefix("#") {
                append(tokText.foregroundColor(Theme.textHint).italic())
            } else if tok.hasPrefix("\"") || tok.hasPrefix("'") {
                append(tokText.foregroundColor(Theme.success))
            } else if let first = tok.first, first.isNumber {
                append(tokText.foregroundColor(Theme.warning))
            } else {
                append(tokText.foregroundColor(Theme.textPrimary))
            }
            last = r.location + r.length
        }
        if last < ns.length {
            appendPlain(code[code.index(code.startIndex, offsetBy: last)...])
        }
        return result ?? Text("")
    }
}

// MARK: - 块级视图

/// Markdown 正文渲染入口 — AssistantBubble 内替换原 plain Text。
struct MarkdownBody: View {

    let text: String
    var isError: Bool = false

    private var contentColor: Color { isError ? Theme.error : Theme.textPrimary }

    var body: some View {
        let blocks = MdParser.parseBlocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                blockView(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ b: MdBlock) -> some View {
        switch b {
        case .heading(let level, let spans):
            MdText(spans: spans, size: headingSize(level), color: contentColor)
        case .para(let spans):
            paraView(spans)
        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)
        case .quote(let spans):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 3, height: 20)
                MdText(spans: spans, size: 14, color: Theme.textSecondary)
            }
        case .ul(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.0)
                            .font(.system(size: 15))
                            .foregroundColor(contentColor)
                        MdText(spans: item.1, size: 15, color: contentColor)
                    }
                }
            }
        case .ol(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.0).")
                            .font(.system(size: 15))
                            .foregroundColor(contentColor)
                        MdText(spans: item.1, size: 15, color: contentColor)
                    }
                }
            }
        case .hr:
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        case .table(let header, let rows, let aligns):
            MdTableView(header: header, rows: rows, aligns: aligns)
        }
    }

    @ViewBuilder
    private func paraView(_ spans: [MdSpan]) -> some View {
        // 行级展示数学：整段居中放大
        if spans.count == 1, case .math(let tex, true) = spans[0] {
            HStack {
                Spacer(minLength: 0)
                Text(tex)
                    .font(.system(size: 15, design: .monospaced))
                    .italic()
                    .foregroundColor(Theme.accent)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        } else if spans.contains(where: { if case .image = $0 { return true } else { return false } }) {
            // k8 接线：段落内图片拆出独立行渲染，其余 span 走文本
            let images = spans.filter { if case .image = $0 { return true } else { return false } }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, span in
                    if case .image(let alt, let url) = span {
                        MarkdownImage(url: url, alt: alt)
                    }
                }
                let rest = spans.filter { if case .image = $0 { return false } else { return true } }
                if !rest.isEmpty {
                    MdText(spans: rest, size: 15, color: contentColor)
                }
            }
        } else {
            MdText(spans: spans, size: 15, color: contentColor)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15.5
        default: return 15
        }
    }
}

// MARK: - 行内文本

private struct MdText: View {
    let spans: [MdSpan]
    let size: CGFloat
    let color: Color

    var body: some View {
        MdInline.render(spans, size: size, color: color)
            .textSelection(.enabled)
    }
}

// MARK: - 码块

private struct CodeBlockView: View {
    let lang: String
    let code: String

    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            MdHighlight.highlight(code, lang: lang)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeOut(duration: 0.3)) { copied = false }
                    }
                } label: {
                    Text(copied ? "已复制" : "复制")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? Theme.accent : Theme.textHint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceElevated.opacity(0.9))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制代码")
                if !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textHint)
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 10)
        }
    }
}

// MARK: - 表格

/// 表格（GFM/GitHub 布局语义，三端一致）：全表共享列宽（预量每列最长内容）→ 列列对齐；
/// auto 列宽贴合内容，封顶 220 防长文本拉爆（超宽换行）；总宽超容器横向滚动兜底。
private struct MdTableView: View {
    let header: [[MdSpan]]
    let rows: [[[MdSpan]]]
    let aligns: [TextAlignment]

    private var cols: Int { max(header.count, 1) }

    /// 每列宽度 = 该列最长单元格内容宽（UIFont 预量），下限 56 / 封顶 220
    private var widths: [CGFloat] {
        let font = UIFont.systemFont(ofSize: 12)
        let all = [header] + rows
        return (0..<cols).map { ci in
            var w: CGFloat = 56
            for row in all {
                guard ci < row.count else { continue }
                let size = (spanText(row[ci]) as NSString).boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).size
                w = max(w, ceil(size.width) + 20)
            }
            return min(w, 220)
        }
    }

    var body: some View {
        let w = widths
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.offset) { ci, cell in
                        cellView(cell, width: w[ci], align: aligns.count > ci ? aligns[ci] : .leading)
                            .background(Theme.surfaceElevated)
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<cols, id: \.self) { ci in
                            cellView(ci < row.count ? row[ci] : [], width: w[ci], align: aligns.count > ci ? aligns[ci] : .leading)
                        }
                    }
                    Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func cellView(_ spans: [MdSpan], width: CGFloat, align: TextAlignment) -> some View {
        let frameAlign: Alignment = align == .center ? .center : (align == .trailing ? .trailing : .leading)
        return MdText(spans: spans, size: 12, color: Theme.textPrimary)
            .multilineTextAlignment(align)
            .frame(width: width, alignment: frameAlign)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

// MARK: - 网络图片

/// Markdown `![alt](url)` 渲染 — AsyncImage 三态（加载中占位 / 失败回退文本 / 成功圆角图）。
struct MarkdownImage: View {
    let url: String
    let alt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        Text("🖼 图片加载失败 · \(url)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textHint)
                    default:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surface)
                            .frame(height: 120)
                            .overlay(
                                Text("🖼 加载中…")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textHint)
                            )
                    }
                }
            } else {
                Text("🖼 图片加载失败 · \(url)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textHint)
            }
            if !alt.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(alt)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textHint)
            }
        }
    }
}
