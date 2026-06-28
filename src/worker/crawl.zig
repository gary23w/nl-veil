//! crawl.zig: parse HTML, strip boilerplate,
//! prune to the meaningful content with PruningContentFilter density heuristic, and emit
//! clean, LLM-ready markdown with link citations ([N] + a References list). This is the FIRST thing
//! the AI's web-reading tools reach for; the r.jina.ai reader + curl remain as fallbacks underneath.
//!
//! (content_filter_strategy.py PruningContentFilter,
//! markdown_generation_strategy.py DefaultMarkdownGenerator, content_scraping_strategy.py). No browser
//! / JS rendering (that path falls back to the jina reader); everything here is a string/tree algorithm.

const std = @import("std");

pub const Node = struct {
    is_text: bool = false,
    tag: []const u8 = "",
    text: []const u8 = "",
    class: []const u8 = "",
    id: []const u8 = "",
    href: []const u8 = "",
    src: []const u8 = "",
    alt: []const u8 = "",
    children: std.ArrayListUnmanaged(*Node) = .empty,
};

fn isVoid(tag: []const u8) bool {
    const v = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
    for (v) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}
fn isRawText(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "script") or std.mem.eql(u8, tag, "style");
}

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    title: []const u8 = "",

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }
};

fn lowerEqAt(s: []const u8, i: usize, lit: []const u8) bool {
    if (i + lit.len > s.len) return false;
    for (lit, 0..) |c, k| if (std.ascii.toLower(s[i + k]) != c) return false;
    return true;
}

const Parser = struct {
    a: std.mem.Allocator,
    html: []const u8,
    i: usize = 0,
    title: []const u8 = "",

    fn newNode(p: *Parser) *Node {
        const n = p.a.create(Node) catch unreachable;
        n.* = .{};
        return n;
    }

    fn parse(p: *Parser) *Node {
        const root = p.newNode();
        root.tag = "root";
        var stack: std.ArrayListUnmanaged(*Node) = .empty;
        stack.append(p.a, root) catch {};
        const html = p.html;
        while (p.i < html.len) {
            if (html[p.i] == '<') {
                if (lowerEqAt(html, p.i, "<!--")) {
                    const end = std.mem.indexOfPos(u8, html, p.i + 4, "-->") orelse html.len;
                    p.i = @min(end + 3, html.len);
                    continue;
                }
                if (p.i + 1 < html.len and (html[p.i + 1] == '!' or html[p.i + 1] == '?')) {
                    const end = std.mem.indexOfScalarPos(u8, html, p.i, '>') orelse html.len;
                    p.i = @min(end + 1, html.len);
                    continue;
                }
                if (p.i + 1 < html.len and html[p.i + 1] == '/') {
                    const gt = std.mem.indexOfScalarPos(u8, html, p.i, '>') orelse html.len;
                    const name = std.ascii.allocLowerString(p.a, std.mem.trim(u8, html[p.i + 2 .. gt], " \t\r\n/")) catch "";
                    var k: usize = stack.items.len;
                    while (k > 1) : (k -= 1) {
                        if (std.mem.eql(u8, stack.items[k - 1].tag, name)) {
                            stack.shrinkRetainingCapacity(k - 1);
                            break;
                        }
                    }
                    p.i = @min(gt + 1, html.len);
                    continue;
                }
                const gt = std.mem.indexOfScalarPos(u8, html, p.i, '>') orelse html.len;
                if (gt >= html.len) break;
                const inner = html[p.i + 1 .. gt];
                const self_close = inner.len > 0 and inner[inner.len - 1] == '/';
                const node = p.parseOpen(inner);
                const parent = stack.items[stack.items.len - 1];
                parent.children.append(p.a, node) catch {};
                p.i = gt + 1;
                if (isRawText(node.tag)) {
                    var buf: [16]u8 = undefined;
                    const close = std.fmt.bufPrint(&buf, "</{s}", .{node.tag}) catch "</";
                    const end = ciIndexOf(html, p.i, close) orelse html.len;
                    p.i = @min((std.mem.indexOfScalarPos(u8, html, end, '>') orelse html.len) + 1, html.len);
                } else if (!self_close and !isVoid(node.tag)) {
                    stack.append(p.a, node) catch {};
                }
            } else {
                const start = p.i;
                const nx = std.mem.indexOfScalarPos(u8, html, p.i, '<') orelse html.len;
                const raw = html[start..nx];
                p.i = nx;
                if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
                    const t = p.newNode();
                    t.is_text = true;
                    t.text = raw;
                    const parent = stack.items[stack.items.len - 1];
                    if (std.mem.eql(u8, parent.tag, "title") and p.title.len == 0)
                        p.title = std.mem.trim(u8, raw, " \t\r\n");
                    parent.children.append(p.a, t) catch {};
                }
            }
        }
        return root;
    }

    fn parseOpen(p: *Parser, inner_in: []const u8) *Node {
        var inner = inner_in;
        if (inner.len > 0 and inner[inner.len - 1] == '/') inner = inner[0 .. inner.len - 1];
        const n = p.newNode();
        var j: usize = 0;
        while (j < inner.len and !std.ascii.isWhitespace(inner[j])) j += 1;
        n.tag = std.ascii.allocLowerString(p.a, inner[0..j]) catch "";
        n.class = attr(inner, "class");
        n.id = attr(inner, "id");
        n.href = attr(inner, "href");
        n.src = attr(inner, "src");
        n.alt = attr(inner, "alt");
        return n;
    }
};

