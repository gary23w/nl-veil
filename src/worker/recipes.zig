//! Recipe tools: an ADMIN authors a named SEQUENCE OF STEPS over tools a user is ALREADY allowed to run, and
//! grants specific users access to run it by name. A recipe is DATA — never host code. This module is the DATA
//! half: parse a recipe file, validate it, render its OpenAI function schema, and substitute a call's inputs
//! and prior step results into a step's args. It holds NO execution loop.
//!
//! Why the loop lives in tools.zig, not here: a recipe runs each step by calling tools.execute() recursively,
//! so every step re-hits the ONE sandbox gate under the caller's OWN caps (an admin-authored `run_python` step
//! is refused when a sandboxed grantee runs it — that is the whole safety property, and it is enforced at RUN
//! time). Putting the loop here would need tools.zig; tools.zig needs this module; that is an import cycle. So
//! this file stays pure: bytes in, parsed/validated/rendered data out. The caller in tools.zig owns the gate,
//! the recursion, the depth cap, and the authored-name collision guard (a check that needs the per-caller Mem
//! db, which this global, db-less loader cannot see — see loadDir's doc for the split).
//!
//! The injection surface is substitute(): a step's args template is filled with untrusted call inputs. Every
//! substituted value is JSON-string-ESCAPED and spliced only INSIDE a string VALUE, so a value carrying a quote,
//! a backslash, or a newline cannot break the args JSON or inject a new argument. That escaping is the point of
//! this module; the test at the bottom feeds it `he said "hi"` and asserts the result still parses.
const std = @import("std");

const log = std.log.scoped(.recipes);

/// Belt-and-braces bounds. The real depth safety (no recipe-calls-recipe, one level) is enforced at RUN time in
/// tools.zig; these keep a hand-edited file from carrying an absurd number of steps/params into the registry.
pub const MAX_STEPS = 32;
pub const MAX_PARAMS = 24;
pub const MAX_NAME = 64;

/// One step: run `tool` with `args_json` as its arguments. `args_json` is the COMPACT, re-serialized template
/// (loadDir normalizes it through std.json so whitespace/ordering are stable) — substitute() fills its `{{…}}`
/// tokens at run time. `id` is how a later step (and `output`) refers to this step's result.
pub const Step = struct {
    id: []const u8,
    tool: []const u8,
    args_json: []const u8,
};

/// One declared input. `ptype` is the JSON-schema type advertised to the model (schemaFor normalizes anything
/// unrecognised to "string"). Named `ptype` because `type` is a Zig keyword.
pub const Param = struct {
    name: []const u8,
    ptype: []const u8,
    desc: []const u8,
};

/// A parsed recipe. Every slice is owned by the Registry's arena (see Registry) and is valid exactly as long as
/// that Registry lives — get() hands out `*const Recipe` into that arena.
pub const Recipe = struct {
    name: []const u8,
    description: []const u8,
    owner_uid: u64,
    params: []Param,
    steps: []Step,
    /// Step id whose result is the tool's return. "" ⇒ default to the last step — resolve via outputStepId().
    output: []const u8,

    /// The step id whose result this recipe returns: the authored `output`, or the last step when unset.
    pub fn outputStepId(self: *const Recipe) []const u8 {
        if (self.output.len > 0) return self.output;
        if (self.steps.len == 0) return "";
        return self.steps[self.steps.len - 1].id;
    }
};

/// A resolved token binding for substitute(): `name` is the bare token (a param name or a prior step id),
/// `value` is the raw (unescaped) string to splice in. The caller in tools.zig builds two of these lists — the
/// call's inputs and the prior steps' results — and substitute escapes each value as it splices it.
pub const Binding = struct { name: []const u8, value: []const u8 };

/// The parsed recipe set, loaded from a directory of *.json files.
///
/// OWNERSHIP: the Registry owns an ArenaAllocator (child = the gpa passed to loadDir). EVERY byte of every
/// parsed recipe — names, descriptions, params, step args — is allocated from that arena. There is nothing to
/// free per-recipe; deinit() drops the whole arena at once. get() returns pointers INTO the arena, so they stay
/// valid until deinit().
///
/// RELOAD: recipes are files, so a reload is simply a fresh loadDir() building a NEW Registry. The owner swaps
/// the new one in and deinit()s the OLD one — but only once no in-flight turn still holds a `*const Recipe` from
/// it (grants, and the schemas derived from them, are resolved ONCE per turn, so the swap is safe at a turn
/// boundary). Never deinit a Registry a live turn is still reading.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    recipes: []Recipe = &.{},

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    pub fn count(self: *const Registry) usize {
        return self.recipes.len;
    }

    /// The recipe named `name`, or null. Pointer is arena-stable for the Registry's lifetime.
    pub fn get(self: *const Registry, name: []const u8) ?*const Recipe {
        for (self.recipes) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }
};

