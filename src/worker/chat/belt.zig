//! belt — the tool belt as a MAP the model walks, not a list it is handed.
//!
//! The problem this solves is scale. A tools array is re-uploaded on every inference, and the model has to pick
//! from all of it at once. At 20 tools that is fine; at 49 a 12B model demonstrably reached for invented and
//! irrelevant verbs (the compact belt exists for exactly that); at 221 — the chat belt plus Agent Garrett's 166
//! security tools, measured 2026-10-10 on conv c6ac996e9 — it was 405 KB (~110k tokens) a call, the spend
//! ceiling tripped every three or four inferences, and even a frontier model paid for 200 tools it never touched.
//! Shrinking descriptions helps by a constant factor. Nothing flat survives the next catalogue.
//!
//! So the belt is a tree and the turn is a walk through it — a maze, in the sense Gary's maze write-up solves one:
//! the SOLVER holds the whole map and a visited grid and does plain depth-first search with backtracking; the hard
//! part was never the search, it was staying in lockstep with the server. Here the split is the same. The ENGINE
//! holds the whole map (every def, every path), the visited marks, the path stack and the set of tools currently
//! open; the MODEL has local vision only — the branches at the node it stands in, at most BRANCH_SHOW of them, each
//! a one-line use case — and does the one thing even a tiny model does reliably: pick the line that matches, go
//! deeper, back out when it was wrong. Reaching a GROUP opens it: its tools' full typed defs join the tools array
//! and are callable by name from then on. The model never remembers where it has been; the engine does.
//!
//! Three things make the walk cheap enough to be the default rather than a fallback:
//!
//!   * ENGINE HEURISTIC FIRST (the solver reads the map before the walker moves). At turn start the engine scores
//!     every group against the request with the same cue tokens the facts ledger uses and pre-opens the best one,
//!     after restoring whatever the previous turn had open — conversations stay on a topic. The common case begins
//!     with the right tools already open and pays zero navigation rounds.
//!   * AUTO-OPEN ON A KNOWN NAME (never make a walker who knows the exit walk). A call to a tool that exists in the
//!     tree but is not open opens its group AND runs the call, in that same round. A capable model that knows
//!     `browser_click` from the doctrine never pays for the map at all; the tree only ever shrinks what is
//!     ADVERTISED, never what is CALLABLE — the same contract the compact belt already relies on.
//!   * A LOST WALKER IS HANDED THE MAP. `find` is the engine's breadth-first search over the whole tree by cue —
//!     the model may ask for it any time, and after NAV_MAX navigation rounds in a row without a tool call the
//!     engine runs it unasked and opens the best match. Depth-first for the model (one branch at a time, the way
//!     a small model thinks), breadth-first for the engine (it has the map; breadth is free), best-first for the
//!     pre-walk. Dead-end memory is the visited grid: a branch the walk entered and left without using ranks
//!     last and is labelled, so the walk cannot loop.
//!
//! What the model sees per inference: the core verbs for its tier, the single navigation verb (open_tools) and
//! the OPEN_MAX most recently used groups. On the measured belt that is ~12-16 KB for a small model instead of
//! 405 KB, and the 166 security tools cost nothing until one is wanted.
//!
//! This module is the algorithm and its state, std-only and tested on the real belt shapes. Wiring (the tools
//! array rebuilt from `Walk.tools` whenever the open set changes, `open_tools` intercepted in the dispatch,
//! `autoOpen` in the unknown-name path, `save`/`start` around the turn) lives in engine.zig.

const std = @import("std");
const cctx = @import("context.zig");

/// Most branches shown at one node. Seven is the width a small model picks from reliably; a node with more
/// shows its best seven for the cue and says how many more there are (name one, or `find`).
pub const BRANCH_SHOW: usize = 7;
/// Most groups open at once. Four groups is ~30 defs — about today's compact belt — and the least recently USED
/// one closes when a fifth opens. The model is told what closed; reopening costs one round.
pub const OPEN_MAX: usize = 4;
/// Navigation rounds in a row (no tool call between them) before the engine stops letting the model wander
/// and runs `find` for it from the turn's cue.
pub const NAV_MAX: u8 = 4;
/// Matches `find` lists.
pub const FIND_TOP: usize = 5;
/// Most cue tokens read from a request for ranking.
const CUE_MAX: usize = 24;

pub const NAV_TOOL = "open_tools";

/// The one navigation verb. Deliberately a single def with three optional arguments rather than three verbs:
/// a small model that has to choose between `descend`, `search` and `back` has been handed another maze.
pub const NAV_DEF =
    \\{"type":"function","function":{"name":"open_tools","description":"Your tools are a MAP, not a list. Call this with no arguments to see the families of tools; with path (e.g. \"web\" then \"web/browser\") to walk into one and open its tools so they become callable by name; with find (a few words for what you need, e.g. \"screenshot of a page\") to search the whole map at once; with back=true to leave a branch that did not fit. If you already know a tool's name, just call it: it opens itself.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"a branch to walk into, as shown in the map (\"web\", \"web/browser\", \"..\")"},"find":{"type":"string","description":"what you need, in a few words; searches every branch"},"back":{"type":"boolean","description":"leave the current branch"}}}}}
;

/// The teaching block for the system prompt, for a turn whose belt is a map.
pub const DOCTRINE =
    "YOUR TOOLS ARE A MAP. You start with a few core tools and open_tools. When you need something you have no " ++
    "tool for, call open_tools with no arguments: it shows the families (web, build, knowledge, security, ...), " ++
    "each with one line saying what it is for. Pick the line that matches and call open_tools with its path; " ++
    "keep going one level at a time until a branch OPENS and lists tools you can call by name. If a branch does " ++
    "not fit, open_tools back=true and try another. If you know the tool's name already, just call it. Never " ++
    "say a tool is missing before you have looked at the map.";

pub const Kind = enum(u8) { family, group, tool };

/// One node of the map. Every string lives in the tree's arena, the def lines included: the tree is built once
/// a turn from belts of mixed lifetime (static constants, a discovered catalogue, plugin schemas) and must not
/// care which of them outlives it.
pub const Node = struct {
    kind: Kind,
    /// "web/browser"; "" for the root
    path: []const u8,
    /// last path segment; a tool's name
    name: []const u8,
    /// one line: what this branch is FOR
    desc: []const u8,
    /// a tool's def line (one `{"type":"function",...}` object); "" otherwise
    def: []const u8 = "",
    parent: u32,
    children: std.ArrayListUnmanaged(u32) = .empty,
    /// how many tools sit under this node, at any depth
    tool_count: u32 = 0,
};

pub const ROOT: u32 = 0;
pub const NONE: u32 = std.math.maxInt(u32);

pub const Tree = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Tree {
        var t: Tree = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        try t.nodes.append(gpa, .{ .kind = .family, .path = "", .name = "", .desc = "every tool, by what it is for", .parent = NONE });
        return t;
    }

    pub fn deinit(t: *Tree) void {
        for (t.nodes.items) |*n| n.children.deinit(t.gpa);
        t.nodes.deinit(t.gpa);
        t.arena.deinit();
    }

    /// Add every def in `defs` (comma/newline-joined `{"type":"function",...}` lines, the shape every belt in
    /// this codebase is written in) under the path `pathFor` gives its name. A def whose name cannot be read is
    /// skipped; a duplicate name keeps the first.
    pub fn addDefs(t: *Tree, defs: []const u8) !void {
        try t.addDefsFrom(defs, "", "");
    }

    /// THE COMPILER: any source's defs into the map, live. A def's path is, in order: the source's own `hints`
    /// (lines of `name=path` — an MCP server that categorizes its tools says so and the map takes its word);
    /// else, for a source with no `mount`, `pathFor` (the built-in table and the discovered families it knows);
    /// else under `mount`: a source of up to twice BRANCH_SHOW tools is one group at the mount itself, a larger
    /// one is grouped by the first `_`-separated token when at least three tools share it (`issue_*`, `wiki_*`)
    /// and the rest land in `<mount>/misc`. So an MCP server nobody wrote a table for still compiles into a
    /// walkable branch, and the better its own naming or hints, the better its branch.
    pub fn addDefsFrom(t: *Tree, defs: []const u8, mount: []const u8, hints: []const u8) !void {
        const a = t.arena.allocator();
        var prefixes: std.StringHashMapUnmanaged(u32) = .empty;
        defer prefixes.deinit(t.gpa);
        var total: usize = 0;
        if (mount.len > 0) {
            var count = std.mem.splitScalar(u8, defs, '\n');
            while (count.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r,");
                const name = defName(line) orelse continue;
                total += 1;
                const p = prefixOf(name) orelse continue;
                const slot = try prefixes.getOrPut(t.gpa, p);
                if (!slot.found_existing) slot.value_ptr.* = 0;
                slot.value_ptr.* += 1;
            }
        }
        var it = std.mem.splitScalar(u8, defs, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r,");
            if (line.len == 0) continue;
            const name = defName(line) orelse continue;
            if (t.locate(name) != null) continue;
            const path: []const u8 = hintFor(hints, name) orelse if (mount.len == 0) pathFor(name) else blk: {
                if (total <= 2 * BRANCH_SHOW) break :blk mount;
                const p = prefixOf(name) orelse break :blk try std.fmt.allocPrint(a, "{s}/misc", .{mount});
                const n = prefixes.get(p) orelse 0;
                if (n >= 3 and !std.mem.endsWith(u8, mount, p)) break :blk try std.fmt.allocPrint(a, "{s}/{s}", .{ mount, p });
                break :blk try std.fmt.allocPrint(a, "{s}/misc", .{mount});
            };
            try t.addTool(path, name, defDesc(line), line);
        }
    }

    /// Add one tool under `path` ("web/browser"), creating the branch nodes it needs.
    pub fn addTool(t: *Tree, path: []const u8, name: []const u8, desc: []const u8, def: []const u8) !void {
        const a = t.arena.allocator();
        var parent: u32 = ROOT;
        var segs = std.mem.splitScalar(u8, path, '/');
        var so_far: usize = 0;
        while (segs.next()) |seg| {
            if (seg.len == 0) continue;
            so_far += seg.len + 1;
            const sub_path = path[0..@min(path.len, so_far - 1)];
            parent = t.childNamed(parent, seg) orelse blk: {
                const idx: u32 = @intCast(t.nodes.items.len);
                try t.nodes.append(t.gpa, .{
                    .kind = .family, // becomes .group when its first tool lands
                    .path = try a.dupe(u8, sub_path),
                    .name = try a.dupe(u8, seg),
                    .desc = branchDesc(sub_path),
                    .parent = parent,
                });
                try t.nodes.items[parent].children.append(t.gpa, idx);
                break :blk idx;
            };
        }
        const owner = &t.nodes.items[parent];
        if (owner.kind == .family and parent != ROOT) owner.kind = .group;
        const tool_idx: u32 = @intCast(t.nodes.items.len);
        const d = std.mem.trim(u8, desc, " \r\n\t");
        try t.nodes.append(t.gpa, .{
            .kind = .tool,
            .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }),
            .name = try a.dupe(u8, name),
            .desc = try unescapeLine(a, firstSentence(d, 110)),
            .def = try a.dupe(u8, def), // owned: a discovered belt is freed before the turn's last inference
            .parent = parent,
        });
        try t.nodes.items[parent].children.append(t.gpa, tool_idx);
        var up = parent;
        while (up != NONE) : (up = t.nodes.items[up].parent) t.nodes.items[up].tool_count += 1;
    }

    pub fn childNamed(t: *const Tree, parent: u32, name: []const u8) ?u32 {
        for (t.nodes.items[parent].children.items) |c| if (std.mem.eql(u8, t.nodes.items[c].name, name)) return c;
        return null;
    }

    /// The node at `path` ("web/browser"), or null.
    pub fn find(t: *const Tree, path: []const u8) ?u32 {
        var at: u32 = ROOT;
        var segs = std.mem.splitScalar(u8, std.mem.trim(u8, path, " /"), '/');
        while (segs.next()) |seg| {
            if (seg.len == 0) continue;
            at = t.childNamed(at, seg) orelse return null;
        }
        return at;
    }

    /// The TOOL node named `name`, anywhere in the tree, or null.
    pub fn locate(t: *const Tree, name: []const u8) ?u32 {
        for (t.nodes.items, 0..) |n, i| if (n.kind == .tool and std.mem.eql(u8, n.name, name)) return @intCast(i);
        return null;
    }

    /// The group a tool belongs to.
    pub fn groupOf(t: *const Tree, tool: u32) u32 {
        return t.nodes.items[tool].parent;
    }

    pub fn node(t: *const Tree, i: u32) *const Node {
        return &t.nodes.items[i];
    }
};