/// case-insensitive substring search from `from`
fn ciIndexOf(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or from >= hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (lowerEqAt(hay, i, needle)) return i;
    }
    return null;
}

/// extract an attribute value (handles "..", '..', or bare); returns a slice into `inner`
fn attr(inner: []const u8, name: []const u8) []const u8 {
    var i: usize = 0;
    while (i < inner.len) {
        if (lowerEqAt(inner, i, name) and (i == 0 or std.ascii.isWhitespace(inner[i - 1]))) {
            var k = i + name.len;
            while (k < inner.len and std.ascii.isWhitespace(inner[k])) k += 1;
            if (k < inner.len and inner[k] == '=') {
                k += 1;
                while (k < inner.len and std.ascii.isWhitespace(inner[k])) k += 1;
                if (k < inner.len and (inner[k] == '"' or inner[k] == '\'')) {
                    const q = inner[k];
                    const end = std.mem.indexOfScalarPos(u8, inner, k + 1, q) orelse inner.len;
                    return inner[k + 1 .. end];
                }
                const start = k;
                while (k < inner.len and !std.ascii.isWhitespace(inner[k])) k += 1;
                return inner[start..k];
            }
        }
        i += 1;
    }
    return "";
}

pub fn parse(gpa: std.mem.Allocator, html: []const u8) Doc {
    var arena = std.heap.ArenaAllocator.init(gpa);
    var p = Parser{ .a = arena.allocator(), .html = html };
    const root = p.parse();
    return .{ .arena = arena, .root = root, .title = p.title };
}

const EXCLUDED = [_][]const u8{ "nav", "footer", "header", "aside", "script", "style", "form", "iframe", "noscript", "svg", "button", "select", "input", "textarea" };

fn isExcluded(tag: []const u8) bool {
    for (EXCLUDED) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}

fn negativeClass(s: []const u8) bool {
    const pats = [_][]const u8{ "nav", "footer", "header", "sidebar", "ads", "comment", "promo", "advert", "social", "share", "menu", "cookie", "banner", "popup", "modal", "newsletter", "related" };
    var lo: [128]u8 = undefined;
    const n = @min(s.len, lo.len);
    for (s[0..n], 0..) |c, k| lo[k] = std.ascii.toLower(c);
    for (pats) |pat| if (std.mem.indexOf(u8, lo[0..n], pat) != null) return true;
    return false;
}

fn tagWeight(tag: []const u8) f64 {
    const T = struct { t: []const u8, w: f64 };
    const ws = [_]T{
        .{ .t = "div", .w = 0.5 },     .{ .t = "p", .w = 1.0 },     .{ .t = "article", .w = 1.0 },
        .{ .t = "section", .w = 0.8 }, .{ .t = "span", .w = 0.3 },  .{ .t = "li", .w = 0.5 },
        .{ .t = "ul", .w = 0.5 },      .{ .t = "ol", .w = 0.5 },    .{ .t = "h1", .w = 1.0 },
        .{ .t = "h2", .w = 1.0 },      .{ .t = "h3", .w = 1.0 },    .{ .t = "h4", .w = 0.9 },
        .{ .t = "h5", .w = 0.8 },      .{ .t = "h6", .w = 0.7 },    .{ .t = "blockquote", .w = 0.8 },
        .{ .t = "pre", .w = 0.9 },     .{ .t = "table", .w = 0.7 }, .{ .t = "main", .w = 1.0 },
    };
    for (ws) |x| if (std.mem.eql(u8, tag, x.t)) return x.w;
    return 0.5;
}

const Metrics = struct { text_len: usize = 0, tag_len: usize = 0, link_text_len: usize = 0 };

fn measure(node: *const Node) Metrics {
    var m = Metrics{};
    if (node.is_text) {
        const t = std.mem.trim(u8, node.text, " \t\r\n");
        m.text_len = t.len;
        m.tag_len = node.text.len;
        return m;
    }
    for (node.children.items) |c| {
        const cm = measure(c);
        m.text_len += cm.text_len;
        m.tag_len += cm.tag_len;
        if (!c.is_text and std.mem.eql(u8, c.tag, "a")) m.link_text_len += cm.text_len;
        m.link_text_len += cm.link_text_len;
    }
    m.tag_len += node.tag.len * 2 + 5;
    return m;
}