/// Errors parseBytes can reject a file with. loadDir turns each into a skip+log line — one bad file never
/// stops the others loading, and never crashes.
pub const LoadError = error{
    BadJson,
    BadName,
    CollidesBuiltin,
    Duplicate,
    NoSteps,
    TooManySteps,
    TooManyParams,
    BadStep,
    BadArgs,
} || std.mem.Allocator.Error;

/// A recipe name must be unique and `[a-z0-9_]` — the same shape a tool name takes, so a recipe can be routed by
/// exact-match like any built-in and can never carry path/escape characters.
fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_NAME) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Parse ONE recipe's bytes into an arena-owned Recipe, or reject it. `scratch` backs the transient JSON parse
/// (freed before return); `arena` holds everything the returned Recipe points at. `existing` is the recipes
/// already loaded from this dir, for the duplicate-name check. `isBuiltin` refuses a name that would shadow a
/// built-in tool (I1). Kept separate from loadDir so it is testable without touching the filesystem.
fn parseBytes(
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    raw: []const u8,
    isBuiltin: *const fn ([]const u8) bool,
    existing: []const Recipe,
) LoadError!Recipe {
    // The on-disk shape. `@"type"` because the JSON key is "type", a Zig keyword. A missing step `args` parses
    // to .null and is normalized to an empty object below.
    const FileParam = struct { name: []const u8 = "", @"type": []const u8 = "string", description: []const u8 = "" };
    const FileStep = struct { id: []const u8 = "", tool: []const u8 = "", args: std.json.Value = .null };
    const FileRecipe = struct {
        name: []const u8 = "",
        description: []const u8 = "",
        owner_uid: u64 = 0,
        params: []FileParam = &.{},
        steps: []FileStep = &.{},
        output: []const u8 = "",
    };

    const parsed = std.json.parseFromSlice(FileRecipe, scratch, raw, .{ .ignore_unknown_fields = true }) catch
        return error.BadJson;
    defer parsed.deinit(); // all dupes below happen BEFORE this runs, so the arena copy outlives the parse
    const fr = parsed.value;

    if (!validName(fr.name)) return error.BadName;
    if (isBuiltin(fr.name)) return error.CollidesBuiltin; // a recipe may never shadow a built-in (I1)
    for (existing) |e| if (std.mem.eql(u8, e.name, fr.name)) return error.Duplicate;
    if (fr.steps.len == 0) return error.NoSteps;
    if (fr.steps.len > MAX_STEPS) return error.TooManySteps;
    if (fr.params.len > MAX_PARAMS) return error.TooManyParams;

    const params = try arena.alloc(Param, fr.params.len);
    for (fr.params, 0..) |p, i| {
        params[i] = .{
            .name = try arena.dupe(u8, p.name),
            .ptype = try arena.dupe(u8, if (p.@"type".len > 0) p.@"type" else "string"),
            .desc = try arena.dupe(u8, p.description),
        };
    }

    const steps = try arena.alloc(Step, fr.steps.len);
    for (fr.steps, 0..) |s, i| {
        if (s.id.len == 0 or s.tool.len == 0) return error.BadStep;
        // Re-serialize the args object to compact JSON in the arena. This validates it, strips whitespace, and
        // gives substitute() a stable byte layout to scan. A missing args ⇒ empty object.
        const args_json = switch (s.args) {
            .null => try arena.dupe(u8, "{}"),
            else => std.json.Stringify.valueAlloc(arena, s.args, .{}) catch return error.BadArgs,
        };
        steps[i] = .{
            .id = try arena.dupe(u8, s.id),
            .tool = try arena.dupe(u8, s.tool),
            .args_json = args_json,
        };
    }

    return .{
        .name = try arena.dupe(u8, fr.name),
        .description = try arena.dupe(u8, fr.description),
        .owner_uid = fr.owner_uid,
        .params = params,
        .steps = steps,
        .output = try arena.dupe(u8, fr.output),
    };
}