/// The verbs a SMALL model keeps in hand without walking: enough to read, write, run, search and remember. Every
/// other verb is on the map — one pick away, and auto-opened the moment the model names it.
pub const CORE_SMALL = [_][]const u8{ "read_file", "write_file", "edit_file", "list_dir", "run_python", "web_search", "web_fetch", "recall", "observe" };

/// A turn's belt split into what rides every inference (`core`) and what the model walks (`map`). The small
/// tier keeps CORE_SMALL and walks everything else; a mid or large model keeps the whole built-in belt it reads
/// fine today and walks only the discovered families — security, cloud, plugins — which are the ones that grow
/// without bound. Both gpa-owned; `tools` advertises a core def once even when its group is open.
pub const Split = struct { core: []u8, map: []u8 };
pub fn splitBelt(gpa: std.mem.Allocator, defs: []const u8, small: bool) !Split {
    var core: std.ArrayListUnmanaged(u8) = .empty;
    errdefer core.deinit(gpa);
    var map: std.ArrayListUnmanaged(u8) = .empty;
    errdefer map.deinit(gpa);
    var it = std.mem.splitScalar(u8, defs, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r,");
        if (line.len == 0) continue;
        const name = defName(line) orelse continue;
        const in_core = if (small) blk: {
            for (CORE_SMALL) |c| if (std.mem.eql(u8, c, name)) break :blk true;
            break :blk false;
        } else !isDiscovered(name);
        const dst = if (in_core) &core else &map;
        if (dst.items.len > 0) try dst.appendSlice(gpa, ",\n");
        try dst.appendSlice(gpa, line);
    }
    return .{ .core = try core.toOwnedSlice(gpa), .map = try map.toOwnedSlice(gpa) };
}

/// A def from a family that arrives at runtime and grows without bound.
fn isDiscovered(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "security_") or std.mem.startsWith(u8, name, "cf_") or std.mem.startsWith(u8, name, "plug_");
}

/// The first `_`-separated token of a name, when there is more than one token.
fn prefixOf(name: []const u8) ?[]const u8 {
    const us = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    if (us < 2 or us + 1 >= name.len) return null;
    return name[0..us];
}

/// A source's own placement of a tool, from its hints (`name=path` lines), or null.
fn hintFor(hints: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, hints, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), name)) {
            const p = std.mem.trim(u8, line[eq + 1 ..], " /");
            if (p.len > 0) return p;
        }
    }
    return null;
}

/// A provider of defs — the built-ins, Agent Garrett, a plugin, any MCP server — as the Belt holds it.
pub const Source = struct {
    name: []const u8,
    defs: []const u8,
    mount: []const u8,
    hints: []const u8,
};

/// The DYNAMIC belt: sources attach and detach at any time, and the map is recompiled from whatever is attached.
/// Turning Agent Garrett on is `attach("garrett", defs, "", "")`; turning it off is `detach("garrett")`; a plugin
/// or an MCP server that arrives mid-session is one more `attach`, mounted wherever it belongs. The compiled tree
/// is replaced, never edited, so a turn that started on one tree walks it to the end — recompile between turns.
pub const Belt = struct {
    gpa: std.mem.Allocator,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    tree: ?Tree = null,

    pub fn init(gpa: std.mem.Allocator) Belt {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Belt) void {
        for (b.sources.items) |s| b.freeSource(s);
        b.sources.deinit(b.gpa);
        if (b.tree) |*t| t.deinit();
    }

    fn freeSource(b: *Belt, s: Source) void {
        b.gpa.free(s.name);
        b.gpa.free(s.defs);
        b.gpa.free(s.mount);
        b.gpa.free(s.hints);
    }

    /// Attach (or replace) a source. Copies everything, so the caller's buffers may go.
    pub fn attach(b: *Belt, name: []const u8, defs: []const u8, mount: []const u8, hints: []const u8) !void {
        _ = b.detach(name);
        const s: Source = .{
            .name = try b.gpa.dupe(u8, name),
            .defs = try b.gpa.dupe(u8, defs),
            .mount = try b.gpa.dupe(u8, mount),
            .hints = try b.gpa.dupe(u8, hints),
        };
        errdefer b.freeSource(s);
        try b.sources.append(b.gpa, s);
        b.invalidate();
    }

    /// Detach a source by name; true when it was attached.
    pub fn detach(b: *Belt, name: []const u8) bool {
        for (b.sources.items, 0..) |s, i| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            b.freeSource(s);
            _ = b.sources.orderedRemove(i);
            b.invalidate();
            return true;
        }
        return false;
    }

    pub fn has(b: *const Belt, name: []const u8) bool {
        for (b.sources.items) |s| if (std.mem.eql(u8, s.name, name)) return true;
        return false;
    }

    fn invalidate(b: *Belt) void {
        if (b.tree) |*t| t.deinit();
        b.tree = null;
    }

    /// The map for what is attached right now: compiled on first use after a change, cached until the next.
    pub fn compile(b: *Belt) !*const Tree {
        if (b.tree == null) {
            var t = try Tree.init(b.gpa);
            errdefer t.deinit();
            for (b.sources.items) |s| try t.addDefsFrom(s.defs, s.mount, s.hints);
            b.tree = t;
        }
        return &b.tree.?;
    }
};

/// Where a tool lives, from its name alone: the built-in table first, then the discovered families by prefix.
/// A name nothing recognises lands in "other", which the view shows like any branch — the map is never wrong,
/// only occasionally dull.
pub fn pathFor(name: []const u8) []const u8 {
    const S = struct { n: []const u8, p: []const u8 };
    const table = [_]S{
        .{ .n = "read_file", .p = "build/files" },       .{ .n = "write_file", .p = "build/files" },       .{ .n = "edit_file", .p = "build/files" },
        .{ .n = "list_dir", .p = "build/files" },        .{ .n = "delete_file", .p = "build/files" },      .{ .n = "stage_file", .p = "build/files" },
        .{ .n = "absorb", .p = "build/files" },          .{ .n = "sync_dir", .p = "build/files" },         .{ .n = "run_python", .p = "build/code" },
        .{ .n = "run_tests", .p = "build/code" },        .{ .n = "stop_process", .p = "build/code" },      .{ .n = "web_fetch", .p = "web/fetch" },
        .{ .n = "web_search", .p = "web/fetch" },        .{ .n = "fetch_json", .p = "web/fetch" },         .{ .n = "read_url", .p = "web/fetch" },
        .{ .n = "osint_scan", .p = "web/fetch" },        .{ .n = "deep_crawl", .p = "web/fetch" },         .{ .n = "recall", .p = "knowledge/memory" },
        .{ .n = "observe", .p = "knowledge/memory" },    .{ .n = "recall_hive", .p = "knowledge/memory" }, .{ .n = "read_doc", .p = "knowledge/memory" },
        .{ .n = "cast", .p = "delegate/swarm" },         .{ .n = "steer_swarm", .p = "delegate/swarm" },   .{ .n = "stop_swarm", .p = "delegate/swarm" },
        .{ .n = "answer_swarm", .p = "delegate/swarm" }, .{ .n = "open_subchat", .p = "delegate/swarm" },  .{ .n = "poll", .p = "connect/mcp" },
        .{ .n = "get_credential", .p = "connect/mcp" },
    };
    for (table) |e| if (std.mem.eql(u8, e.n, name)) return e.p;
    if (std.mem.startsWith(u8, name, "security_")) return securityPath(name["security_".len..]);
    if (std.mem.startsWith(u8, name, "plug_")) return "connect/plugins";
    if (std.mem.startsWith(u8, name, "cf_")) return "cloud";
    if (std.mem.startsWith(u8, name, "browser_")) return "web/browser";
    if (std.mem.startsWith(u8, name, "pixel_")) return "knowledge/images";
    if (std.mem.startsWith(u8, name, "mcp_")) return "connect/mcp";
    if (std.mem.startsWith(u8, name, "schedule_")) return "delegate/schedule";
    if (std.mem.startsWith(u8, name, "swarm_")) return "delegate/swarm";
    return "other";
}