fn classIdWeight(node: *const Node) f64 {
    var s: f64 = 0;
    if (node.class.len > 0 and negativeClass(node.class)) s -= 0.5;
    if (node.id.len > 0 and negativeClass(node.id)) s -= 0.5;
    return s;
}

fn compositeScore(node: *const Node, m: Metrics) f64 {
    var score: f64 = 0;
    var total: f64 = 0;
    const tl: f64 = @floatFromInt(m.text_len);
    const gl: f64 = @floatFromInt(m.tag_len);
    const ll: f64 = @floatFromInt(m.link_text_len);
    score += 0.4 * (if (gl > 0) tl / gl else 0);
    total += 0.4;
    score += 0.2 * (1 - (if (tl > 0) ll / tl else 0));
    total += 0.2;
    score += 0.2 * tagWeight(node.tag);
    total += 0.2;
    score += 0.1 * @max(0, classIdWeight(node));
    total += 0.1;
    score += 0.1 * @log(tl + 1);
    total += 0.1;
    return if (total > 0) score / total else 0;
}

const THRESHOLD: f64 = 0.48;

fn pruneTree(node: *Node) bool {
    if (node.is_text) return std.mem.trim(u8, node.text, " \t\r\n").len > 0;
    if (isExcluded(node.tag)) return false;
    const structural = std.mem.eql(u8, node.tag, "root") or std.mem.eql(u8, node.tag, "html") or std.mem.eql(u8, node.tag, "body");
    const m = measure(node);
    if (!structural and m.text_len == 0 and !std.mem.eql(u8, node.tag, "img")) return false;
    if (!structural and m.text_len >= 1) {
        const score = compositeScore(node, m);
        if (score < THRESHOLD and m.text_len < 200 and negativeClass(node.class)) return false;
        if (score < THRESHOLD * 0.6 and m.text_len < 40) return false;
    }
    var kept: std.ArrayListUnmanaged(*Node) = .empty;
    for (node.children.items) |c| {
        if (pruneTree(c)) kept.append(node_arena, c) catch {};
    }
    node.children = kept;
    return structural or node.children.items.len > 0 or std.mem.eql(u8, node.tag, "img");
}
threadlocal var node_arena: std.mem.Allocator = undefined;