/// Parse every `{dir}/*.json` into a fresh Registry. A malformed file, a bad/duplicate/built-in-colliding name,
/// or an unreadable file is SKIPPED with a log line — never a crash, never a half-loaded recipe. A missing dir
/// is an empty registry (recipes are opt-in), not an error.
///
/// `isBuiltin` is passed in (rather than importing tools.zig — that would re-introduce the cycle) so a recipe
/// that would shadow a built-in is refused at load. The OTHER collision — a make_tool authored name — cannot be
/// checked here: authored tools live in a per-caller Mem db this global loader has no handle to. That guard is
/// the caller's, at RUN time in tools.zig: dispatch built-ins first, recipes next (returning before the
/// runAuthored fallthrough), so a recipe can neither shadow nor be shadowed by an authored body.
pub fn loadDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    isBuiltin: *const fn ([]const u8) bool,
) Registry {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var list: std.ArrayListUnmanaged(Recipe) = .empty;

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        return .{ .arena = arena, .recipes = &.{} };
    };
    defer d.close(io);

    var it = d.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, ent.name }) catch continue;
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 10)) catch |e| {
            log.warn("recipe {s}: unreadable, skipped ({s})", .{ ent.name, @errorName(e) });
            continue;
        };
        defer gpa.free(raw);
        const rec = parseBytes(gpa, a, raw, isBuiltin, list.items) catch |e| {
            log.warn("recipe {s}: skipped ({s})", .{ ent.name, @errorName(e) });
            continue;
        };
        list.append(a, rec) catch continue;
    }

    // Do ALL arena allocation (incl. toOwnedSlice) BEFORE snapshotting `arena` into the returned struct — the
    // ArenaAllocator's state advances on every alloc, so copying it after a later alloc would leave the copy
    // pointing at stale internal bookkeeping.
    const items = list.toOwnedSlice(a) catch list.items;
    return .{ .arena = arena, .recipes = items };
}

// ---- schema rendering ---------------------------------------------------------------------------------------

/// Map an authored param type onto a JSON-schema type the model's function-calling understands. Anything
/// unrecognised is advertised as "string" — a recipe param is a template token, and a token is always spliced
/// as text, so "string" is the honest and safe default.
fn schemaType(t: []const u8) []const u8 {
    const known = [_][]const u8{ "string", "number", "integer", "boolean", "array", "object" };
    for (known) |k| if (std.mem.eql(u8, k, t)) return k;
    return "string";
}

/// One OpenAI function-def line for `rec`, gpa-owned (caller frees). Same shape every tool schema in this
/// codebase uses, so the granted recipes advertise identically to built-ins. All params are marked required —
/// a recipe's template expects each token to resolve; an absent one would silently blank a step's arg.
pub fn schemaFor(gpa: std.mem.Allocator, rec: Recipe) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    build(gpa, &out, rec) catch return dupe(gpa, "");
    return out.toOwnedSlice(gpa) catch dupe(gpa, "");
}

fn build(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rec: Recipe) !void {
    try out.appendSlice(gpa, "{\"type\":\"function\",\"function\":{\"name\":");
    try jstr(gpa, out, rec.name);
    try out.appendSlice(gpa, ",\"description\":");
    try jstr(gpa, out, rec.description);
    try out.appendSlice(gpa, ",\"parameters\":{\"type\":\"object\",\"properties\":{");
    for (rec.params, 0..) |p, i| {
        if (i > 0) try out.append(gpa, ',');
        try jstr(gpa, out, p.name);
        try out.appendSlice(gpa, ":{\"type\":");
        try jstr(gpa, out, schemaType(p.ptype));
        try out.appendSlice(gpa, ",\"description\":");
        try jstr(gpa, out, p.desc);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, "},\"required\":[");
    for (rec.params, 0..) |p, i| {
        if (i > 0) try out.append(gpa, ',');
        try jstr(gpa, out, p.name);
    }
    try out.appendSlice(gpa, "]}}}");
}

// ---- author-time validation ---------------------------------------------------------------------------------