fn hasAny(name: []const u8, keys: []const []const u8) bool {
    for (keys) |k| if (std.mem.indexOf(u8, name, k) != null) return true;
    return false;
}

/// Agent Garrett's catalogue, grouped by what a tool is for. Keyword rules rather than a name table, so a tool
/// the catalogue gains next month lands somewhere sensible. The `gary_` tools are the agent's own task system
/// and get their own sub-map; everything else is an evidence lookup or an operation on a target.
fn securityPath(n: []const u8) []const u8 {
    if (std.mem.startsWith(u8, n, "gary_")) {
        const g = n["gary_".len..];
        if (hasAny(g, &.{"shell"})) return "security/agent/shell";
        if (hasAny(g, &.{"traffic"})) return "security/agent/traffic";
        if (hasAny(g, &.{ "finding", "fact", "retest" })) return "security/agent/findings";
        if (hasAny(g, &.{ "asset", "company", "scope" })) return "security/agent/assets";
        if (hasAny(g, &.{ "tool", "mcp", "skill", "llm" })) return "security/agent/extend";
        if (hasAny(g, &.{ "web", "fetch" })) return "security/agent/web";
        const files = [_][]const u8{ "read", "write", "edit", "multiedit", "glob", "grep", "ls", "bash" };
        for (files) |f| if (std.mem.eql(u8, g, f)) return "security/agent/files";
        if (hasAny(g, &.{ "trace", "output", "graph", "node", "digest" })) return "security/agent/inspect";
        return "security/agent/tasks";
    }
    if (std.mem.eql(u8, n, "hash_id") or hasAny(n, &.{ "crypto", "jwt", "encode", "decode" })) return "security/decode";
    if (hasAny(n, &.{ "nvd", "epss", "kev", "cve", "cvss", "mitre", "circl", "exposure" })) return "security/intel";
    if (hasAny(n, &.{ "dns", "cert", "crtsh", "subdomain", "rdap", "asn", "cidr", "ip_geo", "tor_exit", "origin_ip", "shodan", "greynoise", "whois" })) return "security/dns-ip";
    if (hasAny(n, &.{ "email", "gravatar", "holehe", "pwned", "breach", "leak", "stealer", "paste" })) return "security/email-breach";
    if (hasAny(n, &.{ "people", "username", "github", "devto", "keybase", "phone", "image_osint", "opencorporates", "edgar" })) return "security/people";
    if (hasAny(n, &.{ "forensic", "disk_", "memory_", "pcap", "evtx", "eventlog", "artifact", "evidence", "timestamp", "timeline" })) return "security/forensics";
    if (hasAny(n, &.{"onion"})) return "security/darkweb";
    // web before malware: favicon_hash is a web fingerprint, not a hash lookup
    if (hasAny(n, &.{ "fetch", "crawl", "http", "cors", "fingerprint", "wellknown", "favicon", "urlscan", "wayback", "archive", "unshorten", "dork", "search", "typosquat", "phish" })) return "security/web";
    if (hasAny(n, &.{ "hash", "yara", "file_analyze", "reverse_analyze", "malware", "urlhaus", "ransomware", "ioc", "persistence" })) return "security/malware";
    if (hasAny(n, &.{ "nmap", "vuln", "bucket", "poc", "disclosure" })) return "security/scan";
    return "security/other";
}

/// The one line a BRANCH shows for itself — what it is for, in the user's words. A branch not listed here
/// describes itself by its tools (the view appends a sample of their names).
fn branchDesc(path: []const u8) []const u8 {
    const S = struct { p: []const u8, d: []const u8 };
    const table = [_]S{
        .{ .p = "build", .d = "make and change things in the workdir: files, code, tests" },
        .{ .p = "build/files", .d = "read, write, edit, list and delete files in the workdir" },
        .{ .p = "build/code", .d = "run Python, run the tests, stop a process" },
        .{ .p = "web", .d = "anything about a web page or site: fetch it, search the web, or drive the browser" },
        .{ .p = "web/fetch", .d = "fetch a URL's text or JSON without a browser; search the web; crawl a site" },
        .{ .p = "web/browser", .d = "drive the user's own signed-in browser: open a page, read it as numbered refs, click, type, scroll, screenshot" },
        .{ .p = "knowledge", .d = "what is already known: memory of this and earlier conversations, stored documents, attached images" },
        .{ .p = "knowledge/memory", .d = "recall and remember facts; page through a stored document" },
        .{ .p = "knowledge/images", .d = "text found inside images attached to this conversation" },
        .{ .p = "delegate", .d = "hand work to others: a swarm of minds, a side chat, a scheduled task" },
        .{ .p = "delegate/swarm", .d = "deploy, steer, question or stop a swarm; branch a sub-chat" },
        .{ .p = "delegate/schedule", .d = "create, revise, list or delete scheduled tasks" },
        .{ .p = "cloud", .d = "the user's own Cloudflare account: deploy a Worker, R2 files, D1 queries, the raw API" },
        .{ .p = "connect", .d = "other systems: MCP servers, plugins, credentials, waiting on a client" },
        .{ .p = "connect/mcp", .d = "discover and call tools on a connected MCP server; ask for a credential; wait for a client" },
        .{ .p = "connect/plugins", .d = "tools loaded from plugins" },
        .{ .p = "security", .d = "Agent Garrett, the user's own blue-team agent: threat intel, DNS and certificates, email and breach checks, people and company OSINT, malware and forensics, scanning, and its own task system" },
        .{ .p = "security/intel", .d = "vulnerability intelligence: CVE details, EPSS probability, CISA KEV status, CVSS, MITRE, exposure search" },
        .{ .p = "security/dns-ip", .d = "DNS records, certificate transparency, subdomains, RDAP and ASN registration, IP geolocation, Shodan and GreyNoise" },
        .{ .p = "security/web", .d = "a target web site: fetch, crawl, headers, CORS, tech fingerprint, .well-known, URL scans, Wayback, phishing and typosquat checks" },
        .{ .p = "security/email-breach", .d = "email security posture (SPF, DMARC, DNSSEC), breach and leak checks, pastes, stealer logs" },
        .{ .p = "security/people", .d = "OSINT on a person or company: usernames, GitHub, phone, image, corporate registries" },
        .{ .p = "security/malware", .d = "hashes, YARA, file and reverse analysis, IOC extraction, URLhaus, ransomware and persistence" },
        .{ .p = "security/forensics", .d = "disk, memory, PCAP, event-log and timeline forensics; evidence manifests; timestamps" },
        .{ .p = "security/darkweb", .d = "Tor .onion search, fetch and intel" },
        .{ .p = "security/decode", .d = "decode and encode data, identify hashes, JWTs, crypto addresses" },
        .{ .p = "security/scan", .d = "active scanning of a target in scope: nmap, vulnerability scan, buckets, CVE proof-of-concept, disclosure drafts" },
        .{ .p = "security/agent", .d = "Agent Garrett's own task system: shells, files, tasks and workers, findings, assets, traffic, extensions" },
        .{ .p = "security/agent/shell", .d = "open, drive, read and close interactive shells on the agent" },
        .{ .p = "security/agent/files", .d = "read, write, edit, search and list files on the agent" },
        .{ .p = "security/agent/tasks", .d = "spawn, steer, pause and stop the agent's tasks; set its goals, hints and constraints" },
        .{ .p = "security/agent/inspect", .d = "look inside running work: task graphs, worker traces and output, digests" },
        .{ .p = "security/agent/findings", .d = "record, list and retest findings and facts" },
        .{ .p = "security/agent/assets", .d = "assets, companies and scope on the agent's cases" },
        .{ .p = "security/agent/traffic", .d = "captured request/response traffic" },
        .{ .p = "security/agent/extend", .d = "the agent's custom tools, MCP connections and skills" },
        .{ .p = "security/agent/web", .d = "the agent's own web search and fetch" },
        .{ .p = "security/other", .d = "the rest of Agent Garrett's tools" },
        .{ .p = "other", .d = "tools no family claims" },
    };
    for (table) |e| if (std.mem.eql(u8, e.p, path)) return e.d;
    return "";
}

/// The `"name":"…"` of a def line, or null.
pub fn defName(line: []const u8) ?[]const u8 {
    const key = "\"name\":\"";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// The `"description":"…"` of a def line (raw, still JSON-escaped), or "". Every def in this codebase writes
/// `","parameters"` right after it, and a description that does not is read to its first unescaped quote.
fn defDesc(line: []const u8) []const u8 {
    const key = "\"description\":\"";
    const at = std.mem.indexOf(u8, line, key) orelse return "";
    const start = at + key.len;
    if (std.mem.indexOfPos(u8, line, start, "\",\"parameters\"")) |end| return line[start..end];
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') return line[start..i];
    }
    return "";
}

/// `s` up to and including its first sentence end, bounded by `max` bytes at a word boundary.
fn firstSentence(s: []const u8, max: usize) []const u8 {
    var i: usize = 1;
    while (i < s.len and i < max) : (i += 1) {
        if ((s[i] == ' ' or s[i] == '\\') and (s[i - 1] == '.' or s[i - 1] == '!' or s[i - 1] == '?')) return s[0..i];
    }
    if (s.len <= max) return s;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    const cut = s[0..k];
    const sp = std.mem.lastIndexOfScalar(u8, cut, ' ') orelse return cut;
    return if (sp > max / 2) cut[0..sp] else cut;
}

/// A JSON-escaped description, as plain one-line text.
fn unescapeLine(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n', 't', 'r' => try out.append(a, ' '),
                'u' => {
                    try out.append(a, '?');
                    i += @min(4, s.len - i - 1);
                },
                else => |c| try out.append(a, c),
            }
            continue;
        }
        try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

