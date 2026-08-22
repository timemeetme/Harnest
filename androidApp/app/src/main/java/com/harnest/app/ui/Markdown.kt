package com.harnest.app.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * k6 手写 Markdown 渲染（零外部依赖 — Compose BOM 内手搓）。
 * 支持：标题 / 加粗 / 斜体 / 删除线 / 行内码 / 围栏码块（轻量语法高亮）/ 列表
 * （无序/有序/任务）/ 链接 / 分割线 / 管道表格 / 引用 / KaTeX（$...$/$$...$$
 * 降级为等宽斜体排版 — 无原生 math 布局）。网络图片见 MarkdownImages.kt。
 */

private sealed class MdBlock {
    data class Heading(val level: Int, val spans: List<MdSpan>) : MdBlock()
    data class Para(val spans: List<MdSpan>) : MdBlock()
    data class Code(val lang: String, val code: String) : MdBlock()
    data class Quote(val spans: List<MdSpan>) : MdBlock()
    data class Ul(val items: List<Pair<String, List<MdSpan>>>) : MdBlock() // marker + spans
    data class Ol(val items: List<Pair<Int, List<MdSpan>>>) : MdBlock() // number + spans
    object Hr : MdBlock()
    data class Table(
        val header: List<List<MdSpan>>,
        val rows: List<List<List<MdSpan>>>,
        val aligns: List<TextAlign> = emptyList(),
    ) : MdBlock()
}

private sealed class MdSpan {
    data class TextSpan(val text: String) : MdSpan()
    data class Bold(val spans: List<MdSpan>) : MdSpan()
    data class Italic(val spans: List<MdSpan>) : MdSpan()
    data class Strike(val spans: List<MdSpan>) : MdSpan()
    data class CodeSpan(val code: String) : MdSpan()
    data class Link(val spans: List<MdSpan>, val url: String) : MdSpan()
    data class ImageSpan(val alt: String, val url: String) : MdSpan()
    data class Math(val tex: String, val display: Boolean) : MdSpan()
    data class Mention(val name: String) : MdSpan() // k8 产物/资源 @提及高亮
}

private val CODE_TOKEN_RE =
    Regex("""(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|\b\d+(?:\.\d+)?\b)""")

private fun isFenceLine(t: String): Boolean = t.startsWith("```") || t.startsWith("~~~")

private fun fenceLang(t: String): String = t.drop(3).trim()

private fun isTableDivider(t: String): Boolean =
    t.startsWith("|") && t.endsWith("|") && t.all { it == '|' || it == '-' || it == ':' || it == ' ' } && t.contains('-')

private fun splitTableRow(t: String): List<String> =
    t.trim().removePrefix("|").removeSuffix("|").split("|").map { it.trim() }

private fun stripTableEscapes(s: String): String = s.replace("\\|", "¦PIPE¦")

private fun restoreTableEscapes(s: String): String = s.replace("¦PIPE¦", "|")

private fun tableCells(line: String): List<String> {
    val esc = stripTableEscapes(line)
    return esc.trim().removePrefix("|").removeSuffix("|").split("|").map { restoreTableEscapes(it.trim()) }
}

/** 单元格纯文本（列宽预量用）：递归摊平 MdSpan 树 */
private fun spanText(spans: List<MdSpan>): String = spans.joinToString("") { s ->
    when (s) {
        is MdSpan.TextSpan -> s.text
        is MdSpan.Bold -> spanText(s.spans)
        is MdSpan.Italic -> spanText(s.spans)
        is MdSpan.Strike -> spanText(s.spans)
        is MdSpan.CodeSpan -> s.code
        is MdSpan.Link -> spanText(s.spans)
        is MdSpan.ImageSpan -> s.alt
        is MdSpan.Math -> s.tex
        is MdSpan.Mention -> "@${s.name}"
    }
}

/** 表格对齐解析（GFM）：:---: 居中 / ---: 右 / 其余左 */
private fun tableAligns(divider: String): List<TextAlign> =
    splitTableRow(divider.trim()).map { seg ->
        val s = seg.trim()
        when {
            s.startsWith(":") && s.endsWith(":") && s.length > 1 -> TextAlign.Center
            s.endsWith(":") -> TextAlign.End
            else -> TextAlign.Start
        }
    }