/// Human-readable validation of `rec`, gpa-owned (caller frees WHEN result.len > 0; a clean recipe returns the
/// static "" — do not free that). Lines are newline-separated and prefixed:
///   "ERROR: …"   — the caller MUST block the save (name collision / bad name / no steps / over the step cap).
///   "WARNING: …" — advisory (I7): a step tool that is host-reaching or not a built-in still saves, but will be
///                  refused for non-admin grantees (I4) or, if it names another recipe, refused outright (I5).
/// The SECURITY is I4 (the run-time gate), not this text — this only tells the author what will happen.
pub fn validate(
    gpa: std.mem.Allocator,
    rec: Recipe,
    isBuiltin: *const fn ([]const u8) bool,
    isSandbox: *const fn ([]const u8) bool,
) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;

    if (!validName(rec.name)) {
        out.print(gpa, "ERROR: name '{s}' is not a valid recipe name (need [a-z0-9_], 1..{d} chars)\n", .{ rec.name, MAX_NAME }) catch {};
    } else if (isBuiltin(rec.name)) {
        out.print(gpa, "ERROR: name '{s}' collides with a built-in tool — a recipe may not shadow one\n", .{rec.name}) catch {};
    }
    if (rec.steps.len == 0) out.appendSlice(gpa, "ERROR: recipe has no steps\n") catch {};
    if (rec.steps.len > MAX_STEPS) out.print(gpa, "ERROR: {d} steps exceeds the cap of {d}\n", .{ rec.steps.len, MAX_STEPS }) catch {};

    for (rec.steps) |s| {
        if (std.mem.eql(u8, s.tool, rec.name)) {
            out.print(gpa, "WARNING: step '{s}' calls the recipe itself — a recipe step may not call a recipe; it is refused at run time (I5)\n", .{s.id}) catch {};
        } else if (!isBuiltin(s.tool)) {
            out.print(gpa, "WARNING: step '{s}' tool '{s}' is not a built-in tool (an unknown tool, or another recipe) — a recipe step may not call a recipe; refused at run time (I5)\n", .{ s.id, s.tool }) catch {};
        } else if (!isSandbox(s.tool)) {
            out.print(gpa, "WARNING: step '{s}' tool '{s}' is not sandbox-allowed — it will be REFUSED for non-admin grantees at run time (I4/I7)\n", .{ s.id, s.tool }) catch {};
        }
    }

    if (rec.output.len > 0) {
        var found = false;
        for (rec.steps) |s| {
            if (std.mem.eql(u8, s.id, rec.output)) {
                found = true;
                break;
            }
        }
        if (!found) out.print(gpa, "WARNING: output '{s}' names no step — the last step's result is returned instead\n", .{rec.output}) catch {};
    }

    if (out.items.len == 0) {
        out.deinit(gpa);
        return "";
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return "";
    };
}

// ---- substitution (I6) --------------------------------------------------------------------------------------

/// Fill a step's args template: `{{name}}` tokens inside STRING VALUES are replaced by the matching binding's
/// value, JSON-string-escaped as it is spliced. Returns gpa-owned bytes (caller frees). Resolution checks
/// `params` first, then `step_results`; an unknown token substitutes EMPTY; a malformed `{{` with no closing
/// `}}` is emitted literally. It never crashes — on OOM it falls back to a verbatim copy of the template.
///
/// Only string VALUES are touched: object KEYS and any non-string leaf (number/bool/null) are copied verbatim,
/// so a token can never land in a structural position and produce invalid JSON. And because every spliced value
/// is escaped, a value containing `"`, `\`, or a newline can neither break out of its string nor inject a new
/// argument — that is the security property this function exists for.
pub fn substitute(
    gpa: std.mem.Allocator,
    step_args_json: []const u8,
    params_kv: []const Binding,
    step_results_kv: []const Binding,
) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    scan(gpa, &out, step_args_json, params_kv, step_results_kv) catch {
        out.deinit(gpa);
        return dupe(gpa, step_args_json);
    };
    return out.toOwnedSlice(gpa) catch dupe(gpa, step_args_json);
}