const Emitter = struct {
    a: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    refs: std.ArrayListUnmanaged(u8) = .empty,
    cite: u32 = 0,
    base: []const u8 = "",

    fn nl(e: *Emitter) void {
        const it = e.out.items;
        if (it.len == 0) return;
        if (it.len >= 2 and it[it.len - 1] == '\n' and it[it.len - 2] == '\n') return;
        e.out.append(e.a, '\n') catch {};
    }
    fn para(e: *Emitter) void {
        if (e.out.items.len == 0) return;
        if (e.out.items.len >= 1 and e.out.items[e.out.items.len - 1] != '\n') e.out.append(e.a, '\n') catch {};
        e.nl();
    }
    fn raw(e: *Emitter, s: []const u8) void {
        e.out.appendSlice(e.a, s) catch {};
    }
    fn text(e: *Emitter, s: []const u8) void {
        var last_sp = false;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c == '&') {
                if (i + 2 < s.len and s[i + 1] == '#') {
                    var k = i + 2;
                    const hex = k < s.len and (s[k] == 'x' or s[k] == 'X');
                    if (hex) k += 1;
                    const ds = k;
                    while (k < s.len and (std.ascii.isDigit(s[k]) or (hex and std.ascii.isHex(s[k])))) k += 1;
                    if (k > ds and k < s.len and s[k] == ';') {
                        const cp = std.fmt.parseInt(u21, s[ds..k], if (hex) 16 else 10) catch 0;
                        var ub: [4]u8 = undefined;
                        const un = if (cp > 0) (std.unicode.utf8Encode(cp, &ub) catch 0) else 0;
                        if (un > 0) {
                            e.out.appendSlice(e.a, ub[0..un]) catch {};
                            last_sp = false;
                            i = k + 1;
                            continue;
                        }
                    }
                }
                if (decodeEntity(s, &i)) |d| {
                    e.out.appendSlice(e.a, d) catch {};
                    last_sp = false;
                    continue;
                }
            }
            if (std.ascii.isWhitespace(c)) {
                if (!last_sp and e.out.items.len > 0 and e.out.items[e.out.items.len - 1] != '\n') e.out.append(e.a, ' ') catch {};
                last_sp = true;
            } else {
                e.out.append(e.a, c) catch {};
                last_sp = false;
            }
            i += 1;
        }
    }

    fn emit(e: *Emitter, node: *const Node) void {
        if (node.is_text) {
            e.text(node.text);
            return;
        }
        const t = node.tag;
        if (std.mem.eql(u8, t, "h1") or std.mem.eql(u8, t, "h2") or std.mem.eql(u8, t, "h3") or std.mem.eql(u8, t, "h4") or std.mem.eql(u8, t, "h5") or std.mem.eql(u8, t, "h6")) {
            e.para();
            const n = t[1] - '0';
            var k: u8 = 0;
            while (k < n) : (k += 1) e.raw("#");
            e.raw(" ");
            e.children(node);
            e.para();
            return;
        }
        if (std.mem.eql(u8, t, "p") or std.mem.eql(u8, t, "div") or std.mem.eql(u8, t, "section") or std.mem.eql(u8, t, "article") or std.mem.eql(u8, t, "main")) {
            e.para();
            e.children(node);
            e.para();
            return;
        }
        if (std.mem.eql(u8, t, "br")) {
            e.raw("\n");
            return;
        }
        if (std.mem.eql(u8, t, "hr")) {
            e.para();
            e.raw("---");
            e.para();
            return;
        }
        if (std.mem.eql(u8, t, "b") or std.mem.eql(u8, t, "strong")) {
            e.raw("**");
            e.children(node);
            e.raw("**");
            return;
        }
        if (std.mem.eql(u8, t, "i") or std.mem.eql(u8, t, "em")) {
            e.raw("_");
            e.children(node);
            e.raw("_");
            return;
        }
        if (std.mem.eql(u8, t, "code")) {
            e.raw("`");
            e.children(node);
            e.raw("`");
            return;
        }
        if (std.mem.eql(u8, t, "pre")) {
            e.para();
            e.raw("```\n");
            e.children(node);
            e.raw("\n```");
            e.para();
            return;
        }
        if (std.mem.eql(u8, t, "blockquote")) {
            e.para();
            e.raw("> ");
            e.children(node);
            e.para();
            return;
        }
        if (std.mem.eql(u8, t, "li")) {
            e.nl();
            e.raw("- ");
            e.children(node);
            e.nl();
            return;
        }
        if (std.mem.eql(u8, t, "a")) {
            const start = e.out.items.len;
            e.children(node);
            if (node.href.len > 0 and e.out.items.len > start) {
                e.cite += 1;
                e.raw(std.fmt.allocPrint(e.a, " [{d}]", .{e.cite}) catch "");
                const abs = absUrl(e.a, e.base, node.href);
                e.refs.appendSlice(e.a, std.fmt.allocPrint(e.a, "[{d}] {s}\n", .{ e.cite, abs }) catch "") catch {};
            }
            return;
        }
        if (std.mem.eql(u8, t, "img")) {
            if (node.src.len > 0) {
                const abs = absUrl(e.a, e.base, node.src);
                e.raw(std.fmt.allocPrint(e.a, "![{s}]({s})", .{ node.alt, abs }) catch "");
            }
            return;
        }
        e.children(node);
    }
    fn children(e: *Emitter, node: *const Node) void {
        for (node.children.items) |c| e.emit(c);
    }
};

fn absUrl(a: std.mem.Allocator, base: []const u8, href: []const u8) []const u8 {
    const h = std.mem.trim(u8, href, " \t\r\n");
    if (std.mem.startsWith(u8, h, "http://") or std.mem.startsWith(u8, h, "https://")) return h;
    if (base.len == 0) return h;
    if (std.mem.startsWith(u8, h, "//")) {
        const scheme = if (std.mem.startsWith(u8, base, "https")) "https:" else "http:";
        return std.fmt.allocPrint(a, "{s}{s}", .{ scheme, h }) catch h;
    }
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return h) + 3;
    const path_start = std.mem.indexOfScalarPos(u8, base, scheme_end, '/') orelse base.len;
    const origin = base[0..path_start];
    if (h.len > 0 and h[0] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ origin, h }) catch h;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ origin, h }) catch h;
}

fn decodeEntity(s: []const u8, i: *usize) ?[]const u8 {
    const rest = s[i.*..];
    const ents = [_]struct { e: []const u8, v: []const u8 }{
        .{ .e = "&amp;", .v = "&" },    .{ .e = "&lt;", .v = "<" },    .{ .e = "&gt;", .v = ">" },
        .{ .e = "&quot;", .v = "\"" },  .{ .e = "&#39;", .v = "'" },   .{ .e = "&apos;", .v = "'" },
        .{ .e = "&nbsp;", .v = " " },
        .{ .e = "&mdash;", .v = "—" },
        .{ .e = "&ndash;", .v = "–" },
        .{ .e = "&hellip;", .v = "…" },
        .{ .e = "&rsquo;", .v = "'" },  .{ .e = "&lsquo;", .v = "'" }, .{ .e = "&ldquo;", .v = "\"" },
        .{ .e = "&rdquo;", .v = "\"" }, .{ .e = "&#x27;", .v = "'" },
    };
    for (ents) |x| if (std.mem.startsWith(u8, rest, x.e)) {
        i.* += x.e.len;
        return x.v;
    };
    return null;
}