private fun parseBlocks(text: String): List<MdBlock> {
    val lines = text.replace("\r\n", "\n").split("\n")
    val blocks = ArrayList<MdBlock>()
    var i = 0
    var para = StringBuilder()
    var paraImages = ArrayList<Pair<String, String>>() // k6：段落内图片（alt,url）按出现序
    var ul = ArrayList<Pair<String, List<MdSpan>>>()
    var ol = ArrayList<Pair<Int, List<MdSpan>>>()

    fun flushPara() {
        if (para.isNotEmpty()) {
            val joined = para.toString().replace("\n", " ").trim()
            if (joined.isNotEmpty()) blocks.add(MdBlock.Para(parseInline(joined)))
            para = StringBuilder()
        }
        if (paraImages.isNotEmpty()) {
            for ((alt, url) in paraImages) {
                blocks.add(MdBlock.Para(listOf(MdSpan.ImageSpan(alt, url))))
            }
            paraImages = ArrayList()
        }
    }

    fun flushLists() {
        if (ul.isNotEmpty()) {
            blocks.add(MdBlock.Ul(ArrayList(ul)))
            ul = ArrayList()
        }
        if (ol.isNotEmpty()) {
            blocks.add(MdBlock.Ol(ArrayList(ol)))
            ol = ArrayList()
        }
    }

    fun flushAll() {
        flushPara()
        flushLists()
    }

    while (i < lines.size) {
        val raw = lines[i]
        val t = raw.trim()

        // 围栏码块：消费到闭合围栏（无闭合则吃到结尾）
        if (isFenceLine(t)) {
            flushAll()
            val lang = fenceLang(t)
            val sb = StringBuilder()
            i++
            while (i < lines.size && !isFenceLine(lines[i].trim())) {
                if (sb.isNotEmpty()) sb.append('\n')
                sb.append(lines[i])
                i++
            }
            if (i < lines.size) i++ // 跳过闭合围栏
            blocks.add(MdBlock.Code(lang, sb.toString()))
            continue
        }

        if (t.isEmpty()) {
            flushAll()
            i++
            continue
        }

        // 管道表格：表头行 + 分隔行（---|---）→ 吃到非表格行
        if (t.startsWith("|") && t.endsWith("|") && i + 1 < lines.size && isTableDivider(lines[i + 1].trim())) {
            flushAll()
            val aligns = tableAligns(lines[i + 1])
            val header = tableCells(t).map { parseInline(it) }
            val rows = ArrayList<List<List<MdSpan>>>()
            i += 2
            while (i < lines.size) {
                val rt = lines[i].trim()
                if (rt.startsWith("|") && rt.endsWith("|")) {
                    rows.add(tableCells(rt).map { parseInline(it) })
                    i++
                } else break
            }
            blocks.add(MdBlock.Table(header, rows, aligns))
            continue
        }

        if (t == "---" || t == "***" || t == "___") {
            flushAll()
            blocks.add(MdBlock.Hr)
            i++
            continue
        }

        val h = Regex("^(#{1,6})\\s+(.*)$").find(t)
        if (h != null) {
            flushAll()
            blocks.add(MdBlock.Heading(h.groupValues[1].length, parseInline(h.groupValues[2].trim())))
            i++
            continue
        }

        if (t.startsWith(">")) {
            flushAll()
            blocks.add(MdBlock.Quote(parseInline(t.removePrefix(">").trim())))
            i++
            continue
        }

        // 行级展示数学：整行 $$...$$ → 居中大字等宽行
        val dispMath = Regex("^\\$\\$(.+)\\$\\$$").find(t)
        if (dispMath != null) {
            flushAll()
            blocks.add(MdBlock.Para(listOf(MdSpan.Math(dispMath.groupValues[1].trim(), true))))
            i++
            continue
        }

        val um = Regex("^([*\\-+])\\s+(.*)$").find(t)
        if (um != null) {
            flushPara()
            var body = um.groupValues[2].trim()
            var marker = "•"
            if (body.startsWith("[ ]") || body.startsWith("[x]") || body.startsWith("[X]")) {
                marker = if (body[1] == ' ') "☐" else "☑"
                body = body.substring(3).trim()
            }
            ul.add(marker to parseInline(body))
            i++
            continue
        }

        val om = Regex("^(\\d+)[.)]\\s+(.*)$").find(t)
        if (om != null) {
            flushPara()
            ol.add((om.groupValues[1].toIntOrNull() ?: 1) to parseInline(om.groupValues[2].trim()))
            i++
            continue
        }

        flushLists()
        if (para.isNotEmpty()) para.append('\n')
        para.append(t)
        i++
    }
    flushAll()
    return blocks
}