/// Walk the template, copying non-string bytes verbatim and handing each string's BODY to fill()/verbatim. A
/// string is classified KEY (copied verbatim) vs VALUE (substituted) by peeking past its closing quote for a
/// `:` — in JSON only an object key is followed by one.
fn scan(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tmpl: []const u8,
    params: []const Binding,
    steps: []const Binding,
) !void {
    var i: usize = 0;
    while (i < tmpl.len) {
        const c = tmpl[i];
        if (c != '"') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        // Find the matching closing quote, honoring backslash escapes.
        var j = i + 1;
        while (j < tmpl.len) : (j += 1) {
            if (tmpl[j] == '\\') {
                j += 1; // skip the escaped char
                continue;
            }
            if (tmpl[j] == '"') break;
        }
        const end = if (j < tmpl.len) j else tmpl.len; // tolerate an unterminated string (never crash)
        const body = tmpl[i + 1 .. end];

        const is_key = blk: {
            if (j >= tmpl.len) break :blk false;
            var k = j + 1;
            while (k < tmpl.len and (tmpl[k] == ' ' or tmpl[k] == '\t' or tmpl[k] == '\n' or tmpl[k] == '\r')) k += 1;
            break :blk (k < tmpl.len and tmpl[k] == ':');
        };

        try out.append(gpa, '"');
        if (is_key) {
            try out.appendSlice(gpa, body);
        } else {
            try fill(gpa, out, body, params, steps);
        }
        if (j < tmpl.len) {
            try out.append(gpa, '"');
            i = j + 1;
        } else {
            i = end;
        }
    }
}

/// Substitute `{{token}}` occurrences within one already-escaped string body. Bytes between tokens are copied
/// verbatim (they are valid JSON string content); each token is replaced by its escaped resolved value.
fn fill(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    body: []const u8,
    params: []const Binding,
    steps: []const Binding,
) !void {
    var i: usize = 0;
    while (i < body.len) {
        if (i + 1 < body.len and body[i] == '{' and body[i + 1] == '{') {
            const rest = body[i + 2 ..];
            if (std.mem.indexOf(u8, rest, "}}")) |rel| {
                const name = rest[0..rel];
                if (validToken(name)) {
                    if (resolve(name, params, steps)) |v| try escInto(gpa, out, v); // unknown ⇒ append nothing
                    i += 2 + rel + 2; // consume `{{name}}`
                    continue;
                }
                // `{{…}}` with a non-token payload: emit the literal `{{` and keep scanning the rest as content.
                try out.appendSlice(gpa, "{{");
                i += 2;
                continue;
            }
            // No closing `}}`: emit `{{` literally, continue.
            try out.appendSlice(gpa, "{{");
            i += 2;
            continue;
        }
        try out.append(gpa, body[i]);
        i += 1;
    }
}

/// A token name is the same charset as a param name / step id, but tolerant of uppercase so a mixed-case
/// author token still resolves (against the exact binding names) rather than being emitted literally.
fn validToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Params win over step results (a call input shadows a same-named step). Unknown ⇒ null ⇒ empty splice.
fn resolve(name: []const u8, params: []const Binding, steps: []const Binding) ?[]const u8 {
    for (params) |b| if (std.mem.eql(u8, b.name, name)) return b.value;
    for (steps) |b| if (std.mem.eql(u8, b.name, name)) return b.value;
    return null;
}

// ---- JSON string escaping -----------------------------------------------------------------------------------

/// Append `s` as an escaped JSON string BODY (no surrounding quotes). Mirrors the codebase's llm.jstr escaping:
/// the JSON-mandatory escapes, control chars as \uXXXX, and invalid UTF-8 replaced with U+FFFD so the output is
/// always well-formed. This is what makes a hostile substituted value unable to break the args JSON.
fn escInto(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try out.appendSlice(gpa, "\\\""),
                '\\' => try out.appendSlice(gpa, "\\\\"),
                '\n' => try out.appendSlice(gpa, "\\n"),
                '\r' => try out.appendSlice(gpa, "\\r"),
                '\t' => try out.appendSlice(gpa, "\\t"),
                else => if (c < 0x20) {
                    var b: [8]u8 = undefined;
                    try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
                } else try out.append(gpa, c),
            }
            i += 1;
            continue;
        }
        if (std.unicode.utf8ByteSequenceLength(c)) |len| {
            if (i + len <= s.len) {
                if (std.unicode.utf8Decode(s[i .. i + len])) |_| {
                    try out.appendSlice(gpa, s[i .. i + len]);
                    i += len;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        try out.appendSlice(gpa, "\u{FFFD}");
        i += 1;
    }
}

/// A full JSON string literal (quotes + escaped body).
fn jstr(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    try escInto(gpa, out, s);
    try out.append(gpa, '"');
}

/// gpa-owned copy; OOM degrades to a freeable zero-length slice (matches tools.zig's dupe contract).
fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast(s[0..0]);
}