/// Decode HTML entities in a short string (e.g. a <title>) into a gpa-owned buffer — the body goes through
/// Emitter.text() which already decodes, but the page title is taken raw, so it needs the same pass. Handles both
/// numeric (&#NN; / &#xHH;) and the named entities above. Whitespace is preserved (titles are already trimmed).
fn decodeEntitiesAlloc(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (i + 2 < s.len and s[i + 1] == '#') {
                var k = i + 2;
                const hex = k < s.len and (s[k] == 'x' or s[k] == 'X');
                if (hex) k += 1;
                const ds = k;
                while (k < s.len and (std.ascii.isDigit(s[k]) or (hex and std.ascii.isHex(s[k])))) k += 1;
                if (k > ds and k < s.len and s[k] == ';') {
                    const cp = std.fmt.parseInt(u21, s[ds..k], if (hex) 16 else 10) catch 0;
                    var ub: [4]u8 = undefined;
                    const un = if (cp > 0) (std.unicode.utf8Encode(cp, &ub) catch 0) else 0;
                    if (un > 0) {
                        out.appendSlice(gpa, ub[0..un]) catch {};
                        i = k + 1;
                        continue;
                    }
                }
            }
            if (decodeEntity(s, &i)) |d| {
                out.appendSlice(gpa, d) catch {};
                continue;
            }
        }
        out.append(gpa, s[i]) catch {};
        i += 1;
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, s) catch @constCast(""));
}

pub const Result = struct {
    markdown: []const u8,
    title: []const u8,
    links: u32,
};

/// Fetch-agnostic: takes raw HTML + the page URL, returns clean LLM-ready markdown (fit_markdown).
pub fn extract(gpa: std.mem.Allocator, html: []const u8, base_url: []const u8) Result {
    var doc = parse(gpa, html);
    defer doc.deinit();
    node_arena = doc.arena.allocator();
    _ = pruneTree(doc.root);
    var e = Emitter{ .a = doc.arena.allocator(), .base = base_url };
    e.emit(doc.root);
    var md: std.ArrayListUnmanaged(u8) = .empty;
    const body = std.mem.trim(u8, e.out.items, " \t\r\n");
    md.appendSlice(gpa, body) catch {};
    if (e.refs.items.len > 0) {
        md.appendSlice(gpa, "\n\n## References\n") catch {};
        md.appendSlice(gpa, e.refs.items) catch {};
    }
    return .{
        .markdown = md.toOwnedSlice(gpa) catch (gpa.dupe(u8, body) catch @constCast("")),
        .title = decodeEntitiesAlloc(gpa, doc.title),
        .links = e.cite,
    };
}

fn b64try(gpa: std.mem.Allocator, s: []const u8) ?[]u8 {
    const decoders = [_]std.base64.Base64Decoder{ std.base64.standard.Decoder, std.base64.standard_no_pad.Decoder, std.base64.url_safe.Decoder, std.base64.url_safe_no_pad.Decoder };
    for (decoders) |dec| {
        const n = dec.calcSizeForSlice(s) catch continue;
        const buf = gpa.alloc(u8, n) catch return null;
        dec.decode(buf, s) catch {
            gpa.free(buf);
            continue;
        };
        return buf;
    }
    return null;
}

/// Unwrap a SERP redirect to the real destination URL. Bing: /ck/a?...&u=a1<base64>&... ; DuckDuckGo:
/// /l/?uddg=<urlencoded>. Returns gpa-owned real URL, or a gpa-dup of the input if it isn't a known wrapper.
pub fn unwrapRedirect(gpa: std.mem.Allocator, url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "bing.com/ck/") != null) {
        if (std.mem.indexOf(u8, url, "u=a1")) |p| {
            const start = p + 4;
            var end = start;
            while (end < url.len and url[end] != '&') end += 1;
            if (b64try(gpa, url[start..end])) |dec| {
                if (std.mem.startsWith(u8, dec, "http")) return dec;
                gpa.free(dec);
            }
        }
    }
    if (std.mem.indexOf(u8, url, "uddg=")) |p| {
        const start = p + 5;
        var end = start;
        while (end < url.len and url[end] != '&') end += 1;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i = start;
        while (i < end) {
            if (url[i] == '%' and i + 2 < end) {
                const hv = std.fmt.parseInt(u8, url[i + 1 .. i + 3], 16) catch {
                    out.append(gpa, url[i]) catch {};
                    i += 1;
                    continue;
                };
                out.append(gpa, hv) catch {};
                i += 3;
            } else if (url[i] == '+') {
                out.append(gpa, ' ') catch {};
                i += 1;
            } else {
                out.append(gpa, url[i]) catch {};
                i += 1;
            }
        }
        if (std.mem.startsWith(u8, out.items, "http")) return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, url) catch @constCast(""));
        out.deinit(gpa);
    }
    return gpa.dupe(u8, url) catch @constCast("");
}

