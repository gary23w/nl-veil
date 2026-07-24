//! writer.zig — the small-model WRITING faculty: a grounding scaffold that makes a weak/8b model produce
//! COHERENT, GROUNDED artifacts instead of fabricating. The engine seeds real source material, NUMBERS it so the
//! model cites by [N] (never typing a URL it could invent), then RESOLVES each [N] back to its verified source
//! and strips anything invented.
//!
//! GENERAL MACHINERY — NO use-case is baked in. `compose(ground, …)` either grounds in fetched sources or
//! synthesizes the hive's own knowledge; the prompts cover grounding MECHANICS only. Subject, persona, tone, and
//! structure come from the swarm's GOAL — a news/research/status desk all use the same compose, differing only in
//! that goal text. The ETL NORMALIZATION section below applies the same affect to a weak model's lexical writes
//! (memory, messages).
//!
//! Publishing is NOT a writing concern: the public-post capability is `tools.telegraphPublish` and its
//! orchestration lives in run.zig. writer.zig never references telegraph and carries no use-case persona or policy.
const std = @import("std");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const run = @import("run.zig");

const Worker = run.Worker;
const clip = run.clip;

pub const MAX_SOURCES = 12;

/// The result of a compose: the gpa-owned markdown (caller frees) plus how many citations grounded in real sources.
pub const Doc = struct { md: []const u8 = "", grounded: u32 = 0, cited: u32 = 0 };

/// Grounded write: the engine fetched real numbered sources; the model writes using ONLY them and cites by [N]. This is
/// general RAG machinery (cite the sources, never invent a link) — the engine resolves each [N] to its verified URL.
const GROUNDED_SYS = "You write a clear, well-structured markdown document grounded STRICTLY in the numbered SOURCES the engine fetched this cycle (shown as '[N] …', one per line). ABSOLUTE RULES: use ONLY what those sources say — do NOT add any claim from your own memory or training (if it is not in the list, it does not go in); cite every claim by its SOURCE NUMBER in square brackets, e.g. 'A record was set [3].'; and NEVER write a URL, domain, or link yourself — the engine inserts the real link for each [N] and DROPS any number not in the list. Open with a one-line summary, keep each point to a short factual sentence or two ending with its [N], group related points, and if the sources are thin write a short honest document rather than padding it. FOLLOW THE TASK INSTRUCTIONS below for the subject, tone, and structure. Output ONLY the markdown, no preamble.";

/// Free write (no web sources): synthesize the hive's own shared knowledge + the round's discussion, faithfully.
const FREE_SYS = "You are the hive's scribe. Write a clear, well-organized markdown document on the topic, synthesizing the hive's shared findings and this round's discussion. Structure it: a short summary; the key findings (grounded in the shared knowledge); the RANGE OF VIEWS in the hive — explicitly note where the minds AGREE and where they DISAGREE and why (do NOT flatten genuine disagreement into false consensus); the overall mood; and, where the topic involves a problem, concrete proposed SOLUTIONS or paths forward. Be faithful to the material — do not invent facts. FOLLOW THE TASK INSTRUCTIONS for tone and structure. Output ONLY the markdown, no preamble.";