/// WHAT THE WALK LEARNS — the self-improving part. Every time a `find` or a walk ends in a call, and at the end
/// of every turn for the tools it called, the cue's words are tied to that tool. Next time, those words score
/// the tool (and so its branch) as if its own line carried them: a request the branch lines never anticipated
/// ("is example.com spoofable" → email_security) opens the right group unasked the second time it is asked, on
/// this machine, with no model call and no edit to any table. Per machine, like toolperf's learned tool
/// behaviour; serialized as `token tool count` lines; bounded, evicting the weakest edges.
pub const Learned = struct {
    pub const Edge = struct { tok: []u8, tool: []u8, n: u32 };
    pub const MAX_EDGES: usize = 2000;
    /// the most one learned edge may add to a tool's score for one cue token (a line match is worth 1)
    pub const BONUS_CAP: u32 = 3;

    gpa: std.mem.Allocator,
    edges: std.ArrayListUnmanaged(Edge) = .empty,

    pub fn init(gpa: std.mem.Allocator) Learned {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Learned) void {
        for (l.edges.items) |e| {
            l.gpa.free(e.tok);
            l.gpa.free(e.tool);
        }
        l.edges.deinit(l.gpa);
    }

    /// Tie every content word of `cue` to `tool`.
    pub fn note(l: *Learned, cue: []const u8, tool: []const u8) void {
        var buf: [CUE_MAX][]const u8 = undefined;
        const n = cctx.cueTokens(cue, &buf);
        for (buf[0..n]) |tok| l.bump(tok, tool);
    }

    fn bump(l: *Learned, tok: []const u8, tool: []const u8) void {
        for (l.edges.items) |*e| {
            if (std.ascii.eqlIgnoreCase(e.tok, tok) and std.mem.eql(u8, e.tool, tool)) {
                e.n +|= 1;
                return;
            }
        }
        if (l.edges.items.len >= MAX_EDGES) l.evictWeakest();
        const t = l.gpa.dupe(u8, tok) catch return;
        for (t) |*c| c.* = std.ascii.toLower(c.*);
        const name = l.gpa.dupe(u8, tool) catch {
            l.gpa.free(t);
            return;
        };
        l.edges.append(l.gpa, .{ .tok = t, .tool = name, .n = 1 }) catch {
            l.gpa.free(t);
            l.gpa.free(name);
        };
    }

    fn evictWeakest(l: *Learned) void {
        if (l.edges.items.len == 0) return;
        var weakest: usize = 0;
        for (l.edges.items, 0..) |e, i| if (e.n < l.edges.items[weakest].n) {
            weakest = i;
        };
        const e = l.edges.swapRemove(weakest);
        l.gpa.free(e.tok);
        l.gpa.free(e.tool);
    }

    /// What a cue token adds to `tool`'s score: how often the two were tied, capped.
    pub fn bonus(l: *const Learned, tok: []const u8, tool: []const u8) u16 {
        for (l.edges.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.tok, tok) and std.mem.eql(u8, e.tool, tool)) return @intCast(@min(e.n, BONUS_CAP));
        }
        return 0;
    }

    /// `token tool count` per line. gpa-owned.
    pub fn save(l: *const Learned, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        for (l.edges.items) |e| try out.print(gpa, "{s} {s} {d}\n", .{ e.tok, e.tool, e.n });
        return out.toOwnedSlice(gpa);
    }

    /// Read `save`'s lines back (merging into what is held). A malformed line is skipped.
    pub fn load(l: *Learned, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, " \r\t"), ' ');
            const tok = parts.next() orelse continue;
            const tool = parts.next() orelse continue;
            const n = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
            var i: u32 = 0;
            while (i < n) : (i += 1) l.bump(tok, tool);
        }
    }
};

/// How well a tool answers the cue: the number of cue tokens found in its name or its line, plus what the walk
/// has learned ties those words to it.
fn toolScore(n: *const Node, cue: []const []const u8, learned: ?*const Learned) u16 {
    var s: u16 = 0;
    for (cue) |c| {
        if (std.ascii.indexOfIgnoreCase(n.name, c) != null or std.ascii.indexOfIgnoreCase(n.desc, c) != null) s += 1;
        if (learned) |l| s += l.bonus(c, n.name);
    }
    return s;
}

/// How well a branch answers the cue: its best tool, weighted, plus a little for each tool that answers at all
/// and for its own line — so one strong match beats a dozen weak ones and a branch described in the user's
/// words ranks above one that merely contains them.
fn branchScore(t: *const Tree, idx: u32, cue: []const []const u8, learned: ?*const Learned) u16 {
    const n = t.node(idx);
    if (n.kind == .tool) return toolScore(n, cue, learned) * 3;
    var best: u16 = 0;
    var hits: u16 = 0;
    for (n.children.items) |c| {
        const s = branchScore(t, c, cue, learned);
        if (s > best) best = s;
        if (s > 0) hits += 1;
    }
    var own: u16 = 0;
    for (cue) |c| if (std.ascii.indexOfIgnoreCase(n.desc, c) != null or std.ascii.indexOfIgnoreCase(n.name, c) != null) {
        own += 2;
    };
    return best + @min(hits, 4) + own;
}