private fun parseInline(text: String): List<MdSpan> {
    val out = ArrayList<MdSpan>()
    var i = 0
    val buf = StringBuilder()

    fun flush() {
        if (buf.isNotEmpty()) {
            out.add(MdSpan.TextSpan(buf.toString()))
            buf.clear()
        }
    }

    while (i < text.length) {
        if (text[i] == '\\' && i + 1 < text.length && "\\`*_{}[]()#+-.!|>~\$".indexOf(text[i + 1]) >= 0) {
            buf.append(text[i + 1])
            i += 2
            continue
        }
        when {
            text.startsWith("**", i) -> {
                val e = text.indexOf("**", i + 2)
                if (e > i + 2) {
                    flush()
                    out.add(MdSpan.Bold(parseInline(text.substring(i + 2, e))))
                    i = e + 2
                } else {
                    buf.append(text[i]); i++
                }
            }
            text.startsWith("~~", i) -> {
                val e = text.indexOf("~~", i + 2)
                if (e > i + 2) {
                    flush()
                    out.add(MdSpan.Strike(parseInline(text.substring(i + 2, e))))
                    i = e + 2
                } else {
                    buf.append(text[i]); i++
                }
            }
            text.startsWith("$$", i) -> {
                val e = text.indexOf("$$", i + 2)
                if (e > i + 2) {
                    flush()
                    out.add(MdSpan.Math(text.substring(i + 2, e).trim(), false))
                    i = e + 2
                } else {
                    buf.append(text[i]); i++
                }
            }
            text[i] == '*' -> {
                val e = text.indexOf('*', i + 1)
                if (e > i + 1) {
                    flush()
                    out.add(MdSpan.Italic(parseInline(text.substring(i + 1, e))))
                    i = e + 1
                } else {
                    buf.append(text[i]); i++
                }
            }
            text[i] == '`' -> {
                val e = text.indexOf('`', i + 1)
                if (e > i + 1) {
                    flush()
                    out.add(MdSpan.CodeSpan(text.substring(i + 1, e)))
                    i = e + 1
                } else {
                    buf.append(text[i]); i++
                }
            }
            text[i] == '$' -> {
                val e = text.indexOf('$', i + 1)
                if (e > i + 1) {
                    flush()
                    out.add(MdSpan.Math(text.substring(i + 1, e).trim(), false))
                    i = e + 1
                } else {
                    buf.append(text[i]); i++
                }
            }
            text.startsWith("![", i) -> {
                val closeB = text.indexOf(']', i + 2)
                if (closeB > i && closeB + 1 < text.length && text[closeB + 1] == '(') {
                    val closeP = text.indexOf(')', closeB + 2)
                    if (closeP > closeB) {
                        flush()
                        out.add(MdSpan.ImageSpan(text.substring(i + 2, closeB), text.substring(closeB + 2, closeP).trim()))
                        i = closeP + 1
                    } else {
                        buf.append(text[i]); i++
                    }
                } else {
                    buf.append(text[i]); i++
                }
            }
            text[i] == '@' -> {
                // @mention：@ 前不能是字母数字（排除邮箱）；尾部的 . - / 归还正文
                val prevOk = i == 0 || !text[i - 1].isLetterOrDigit()
                var j = i + 1
                while (j < text.length && (text[j].isLetterOrDigit() || text[j] in "_-./" ||
                        (text[j] >= '\u4e00' && text[j] <= '\u9fa5'))) j++
                val raw = text.substring(i + 1, j).trimEnd('.', '-', '/')
                if (prevOk && raw.length >= 2) {
                    flush()
                    out.add(MdSpan.Mention(raw))
                    i = i + 1 + raw.length
                } else {
                    buf.append(text[i]); i++
                }
            }
            text[i] == '[' -> {
                val closeB = text.indexOf(']', i + 1)
                if (closeB > i && closeB + 1 < text.length && text[closeB + 1] == '(') {
                    val closeP = text.indexOf(')', closeB + 2)
                    if (closeP > closeB) {
                        flush()
                        out.add(MdSpan.Link(parseInline(text.substring(i + 1, closeB)), text.substring(closeB + 2, closeP).trim()))
                        i = closeP + 1
                    } else {
                        buf.append(text[i]); i++
                    }
                } else {
                    buf.append(text[i]); i++
                }
            }
            else -> {
                buf.append(text[i])
                i++
            }
        }
    }
    flush()
    return out
}