/// Compose a written artifact for a weak model. `ground` (set by the caller from the run's config) turns on the
/// engine-seeded retrieval + [N]-citation floor; otherwise the model synthesizes the hive's own knowledge. The subject,
/// persona, and tone come from `topic` (the swarm goal) — NOT from the engine. Returns the gpa-owned markdown +
/// grounding counts; `md` is "" when there was nothing substantial to write. The caller decides where to store/publish.
pub fn compose(w: *Worker, ground: bool, topic: []const u8, context: []const u8, round: u32) Doc {
    const gpa = w.gpa;
    const know = w.mem.assoc(tools.KNOWLEDGE_SCOPE, if (topic.len > 0) topic else "findings", 1, 28);
    defer gpa.free(know);
    const sources = if (ground and w.internet) seedSources(w, topic, round) else (gpa.dupe(u8, "") catch @constCast(""));
    defer if (sources.len > 0) gpa.free(@constCast(sources));
    const srclist: SourceList = if (ground) buildNumberedSources(gpa, sources) else SourceList{};
    defer if (srclist.text.len > 0) gpa.free(@constCast(srclist.text));
    if (know.len < 40 and context.len < 40 and srclist.n == 0) return .{};
    const grounded = ground and srclist.n >= 1;
    const sys = if (grounded) GROUNDED_SYS else FREE_SYS;
    const user = if (grounded)
        std.fmt.allocPrint(gpa, "TASK: {s}\nThe real current date is {s}.\n\nFETCHED SOURCES — cite each by its [N] number, never write a URL:\n{s}\n\nWrite the grounded document now, following the task and citing every claim as [N].", .{ clip(topic, 400), if (w.now_str.len > 0) w.now_str else "today", clip(srclist.text, 4000) }) catch return .{}
    else
        std.fmt.allocPrint(gpa, "TASK: {s}\nThe real current date is {s}.\n\nThe hive's shared knowledge so far:\n{s}\n\nThis round's discussion (the minds' own words — note any dissent or challenge to the consensus):\n{s}\n\nWrite the updated document now.", .{ clip(topic, 400), if (w.now_str.len > 0) w.now_str else "today", clip(know, 3000), clip(context, 1800) }) catch return .{};
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "brief", w.gw_base, w.gw_key, w.gateway_model, sys, user, 1600);
    defer gpa.free(r.content);
    if (!r.ok or r.content.len < 80) return .{};
    const raw_md = std.mem.trim(u8, r.content, " \r\n\t");
    if (!grounded) return .{ .md = gpa.dupe(u8, raw_md) catch (gpa.dupe(u8, "") catch @constCast("")) };
    const g = resolveCitations(gpa, raw_md, srclist.urls[0..srclist.n]);
    if (g.out.len == 0) {
        return .{ .md = gpa.dupe(u8, raw_md) catch (gpa.dupe(u8, "") catch @constCast("")) };
    }
    const md = gpa.dupe(u8, std.mem.trim(u8, g.out, " \r\n\t")) catch (gpa.dupe(u8, "") catch @constCast(""));
    gpa.free(g.out);
    return .{ .md = md, .grounded = g.grounded, .cited = g.cited };
}

/// The ETL spine: one gateway call that TRANSFORMS `payload` under `sys`, grounded in `evidence`. gpa-owned; "" on
/// reject/failure. The shared transform behind every per-destination normalizer below.
fn etl(w: *Worker, sys: []const u8, evidence: []const u8, payload: []const u8, max_tokens: u32) []const u8 {
    const gpa = w.gpa;
    if (std.mem.trim(u8, payload, " \r\n\t").len == 0) return gpa.dupe(u8, "") catch @constCast("");
    const user = std.fmt.allocPrint(gpa, "EVIDENCE (what actually happened this step — trust the tool results, not the model's claims):\n{s}\n\nCANDIDATE:\n{s}\n\nReturn the cleaned, supported result only.", .{ clip(evidence, 2600), clip(payload, 1600) }) catch return (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "etl", w.gw_base, w.gw_key, w.gateway_model, sys, user, max_tokens);
    defer gpa.free(r.content);
    if (!r.ok) return gpa.dupe(u8, "") catch @constCast("");
    return gpa.dupe(u8, std.mem.trim(u8, r.content, " \r\n\t")) catch (gpa.dupe(u8, "") catch @constCast(""));
}

const MEMORY_SYS =
    "You are a strict MEMORY GATEKEEPER for an AI whose writer is a small, hallucination-prone model. The CANDIDATE is " ++
    "facts it wants to save to long-term memory this step. Keep ONLY statements that are (a) clearly SUPPORTED by the " ++
    "evidence AND (b) WORTH REMEMBERING next session — substantive knowledge about the SUBJECT or the world: concrete " ++
    "findings, facts, data, decisions, or a learned technique. DROP: anything fabricated or not backed by the evidence; " ++
    "a plan or intention ('I will…'); a tool-call fragment or JSON; vague filler; AND ephemeral WORKFLOW/STATUS " ++
    "narration useless to recall later — that a file/draft was created, a task started, a file exists or is readable, " ++
    "what the output looks like, or any step of the agent's own process. Rewrite each KEPT fact as ONE clean, " ++
    "self-contained, third-person declarative sentence (no 'I'/'we', no meta). Output ONLY the kept facts, one per line, " ++
    "NOTHING ELSE — no commentary, no counts, no parentheticals, no '(no other facts)' note. If none qualify, output an empty response.";