/// A turn's walk through the map: what is open, where the model stands, what it has tried and left.
pub const Walk = struct {
    gpa: std.mem.Allocator,
    tree: *const Tree,
    here: u32 = ROOT,
    /// open GROUP nodes, NONE when empty
    open: [OPEN_MAX]u32 = [_]u32{NONE} ** OPEN_MAX,
    /// the round each open group was last used (opened or called)
    stamp: [OPEN_MAX]u32 = [_]u32{0} ** OPEN_MAX,
    /// the round a group was opened, per slot — a group left before any call from it is a dead end
    opened_at: [OPEN_MAX]u32 = [_]u32{0} ** OPEN_MAX,
    /// per node: entered and left without a call from under it
    dead: std.DynamicBitSetUnmanaged,
    /// per node: viewed this turn
    seen: std.DynamicBitSetUnmanaged,
    round: u32 = 1,
    nav_streak: u8 = 0,
    /// the tools array changed since the model last saw it (the caller rebuilds)
    dirty: bool = true,
    /// the turn's cue, for the unasked `find`
    cue: []const u8 = "",
    /// the group the engine closed to make room, for the next view's note
    closed: u32 = NONE,
    /// what the walk has learned on this machine (shared across turns; the engine owns and persists it)
    learned: ?*Learned = null,
    /// the last `find` query, so the call it leads to can be learned from
    pending_find: [160]u8 = undefined,
    pending_find_len: u8 = 0,
    /// tools called this turn, for `finish`
    called: std.ArrayListUnmanaged(u32) = .empty,
    /// the always-on defs the engine advertises beside the map (see splitBelt); `tools` rides them first
    core: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, tree: *const Tree, cue: []const u8) !Walk {
        const n = tree.nodes.items.len;
        return .{
            .gpa = gpa,
            .tree = tree,
            .dead = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n),
            .seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n),
            .cue = cue,
        };
    }

    pub fn deinit(w: *Walk) void {
        w.dead.deinit(w.gpa);
        w.seen.deinit(w.gpa);
        w.called.deinit(w.gpa);
    }

    /// Turn end: what this turn asked for is tied to the tools it ended up calling, so the pre-walk opens them
    /// unasked next time the request sounds like this one. Call before `save`.
    pub fn finish(w: *Walk) void {
        const l = w.learned orelse return;
        for (w.called.items) |t| l.note(w.cue, w.tree.node(t).name);
    }

    /// Turn start: restore the previous turn's open set (`saved`, from `save`), then the engine's own read of the
    /// map — the best group for the cue is opened if anything answers it at all. No model call, no round spent.
    /// A group must answer the cue at least this well to be opened unasked: a greeting opens nothing, one weak
    /// name hit opens nothing, a branch described in the request's own words opens.
    const PREOPEN_MIN: u16 = 5;

    /// The group that best answers `cue`, when anything does — the engine's own read of the map before the
    /// walker moves (see start).
    fn bestGroup(w: *const Walk, cue: []const u8) ?u32 {
        var cue_buf: [CUE_MAX][]const u8 = undefined;
        const n = cctx.cueTokens(cue, &cue_buf);
        if (n == 0) return null;
        const toks = cue_buf[0..n];
        var best: u32 = NONE;
        var best_s: u16 = 0;
        for (w.tree.nodes.items, 0..) |node, i| {
            if (node.kind != .group) continue;
            const s = branchScore(w.tree, @intCast(i), toks, w.learned);
            if (s > best_s) {
                best_s = s;
                best = @intCast(i);
            }
        }
        return if (best_s >= PREOPEN_MIN) best else null;
    }

    pub fn start(w: *Walk, saved: []const u8) void {
        var it = std.mem.splitScalar(u8, saved, ',');
        while (it.next()) |p| {
            const path = std.mem.trim(u8, p, " \r\n\t");
            if (path.len == 0) continue;
            if (w.tree.find(path)) |idx| if (w.tree.node(idx).kind == .group) w.openGroup(idx);
        }
        if (w.bestGroup(w.cue)) |g| w.openGroup(g);
        w.dirty = true;
    }

    /// One inference happened.
    pub fn tick(w: *Walk) void {
        w.round += 1;
    }

    /// A tool was called by name: its group stays warm, the walk is no longer wandering, and if the group was
    /// not open (a name the model knew) it opens now — the caller runs the call in the same round.
    /// Returns the group's path when this call OPENED it, else null.
    pub fn noteCall(w: *Walk, name: []const u8) ?[]const u8 {
        w.nav_streak = 0;
        const tool = w.tree.locate(name) orelse return null;
        const g = w.tree.groupOf(tool);
        w.dead.unset(g);
        if (std.mem.indexOfScalar(u32, w.called.items, tool) == null) w.called.append(w.gpa, tool) catch {};
        // a find that led here taught something: those words mean this tool
        if (w.pending_find_len > 0) {
            if (w.learned) |l| l.note(w.pending_find[0..w.pending_find_len], name);
            w.pending_find_len = 0;
        }
        if (w.slotOf(g)) |s| {
            w.stamp[s] = w.round;
            return null;
        }
        w.openGroup(g);
        return w.tree.node(g).path;
    }

    /// Is this tool callable right now (open), or on the core the caller always advertises?
    pub fn isOpen(w: *const Walk, name: []const u8) bool {
        const tool = w.tree.locate(name) orelse return false;
        return w.slotOf(w.tree.groupOf(tool)) != null;
    }

    /// Does the map know this name at all (open or not)?
    pub fn knows(w: *const Walk, name: []const u8) bool {
        return w.tree.locate(name) != null;
    }

    /// The tools array body for the next inference: `core` (the caller's always-on defs, may be empty), the
    /// navigation verb, then every open group's defs, comma-joined. gpa-owned. Clears `dirty`.
    pub fn tools(w: *Walk, gpa: std.mem.Allocator, core: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        if (core.len > 0) {
            try out.appendSlice(gpa, core);
            try out.appendSlice(gpa, ",\n");
        }
        try out.appendSlice(gpa, NAV_DEF);
        for (w.open) |g| {
            if (g == NONE) continue;
            for (w.tree.node(g).children.items) |c| {
                const n = w.tree.node(c);
                if (n.kind != .tool or n.def.len == 0) continue;
                // a core tool that also sits in an open group is advertised once
                if (core.len > 0 and defNamed(core, n.name)) continue;
                try out.appendSlice(gpa, ",\n");
                try out.appendSlice(gpa, n.def);
            }
        }
        w.dirty = false;
        return out.toOwnedSlice(gpa);
    }

    /// The open set, for the next turn: group paths, comma-joined, most recently used first. gpa-owned.
    pub fn save(w: *const Walk, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var order: [OPEN_MAX]usize = undefined;
        var n: usize = 0;
        for (w.open, 0..) |g, i| if (g != NONE) {
            order[n] = i;
            n += 1;
        };
        std.mem.sort(usize, order[0..n], w, struct {
            fn lt(ww: *const Walk, a: usize, b: usize) bool {
                return ww.stamp[a] > ww.stamp[b];
            }
        }.lt);
        for (order[0..n], 0..) |s, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.appendSlice(gpa, w.tree.node(w.open[s]).path);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The open_tools verb. `args_json` is the model's argument object. Returns the text the model reads:
    /// a view of a branch, the list of tools a group opened, or a find result. gpa-owned.
    pub fn navigate(w: *Walk, gpa: std.mem.Allocator, args_json: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        const find_q = jsonStr(args_json, "find");
        const path = jsonStr(args_json, "path");
        const back = std.mem.indexOf(u8, args_json, "\"back\":true") != null;
        if (find_q.len > 0) {
            try w.renderFind(gpa, &out, find_q, false);
            return out.toOwnedSlice(gpa);
        }
        if (back or std.mem.eql(u8, path, "..")) {
            w.leave();
            try w.renderView(gpa, &out, w.here);
            return out.toOwnedSlice(gpa);
        }
        w.nav_streak += 1;
        if (w.nav_streak > NAV_MAX) {
            // lost: the engine reads the map for the model from the turn's own cue, and opens the best match
            try out.appendSlice(gpa, "(you have been walking the map for a while without calling a tool, so here is the whole map searched for what this turn is about)\n");
            try w.renderFind(gpa, &out, w.cue, true);
            w.nav_streak = 0;
            return out.toOwnedSlice(gpa);
        }
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            w.here = ROOT;
            try w.renderView(gpa, &out, ROOT);
            return out.toOwnedSlice(gpa);
        }
        const target = w.resolve(path) orelse {
            try out.print(gpa, "No branch named \"{s}\" here. ", .{path});
            try w.renderView(gpa, &out, w.here);
            return out.toOwnedSlice(gpa);
        };
        const n = w.tree.node(target);
        switch (n.kind) {
            .tool => {
                const g = w.tree.groupOf(target);
                try w.enterGroup(gpa, &out, g);
            },
            .group => try w.enterGroup(gpa, &out, target),
            .family => {
                if (w.here != target and w.here != ROOT and !isAncestor(w.tree, w.here, target)) w.markLeft(w.here);
                w.here = target;
                try w.renderView(gpa, &out, target);
            },
        }
        return out.toOwnedSlice(gpa);
    }

    // ---- internals ----

    fn slotOf(w: *const Walk, g: u32) ?usize {
        for (w.open, 0..) |o, i| if (o == g) return i;
        return null;
    }

    /// Open a group: into a free slot, else over the least recently used one (which is remembered for the view).
    fn openGroup(w: *Walk, g: u32) void {
        if (w.slotOf(g)) |s| {
            w.stamp[s] = w.round;
            return;
        }
        var slot: usize = 0;
        var found = false;
        for (w.open, 0..) |o, i| if (o == NONE) {
            slot = i;
            found = true;
            break;
        };
        if (!found) {
            slot = 0;
            for (w.stamp, 0..) |st, i| if (st < w.stamp[slot]) {
                slot = i;
            };
            w.closed = w.open[slot];
        }
        w.open[slot] = g;
        w.stamp[slot] = w.round;
        w.opened_at[slot] = w.round;
        w.seen.set(g);
        w.dead.unset(g);
        w.dirty = true;
    }

    /// Leaving `idx`: a group opened this turn and never called from is a dead end; a family whose viewed
    /// groups are all dead is dead too.
    fn markLeft(w: *Walk, idx: u32) void {
        if (idx == ROOT) return;
        const n = w.tree.node(idx);
        switch (n.kind) {
            .group => if (w.slotOf(idx)) |s| {
                if (w.stamp[s] == w.opened_at[s]) w.dead.set(idx);
            },
            .family => {
                var all_dead = true;
                var any_seen = false;
                for (n.children.items) |c| {
                    if (!w.seen.isSet(c)) continue;
                    any_seen = true;
                    if (!w.dead.isSet(c)) all_dead = false;
                }
                if (any_seen and all_dead) w.dead.set(idx);
            },
            .tool => {},
        }
    }

    fn leave(w: *Walk) void {
        w.nav_streak += 1;
        if (w.here == ROOT) return;
        w.markLeft(w.here);
        w.here = w.tree.node(w.here).parent;
        if (w.here == NONE) w.here = ROOT;
    }

    /// `path` as the model wrote it: absolute from the root, else relative to where the model stands, else a
    /// bare name anywhere under where it stands (so "browser" works from "web" and from the root).
    fn resolve(w: *const Walk, path: []const u8) ?u32 {
        const p = std.mem.trim(u8, path, " /\r\n\t");
        if (p.len == 0) return ROOT;
        if (w.tree.find(p)) |i| return i;
        if (w.here != ROOT) {
            var buf: [256]u8 = undefined;
            const joined = std.fmt.bufPrint(&buf, "{s}/{s}", .{ w.tree.node(w.here).path, p }) catch return null;
            if (w.tree.find(joined)) |i| return i;
        }
        // a bare name anywhere: the model read it off a view and dropped the prefix
        if (std.mem.indexOfScalar(u8, p, '/') == null) {
            for (w.tree.nodes.items, 0..) |n, i| if (n.kind != .tool and std.mem.eql(u8, n.name, p)) return @intCast(i);
            if (w.tree.locate(p)) |t| return t;
        }
        return null;
    }

    fn enterGroup(w: *Walk, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), g: u32) !void {
        if (w.here != g and w.here != ROOT and w.here != w.tree.node(g).parent) w.markLeft(w.here);
        w.here = g;
        w.closed = NONE;
        w.openGroup(g);
        const n = w.tree.node(g);
        try out.print(gpa, "OPENED {s} — {s}. These tools are callable by name now:\n", .{ n.path, n.desc });
        for (n.children.items) |c| {
            const tn = w.tree.node(c);
            if (tn.kind != .tool) continue;
            try out.print(gpa, "  {s} — {s}\n", .{ tn.name, tn.desc });
        }
        try w.renderOpenSet(gpa, out, g);
    }

    fn renderOpenSet(w: *Walk, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), except: u32) !void {
        var others: usize = 0;
        for (w.open) |o| if (o != NONE and o != except) {
            others += 1;
        };
        if (others > 0) {
            try out.appendSlice(gpa, "Also open: ");
            var first = true;
            for (w.open) |o| if (o != NONE and o != except) {
                if (!first) try out.appendSlice(gpa, ", ");
                first = false;
                try out.appendSlice(gpa, w.tree.node(o).path);
            };
            try out.appendSlice(gpa, ".");
        }
        const had_closed = w.closed != NONE;
        if (had_closed) {
            try out.print(gpa, " Closed to make room: {s} (reopen it with open_tools if you need it again).", .{w.tree.node(w.closed).path});
            w.closed = NONE;
        }
        if (others > 0 or had_closed) try out.append(gpa, '\n');
    }

    /// The branches at `idx`: ranked for the cue, dead ends last and labelled, at most BRANCH_SHOW.
    fn renderView(w: *Walk, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), idx: u32) !void {
        const n = w.tree.node(idx);
        w.seen.set(idx);
        if (idx == ROOT) {
            try out.appendSlice(gpa, "TOOL MAP — the families. Pick the one whose line matches what you need: open_tools path=\"<name>\".\n");
        } else {
            try out.print(gpa, "TOOL MAP — you are at: {s} ({s}). Pick a branch: open_tools path=\"<name>\".\n", .{ n.path, n.desc });
        }
        var cue_buf: [CUE_MAX][]const u8 = undefined;
        const cue_n = cctx.cueTokens(w.cue, &cue_buf);
        const cue = cue_buf[0..cue_n];
        const kids = n.children.items;
        var order = try gpa.alloc(u32, kids.len);
        defer gpa.free(order);
        var scores = try gpa.alloc(u16, w.tree.nodes.items.len);
        defer gpa.free(scores);
        for (kids, 0..) |c, i| {
            order[i] = c;
            scores[c] = if (w.dead.isSet(c)) 0 else branchScore(w.tree, c, cue, w.learned) + 1;
        }
        const Ctx = struct { scores: []u16, kids: []const u32 };
        std.mem.sort(u32, order, Ctx{ .scores = scores, .kids = kids }, struct {
            fn lt(ctx: Ctx, a: u32, b: u32) bool {
                if (ctx.scores[a] != ctx.scores[b]) return ctx.scores[a] > ctx.scores[b];
                return std.mem.indexOfScalar(u32, ctx.kids, a).? < std.mem.indexOfScalar(u32, ctx.kids, b).?;
            }
        }.lt);
        var shown: usize = 0;
        for (order) |c| {
            if (shown == BRANCH_SHOW) break;
            const cn = w.tree.node(c);
            shown += 1;
            try out.print(gpa, "  {s} — ", .{cn.name});
            if (cn.desc.len > 0) {
                try out.appendSlice(gpa, cn.desc);
            } else {
                try sampleNames(w.tree, gpa, out, c);
            }
            switch (cn.kind) {
                .tool => {},
                .group => try out.print(gpa, " ({d} tools{s})", .{ cn.tool_count, if (w.slotOf(c) != null) ", open" else "" }),
                .family => try out.print(gpa, " ({d} tools in {d} branches)", .{ cn.tool_count, cn.children.items.len }),
            }
            if (w.dead.isSet(c)) try out.appendSlice(gpa, " [looked already: nothing fit]");
            try out.append(gpa, '\n');
        }
        if (kids.len > shown) try out.print(gpa, "...and {d} more: name one, or open_tools find=\"what you need\".\n", .{kids.len - shown});
        if (idx != ROOT) try out.appendSlice(gpa, "Up one level: open_tools back=true. ");
        try out.appendSlice(gpa, "Anywhere at once: open_tools find=\"what you need\".\n");
        try w.renderOpenSet(gpa, out, NONE);
    }

    /// Breadth-first over every tool for the words in `q`: the best FIND_TOP with their paths; the best one's
    /// group is opened when there is a clear best.
    fn renderFind(w: *Walk, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), q: []const u8, unasked: bool) !void {
        var cue_buf: [CUE_MAX][]const u8 = undefined;
        const cue_n = cctx.cueTokens(q, &cue_buf);
        const cue = cue_buf[0..cue_n];
        var top: [FIND_TOP]u32 = [_]u32{NONE} ** FIND_TOP;
        var top_s: [FIND_TOP]u16 = [_]u16{0} ** FIND_TOP;
        // remember the question, so the call it leads to can be learned from (an unasked find is the turn's
        // own cue, which `finish` already ties to every call)
        if (!unasked) {
            const keep = @min(q.len, w.pending_find.len);
            @memcpy(w.pending_find[0..keep], q[0..keep]);
            w.pending_find_len = @intCast(keep);
        }
        for (w.tree.nodes.items, 0..) |n, i| {
            if (n.kind != .tool) continue;
            const s = toolScore(&n, cue, w.learned);
            if (s == 0) continue;
            var k: usize = 0;
            while (k < FIND_TOP and top[k] != NONE and top_s[k] >= s) k += 1;
            if (k == FIND_TOP) continue;
            var m: usize = FIND_TOP - 1;
            while (m > k) : (m -= 1) {
                top[m] = top[m - 1];
                top_s[m] = top_s[m - 1];
            }
            top[k] = @intCast(i);
            top_s[k] = s;
        }
        if (top[0] == NONE) {
            try out.print(gpa, "Nothing on the map matches \"{s}\". ", .{q});
            try w.renderView(gpa, out, ROOT);
            return;
        }
        try out.print(gpa, "FOUND for \"{s}\":\n", .{q});
        for (top, 0..) |t, i| {
            if (t == NONE) break;
            const n = w.tree.node(t);
            try out.print(gpa, "  {s} — {s}  (in {s})\n", .{ n.name, n.desc, w.tree.node(n.parent).path });
            _ = i;
        }
        const clear = top[1] == NONE or top_s[0] > top_s[1] or w.tree.groupOf(top[0]) == w.tree.groupOf(top[1]);
        if (clear or unasked) {
            const g = w.tree.groupOf(top[0]);
            w.here = g;
            w.closed = NONE;
            w.openGroup(g);
            try out.print(gpa, "Opened {s}: its tools are callable by name now.\n", .{w.tree.node(g).path});
            try w.renderOpenSet(gpa, out, g);
        } else {
            try out.appendSlice(gpa, "Two branches match equally. Open one: open_tools path=\"<its branch>\".\n");
        }
    }
};