@Composable
private fun renderSpans(spans: List<MdSpan>, c: HarnessColors, fontSize: TextUnit): AnnotatedString {
    val context = LocalContext.current
    return buildAnnotatedString {
        for (s in spans) {
            when (s) {
                is MdSpan.TextSpan -> append(s.text)
                is MdSpan.Bold -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(renderSpans(s.spans, c, fontSize)) }
                is MdSpan.Italic -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(renderSpans(s.spans, c, fontSize)) }
                is MdSpan.Strike -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(renderSpans(s.spans, c, fontSize)) }
                is MdSpan.CodeSpan -> withStyle(
                    SpanStyle(
                        fontFamily = FontFamily.Monospace,
                        fontSize = fontSize * 0.88,
                        background = c.surface,
                        color = c.accent,
                    )
                ) { append(s.code) }
                is MdSpan.Link -> {
                    pushStringAnnotation("url", s.url)
                    withStyle(SpanStyle(color = c.primary, textDecoration = TextDecoration.Underline)) {
                        append(renderSpans(s.spans, c, fontSize))
                    }
                    pop()
                }
                is MdSpan.ImageSpan -> append("[图: " + (s.alt.ifBlank { s.url }) + "]")
                is MdSpan.Mention -> withStyle(
                    SpanStyle(
                        fontFamily = FontFamily.Monospace,
                        fontSize = fontSize * 0.9,
                        color = c.primary,
                        background = c.surface,
                    )
                ) { append("@" + s.name) }
                is MdSpan.Math -> withStyle(
                    SpanStyle(
                        fontFamily = FontFamily.Monospace,
                        fontStyle = FontStyle.Italic,
                        color = c.accent,
                    )
                ) { append(s.tex) }
            }
        }
    }
}

@Composable
private fun MdText(
    spans: List<MdSpan>,
    fontSize: TextUnit,
    color: Color,
    modifier: Modifier = Modifier,
    textAlign: TextAlign? = null,
) {
    val c = harnessColors()
    val context = LocalContext.current
    val annotated = renderSpans(spans, c, fontSize)
    val hasLink = spans.any { it is MdSpan.Link }
    SelectionContainer(modifier) {
        if (hasLink) {
            Text(
                annotated,
                color = color,
                fontSize = fontSize,
                textAlign = textAlign ?: TextAlign.Unspecified,
                modifier = Modifier.clickable {
                    annotated.getStringAnnotations("url", 0, annotated.length).firstOrNull()?.let { a ->
                        try {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(a.item)))
                        } catch (_: Throwable) {
                        }
                    }
                },
            )
        } else {
            Text(annotated, color = color, fontSize = fontSize, textAlign = textAlign ?: TextAlign.Unspecified)
        }
    }
}