const MESSAGE_SYS =
    "You clean a message a weak, hallucination-prone AI is about to send to a TEAMMATE on a shared bus. Keep it ONLY if " ++
    "it conveys a concrete, useful point that is SUPPORTED by the evidence: a real finding, a decision, a specific " ++
    "request, or a coordination note. Rewrite it as one or two clear, self-contained sentences (no 'I will…' padding, no " ++
    "process narration, no tool-call fragments, no restating the obvious). If the message is just narration, a plan, or " ++
    "has no real content the teammate can act on, output NOTHING. Output only the cleaned message or an empty response.";

/// MEMORY ETL — keep only substantive, grounded facts worth recalling; drop fabrication/plans/fragments/workflow noise.
/// `candidates` is one raw fact per line; returns the kept, cleaned facts (newline-joined, gpa-owned) or "".
pub fn normalizeFacts(w: *Worker, candidates: []const u8, evidence: []const u8) []const u8 {
    return etl(w, MEMORY_SYS, evidence, candidates, 400);
}

/// MESSAGE ETL — clean a teammate message to a concrete, grounded note, or "" if it carries nothing actionable.
pub fn normalizeMessage(w: *Worker, raw: []const u8, evidence: []const u8) []const u8 {
    return etl(w, MESSAGE_SYS, evidence, raw, 160);
}

const GroundResult = struct { out: []const u8 = "", grounded: u32 = 0, cited: u32 = 0 };
const SourceList = struct { text: []const u8 = "", urls: [MAX_SOURCES][]const u8 = [_][]const u8{""} ** MAX_SOURCES, n: usize = 0 };

fn isHttpUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}
fn urlEnd(s: []const u8, start: usize) usize {
    var e = start;
    while (e < s.len) : (e += 1) {
        const c = s[e];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == ')' or c == ']' or c == '"' or c == '<' or c == '>' or c == '|' or c == '\\') break;
    }
    while (e > start and (s[e - 1] == '.' or s[e - 1] == ',' or s[e - 1] == ';' or s[e - 1] == ':')) e -= 1;
    return e;
}
fn addDomainFromUrl(set: *std.BufSet, url: []const u8) bool {
    var u = url;
    if (std.mem.startsWith(u8, u, "https://")) u = u[8..] else if (std.mem.startsWith(u8, u, "http://")) u = u[7..];
    if (std.mem.startsWith(u8, u, "www.")) u = u[4..];
    const end = std.mem.indexOfAny(u8, u, "/?#") orelse u.len;
    const host = u[0..end];
    if (host.len < 3 or set.contains(host)) return false;
    set.insert(host) catch return false;
    return true;
}