fn aText(node: *const Node, out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator) void {
    if (node.is_text) {
        const t = std.mem.trim(u8, node.text, " \t\r\n");
        if (t.len > 0) {
            if (out.items.len > 0) out.append(a, ' ') catch {};
            out.appendSlice(a, t) catch {};
        }
        return;
    }
    for (node.children.items) |c| aText(c, out, a);
}

/// A harvested link is the engine's OWN chrome (nav / promo / proxy), not a result, if it points at a known search
/// engine's domain OR at the SERP's own host. Excluding these is what keeps a multi-engine crawl-as-search clean
/// across environments — every engine wraps its results in its own navigation, and we must drop all of it.
fn isEngineLink(real: []const u8, base: []const u8) bool {
    const engines = [_][]const u8{ "bing.com", "duckduckgo.com", "microsoft.com", "msn.com", "mojeek.com", "marginalia.nu", "marginalia-search.com", "startpage.com", "yandex.com", "yandex.ru", "ecosia.org", "brave.com", "4get.ca", "google.com", "googleusercontent.com", "gstatic.com" };
    for (engines) |e| if (std.mem.indexOf(u8, real, e) != null) return true;
    // site chrome that is never a result: licence/attribution badges + footer social. Collision-safe substrings only.
    const junk = [_][]const u8{ "creativecommons.org", "ip2location.com", "ip-api.com", "maxmind.com", "schema.org", "w3.org", "gnu.org/licenses", "twitter.com", "facebook.com", "instagram.com", "linkedin.com", "//t.me/" };
    for (junk) |j| if (std.mem.indexOf(u8, real, j) != null) return true;
    const bh = hostOf(base);
    if (bh.len > 3 and std.mem.indexOf(u8, real, bh) != null) return true;
    return false;
}

/// Links inside a nav/footer/header/aside/form are site chrome, never results — skipping these subtrees stops an
/// engine's footer leaking as fake "results" that fake a >=2 hit and block the registry fallback.
fn isChromeTag(tag: []const u8) bool {
    const chrome = [_][]const u8{ "footer", "nav", "header", "aside", "form", "script", "style", "head" };
    for (chrome) |c| if (std.ascii.eqlIgnoreCase(tag, c)) return true;
    return false;
}

fn walkAnchors(node: *const Node, base: []const u8, gpa: std.mem.Allocator, ta: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), seen: *std.StringHashMapUnmanaged(void), max: usize, n: *usize) void {
    if (n.* >= max) return;
    if (!node.is_text and isChromeTag(node.tag)) return; // skip nav/footer/header chrome
    if (!node.is_text and std.mem.eql(u8, node.tag, "a") and node.href.len > 0) {
        var tb: std.ArrayListUnmanaged(u8) = .empty;
        aText(node, &tb, ta);
        const text = std.mem.trim(u8, tb.items, " \t\r\n");
        const abs0 = absUrl(ta, base, node.href);
        const real = unwrapRedirect(gpa, abs0);
        const is_http = std.mem.startsWith(u8, real, "http");
        const is_engine = isEngineLink(real, base);
        if (is_http and !is_engine and text.len >= 8 and !seen.contains(real)) {
            seen.put(gpa, gpa.dupe(u8, real) catch real, {}) catch {};
            out.appendSlice(gpa, std.fmt.allocPrint(ta, "- {s}\n  {s}\n", .{ clipText(text, 140), real }) catch "") catch {};
            n.* += 1;
        } else gpa.free(real);
        return;
    }
    if (node.is_text) return;
    for (node.children.items) |c| walkAnchors(c, base, gpa, ta, out, seen, max, n);
}

fn clipText(s: []const u8, n: usize) []const u8 {
    return if (s.len <= n) s else s[0..n];
}