fn isAncestor(t: *const Tree, maybe_ancestor: u32, idx: u32) bool {
    var up = t.node(idx).parent;
    while (up != NONE) : (up = t.node(up).parent) if (up == maybe_ancestor) return true;
    return false;
}

/// The first few tool names under a branch with no line of its own.
fn sampleNames(t: *const Tree, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), idx: u32) !void {
    var shown: usize = 0;
    var stack: [64]u32 = undefined;
    var sp: usize = 0;
    stack[sp] = idx;
    sp += 1;
    while (sp > 0 and shown < 4) {
        sp -= 1;
        const n = t.node(stack[sp]);
        if (n.kind == .tool) {
            if (shown > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, n.name);
            shown += 1;
            continue;
        }
        var i = n.children.items.len;
        while (i > 0 and sp < stack.len) : (i -= 1) {
            stack[sp] = n.children.items[i - 1];
            sp += 1;
        }
    }
    if (shown > 0 and t.node(idx).tool_count > shown) try out.appendSlice(gpa, ", ...");
}

/// Does a defs block advertise a def named `name`?
fn defNamed(defs: []const u8, name: []const u8) bool {
    var buf: [160]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"name\":\"{s}\"", .{name}) catch return false;
    return std.mem.indexOf(u8, defs, needle) != null;
}

/// The string value of `key` in a flat JSON object, raw (no unescaping — paths and queries carry none), or "".
fn jsonStr(obj: []const u8, key: []const u8) []const u8 {
    var kb: [48]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return "";
    const at = std.mem.indexOf(u8, obj, k) orelse return "";
    var i = at + k.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    if (i >= obj.len or obj[i] != '"') return "";
    i += 1;
    const start = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '\\') {
            i += 1;
            continue;
        }
        if (obj[i] == '"') return obj[start..i];
    }
    return "";
}

// ---------------------------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------------------------

const tt = std.testing;

fn fixtureDefs(gpa: std.mem.Allocator, names: []const u8, desc_prefix: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, names, " \n");
    while (it.next()) |n| {
        if (out.items.len > 0) try out.appendSlice(gpa, ",\n");
        try out.print(gpa, "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}{s}.\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}}}}}}", .{ n, desc_prefix, n });
    }
    return out.toOwnedSlice(gpa);
}

/// The chat belt as measured on conv c6ac996e9 (2026-10-10): the 55 built-in verbs a full turn advertised.
const BUILTIN_NAMES =
    "run_python stop_process write_file edit_file read_file absorb list_dir stage_file run_tests delete_file " ++
    "web_fetch web_search fetch_json read_url observe recall recall_hive read_doc poll get_credential cast " ++
    "steer_swarm stop_swarm swarm_status swarm_asks answer_swarm schedule_task schedule_update schedule_list " ++
    "schedule_delete sync_dir open_subchat browser_navigate browser_read browser_click browser_type browser_eval " ++
    "browser_click_at browser_type_text browser_key browser_scroll browser_console browser_network browser_close " ++
    "pixel_ingest pixel_capture pixel_search mcp_discover mcp_call cf_deploy_worker cf_r2_list cf_r2_put cf_r2_get " ++
    "cf_d1_query cf_api";

/// ...and Agent Garrett's 166, as the catalogue listed them that night.
const SECURITY_NAMES =
    "archive_urls artifact_carve asn_info breach_check bucket_finder cert_ct cidr circl_cve cors_check crawl " ++
    "crtsh_subs crypto_addr crypto_ctf cve_poc cve_search cvss decode devto_user disclosure_draft disk_forensics " ++
    "dns_lookup dns_records dork edgar email_forensics email_permutations email_recon email_security encode " ++
    "epss_lookup eventlog_triage evidence_manifest evtx_analyze exposure_search favicon_hash fetch_url file_analyze " ++
    "forensic_timeline forensics_triage gary_add_company_scope gary_add_hint gary_add_intent gary_add_task_hint " ++
    "gary_add_task_scope gary_bash gary_bind_finding_traffic gary_create_custom_tool gary_create_mcp " ++
    "gary_create_skill gary_delete_assets_by_host gary_edit gary_expand_digest gary_get_finding_retest_context " ++
    "gary_get_finding_traffic gary_get_task_graph gary_get_task_node_detail gary_get_task_worker_trace " ++
    "gary_get_worker_output gary_get_worker_trace gary_glob gary_goal_met gary_graph_overview gary_grep " ++
    "gary_insert_assets gary_kill_work gary_list_assets gary_list_companies gary_list_facts gary_list_findings " ++
    "gary_list_goals gary_list_llm_profiles gary_list_task_findings gary_list_task_worker_traces gary_list_tasks " ++
    "gary_list_untested_assets gary_ls gary_multiedit gary_node_detail gary_pause_task gary_prove_goal gary_read " ++
    "gary_record_fact gary_record_finding_retest_result gary_report_finding gary_search_all_worker_traces " ++
    "gary_search_task_worker_traces gary_set_constraints gary_set_goals gary_shell_close gary_shell_list " ++
    "gary_shell_open gary_shell_read gary_shell_send gary_skill gary_sleep gary_spawn_task gary_steer_work " ++
    "gary_tasklist gary_taskoutput gary_taskstop gary_todowrite gary_traffic_blob gary_traffic_get " ++
    "gary_traffic_search gary_update_custom_tool gary_update_finding_report gary_update_mcp gary_update_skill_file " ++
    "gary_web_search gary_webfetch gary_write github_osint github_user gravatar greynoise hash_id hash_lookup holehe " ++
    "http_headers image_osint ioc_extract ip_geo jwt kev_lookup kev_recent keybase leakcheck memory_forensics mitre " ++
    "nmap_scan nvd_lookup onion_fetch onion_intel onion_search opencorporates origin_ip paste_search pcap_analyze " ++
    "people_search persistence_analyze phish_check phone_osint post_malware_pipeline pwned_password " ++
    "ransomware_watch rdap_domain rdap_ip reverse_analyze reverse_dns shodan_internetdb stealer_check " ++
    "subdomain_takeover subdomains tech_fingerprint timestamp tor_exit typosquat unshorten urlhaus urlscan " ++
    "username_enum vuln_scan wayback web_search wellknown yara_scan";

fn measuredTree(gpa: std.mem.Allocator) !Tree {
    var t = try Tree.init(gpa);
    errdefer t.deinit();
    const builtin = try fixtureDefs(gpa, BUILTIN_NAMES, "built-in ");
    defer gpa.free(builtin);
    try t.addDefs(builtin);
    // the security names arrive prefixed, as garrett.renderDefs emits them
    var sec: std.ArrayListUnmanaged(u8) = .empty;
    defer sec.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, SECURITY_NAMES, " ");
    while (it.next()) |n| {
        if (sec.items.len > 0) try sec.appendSlice(gpa, ",\n");
        try sec.print(gpa, "{{\"type\":\"function\",\"function\":{{\"name\":\"security_{s}\",\"description\":\"{s}. Passive/read-only evidence lookup.\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}}}}}}", .{ n, n });
    }
    try t.addDefs(sec.items);
    return t;
}