/// ENGINE-SEEDED RETRIEVAL — the engine retrieves real sources for the topic ITSELF (a weak model can't be relied on
/// to search) via the shared web-search chain (our crawler first, then the self-healing registry; NO google-news),
/// returned with URLs INTACT straight to the writer. Tracks per-round seed/diversity for the publish gates.
fn seedSources(w: *Worker, topic: []const u8, round: u32) []const u8 {
    const gpa = w.gpa;
    const q = if (topic.len > 0) clip(topic, 140) else "top world news science technology business";
    const environ = w.mem.environ orelse return (gpa.dupe(u8, "") catch @constCast(""));
    const wd = std.fmt.allocPrint(gpa, "{s}/work", .{w.run_dir}) catch return (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(wd);
    const body = tools.searchWeb(w.io, gpa, environ, w.run_dir, wd, "seed", "web", q, 12);
    defer gpa.free(@constCast(body));
    const out = std.mem.trim(u8, body, " \r\n\t");
    if (out.len < 20) return (gpa.dupe(u8, "") catch @constCast(""));
    var domains = std.BufSet.init(gpa);
    defer domains.deinit();
    var seeded: u32 = 0;
    var diversity: u32 = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (!isHttpUrl(t)) continue;
        seeded += 1;
        if (addDomainFromUrl(&domains, t)) diversity += 1;
    }
    w.round_seed_sources = seeded;
    if (diversity > w.round_source_diversity) w.round_source_diversity = diversity;
    if (w.round_seed_sources + w.round_independent_sources > 0)
        w.round_seed_dependency_pct = (w.round_seed_sources * 100) / (w.round_seed_sources + w.round_independent_sources)
    else
        w.round_seed_dependency_pct = 100;
    w.act("engine", round, "seed", "retrieved live sources for the desk (crawler + registry)", clip(out, 300));
    return gpa.dupe(u8, clip(out, 6000)) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// Parse the fetched SOURCE text ("- TITLE\n  URL\n  SNIPPET" items) into a NUMBERED list — [1] title, [2] title … —
/// with a parallel array of the REAL URLs. The model sees the numbered titles WITHOUT URLs, so it can only reference a
/// source by number; the engine fills in the verified link. A weak model never types a URL, so it cannot invent one.
fn buildNumberedSources(gpa: std.mem.Allocator, raw: []const u8) SourceList {
    var s: SourceList = .{};
    var disp: std.ArrayListUnmanaged(u8) = .empty;
    var pending_title: []const u8 = "";
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        if (isHttpUrl(t)) {
            if (s.n >= MAX_SOURCES) break;
            const url = t[0..urlEnd(t, 0)];
            var dup = false;
            for (s.urls[0..s.n]) |u| {
                if (std.mem.eql(u8, u, url)) {
                    dup = true;
                    break;
                }
            }
            if (!dup and url.len > 10) {
                const title = if (pending_title.len > 0) pending_title else "(headline)";
                s.urls[s.n] = url;
                s.n += 1;
                if (std.fmt.allocPrint(gpa, "[{d}] {s}\n", .{ s.n, clip(title, 200) })) |numbered| {
                    defer gpa.free(numbered);
                    disp.appendSlice(gpa, numbered) catch {};
                } else |_| {}
            }
            pending_title = "";
        } else if (std.mem.startsWith(u8, t, "- ")) {
            pending_title = std.mem.trim(u8, t[2..], " \r\t");
        } else if (!std.mem.startsWith(u8, t, "[src:web]")) {
            pending_title = t;
        }
    }
    s.text = disp.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
    return s;
}

/// CITATION RESOLUTION (the enforced RAG floor). Replace each [N] with a real markdown link to urls[N-1]; drop an
/// out-of-range [N]; strip any URL or markdown link the model wrote anyway (it was told never to type one); remove
/// storage-wrapper noise. grounded = distinct valid [N] resolved.
fn resolveCitations(gpa: std.mem.Allocator, md: []const u8, urls: []const []const u8) GroundResult {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var cited: u32 = 0;
    var grounded: u32 = 0;
    var seen = [_]bool{false} ** MAX_SOURCES;
    var i: usize = 0;
    while (i < md.len) {
        if (std.mem.startsWith(u8, md[i..], "[src:web]")) {
            i += "[src:web]".len;
            continue;
        }
        if (std.mem.startsWith(u8, md[i..], "request {") or std.mem.startsWith(u8, md[i..], "req={") or std.mem.startsWith(u8, md[i..], "{\"url\"") or std.mem.startsWith(u8, md[i..], "{\"query\"")) {
            const close = std.mem.indexOfScalarPos(u8, md, i, '}') orelse (md.len - 1);
            i = @min(close + 1, md.len);
            continue;
        }
        if (std.mem.startsWith(u8, md[i..], " :: ")) {
            i += 4;
            continue;
        }
        if (md[i] == '[' and i + 1 < md.len and std.ascii.isDigit(md[i + 1])) {
            var j = i + 1;
            while (j < md.len and std.ascii.isDigit(md[j])) j += 1;
            if (j < md.len and md[j] == ']' and j > i + 1) {
                const num = std.fmt.parseInt(usize, md[i + 1 .. j], 10) catch 0;
                if (num >= 1 and num <= urls.len and urls[num - 1].len > 0) {
                    cited += 1;
                    if (!seen[num - 1]) {
                        seen[num - 1] = true;
                        grounded += 1;
                    }
                    if (std.fmt.allocPrint(gpa, "[[{d}]]({s})", .{ num, urls[num - 1] })) |link| {
                        defer gpa.free(link);
                        out.appendSlice(gpa, link) catch {};
                    } else |_| {}
                }
                i = j + 1;
                continue;
            }
        }
        if (md[i] == '[') {
            if (std.mem.indexOfPos(u8, md, i, "](")) |mid| {
                if (mid - i < 200) {
                    if (std.mem.indexOfScalarPos(u8, md, mid + 2, ')')) |rb| {
                        if (isHttpUrl(md[mid + 2 .. rb])) {
                            out.appendSlice(gpa, md[i + 1 .. mid]) catch {};
                            i = rb + 1;
                            continue;
                        }
                    }
                }
            }
        }
        if (isHttpUrl(md[i..])) {
            out.appendSlice(gpa, "(source unverified)") catch {};
            i = urlEnd(md, i);
            continue;
        }
        out.append(gpa, md[i]) catch {};
        i += 1;
    }
    return .{ .out = out.toOwnedSlice(gpa) catch (gpa.dupe(u8, md) catch @constCast("")), .grounded = grounded, .cited = cited };
}