/// CRAWL-AS-SEARCH: harvest result links from a fetched SERP HTML. Returns gpa-owned "- title\n  url\n" lines
/// (decoded real URLs), ready to feed an agent. `base_url` is the SERP origin (for relative-link resolution).
pub fn searchResults(gpa: std.mem.Allocator, serp_html: []const u8, base_url: []const u8, max: usize) []const u8 {
    var doc = parse(gpa, serp_html);
    defer doc.deinit();
    const ta = doc.arena.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var n: usize = 0;
    walkAnchors(doc.root, base_url, gpa, ta, &out, &seen, max, &n);
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

const STOPWORDS = [_][]const u8{ "the", "a", "an", "and", "or", "of", "to", "in", "is", "are", "for", "on", "with", "as", "by", "at", "be", "this", "that", "it", "from", "was", "were", "has", "have", "had", "but", "not", "they", "you", "we", "he", "she", "his", "her", "their", "our", "its", "will", "would", "can", "could", "do", "does", "did", "so", "if", "than", "then", "into", "about", "over", "out", "up", "no", "all", "more", "most", "some", "such", "only", "also" };

fn isStop(w: []const u8) bool {
    for (STOPWORDS) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// Lowercase + split `s` on non-alphanumeric, drop stopwords and length<2; append owned tokens to `out` (arena `a`).
fn tokenize(a: std.mem.Allocator, s: []const u8, out: *std.ArrayListUnmanaged([]const u8)) void {
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and !std.ascii.isAlphanumeric(s[i])) i += 1;
        const start = i;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '\'')) i += 1;
        if (i <= start) continue;
        const raw = s[start..i];
        if (raw.len < 2) continue;
        const w = a.alloc(u8, raw.len) catch continue;
        for (raw, 0..) |c, j| w[j] = std.ascii.toLower(c);
        if (!isStop(w)) out.append(a, w) catch {};
    }
}

/// Split markdown into paragraph-ish chunks on blank lines (a heading or a list-block is its own chunk). Owned by `a`.
pub fn chunkMarkdown(a: std.mem.Allocator, md: []const u8, out: *std.ArrayListUnmanaged([]const u8)) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) {
            const body = std.mem.trim(u8, buf.items, " \t\r\n");
            if (body.len > 0) out.append(a, a.dupe(u8, body) catch "") catch {};
            buf.clearRetainingCapacity();
        } else {
            buf.appendSlice(a, line) catch {};
            buf.append(a, '\n') catch {};
        }
    }
    const body = std.mem.trim(u8, buf.items, " \t\r\n");
    if (body.len > 0) out.append(a, a.dupe(u8, body) catch "") catch {};
}

const Scored = struct { idx: usize, score: f64 };
fn scoredDesc(_: void, x: Scored, y: Scored) bool {
    return x.score > y.score;
}

/// BM25-rank `md`'s chunks against `query` and return the most relevant chunks, re-joined in document order and
/// capped near `max_bytes`. Empty query (or no chunk matches) -> the document head, clipped. gpa-owned result.
pub fn fitToQuery(gpa: std.mem.Allocator, md: []const u8, query: []const u8, max_bytes: usize) []const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var chunks: std.ArrayListUnmanaged([]const u8) = .empty;
    chunkMarkdown(a, md, &chunks);
    var qtok: std.ArrayListUnmanaged([]const u8) = .empty;
    tokenize(a, query, &qtok);
    if (chunks.items.len == 0 or qtok.items.len == 0) return gpa.dupe(u8, clipText(md, max_bytes)) catch @constCast("");

    const N = chunks.items.len;
    var df: std.StringHashMapUnmanaged(usize) = .empty;
    const tf = a.alloc(std.StringHashMapUnmanaged(usize), N) catch return gpa.dupe(u8, clipText(md, max_bytes)) catch @constCast("");
    const lens = a.alloc(usize, N) catch return gpa.dupe(u8, clipText(md, max_bytes)) catch @constCast("");
    var total_len: usize = 0;
    for (chunks.items, 0..) |ch, ci| {
        tf[ci] = .empty;
        var toks: std.ArrayListUnmanaged([]const u8) = .empty;
        tokenize(a, ch, &toks);
        lens[ci] = toks.items.len;
        total_len += toks.items.len;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (toks.items) |w| {
            const e = tf[ci].getOrPut(a, w) catch continue;
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
            if (!seen.contains(w)) {
                seen.put(a, w, {}) catch {};
                const d = df.getOrPut(a, w) catch continue;
                if (!d.found_existing) d.value_ptr.* = 0;
                d.value_ptr.* += 1;
            }
        }
    }
    const Nf = @as(f64, @floatFromInt(N));
    const avgdl = if (total_len > 0) @as(f64, @floatFromInt(total_len)) / Nf else 1.0;
    const k1 = 1.2;
    const b = 0.75;

    const scored = a.alloc(Scored, N) catch return gpa.dupe(u8, clipText(md, max_bytes)) catch @constCast("");
    for (0..N) |ci| {
        var s: f64 = 0;
        const dl = @as(f64, @floatFromInt(lens[ci]));
        for (qtok.items) |qt| {
            const fr = tf[ci].get(qt) orelse 0;
            if (fr == 0) continue;
            const f = @as(f64, @floatFromInt(fr));
            const dfi = @as(f64, @floatFromInt(df.get(qt) orelse 0));
            const idf = @log((Nf - dfi + 0.5) / (dfi + 0.5) + 1.0);
            s += idf * (f * (k1 + 1.0)) / (f + k1 * (1.0 - b + b * dl / avgdl));
        }
        scored[ci] = .{ .idx = ci, .score = s };
    }
    std.mem.sort(Scored, scored, {}, scoredDesc);

    var picked: std.ArrayListUnmanaged(usize) = .empty;
    var used: usize = 0;
    for (scored) |sc| {
        if (sc.score <= 0) break;
        const clen = chunks.items[sc.idx].len + 2;
        if (used + clen > max_bytes and picked.items.len > 0) break;
        picked.append(a, sc.idx) catch {};
        used += clen;
        if (used >= max_bytes) break;
    }
    if (picked.items.len == 0) return gpa.dupe(u8, clipText(md, max_bytes)) catch @constCast("");
    std.mem.sort(usize, picked.items, {}, std.sort.asc(usize));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (picked.items) |idx| {
        out.appendSlice(gpa, chunks.items[idx]) catch {};
        out.appendSlice(gpa, "\n\n") catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, clipText(md, max_bytes)) catch @constCast(""));
}