// ---- tests --------------------------------------------------------------------------------------------------

fn tBuiltin(n: []const u8) bool {
    const b = [_][]const u8{ "web_search", "write_file", "read_file", "run_python" };
    for (b) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

fn tSandbox(n: []const u8) bool {
    // run_python is a built-in but NOT sandbox-allowed — the case validate warns about.
    const b = [_][]const u8{ "web_search", "write_file", "read_file" };
    for (b) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

test "parseBytes: a good recipe round-trips (name, params, normalized args, output default)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw =
        \\{ "name":"research_brief", "description":"Search a topic and write a cited brief.",
        \\  "owner_uid": 7,
        \\  "params":[{"name":"topic","type":"string","description":"what to research"}],
        \\  "steps":[
        \\    {"id":"search","tool":"web_search","args":{"query":"{{topic}}"}},
        \\    {"id":"write","tool":"write_file","args":{"path":"brief.md","content":"# {{topic}}\n\n{{search}}"}}
        \\  ] }
    ;
    const rec = try parseBytes(std.testing.allocator, arena.allocator(), raw, &tBuiltin, &.{});
    try std.testing.expectEqualStrings("research_brief", rec.name);
    try std.testing.expectEqual(@as(u64, 7), rec.owner_uid);
    try std.testing.expectEqual(@as(usize, 1), rec.params.len);
    try std.testing.expectEqualStrings("topic", rec.params[0].name);
    try std.testing.expectEqual(@as(usize, 2), rec.steps.len);
    try std.testing.expectEqualStrings("web_search", rec.steps[0].tool);
    // args re-serialized compact:
    try std.testing.expectEqualStrings("{\"query\":\"{{topic}}\"}", rec.steps[0].args_json);
    // no explicit output ⇒ last step id:
    try std.testing.expectEqualStrings("write", rec.outputStepId());
}

test "parseBytes: a name colliding with a built-in is rejected; a duplicate is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const collide =
        \\{"name":"write_file","description":"x","steps":[{"id":"a","tool":"web_search","args":{}}]}
    ;
    try std.testing.expectError(error.CollidesBuiltin, parseBytes(std.testing.allocator, arena.allocator(), collide, &tBuiltin, &.{}));

    // duplicate against an already-loaded recipe of the same name
    const good =
        \\{"name":"brief","description":"x","steps":[{"id":"a","tool":"web_search","args":{}}]}
    ;
    const first = try parseBytes(std.testing.allocator, arena.allocator(), good, &tBuiltin, &.{});
    const existing = [_]Recipe{first};
    try std.testing.expectError(error.Duplicate, parseBytes(std.testing.allocator, arena.allocator(), good, &tBuiltin, &existing));
}

test "parseBytes: a wrong-shaped json file is skipped (BadJson), a stepless recipe is NoSteps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadJson, parseBytes(std.testing.allocator, arena.allocator(), "{ this is not json", &tBuiltin, &.{}));
    const stepless =
        \\{"name":"empty","description":"x","steps":[]}
    ;
    try std.testing.expectError(error.NoSteps, parseBytes(std.testing.allocator, arena.allocator(), stepless, &tBuiltin, &.{}));
    const badname =
        \\{"name":"Bad Name!","description":"x","steps":[{"id":"a","tool":"web_search","args":{}}]}
    ;
    try std.testing.expectError(error.BadName, parseBytes(std.testing.allocator, arena.allocator(), badname, &tBuiltin, &.{}));
}