// ---------------------------------------------------------------------------
// tests — the grounding floor's pure machinery runs on fixed buffers, no Worker
// ---------------------------------------------------------------------------

test "urlEnd stops at delimiters and trims trailing punctuation" {
    const a = "https://a.example/path). tail";
    try std.testing.expectEqualStrings("https://a.example/path", a[0..urlEnd(a, 0)]);
    const b = "https://b.example/x,\nrest";
    try std.testing.expectEqualStrings("https://b.example/x", b[0..urlEnd(b, 0)]);
    const c = "https://c.example.";
    try std.testing.expectEqualStrings("https://c.example", c[0..urlEnd(c, 0)]);
}

test "buildNumberedSources numbers titles, dedups urls, and never shows the model a url" {
    const raw =
        "- First story\n" ++
        "https://one.example/a\n" ++
        "- Second story\n" ++
        "https://one.example/a\n" ++
        "https://two.example/b\n" ++
        "http://a.b\n";
    const s = buildNumberedSources(std.testing.allocator, raw);
    defer std.testing.allocator.free(s.text);
    try std.testing.expectEqual(@as(usize, 2), s.n);
    try std.testing.expectEqualStrings("https://one.example/a", s.urls[0]);
    try std.testing.expectEqualStrings("https://two.example/b", s.urls[1]);
    try std.testing.expectEqualStrings("[1] First story\n[2] (headline)\n", s.text);
    // the invariant this faculty exists for: the model-visible text carries NO urls to copy or mangle
    try std.testing.expect(std.mem.indexOf(u8, s.text, "http") == null);
}

test "resolveCitations resolves [N], drops out-of-range, and strips invented links and bare urls" {
    const urls = [_][]const u8{ "https://one.example/a", "https://two.example/b" };
    const md = "See [1] and [1]; also [2] but [7] fake. Read [my take](https://evil.example/x) at https://bare.example/y.";
    const r = resolveCitations(std.testing.allocator, md, &urls);
    defer std.testing.allocator.free(r.out);
    try std.testing.expectEqual(@as(u32, 3), r.cited);
    try std.testing.expectEqual(@as(u32, 2), r.grounded);
    try std.testing.expectEqualStrings(
        "See [[1]](https://one.example/a) and [[1]](https://one.example/a); also [[2]](https://two.example/b) but  fake. Read my take at (source unverified).",
        r.out,
    );
}

test "resolveCitations strips [src:web] markers and storage-wrapper noise" {
    const urls = [_][]const u8{"https://one.example/a"};
    const md = "[src:web]Alpha {\"url\":\"x\"} beta :: gamma [1]";
    const r = resolveCitations(std.testing.allocator, md, &urls);
    defer std.testing.allocator.free(r.out);
    try std.testing.expectEqual(@as(u32, 1), r.cited);
    try std.testing.expectEqual(@as(u32, 1), r.grounded);
    try std.testing.expectEqualStrings("Alpha  betagamma [[1]](https://one.example/a)", r.out);
}