test "the measured 221-tool belt maps into a tree a small model can walk: <= 7 families, every group bounded, nothing lost" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    const root = t.node(ROOT);
    try tt.expectEqual(@as(u32, 221), root.tool_count);
    try tt.expect(root.children.items.len <= BRANCH_SHOW); // build web knowledge delegate cloud connect security
    try tt.expect(t.find("other") == null); // every built-in has a home
    // no group is wider than a model should be shown at once, and the biggest discovered family still fans out
    var widest: usize = 0;
    var groups: usize = 0;
    for (t.nodes.items) |n| {
        if (n.kind != .group) continue;
        groups += 1;
        widest = @max(widest, n.children.items.len);
    }
    try tt.expect(groups >= 18);
    try tt.expect(widest <= 24);
    // the security catalogue: its families fan out under one head, and "other" is a corner, not a dump
    const sec = t.find("security") orelse return error.NoSecurity;
    try tt.expectEqual(@as(u32, 166), t.node(sec).tool_count);
    try tt.expect(t.node(sec).children.items.len <= 12);
    if (t.find("security/other")) |o| try tt.expect(t.node(o).tool_count <= 8);
    // paths are what the model reads back
    try tt.expectEqualStrings("web/browser", t.node(t.groupOf(t.locate("browser_click").?)).path);
    try tt.expectEqualStrings("security/intel", t.node(t.groupOf(t.locate("security_nvd_lookup").?)).path);
    try tt.expectEqualStrings("security/agent/shell", t.node(t.groupOf(t.locate("security_gary_shell_open").?)).path);
    try tt.expectEqualStrings("cloud", t.node(t.groupOf(t.locate("cf_r2_put").?)).path);
}

test "a walk from the root reaches any tool in at most three picks, each from at most seven lines" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "");
    defer w.deinit();
    const gpa = tt.allocator;
    // root: the families
    const v0 = try w.navigate(gpa, "{}");
    defer gpa.free(v0);
    try tt.expect(std.mem.startsWith(u8, v0, "TOOL MAP"));
    try tt.expect(std.mem.indexOf(u8, v0, "  security — Agent Garrett") != null);
    try tt.expect(countLines(v0, "  ") <= BRANCH_SHOW);
    // pick 1: the family
    const v1 = try w.navigate(gpa, "{\"path\":\"security\"}");
    defer gpa.free(v1);
    try tt.expect(std.mem.indexOf(u8, v1, "you are at: security") != null);
    try tt.expect(countLines(v1, "  ") <= BRANCH_SHOW);
    try tt.expect(std.mem.indexOf(u8, v1, "more: name one") != null); // 12 branches, 7 shown
    // pick 2: a bare branch name read off the view, relative to where it stands
    const v2 = try w.navigate(gpa, "{\"path\":\"intel\"}");
    defer gpa.free(v2);
    try tt.expect(std.mem.startsWith(u8, v2, "OPENED security/intel"));
    try tt.expect(std.mem.indexOf(u8, v2, "  security_nvd_lookup — ") != null);
    try tt.expect(w.isOpen("security_nvd_lookup"));
    try tt.expect(!w.isOpen("security_dns_lookup"));
    // the tools array now carries the navigation verb and exactly the opened group
    const arr = try w.tools(gpa, "");
    defer gpa.free(arr);
    try tt.expect(std.mem.indexOf(u8, arr, "\"name\":\"open_tools\"") != null);
    try tt.expect(std.mem.indexOf(u8, arr, "\"name\":\"security_nvd_lookup\"") != null);
    try tt.expect(std.mem.indexOf(u8, arr, "\"name\":\"security_dns_lookup\"") == null);
    try tt.expect(std.mem.indexOf(u8, arr, "\"name\":\"browser_click\"") == null);
    // ...and is a valid tools array
    const json = try std.fmt.allocPrint(gpa, "[{s}]", .{arr});
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try tt.expect(parsed.value.array.items.len >= 8);
}

test "a known name needs no walk: it opens its own group in the round it is called, and stays open" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "");
    defer w.deinit();
    try tt.expect(!w.isOpen("browser_click"));
    try tt.expect(w.knows("browser_click"));
    try tt.expect(!w.knows("teleport"));
    try tt.expectEqualStrings("web/browser", w.noteCall("browser_click").?);
    try tt.expect(w.isOpen("browser_click"));
    try tt.expect(w.isOpen("browser_read")); // the whole group, not the one verb
    try tt.expect(w.noteCall("browser_read") == null); // already open: nothing to report
    try tt.expect(w.dirty);
}

test "the engine reads the map first: a cue opens the right group before the first inference, and the next turn restores it" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "check the DMARC and SPF email security posture of example.com");
    defer w.deinit();
    w.start("");
    try tt.expect(w.isOpen("security_email_security"));
    const saved = try w.save(tt.allocator);
    defer tt.allocator.free(saved);
    try tt.expectEqualStrings("security/email-breach", saved);
    // a later turn on a different question restores the toolbox AND opens what the new cue wants
    var w2 = try Walk.init(tt.allocator, &t, "take a screenshot of the browser page and click the login button");
    defer w2.deinit();
    w2.start(saved);
    try tt.expect(w2.isOpen("security_email_security"));
    try tt.expect(w2.isOpen("browser_click"));
    // a cue that matches nothing opens nothing extra
    var w3 = try Walk.init(tt.allocator, &t, "hello");
    defer w3.deinit();
    w3.start("");
    const empty = try w3.save(tt.allocator);
    defer tt.allocator.free(empty);
    try tt.expectEqual(@as(usize, 0), empty.len);
}

test "find is the engine's breadth-first search: it lists the best matches with their paths and opens a clear winner" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "");
    defer w.deinit();
    const r = try w.navigate(tt.allocator, "{\"find\":\"subdomain takeover\"}");
    defer tt.allocator.free(r);
    try tt.expect(std.mem.startsWith(u8, r, "FOUND for"));
    try tt.expect(std.mem.indexOf(u8, r, "security_subdomain_takeover") != null);
    try tt.expect(std.mem.indexOf(u8, r, "(in security/dns-ip)") != null);
    try tt.expect(std.mem.indexOf(u8, r, "Opened security/dns-ip") != null);
    try tt.expect(w.isOpen("security_subdomain_takeover"));
    // nothing matching: the root map, not an error
    const none = try w.navigate(tt.allocator, "{\"find\":\"zzzz qqqq\"}");
    defer tt.allocator.free(none);
    try tt.expect(std.mem.indexOf(u8, none, "Nothing on the map matches") != null);
    try tt.expect(std.mem.indexOf(u8, none, "TOOL MAP") != null);
}

test "the open set is bounded and least-recently-used: a fifth group closes the coldest, and the model is told" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "");
    defer w.deinit();
    const gpa = tt.allocator;
    _ = w.noteCall("read_file"); // build/files
    w.tick();
    _ = w.noteCall("browser_read"); // web/browser
    w.tick();
    _ = w.noteCall("cf_api"); // cloud
    w.tick();
    _ = w.noteCall("recall"); // knowledge/memory
    w.tick();
    _ = w.noteCall("read_file"); // build/files is warm again; web/browser is now the coldest
    w.tick();
    const r = try w.navigate(gpa, "{\"path\":\"security/intel\"}");
    defer gpa.free(r);
    try tt.expect(std.mem.indexOf(u8, r, "Closed to make room: web/browser") != null);
    try tt.expect(!w.isOpen("browser_read"));
    try tt.expect(w.isOpen("read_file"));
    try tt.expect(w.isOpen("security_nvd_lookup"));
    var open: usize = 0;
    for (w.open) |o| if (o != NONE) {
        open += 1;
    };
    try tt.expectEqual(OPEN_MAX, open);
    // most recently used first in the saved order
    const saved = try w.save(gpa);
    defer gpa.free(saved);
    try tt.expect(std.mem.startsWith(u8, saved, "security/intel,"));
}

test "a branch entered and left without a call is a dead end: labelled, ranked last, and a family of dead ends is dead" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "");
    defer w.deinit();
    const gpa = tt.allocator;
    const a = try w.navigate(gpa, "{\"path\":\"web\"}");
    defer gpa.free(a);
    const b = try w.navigate(gpa, "{\"path\":\"fetch\"}"); // opens web/fetch
    defer gpa.free(b);
    try tt.expect(w.isOpen("web_fetch"));
    const c = try w.navigate(gpa, "{\"back\":true}"); // left without a call: dead
    defer gpa.free(c);
    try tt.expect(w.dead.isSet(t.find("web/fetch").?));
    try tt.expect(std.mem.indexOf(u8, c, "fetch — ") != null);
    try tt.expect(std.mem.indexOf(u8, c, "[looked already: nothing fit]") != null);
    // the live branch is listed before the dead one
    try tt.expect(std.mem.indexOf(u8, c, "  browser — ").? < std.mem.indexOf(u8, c, "  fetch — ").?);
    // a call from it brings it back to life
    _ = w.noteCall("web_fetch");
    try tt.expect(!w.dead.isSet(t.find("web/fetch").?));
}

test "a walker that wanders is handed the map: after NAV_MAX rounds without a call, find runs from the turn's cue" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "run the python tests in the workdir");
    defer w.deinit();
    const gpa = tt.allocator;
    var i: u8 = 0;
    while (i < NAV_MAX) : (i += 1) {
        const v = try w.navigate(gpa, "{\"path\":\"security\"}");
        gpa.free(v);
    }
    try tt.expect(!w.isOpen("run_tests"));
    const v = try w.navigate(gpa, "{\"path\":\"security\"}");
    defer gpa.free(v);
    try tt.expect(std.mem.indexOf(u8, v, "walking the map for a while") != null);
    try tt.expect(w.isOpen("run_tests"));
    try tt.expectEqual(@as(u8, 0), w.nav_streak);
}

test "core tools ride once, a wrong path answers with the view, and a tool named as a path opens its group" {
    var t = try measuredTree(tt.allocator);
    defer t.deinit();
    var w = try Walk.init(tt.allocator, &t, "");
    defer w.deinit();
    const gpa = tt.allocator;
    const core = try fixtureDefs(gpa, "read_file write_file", "core ");
    defer gpa.free(core);
    _ = w.noteCall("edit_file"); // opens build/files, which also holds the two core verbs
    const arr = try w.tools(gpa, core);
    defer gpa.free(arr);
    try tt.expectEqual(@as(usize, 1), std.mem.count(u8, arr, "\"name\":\"read_file\""));
    try tt.expectEqual(@as(usize, 1), std.mem.count(u8, arr, "\"name\":\"edit_file\""));
    try tt.expect(std.mem.startsWith(u8, arr, core));
    const bad = try w.navigate(gpa, "{\"path\":\"teleport\"}");
    defer gpa.free(bad);
    try tt.expect(std.mem.startsWith(u8, bad, "No branch named \"teleport\" here. TOOL MAP"));
    const via_tool = try w.navigate(gpa, "{\"path\":\"security_nvd_lookup\"}");
    defer gpa.free(via_tool);
    try tt.expect(std.mem.startsWith(u8, via_tool, "OPENED security/intel"));
}