test "substitute: a hostile value is JSON-escaped and cannot break the JSON or inject an arg" {
    const gpa = std.testing.allocator;
    const hostile = "he said \"hi\"\n\\"; // a quote, a newline, and a backslash
    const params = [_]Binding{.{ .name = "topic", .value = hostile }};
    const tmpl = "{\"content\":\"# {{topic}}\"}";
    const outb = substitute(gpa, tmpl, &params, &.{});
    defer gpa.free(outb);

    // STRICT parse (unknown fields NOT ignored): succeeds ⇒ valid JSON AND no injected field.
    const P = struct { content: []const u8 };
    const parsed = try std.json.parseFromSlice(P, gpa, outb, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("# " ++ hostile, parsed.value.content);
}

test "substitute: keys are not substituted; unknown token ⇒ empty; params shadow step results" {
    const gpa = std.testing.allocator;

    // a token in KEY position is left literal (values only)
    {
        const outb = substitute(gpa, "{\"{{topic}}\":\"x\"}", &.{}, &.{});
        defer gpa.free(outb);
        try std.testing.expect(std.mem.indexOf(u8, outb, "\"{{topic}}\"") != null);
    }
    // unknown token substitutes empty, structure preserved
    {
        const outb = substitute(gpa, "{\"a\":\"<{{missing}}>\"}", &.{}, &.{});
        defer gpa.free(outb);
        try std.testing.expectEqualStrings("{\"a\":\"<>\"}", outb);
    }
    // params win over step results for the same name
    {
        const p = [_]Binding{.{ .name = "x", .value = "P" }};
        const s = [_]Binding{.{ .name = "x", .value = "S" }};
        const outb = substitute(gpa, "{\"v\":\"{{x}}\"}", &p, &s);
        defer gpa.free(outb);
        try std.testing.expectEqualStrings("{\"v\":\"P\"}", outb);
    }
}

test "validate: built-in collision is an ERROR; a non-sandbox step tool is a WARNING" {
    const gpa = std.testing.allocator;
    // clean recipe ⇒ "" (do not free)
    {
        const rec = Recipe{
            .name = "brief",
            .description = "x",
            .owner_uid = 1,
            .params = &.{},
            .steps = &.{.{ .id = "a", .tool = "web_search", .args_json = "{}" }},
            .output = "",
        };
        const v = validate(gpa, rec, &tBuiltin, &tSandbox);
        try std.testing.expectEqual(@as(usize, 0), v.len);
    }
    // run_python step ⇒ WARNING (refused for grantees)
    {
        const rec = Recipe{
            .name = "danger",
            .description = "x",
            .owner_uid = 1,
            .params = &.{},
            .steps = &.{.{ .id = "a", .tool = "run_python", .args_json = "{}" }},
            .output = "",
        };
        const v = validate(gpa, rec, &tBuiltin, &tSandbox);
        defer gpa.free(v);
        try std.testing.expect(std.mem.indexOf(u8, v, "WARNING") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "run_python") != null);
    }
    // name collides with a built-in ⇒ ERROR
    {
        const rec = Recipe{
            .name = "write_file",
            .description = "x",
            .owner_uid = 1,
            .params = &.{},
            .steps = &.{.{ .id = "a", .tool = "web_search", .args_json = "{}" }},
            .output = "",
        };
        const v = validate(gpa, rec, &tBuiltin, &tSandbox);
        defer gpa.free(v);
        try std.testing.expect(std.mem.indexOf(u8, v, "ERROR") != null);
    }
}

test "schemaFor: renders a valid OpenAI function def with required params" {
    const gpa = std.testing.allocator;
    const rec = Recipe{
        .name = "research_brief",
        .description = "Search & brief",
        .owner_uid = 1,
        .params = &.{.{ .name = "topic", .ptype = "string", .desc = "what to research" }},
        .steps = &.{.{ .id = "a", .tool = "web_search", .args_json = "{}" }},
        .output = "",
    };
    const s = schemaFor(gpa, rec);
    defer gpa.free(s);
    // it must parse as JSON and carry the name + required topic
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, s, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"research_brief\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"required\":[\"topic\"]") != null);
}

test "loadDir: reads a directory, skipping a malformed file and a colliding one (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "zig-recipes-it-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/good.json", .data =
        \\{"name":"brief","description":"x","steps":[{"id":"a","tool":"web_search","args":{"q":"{{topic}}"}}],"params":[{"name":"topic","type":"string","description":"t"}]}
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/broken.json", .data = "{ not json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/collide.json", .data =
        \\{"name":"write_file","description":"x","steps":[{"id":"a","tool":"web_search","args":{}}]}
    });

    var reg = loadDir(gpa, io, dir, &tBuiltin);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.get("brief") != null);
    try std.testing.expect(reg.get("write_file") == null);
}