fn hostOf(url: []const u8) []const u8 {
    const p = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[p + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..end];
}

fn walkLinks(node: *const Node, base: []const u8, host: []const u8, gpa: std.mem.Allocator, ta: std.mem.Allocator, intl: *std.ArrayListUnmanaged(u8), extl: *std.ArrayListUnmanaged(u8), media: *std.ArrayListUnmanaged(u8), seen: *std.StringHashMapUnmanaged(void), max: usize, ni: *usize, ne: *usize, nm: *usize) void {
    if (node.is_text) return;
    if (std.mem.eql(u8, node.tag, "a") and node.href.len > 0) {
        const abs = absUrl(ta, base, node.href);
        if (std.mem.startsWith(u8, abs, "http") and !seen.contains(abs)) {
            const same = host.len > 0 and std.mem.eql(u8, hostOf(abs), host);
            if ((same and ni.* < max) or (!same and ne.* < max)) {
                seen.put(gpa, gpa.dupe(u8, abs) catch abs, {}) catch {};
                var tb: std.ArrayListUnmanaged(u8) = .empty;
                aText(node, &tb, ta);
                const text = clipText(std.mem.trim(u8, tb.items, " \t\r\n"), 90);
                const line = std.fmt.allocPrint(ta, "- {s}{s}{s}\n", .{ text, if (text.len > 0) " | " else "", abs }) catch "";
                if (same) {
                    intl.appendSlice(gpa, line) catch {};
                    ni.* += 1;
                } else {
                    extl.appendSlice(gpa, line) catch {};
                    ne.* += 1;
                }
            }
        }
    } else if (std.mem.eql(u8, node.tag, "img") and node.src.len > 0 and nm.* < max) {
        const abs = absUrl(ta, base, node.src);
        if (std.mem.startsWith(u8, abs, "http") and !seen.contains(abs)) {
            seen.put(gpa, gpa.dupe(u8, abs) catch abs, {}) catch {};
            const alt = clipText(std.mem.trim(u8, node.alt, " \t\r\n"), 90);
            media.appendSlice(gpa, std.fmt.allocPrint(ta, "- {s}{s}{s}\n", .{ alt, if (alt.len > 0) " | " else "", abs }) catch "") catch {};
            nm.* += 1;
        }
    }
    for (node.children.items) |c| walkLinks(c, base, host, gpa, ta, intl, extl, media, seen, max, ni, ne, nm);
}

/// Structured link/media extraction: returns "## Internal links\n...\n## External links\n...\n## Media\n..." with up
/// to `max` entries per section (deduped, absolute URLs). gpa-owned. base_url sets the origin for internal/external.
pub fn extractLinks(gpa: std.mem.Allocator, html: []const u8, base_url: []const u8, max: usize) []const u8 {
    var doc = parse(gpa, html);
    defer doc.deinit();
    const ta = doc.arena.allocator();
    const host = hostOf(base_url);
    var intl: std.ArrayListUnmanaged(u8) = .empty;
    var extl: std.ArrayListUnmanaged(u8) = .empty;
    var media: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var ni: usize = 0;
    var ne: usize = 0;
    var nm: usize = 0;
    walkLinks(doc.root, base_url, host, gpa, ta, &intl, &extl, &media, &seen, max, &ni, &ne, &nm);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (intl.items.len > 0) {
        out.appendSlice(gpa, "## Internal links\n") catch {};
        out.appendSlice(gpa, intl.items) catch {};
    }
    if (extl.items.len > 0) {
        out.appendSlice(gpa, "\n## External links\n") catch {};
        out.appendSlice(gpa, extl.items) catch {};
    }
    if (media.items.len > 0) {
        out.appendSlice(gpa, "\n## Media\n") catch {};
        out.appendSlice(gpa, media.items) catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}