test "the def readers cope with the real belt's shapes" {
    try tt.expectEqualStrings("read_file", defName("{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read a file.\",\"parameters\":{}}}").?);
    try tt.expect(defName("{\"type\":\"function\"}") == null);
    try tt.expectEqualStrings("Say \\\"hi\\\". Then more", defDesc("{\"name\":\"x\",\"description\":\"Say \\\"hi\\\". Then more\",\"parameters\":{}}"));
    try tt.expectEqualStrings("no params", defDesc("{\"name\":\"x\",\"description\":\"no params\"}"));
    try tt.expectEqualStrings("First one.", firstSentence("First one. Second one here.", 100));
    try tt.expectEqualStrings("web/browser", jsonStr("{\"path\": \"web/browser\"}", "path"));
    try tt.expectEqualStrings("", jsonStr("{\"back\":true}", "path"));
    const u = try unescapeLine(tt.allocator, "a \\\"b\\\"\\nc");
    defer tt.allocator.free(u);
    try tt.expectEqualStrings("a \"b\" c", u);
    // every chat belt verb has a home, so no tool a user relies on today becomes unreachable through the map
    var it = std.mem.tokenizeAny(u8, BUILTIN_NAMES, " ");
    while (it.next()) |n| try tt.expect(!std.mem.eql(u8, pathFor(n), "other"));
    try tt.expectEqualStrings("connect/plugins", pathFor("plug_jira_create_issue"));
    try tt.expectEqualStrings("other", pathFor("teleport"));
}

test "splitBelt: a small model keeps the core in hand and walks the rest; a large one walks only what grows" {
    const gpa = tt.allocator;
    const all = try fixtureDefs(gpa, BUILTIN_NAMES ++ " security_nvd_lookup plug_jira_issue", "x ");
    defer gpa.free(all);
    const small = try splitBelt(gpa, all, true);
    defer gpa.free(small.core);
    defer gpa.free(small.map);
    try tt.expectEqual(CORE_SMALL.len, std.mem.count(u8, small.core, "\"name\":\""));
    try tt.expect(std.mem.indexOf(u8, small.core, "\"name\":\"read_file\"") != null);
    try tt.expect(std.mem.indexOf(u8, small.map, "\"name\":\"read_file\"") == null);
    try tt.expect(std.mem.indexOf(u8, small.map, "\"name\":\"browser_click\"") != null);
    try tt.expectEqual(@as(usize, 55 + 2 - CORE_SMALL.len), std.mem.count(u8, small.map, "\"name\":\""));
    const large = try splitBelt(gpa, all, false);
    defer gpa.free(large.core);
    defer gpa.free(large.map);
    try tt.expectEqual(@as(usize, 55 - 6), std.mem.count(u8, large.core, "\"name\":\"")); // the six cf_ verbs walk
    try tt.expectEqual(@as(usize, 6 + 2), std.mem.count(u8, large.map, "\"name\":\""));
    try tt.expect(std.mem.indexOf(u8, large.core, "\"name\":\"browser_click\"") != null);
    try tt.expect(std.mem.indexOf(u8, large.map, "\"name\":\"security_nvd_lookup\"") != null);
    // the pieces are each a valid comma-joined defs block
    const arr = try std.fmt.allocPrint(gpa, "[{s}]", .{large.map});
    defer gpa.free(arr);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
    defer parsed.deinit();
    try tt.expectEqual(@as(usize, 8), parsed.value.array.items.len);
}

test "the belt is dynamic: a source attaches and the map recompiles with it, detaches and the map forgets it" {
    const gpa = tt.allocator;
    var b = Belt.init(gpa);
    defer b.deinit();
    const builtin = try fixtureDefs(gpa, BUILTIN_NAMES, "built-in ");
    defer gpa.free(builtin);
    try b.attach("builtin", builtin, "", "");
    const t0 = try b.compile();
    try tt.expectEqual(@as(u32, 55), t0.node(ROOT).tool_count);
    try tt.expect(t0.find("security") == null);
    // Agent Garrett switched on: its catalogue compiles into the map
    var sec: std.ArrayListUnmanaged(u8) = .empty;
    defer sec.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, SECURITY_NAMES, " ");
    while (it.next()) |n| {
        if (sec.items.len > 0) try sec.appendSlice(gpa, ",\n");
        try sec.print(gpa, "{{\"type\":\"function\",\"function\":{{\"name\":\"security_{s}\",\"description\":\"{s}.\",\"parameters\":{{}}}}}}", .{ n, n });
    }
    try b.attach("garrett", sec.items, "", "");
    try tt.expect(b.has("garrett"));
    const t1 = try b.compile();
    try tt.expectEqual(@as(u32, 221), t1.node(ROOT).tool_count);
    try tt.expect(t1.find("security/intel") != null);
    // switched off: the branch is gone and nothing else moved
    try tt.expect(b.detach("garrett"));
    try tt.expect(!b.detach("garrett"));
    const t2 = try b.compile();
    try tt.expectEqual(@as(u32, 55), t2.node(ROOT).tool_count);
    try tt.expect(t2.find("security") == null);
    try tt.expect(t2.locate("browser_click") != null);
    // the same compiled tree is handed back until something changes
    try tt.expect(@intFromPtr(try b.compile()) == @intFromPtr(t2));
}

test "an MCP server nobody wrote a table for compiles into a walkable branch: mounted, grouped by its own naming, hinted when it says so" {
    const gpa = tt.allocator;
    var b = Belt.init(gpa);
    defer b.deinit();
    // a small server is one group at its mount
    const small = try fixtureDefs(gpa, "jira_create jira_list jira_comment ping", "acme ");
    defer gpa.free(small);
    try b.attach("mcp:jira", small, "connect/jira", "");
    const t = try b.compile();
    const jira = t.find("connect/jira") orelse return error.NoMount;
    try tt.expectEqual(Kind.group, t.node(jira).kind);
    try tt.expectEqual(@as(u32, 4), t.node(jira).tool_count);
    try tt.expectEqualStrings("connect/jira", t.node(t.groupOf(t.locate("ping").?)).path);
    // a big server groups by the first token where three or more share it; strays go to misc; a hint wins outright
    const big = try fixtureDefs(gpa, "issue_create issue_list issue_comment issue_close wiki_read wiki_write wiki_search cal_today cal_free cal_book cal_cancel ping status whoami version", "acme ");
    defer gpa.free(big);
    try b.attach("mcp:acme", big, "connect/acme", "wiki_search=knowledge/search\n");
    const t2 = try b.compile();
    try tt.expectEqualStrings("connect/acme/issue", t2.node(t2.groupOf(t2.locate("issue_close").?)).path);
    try tt.expectEqualStrings("connect/acme/cal", t2.node(t2.groupOf(t2.locate("cal_book").?)).path);
    try tt.expectEqualStrings("connect/acme/misc", t2.node(t2.groupOf(t2.locate("whoami").?)).path);
    try tt.expectEqualStrings("knowledge/search", t2.node(t2.groupOf(t2.locate("wiki_search").?)).path);
    try tt.expectEqualStrings("connect/acme/wiki", t2.node(t2.groupOf(t2.locate("wiki_read").?)).path);
    // a duplicate name across sources keeps the first (acme's `ping` is jira's), one tool was hinted elsewhere
    try tt.expectEqual(@as(u32, 4 + 15 - 1 - 1), t2.node(t2.find("connect").?).tool_count);
    try tt.expectEqualStrings("connect/jira", t2.node(t2.groupOf(t2.locate("ping").?)).path);
    var w = try Walk.init(gpa, t2, "");
    defer w.deinit();
    const v = try w.navigate(gpa, "{\"path\":\"connect/acme\"}");
    defer gpa.free(v);
    try tt.expect(std.mem.indexOf(u8, v, "you are at: connect/acme") != null);
    try tt.expect(std.mem.indexOf(u8, v, "  issue — ") != null);
    try tt.expect(std.mem.indexOf(u8, v, "issue_create") != null); // no line of its own: it shows its tools
}

test "the walk learns: a find that led to a call, and a turn's calls, teach the pre-walk to open the right group unasked" {
    const gpa = tt.allocator;
    var t = try measuredTree(gpa);
    defer t.deinit();
    var learned = Learned.init(gpa);
    defer learned.deinit();
    // a request no branch line anticipates opens nothing...
    var w0 = try Walk.init(gpa, &t, "is example.com spoofable");
    defer w0.deinit();
    w0.learned = &learned;
    w0.start("");
    try tt.expect(!w0.isOpen("security_email_security"));
    // ...the model finds its way and calls the tool; the turn ends
    const f = try w0.navigate(gpa, "{\"find\":\"email security posture\"}");
    defer gpa.free(f);
    try tt.expect(w0.isOpen("security_email_security"));
    _ = w0.noteCall("security_email_security");
    w0.finish();
    try tt.expect(learned.bonus("spoofable", "security_email_security") > 0); // the turn's words
    try tt.expect(learned.bonus("posture", "security_email_security") > 0); // the find's words
    try tt.expectEqual(@as(u16, 0), learned.bonus("spoofable", "security_nvd_lookup"));
    // next time the same question is asked, the engine opens the group before the first inference
    var w1 = try Walk.init(gpa, &t, "is example.com spoofable");
    defer w1.deinit();
    w1.learned = &learned;
    w1.start("");
    try tt.expect(w1.isOpen("security_email_security"));
    // what was learned survives a restart, and the bonus is capped so one habit cannot drown the map
    const text = try learned.save(gpa);
    defer gpa.free(text);
    try tt.expect(std.mem.indexOf(u8, text, "spoofable security_email_security 1\n") != null);
    var again = Learned.init(gpa);
    defer again.deinit();
    again.load(text);
    again.load(text);
    again.load(text);
    again.load(text);
    try tt.expectEqual(@as(u16, Learned.BONUS_CAP), again.bonus("spoofable", "security_email_security"));
    again.load("malformed line without enough fields\n\n");
}

fn countLines(text: []const u8, prefix: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, prefix)) {
        n += 1;
    };
    return n;
}