@Composable
private fun codeKeywords(lang: String): Set<String> = when (lang.lowercase()) {
    "kotlin", "kt" -> setOf(
        "fun", "val", "var", "class", "object", "interface", "return", "if", "else", "when",
        "for", "while", "import", "package", "private", "public", "internal", "data", "sealed",
        "suspend", "companion", "override", "null", "true", "false", "this", "is", "in", "as",
        "try", "catch", "finally", "throw", "init", "constructor", "by", "lazy",
    )
    "java" -> setOf(
        "class", "interface", "public", "private", "protected", "static", "final", "void",
        "return", "if", "else", "for", "while", "new", "import", "package", "extends",
        "implements", "null", "true", "false", "this", "try", "catch", "finally", "throw",
        "throws", "int", "long", "double", "boolean", "char", "byte", "short", "float",
    )
    "ts", "typescript", "js", "javascript" -> setOf(
        "function", "const", "let", "var", "return", "if", "else", "for", "while", "class",
        "interface", "type", "import", "export", "from", "async", "await", "new", "null",
        "undefined", "true", "false", "this", "try", "catch", "finally", "throw", "extends",
        "implements", "public", "private", "readonly", "enum", "switch", "case", "break",
        "default", "of", "in",
    )
    "py", "python" -> setOf(
        "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from",
        "as", "pass", "None", "True", "False", "try", "except", "finally", "raise", "with",
        "lambda", "yield", "global", "nonlocal", "in", "is", "and", "or", "not", "async", "await",
    )
    "json" -> emptySet()
    "bash", "sh", "shell", "zsh" -> setOf(
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
        "in", "function", "return", "local", "export", "echo", "cd", "ls", "grep", "cat",
    )
    else -> setOf(
        "fun", "val", "var", "class", "return", "if", "else", "for", "while", "import",
        "function", "const", "let", "def", "null", "true", "false", "this",
    )
}

@Composable
private fun highlightCode(code: String, lang: String, c: HarnessColors): AnnotatedString {
    val keywords = codeKeywords(lang)
    return buildAnnotatedString {
        var last = 0
        for (m in CODE_TOKEN_RE.findAll(code)) {
            if (m.range.first > last) appendPlainSegment(code.substring(last, m.range.first), keywords, c)
            val tok = m.value
            val color = when {
                tok.startsWith("//") || tok.startsWith("/*") || tok.startsWith("#") -> c.textHint
                tok.startsWith("\"") || tok.startsWith("'") -> c.success
                tok.first().isDigit() -> c.warning
                else -> c.textPrimary
            }
            withStyle(SpanStyle(color = color, fontStyle = if (color == c.textHint) FontStyle.Italic else null)) {
                append(tok)
            }
            last = m.range.last + 1
        }
        if (last < code.length) appendPlainSegment(code.substring(last), keywords, c)
    }
}

private fun AnnotatedString.Builder.appendPlainSegment(seg: String, keywords: Set<String>, c: HarnessColors) {
    if (keywords.isEmpty()) {
        append(seg)
        return
    }
    var i = 0
    while (i < seg.length) {
        if (seg[i].isLetter() || seg[i] == '_') {
            var j = i + 1
            while (j < seg.length && (seg[j].isLetterOrDigit() || seg[j] == '_')) j++
            val word = seg.substring(i, j)
            if (keywords.contains(word)) {
                withStyle(SpanStyle(color = c.accent)) { append(word) }
            } else {
                append(word)
            }
            i = j
        } else {
            append(seg[i])
            i++
        }
    }
}

@Composable
private fun CodeBlock(lang: String, code: String) {
    val c = harnessColors()
    val highlighted = highlightCode(code, lang, c)
    Box(
        Modifier
            .fillMaxWidth()
            .background(c.surface, RoundedCornerShape(8.dp)),
    ) {
        if (lang.isNotBlank()) {
            Text(
                lang,
                color = c.textHint,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.align(Alignment.TopEnd).padding(top = 6.dp, end = 10.dp),
            )
        }
        SelectionContainer {
            Text(
                highlighted,
                color = c.textPrimary,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }
    }
}

/**
 * 表格（GFM/GitHub 布局语义，三端一致）：
 *  - 全表共享列宽：TextMeasurer 预量每列最长单元格宽度，所有行同宽 → 列列对齐
 *  - auto 列宽：列宽贴合内容（等价 table-layout:auto），封顶 220dp 防长文本拉爆（超宽换行）
 *  - 总宽超容器时横向滚动兜底；对齐解析自 :--- / :---: / ---: 分隔行
 */
@Composable
private fun MdTable(header: List<List<MdSpan>>, rows: List<List<List<MdSpan>>>, aligns: List<TextAlign>) {
    val c = harnessColors()
    val cols = header.size.coerceAtLeast(1)
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val widths = remember(header, rows) {
        val style = TextStyle(fontSize = 12.sp)
        val all = listOf(header) + rows
        (0 until cols).map { ci ->
            var w = 56.dp
            for (row in all) {
                val cell = row.getOrNull(ci) ?: continue
                val m = measurer.measure(spanText(cell), style)
                val dp = with(density) { m.size.width.toDp() }
                w = maxOf(w, dp + 20.dp)
            }
            minOf(w, 220.dp)
        }
    }
    Column(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .background(c.surface, RoundedCornerShape(8.dp))
            .padding(1.dp),
    ) {
        Row(Modifier.background(c.surfaceElevated)) {
            header.forEachIndexed { ci, cell ->
                Box(Modifier.width(widths[ci]).padding(horizontal = 8.dp, vertical = 6.dp)) {
                    MdText(cell, 12.sp, c.textPrimary, textAlign = aligns.getOrNull(ci))
                }
            }
        }
        rows.forEachIndexed { ri, row ->
            if (ri > 0 || header.isNotEmpty()) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(c.divider))
            }
            Row {
                for (ci in 0 until cols) {
                    val cell = row.getOrNull(ci) ?: emptyList()
                    Box(Modifier.width(widths[ci]).padding(horizontal = 8.dp, vertical = 6.dp)) {
                        MdText(cell, 12.sp, c.textPrimary, textAlign = aligns.getOrNull(ci))
                    }
                }
            }
        }
    }
}

/** Markdown 正文渲染入口 — AssistantBubble 内替换原 plain Text。 */
@Composable
fun MarkdownBody(text: String, isError: Boolean = false, modifier: Modifier = Modifier) {
    val c = harnessColors()
    val blocks = remember(text) { parseBlocks(text) }
    val contentColor = if (isError) c.error else c.textPrimary
    Column(modifier.fillMaxWidth()) {
        blocks.forEachIndexed { idx, b ->
            if (idx > 0) Spacer(Modifier.height(6.dp))
            when (b) {
                is MdBlock.Heading -> {
                    val size = when (b.level) {
                        1 -> 19.sp
                        2 -> 17.sp
                        3 -> 15.5.sp
                        else -> 15.sp
                    }
                    MdText(b.spans, size, contentColor)
                }
                is MdBlock.Para -> {
                    // k8 接线：段落内图片（flushPara 已拆为独立 ImageSpan 段）→ MarkdownImage 网络加载
                    val imgs = b.spans.filterIsInstance<MdSpan.ImageSpan>()
                    if (imgs.isEmpty()) {
                        MdText(b.spans, 15.sp, contentColor)
                    } else {
                        Column(Modifier.fillMaxWidth()) {
                            for (img in imgs) MarkdownImage(img.url, img.alt)
                            val rest = b.spans.filterNot { it is MdSpan.ImageSpan }
                            if (rest.isNotEmpty()) MdText(rest, 15.sp, contentColor)
                        }
                    }
                }
                is MdBlock.Code -> CodeBlock(b.lang, b.code)
                is MdBlock.Quote -> Row {
                    Box(Modifier.width(3.dp).height(20.dp).background(c.divider))
                    Spacer(Modifier.width(8.dp))
                    MdText(b.spans, 14.sp, c.textSecondary)
                }
                is MdBlock.Ul -> Column {
                    b.items.forEachIndexed { i, (marker, spans) ->
                        if (i > 0) Spacer(Modifier.height(3.dp))
                        Row {
                            Text(marker, color = contentColor, fontSize = 15.sp)
                            Spacer(Modifier.width(8.dp))
                            MdText(spans, 15.sp, contentColor, Modifier.weight(1f))
                        }
                    }
                }
                is MdBlock.Ol -> Column {
                    b.items.forEachIndexed { i, (num, spans) ->
                        if (i > 0) Spacer(Modifier.height(3.dp))
                        Row {
                            Text("$num.", color = contentColor, fontSize = 15.sp)
                            Spacer(Modifier.width(8.dp))
                            MdText(spans, 15.sp, contentColor, Modifier.weight(1f))
                        }
                    }
                }
                MdBlock.Hr -> Box(Modifier.fillMaxWidth().height(1.dp).background(c.divider))
                is MdBlock.Table -> MdTable(b.header, b.rows, b.aligns)
            }
        }
    }
}
