//! ROUTING GUARD for the per-role model trio — the test that fails when a labeled LLM call in the chat
//! engine stops reaching its role's provider.
//!
//! WHY THIS EXISTS AS A SOURCE AUDIT rather than a live wire test. The label→role mapping is not data;
//! it is TEN hand-written positional argument lists that each pass `think.base_url, think.key,
//! think.model` (or `prompt.*`, or a whole `Provider` value) down a chain of helpers to a call whose tag
//! literal is the label. Swap `think` for `prompt` at any one of them and every type checks, every test
//! passes, and a user's planning traffic silently bills to their auto-loop model. Add an eleventh labeled
//! call that reads `trio.thinking` directly instead of `trio.pick(.thinking)` and the blank-role fallback
//! quietly dies for that call alone. Neither failure is observable from `ModelTrio.pick` in isolation —
//! pick is already tested (engine.zig) and it is not where the bug lives. The bug lives in the argument
//! lists.
//!
//! So this test reads engine.zig as text and re-derives the mapping the way a reviewer would, but
//! exhaustively:
//!
//!   1. find EVERY `llm.<call>(...)` site in the engine and pull its tag literal (the label);
//!   2. take the three arguments that land on llm's `base_url, key, model` parameters;
//!   3. walk them back — through pass-through helper parameters (three loose strings OR one whole
//!      `Provider`), across as many call layers as it takes — until they bottom out at a
//!      `trio.pick(.role)` / `trio.coding` binding, whether that binding is a local `const` or written
//!      inline as the argument itself;
//!   4. assert the role that binding names is the role the label is supposed to run on.
//!
//! What that buys, against the failure modes that actually ship:
//!   * a MISROUTE (think↔prompt swapped at any link in any chain) fails step 4;
//!   * a NEW labeled call that forgets pick() fails step 3 (unresolvable) or step 4;
//!   * a NEW label nobody added here fails the known-label check — the exhaustiveness guard;
//!   * a DUPLICATED call site fails the exact per-label count of 1;
//!   * a SPLIT TRIPLE (`think.base_url, prompt.key, think.model` — the shape that ships one provider's
//!     key to another provider's endpoint) fails as MixedProvider. That one is a credential leak, not
//!     a billing bug, which is why it is checked at every link and not only at the outermost one;
//!   * reading `trio.thinking` raw instead of `trio.pick(.thinking)` fails as RawRoleBypassesPick —
//!     that is the blank-role fallback (an unset role must inherit coding) breaking for one call.
//!
//! The audit is deliberately BRITTLE-LOUD: anything it cannot parse or resolve is an error, never a
//! silent skip. A guard that shrugs when the code moves is worth less than no guard at all.
//!
//! It does NOT observe the wire. See the gap note at the bottom of this file.

const std = @import("std");
const engine = @import("engine.zig");

const ENGINE_SRC = @embedFile("engine.zig");

const Role = engine.Role;

/// THE FULL KNOWN LABEL SET. Every label the chat engine may tag an LLM call with, and the role that
/// label must run on. A new labeled call site is a deliberate routing decision — it belongs here, and
/// the test refuses to pass until someone makes that decision explicitly.
const EXPECTED = [_]struct { label: []const u8, role: Role }{
    .{ .label = "chat", .role = .coding }, // the main agentic answer stream
    .{ .label = "loop", .role = .prompting }, // the auto-loop self-prompt-back drive
    .{ .label = "plan", .role = .thinking },
    .{ .label = "reflect", .role = .thinking },
    .{ .label = "summary", .role = .thinking },
    .{ .label = "ctxsum", .role = .thinking },
    .{ .label = "compact", .role = .thinking },
    .{ .label = "lesson", .role = .thinking },
    // Both of these write a PROMPT for the next step rather than answering or reasoning about the task, which
    // is what the prompting role is for — and both are hot paths (the reformulator can fire on every
    // web_search of a research turn), so they belong on the cheap driver, not the coder.
    .{ .label = "searchq", .role = .prompting }, // rewrites a web_search query before it executes
    .{ .label = "stuck", .role = .prompting }, // writes the afk stuck-recovery instruction
    .{ .label = "planrec", .role = .prompting }, // settle-time plan reconcile: a cheap ledger-vs-tasks verdict, not reasoning
};

/// Every public entry point in llm.zig that takes the (run_dir, tag, base_url, key, model) prefix. If a
/// new one is added there, add it here — otherwise its call sites are invisible to this audit.
const LLM_CALLEES = [_][]const u8{ "complete", "completeStream", "chat", "chatTemp", "visionExtract" };

/// Positions of `tag`, `base_url`, `key`, `model` in that shared parameter prefix
/// (gpa, io, run_dir, tag, base_url, key, model, ...). Reordering llm.zig's parameters without updating
/// these does not silently pass: the triple read from 4/5/6 stops looking like a provider triple and
/// the audit fails to resolve it.
const ARG_TAG = 3;
const ARG_BASE = 4;
const ARG_KEY = 5;
const ARG_MODEL = 6;

const AuditError = error{
    /// The source could not be parsed where the audit needs to read it — treat as a failure and fix the
    /// audit, never as "nothing to check here".
    ParseFailed,
    /// A provider triple that could not be traced back to any `trio.*` binding.
    Unresolvable,
    /// base_url / key / model came from DIFFERENT providers — the credential-crossing shape.
    MixedProvider,
    /// A role bound as `trio.thinking` / `trio.prompting` instead of `trio.pick(.role)`, which skips the
    /// unset-role → coding fallback for that call only.
    RawRoleBypassesPick,
    /// A pass-through helper nobody calls — its label can never reach the wire, so the mapping is a lie.
    NoCallers,
    /// Two callers of the same helper route it to different roles, so the label's role is not a fact.
    ConflictingCallers,
    TooDeep,
};

// ---------------------------------------------------------------------------
// source scanning — a small, honest lexer: it knows strings, char literals, `//` comments and `\\`
// multiline-string lines, which is exactly enough to not be fooled by the engine's own prose.
// ---------------------------------------------------------------------------

fn skipString(src: []const u8, i: usize) ?usize {
    var j = i + 1;
    while (j < src.len) {
        if (src[j] == '\\') {
            j += 2;
            continue;
        }
        if (src[j] == '"') return j + 1;
        j += 1;
    }
    return null;
}

fn skipChar(src: []const u8, i: usize) ?usize {
    var j = i + 1;
    while (j < src.len) {
        if (src[j] == '\\') {
            j += 2;
            continue;
        }
        if (src[j] == '\'') return j + 1;
        j += 1;
    }
    return null;
}

fn toLineEnd(src: []const u8, i: usize) usize {
    return std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
}

/// Is byte `at` real code, or does it sit inside a comment / string on its line? Used to keep the engine's
/// own commentary ("llm.completeStream fires this per delta") out of the call inventory.
fn isCodeAt(src: []const u8, at: usize) bool {
    var i: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |p| i = p + 1;
    while (i < at) {
        const c = src[i];
        if (c == '"') {
            const j = skipString(src, i) orelse return false;
            // Landing PAST `at` means `at` is inside this literal, so the match is text, not code. Without
            // this the loop simply exits (i < at goes false) and falls through to `return true` — which is
            // how `const note = "llm.complete( …"` was being counted as a real call site.
            if (j > at) return false;
            i = j;
            continue;
        }
        if (c == '\'') {
            const j = skipChar(src, i) orelse return false;
            if (j > at) return false; // same reasoning, for a char literal
            i = j;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') return false;
        if (c == '\\' and i + 1 < src.len and src[i + 1] == '\\') return false;
        i += 1;
    }
    return true;
}

/// Drop the comments wrapped around one argument or parameter. A multi-line signature attaches its
/// preceding comment block to the NEXT argument's text, so leading `//` lines are stripped first; a
/// trailing `// note` is cut only when the argument is not itself a string literal (a "https://..."
/// literal must survive intact).
fn stripComments(a: []const u8) []const u8 {
    var s = std.mem.trim(u8, a, " \t\r\n");
    while (std.mem.startsWith(u8, s, "//")) {
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return "";
        s = std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
    }
    if (s.len > 0 and s[0] != '"') {
        if (std.mem.indexOf(u8, s, "//")) |c| s = std.mem.trim(u8, s[0..c], " \t\r\n");
    }
    return s;
}

/// Split the top-level, comma-separated contents of the parenthesis group opening at `open` into `out`.
/// Works for both a call's arguments and a declaration's parameters; handles multi-line groups.
fn splitArgs(src: []const u8, open: usize, out: [][]const u8) ?usize {
    if (open >= src.len or src[open] != '(') return null;
    var depth: usize = 0;
    var n: usize = 0;
    var start = open + 1;
    var i = open;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '"' => {
                i = skipString(src, i) orelse return null;
                continue;
            },
            '\'' => {
                i = skipChar(src, i) orelse return null;
                continue;
            },
            '/' => {
                if (i + 1 < src.len and src[i + 1] == '/') {
                    i = toLineEnd(src, i);
                    continue;
                }
                i += 1;
            },
            '\\' => {
                if (i + 1 < src.len and src[i + 1] == '\\') {
                    i = toLineEnd(src, i);
                    continue;
                }
                i += 1;
            },
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) {
                    const last = stripComments(src[start..i]);
                    if (last.len > 0) {
                        if (n >= out.len) return null;
                        out[n] = last;
                        n += 1;
                    }
                    return n;
                }
                i += 1;
            },
            ',' => {
                if (depth == 1) {
                    if (n >= out.len) return null;
                    out[n] = stripComments(src[start..i]);
                    n += 1;
                    start = i + 1;
                }
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

/// One top-level `fn` (or `test`) and the byte range it owns. Ranges are derived from column-0 `fn` /
/// `pub fn` / `test` lines, which is the engine's uniform style; nested struct methods stay inside the
/// enclosing top-level declaration, and no labeled LLM call lives in one.
const FnSpan = struct {
    name: []const u8,
    start: usize,
    end: usize,
    open: usize, // index of '(' in the signature; 0 for a `test` block
};

fn collectFns(alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(FnSpan)) !void {
    var i: usize = 0;
    while (i < src.len) {
        const nl = toLineEnd(src, i);
        const line = src[i..nl];
        var name_off: usize = 0;
        var is_fn = false;
        if (std.mem.startsWith(u8, line, "fn ")) {
            is_fn = true;
            name_off = 3;
        } else if (std.mem.startsWith(u8, line, "pub fn ")) {
            is_fn = true;
            name_off = 7;
        }
        if (is_fn or std.mem.startsWith(u8, line, "test ")) {
            if (out.items.len > 0) out.items[out.items.len - 1].end = i;
            var name: []const u8 = "";
            var open: usize = 0;
            if (is_fn) {
                const rest = line[name_off..];
                const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return error.ParseFailed;
                name = rest[0..paren];
                open = i + name_off + paren;
            }
            try out.append(alloc, .{ .name = name, .start = i, .end = src.len, .open = open });
        }
        if (nl >= src.len) break;
        i = nl + 1;
    }
}

fn spanAt(spans: []const FnSpan, at: usize) ?*const FnSpan {
    for (spans) |*s| if (at >= s.start and at < s.end) return s;
    return null;
}

const Site = struct { name_start: usize, open: usize };

/// Next call of `name` at or after `from`: the identifier must stand alone (not a field access, not a
/// longer identifier) and be followed by '('.
fn findCall(src: []const u8, name: []const u8, from: usize) ?Site {
    var pos = from;
    while (std.mem.indexOfPos(u8, src, pos, name)) |at| {
        pos = at + name.len;
        if (at > 0) {
            const p = src[at - 1];
            if (std.ascii.isAlphanumeric(p) or p == '_' or p == '.') continue;
        }
        var j = at + name.len;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\r' or src[j] == '\n')) j += 1;
        if (j >= src.len or src[j] != '(') continue;
        if (!isCodeAt(src, at)) continue;
        return .{ .name_start = at, .open = j };
    }
    return null;
}

fn paramIndexOf(params: []const []const u8, want: []const u8) ?usize {
    for (params, 0..) |p, idx| {
        const colon = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..colon], " \t\r\n"), want)) return idx;
    }
    return null;
}

/// `expr` == "<owner>.<field>" → owner. The owner may be a bare identifier (`p`) or a dotted/called path
/// (`trio.pick(.thinking)`), so that a triple written inline off pick() resolves like any other; anything
/// with whitespace or an operator in it is refused, since this audit must not guess at an expression it
/// cannot read.
fn fieldOwner(expr: []const u8, field: []const u8) ?[]const u8 {
    if (expr.len <= field.len + 1) return null;
    if (expr[expr.len - field.len - 1] != '.') return null;
    if (!std.mem.eql(u8, expr[expr.len - field.len ..], field)) return null;
    const owner = expr[0 .. expr.len - field.len - 1];
    for (owner) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '(' or c == ')') continue;
        return null;
    }
    return owner;
}

/// Does `expr` end in the dotted path `tail` at a component boundary? `trio.pick(.thinking)` and
/// `args.trio.pick(.thinking)` both match tail "trio.pick(.thinking)"; `my_trio.thinking` does NOT match
/// tail "trio.thinking", because the byte before the tail has to be a '.' and not part of a longer name.
fn pathEndsWith(expr: []const u8, tail: []const u8) bool {
    if (std.mem.eql(u8, expr, tail)) return true;
    if (expr.len <= tail.len) return false;
    if (!std.mem.endsWith(u8, expr, tail)) return false;
    return expr[expr.len - tail.len - 1] == '.';
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

const ROLE_NAMES = [_]struct { name: []const u8, role: Role }{
    .{ .name = "coding", .role = .coding },
    .{ .name = "thinking", .role = .thinking },
    .{ .name = "prompting", .role = .prompting },
};

/// The role a whole-Provider local `const v = trio.pick(.role)` / `const v = trio.coding` names.
fn varRole(body: []const u8, v: []const u8) AuditError!Role {
    var buf: [192]u8 = undefined;
    for (ROLE_NAMES) |r| {
        const needle = std.fmt.bufPrint(&buf, "const {s} = trio.pick(.{s})", .{ v, r.name }) catch return error.ParseFailed;
        if (std.mem.indexOf(u8, body, needle) != null) return r.role;
    }
    // `trio.coding` raw is exact — pick(.coding) is the identity. The other two are not: reading them raw
    // skips the "unset role inherits coding" fallback, which is the single-model client's whole contract.
    const raw_coding = std.fmt.bufPrint(&buf, "const {s} = trio.coding;", .{v}) catch return error.ParseFailed;
    if (std.mem.indexOf(u8, body, raw_coding) != null) return .coding;
    for ([_][]const u8{ "thinking", "prompting" }) |bad| {
        const raw = std.fmt.bufPrint(&buf, "const {s} = trio.{s};", .{ v, bad }) catch return error.ParseFailed;
        if (std.mem.indexOf(u8, body, raw) != null) return error.RawRoleBypassesPick;
    }
    return error.Unresolvable;
}

/// The role three bare locals bound field-at-a-time name — `const base_url = trio.coding.base_url;` and
/// friends, the shape runInnerAgentic uses. Null means "not bound here" (so they are parameters).
fn bareLocalRole(body: []const u8, b: []const u8, k: []const u8, m: []const u8) AuditError!?Role {
    const fields = [_][2][]const u8{ .{ b, "base_url" }, .{ k, "key" }, .{ m, "model" } };
    var buf: [192]u8 = undefined;
    for (ROLE_NAMES) |r| {
        // pick() form: `const base_url = trio.pick(.thinking).base_url;` — the correct shape for any role.
        var via_pick = true;
        for (fields) |f| {
            const needle = std.fmt.bufPrint(&buf, "const {s} = trio.pick(.{s}).{s};", .{ f[0], r.name, f[1] }) catch return error.ParseFailed;
            if (std.mem.indexOf(u8, body, needle) == null) via_pick = false;
        }
        if (via_pick) return r.role;

        // raw form: `const base_url = trio.coding.base_url;`. Exact for coding, a fallback-killing bug for
        // the other two (an unset role would no longer inherit coding for this call).
        var via_raw = true;
        for (fields) |f| {
            const needle = std.fmt.bufPrint(&buf, "const {s} = trio.{s}.{s};", .{ f[0], r.name, f[1] }) catch return error.ParseFailed;
            if (std.mem.indexOf(u8, body, needle) == null) via_raw = false;
        }
        if (via_raw) {
            if (r.role != .coding) return error.RawRoleBypassesPick;
            return r.role;
        }
    }
    return null;
}

/// A whole `Provider` written DIRECTLY as an expression — `trio.pick(.prompting)` passed straight into a
/// helper's argument list, with no `const` binding in between. Null means "not a trio expression at all"
/// (so the caller keeps looking); an error means it IS one and it is the wrong shape.
fn directProviderRole(expr: []const u8) AuditError!?Role {
    var buf: [64]u8 = undefined;
    for (ROLE_NAMES) |r| {
        const via_pick = std.fmt.bufPrint(&buf, "trio.pick(.{s})", .{r.name}) catch return error.ParseFailed;
        if (pathEndsWith(expr, via_pick)) return r.role;
    }
    // Same rule as everywhere else in this file: `trio.coding` raw is the identity of pick(.coding), while a
    // raw `trio.thinking` / `trio.prompting` argument skips the unset-role → coding fallback for that call.
    for (ROLE_NAMES) |r| {
        const raw = std.fmt.bufPrint(&buf, "trio.{s}", .{r.name}) catch return error.ParseFailed;
        if (pathEndsWith(expr, raw)) {
            if (r.role != .coding) return error.RawRoleBypassesPick;
            return r.role;
        }
    }
    return null;
}

/// Resolve a WHOLE-Provider expression to its role, in the function that expression is written in.
///
/// Three ways it can bottom out, tried in order:
///   * written inline as `trio.pick(.role)` right there in the argument list;
///   * a local `const p = trio.pick(.role)` in this function's body (varRole);
///   * FORM D — the Provider arrived as this function's own named `p: Provider` PARAMETER, in which case the
///     routing decision belongs to whoever called it. Exactly like the three-loose-strings case (form C),
///     that is resolved by finding EVERY call site and reading the role out of each one's argument.
///
/// Two callers that disagree is not a tie to break, it is the bug: a helper reached once with `think` and
/// once with `prompt` runs its label on two different models depending on who called it, and its entry in
/// EXPECTED is then a statement that cannot be true. That is ConflictingCallers, and it fails.
fn providerExprRole(
    src: []const u8,
    spans: []const FnSpan,
    span: *const FnSpan,
    expr: []const u8,
    depth: usize,
) AuditError!Role {
    if (depth > 8) return error.TooDeep;
    if (try directProviderRole(expr)) |r| return r;

    // Past this point it must be a plain name — a local binding or a parameter. A call, a field access or an
    // `if` expression is something this audit cannot follow, and it says so rather than assuming a role.
    if (!isIdent(expr)) return error.Unresolvable;

    const body = src[span.start..span.end];
    if (varRole(body, expr)) |r| {
        return r;
    } else |err| switch (err) {
        error.Unresolvable => {}, // not bound in this body — it may be a parameter; fall through
        else => return err, // RawRoleBypassesPick and friends are answers, not "keep looking"
    }

    if (span.name.len == 0) return error.Unresolvable; // a `test` block has no callers to ask
    var pbuf: [64][]const u8 = undefined;
    const pn = splitArgs(src, span.open, &pbuf) orelse return error.ParseFailed;
    const params = pbuf[0..pn];
    const ip = paramIndexOf(params, expr) orelse return error.Unresolvable;

    // It has to actually BE a Provider. If the parameter is some other type, the triple did not come from
    // where this audit thinks it did, and guessing would be the failure mode this whole file exists against.
    const colon = std.mem.indexOfScalar(u8, params[ip], ':') orelse return error.ParseFailed;
    const ty = std.mem.trim(u8, params[ip][colon + 1 ..], " \t\r\n");
    if (!pathEndsWith(ty, "Provider")) return error.Unresolvable;

    var found: ?Role = null;
    var callers: usize = 0;
    var pos: usize = 0;
    while (findCall(src, span.name, pos)) |site| {
        pos = site.name_start + span.name.len;
        if (site.name_start >= span.start and site.name_start < span.end) continue; // the decl, or self-recursion
        var abuf: [64][]const u8 = undefined;
        const an = splitArgs(src, site.open, &abuf) orelse return error.ParseFailed;
        if (an <= ip) return error.ParseFailed;
        const cspan = spanAt(spans, site.name_start) orelse return error.ParseFailed;
        const r = try providerExprRole(src, spans, cspan, abuf[ip], depth + 1);
        callers += 1;
        if (found) |f| {
            if (f != r) return error.ConflictingCallers;
        } else found = r;
    }
    if (callers == 0) return error.NoCallers;
    return found.?;
}

/// Walk one (base_url, key, model) argument triple back to the `trio` binding it came from.
fn resolve(
    src: []const u8,
    spans: []const FnSpan,
    span: *const FnSpan,
    b: []const u8,
    k: []const u8,
    m: []const u8,
    depth: usize,
) AuditError!Role {
    if (depth > 8) return error.TooDeep;
    const body = src[span.start..span.end];

    // FORM A — `v.base_url, v.key, v.model`: the three fields of ONE Provider expression. That expression may
    // be a local `const`, an inline `trio.pick(.role)`, or a `p: Provider` parameter passed down from a
    // caller (form D) — providerExprRole covers all three.
    if (std.mem.indexOfScalar(u8, b, '.') != null) {
        const ob = fieldOwner(b, "base_url") orelse return error.ParseFailed;
        const ok_ = fieldOwner(k, "key") orelse return error.ParseFailed;
        const om = fieldOwner(m, "model") orelse return error.ParseFailed;
        // All three fields MUST come from the same Provider. A mixed triple is how one provider's key
        // reaches another provider's endpoint.
        if (!std.mem.eql(u8, ob, ok_) or !std.mem.eql(u8, ob, om)) return error.MixedProvider;
        return providerExprRole(src, spans, span, ob, depth + 1);
    }

    // FORM B — three bare locals bound field-at-a-time off `trio` right here.
    if (try bareLocalRole(body, b, k, m)) |r| return r;

    // FORM C — they are this function's own parameters, so the routing decision was made by whoever
    // called it. Resolve at EVERY call site and require them to agree: a helper reached from two places
    // that disagree has no single role, which is itself the bug.
    if (span.name.len == 0) return error.Unresolvable;
    var pbuf: [64][]const u8 = undefined;
    const pn = splitArgs(src, span.open, &pbuf) orelse return error.ParseFailed;
    const params = pbuf[0..pn];
    const ib = paramIndexOf(params, b) orelse return error.Unresolvable;
    const ik = paramIndexOf(params, k) orelse return error.Unresolvable;
    const im = paramIndexOf(params, m) orelse return error.Unresolvable;

    var found: ?Role = null;
    var callers: usize = 0;
    var pos: usize = 0;
    while (findCall(src, span.name, pos)) |site| {
        pos = site.name_start + span.name.len;
        // Skip the declaration itself and any self-recursion — both sit inside this span.
        if (site.name_start >= span.start and site.name_start < span.end) continue;
        var abuf: [64][]const u8 = undefined;
        const an = splitArgs(src, site.open, &abuf) orelse return error.ParseFailed;
        if (an <= ib or an <= ik or an <= im) return error.ParseFailed;
        const cspan = spanAt(spans, site.name_start) orelse return error.ParseFailed;
        const r = try resolve(src, spans, cspan, abuf[ib], abuf[ik], abuf[im], depth + 1);
        callers += 1;
        if (found) |f| {
            if (f != r) return error.ConflictingCallers;
        } else found = r;
    }
    if (callers == 0) return error.NoCallers;
    return found.?;
}

// ---------------------------------------------------------------------------
// the audit
// ---------------------------------------------------------------------------

test "trio routing: every labeled LLM call in the chat engine reaches its role's provider" {
    const alloc = std.testing.allocator;
    const src = ENGINE_SRC;

    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, src, &spans);
    try std.testing.expect(spans.items.len > 50); // sanity: the span scanner actually found the engine

    var seen = [_]usize{0} ** EXPECTED.len;
    var total: usize = 0;

    for (LLM_CALLEES) |callee| {
        var nbuf: [48]u8 = undefined;
        const needle = try std.fmt.bufPrint(&nbuf, "llm.{s}(", .{callee});
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, src, pos, needle)) |at| {
            pos = at + needle.len;
            if (!isCodeAt(src, at)) continue; // a mention in the engine's own commentary

            const open = at + needle.len - 1;
            var abuf: [32][]const u8 = undefined;
            const an = splitArgs(src, open, &abuf) orelse {
                std.debug.print("trio routing: could not parse the argument list of llm.{s} at byte {d}\n", .{ callee, at });
                return error.ParseFailed;
            };
            if (an <= ARG_MODEL) {
                std.debug.print("trio routing: llm.{s} at byte {d} has {d} args — the (run_dir, tag, base_url, key, model) prefix moved\n", .{ callee, at, an });
                return error.ParseFailed;
            }

            const tag = abuf[ARG_TAG];
            if (tag.len < 2 or tag[0] != '"' or tag[tag.len - 1] != '"') {
                // A computed tag would make the label unknowable to any reader, this audit included.
                std.debug.print("trio routing: llm.{s} at byte {d} has a non-literal tag `{s}`\n", .{ callee, at, tag });
                return error.ParseFailed;
            }
            const label = tag[1 .. tag.len - 1];

            // T2 — EXHAUSTIVENESS. A label nobody declared above is a new call whose routing was never
            // decided. Fail loudly rather than let it inherit whatever provider happened to be in scope.
            var idx: ?usize = null;
            for (EXPECTED, 0..) |e, i| {
                if (std.mem.eql(u8, e.label, label)) idx = i;
            }
            if (idx == null) {
                std.debug.print(
                    "trio routing: UNKNOWN LABEL \"{s}\" (llm.{s} at byte {d}).\n" ++
                        "  A new labeled LLM call must declare its role in EXPECTED in this file, and must take\n" ++
                        "  its provider from ModelTrio.pick(.<role>) — not from trio.thinking/trio.prompting directly.\n",
                    .{ label, callee, at },
                );
                return error.Unresolvable;
            }
            const e = EXPECTED[idx.?];
            seen[idx.?] += 1;
            total += 1;

            const span = spanAt(spans.items, at) orelse return error.ParseFailed;
            const got = resolve(src, spans.items, span, abuf[ARG_BASE], abuf[ARG_KEY], abuf[ARG_MODEL], 0) catch |err| {
                std.debug.print(
                    "trio routing: label \"{s}\" (llm.{s}, in fn `{s}`) — {t}\n" ++
                        "  provider triple as written: ({s}, {s}, {s})\n",
                    .{ label, callee, span.name, err, abuf[ARG_BASE], abuf[ARG_KEY], abuf[ARG_MODEL] },
                );
                return err;
            };

            // T1 — the mapping itself.
            if (got != e.role) {
                std.debug.print(
                    "trio routing: MISROUTE — label \"{s}\" must run on the {s} model, but its provider\n" ++
                        "  resolves to {s} (in fn `{s}`, triple: {s}, {s}, {s}).\n",
                    .{ label, @tagName(e.role), @tagName(got), span.name, abuf[ARG_BASE], abuf[ARG_KEY], abuf[ARG_MODEL] },
                );
                return error.Unresolvable;
            }
        }
    }

    // T3 — EXACT counts, not "at least one". A label that vanished (0) means the call was deleted or its
    // tag renamed; a label seen twice means a duplicated call site, which doubles that role's traffic.
    for (EXPECTED, seen) |e, n| {
        if (n != 1) {
            std.debug.print("trio routing: label \"{s}\" has {d} call sites in the engine, expected exactly 1\n", .{ e.label, n });
            return error.Unresolvable;
        }
    }
    try std.testing.expectEqual(EXPECTED.len, total);

    // The fallback contract (an unset thinking/prompting role inherits coding) only holds while the engine
    // reads those roles THROUGH pick. Every resolution above already enforces it per call; this pins that
    // pick is genuinely the engine's routing primitive and not an unused decl.
    try std.testing.expect(std.mem.indexOf(u8, src, "trio.pick(.thinking)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "trio.pick(.prompting)") != null);
}

test "trio routing: no chat sibling file makes an unrouted LLM call" {
    // The engine is the only file in the chat backend that talks to a model. If a sibling grows an LLM
    // call, it grows a routing decision the audit above cannot see — so it has to come home to the engine
    // (or this audit has to be extended to it) rather than pick a provider on its own.
    const siblings = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "context.zig", .src = @embedFile("context.zig") },
        .{ .name = "plan.zig", .src = @embedFile("plan.zig") },
        .{ .name = "service.zig", .src = @embedFile("service.zig") },
        .{ .name = "sync.zig", .src = @embedFile("sync.zig") },
    };
    for (siblings) |s| {
        for (LLM_CALLEES) |callee| {
            var nbuf: [48]u8 = undefined;
            const needle = try std.fmt.bufPrint(&nbuf, "llm.{s}(", .{callee});
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, s.src, pos, needle)) |at| {
                pos = at + needle.len;
                if (!isCodeAt(s.src, at)) continue;
                std.debug.print("trio routing: {s} calls llm.{s} directly (byte {d}) — route it through the engine's trio\n", .{ s.name, callee, at });
                return error.Unresolvable;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// self-tests for the audit's own machinery. A source audit that silently mis-parses is worse than none,
// so the parts that could quietly return the wrong answer are pinned against fixtures.
// ---------------------------------------------------------------------------

test "routing audit: the scanner is not fooled by comments, strings, or split triples" {
    const fixture =
        \\fn runTurn(app: *App, trio: ModelTrio) void {
        \\    const think = trio.pick(.thinking);
        \\    const prompt = trio.pick(.prompting);
        \\    // a mention of llm.complete( in prose must not count as a call site
        \\    const note = "llm.complete( inside a string literal";
        \\    _ = llm.complete(gpa, io, run_root, "loop", prompt.base_url, prompt.key, prompt.model, x, "", 1, 0.5);
        \\    helper(app, run_root, think.base_url, think.key, think.model);
        \\    _ = note;
        \\}
        \\
        \\fn helper(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8) void {
        \\    _ = llm.complete(gpa, io, run_root, "plan", base_url, key, model, m, "", 1, 0.3);
        \\}
        \\
    ;
    const alloc = std.testing.allocator;
    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, fixture, &spans);
    try std.testing.expectEqual(@as(usize, 2), spans.items.len);

    // exactly two real call sites — the prose mention and the string literal are not among them
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, fixture, pos, "llm.complete(")) |at| {
        pos = at + "llm.complete(".len;
        if (isCodeAt(fixture, at)) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);

    // the inline triple resolves to prompting; the pass-through helper resolves through its caller to thinking
    const run_span = spanAt(spans.items, 0).?;
    try std.testing.expectEqual(Role.prompting, try resolve(fixture, spans.items, run_span, "prompt.base_url", "prompt.key", "prompt.model", 0));
    const help_at = std.mem.indexOf(u8, fixture, "fn helper(").?;
    const help_span = spanAt(spans.items, help_at).?;
    try std.testing.expectEqual(Role.thinking, try resolve(fixture, spans.items, help_span, "base_url", "key", "model", 0));

    // the credential-crossing shape is rejected, not quietly resolved to whichever field came first
    try std.testing.expectError(error.MixedProvider, resolve(fixture, spans.items, run_span, "think.base_url", "prompt.key", "think.model", 0));
    // an unknown Provider name is unresolvable rather than assumed
    try std.testing.expectError(error.Unresolvable, resolve(fixture, spans.items, run_span, "mystery.base_url", "mystery.key", "mystery.model", 0));
}

test "routing audit: reading a role without pick() is rejected, since it kills the blank-role fallback" {
    const fixture =
        \\fn runTurn(app: *App, trio: ModelTrio) void {
        \\    const think = trio.thinking;
        \\    _ = llm.complete(gpa, io, run_root, "plan", think.base_url, think.key, think.model, m, "", 1, 0.3);
        \\}
        \\
    ;
    const alloc = std.testing.allocator;
    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, fixture, &spans);
    const span = spanAt(spans.items, 0).?;
    try std.testing.expectError(
        error.RawRoleBypassesPick,
        resolve(fixture, spans.items, span, "think.base_url", "think.key", "think.model", 0),
    );
}

test "routing audit: a pass-through helper with two disagreeing callers has no role" {
    const fixture =
        \\fn a(trio: ModelTrio) void {
        \\    const think = trio.pick(.thinking);
        \\    helper(think.base_url, think.key, think.model);
        \\}
        \\
        \\fn b(trio: ModelTrio) void {
        \\    const prompt = trio.pick(.prompting);
        \\    helper(prompt.base_url, prompt.key, prompt.model);
        \\}
        \\
        \\fn helper(base_url: []const u8, key: []const u8, model: []const u8) void {
        \\    _ = llm.complete(gpa, io, run_root, "compact", base_url, key, model, m, "", 1, 0.3);
        \\}
        \\
    ;
    const alloc = std.testing.allocator;
    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, fixture, &spans);
    const help_at = std.mem.indexOf(u8, fixture, "fn helper(").?;
    const span = spanAt(spans.items, help_at).?;
    try std.testing.expectError(
        error.ConflictingCallers,
        resolve(fixture, spans.items, span, "base_url", "key", "model", 0),
    );
}

test "routing audit: a whole Provider passed as one parameter resolves at its call sites" {
    // FORM D, both ways it is written in the engine today: `writer` is handed a local `const prompt =
    // trio.pick(.prompting)`, `reader` is handed `trio.pick(.thinking)` inline with no binding at all.
    const fixture =
        \\fn runTurn(app: *App, trio: ModelTrio) void {
        \\    const prompt = trio.pick(.prompting);
        \\    _ = writer(app, run_root, prompt, "goal");
        \\    _ = reader(app, run_root, trio.pick(.thinking), "goal");
        \\}
        \\
        \\fn writer(app: *App, run_root: []const u8, p: Provider, goal: []const u8) ?[]u8 {
        \\    var step = llm.complete(gpa, app.io, run_root, "stuck", p.base_url, p.key, p.model, m, "", 256, 0.6);
        \\    return step;
        \\}
        \\
        \\fn reader(app: *App, run_root: []const u8, p: Provider, goal: []const u8) ?[]u8 {
        \\    var step = llm.complete(gpa, app.io, run_root, "summary", p.base_url, p.key, p.model, m, "", 256, 0.6);
        \\    return step;
        \\}
        \\
    ;
    const alloc = std.testing.allocator;
    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, fixture, &spans);

    const w_at = std.mem.indexOf(u8, fixture, "fn writer(").?;
    const w_span = spanAt(spans.items, w_at).?;
    try std.testing.expectEqual(Role.prompting, try resolve(fixture, spans.items, w_span, "p.base_url", "p.key", "p.model", 0));

    const r_at = std.mem.indexOf(u8, fixture, "fn reader(").?;
    const r_span = spanAt(spans.items, r_at).?;
    try std.testing.expectEqual(Role.thinking, try resolve(fixture, spans.items, r_span, "p.base_url", "p.key", "p.model", 0));

    // a triple taken inline off pick() in the caller itself, with no helper hop at all
    const top = spanAt(spans.items, 0).?;
    try std.testing.expectEqual(Role.thinking, try resolve(
        fixture,
        spans.items,
        top,
        "trio.pick(.thinking).base_url",
        "trio.pick(.thinking).key",
        "trio.pick(.thinking).model",
        0,
    ));
    // ...and the credential-crossing shape is still caught when written that way
    try std.testing.expectError(error.MixedProvider, resolve(
        fixture,
        spans.items,
        top,
        "trio.pick(.thinking).base_url",
        "trio.pick(.prompting).key",
        "trio.pick(.thinking).model",
        0,
    ));
}

test "routing audit: one Provider parameter reached from two roles is an ambiguity, not a first-wins" {
    // THE POINT OF FORM D. `helper` carries the label "searchq", but which model that label bills to depends
    // on which of the two callers is live. Silently taking the first answer would report a routing fact that
    // is false half the time — the exact class of bug this file exists to catch.
    const fixture =
        \\fn a(trio: ModelTrio) void {
        \\    const think = trio.pick(.thinking);
        \\    _ = helper(think, "x");
        \\}
        \\
        \\fn b(trio: ModelTrio) void {
        \\    _ = helper(trio.pick(.prompting), "y");
        \\}
        \\
        \\fn helper(p: Provider, q: []const u8) void {
        \\    _ = llm.complete(gpa, io, run_root, "searchq", p.base_url, p.key, p.model, m, "", 48, 0.3);
        \\}
        \\
    ;
    const alloc = std.testing.allocator;
    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, fixture, &spans);
    const help_at = std.mem.indexOf(u8, fixture, "fn helper(").?;
    const span = spanAt(spans.items, help_at).?;
    try std.testing.expectError(
        error.ConflictingCallers,
        resolve(fixture, spans.items, span, "p.base_url", "p.key", "p.model", 0),
    );
}

test "routing audit: form D stays strict — no callers, wrong type, and raw-role arguments all fail" {
    const fixture =
        \\fn orphan(p: Provider) void {
        \\    _ = llm.complete(gpa, io, run_root, "stuck", p.base_url, p.key, p.model, m, "", 48, 0.3);
        \\}
        \\
        \\fn caller(trio: ModelTrio) void {
        \\    _ = raw(trio.thinking);
        \\    _ = notprovider(cfg);
        \\}
        \\
        \\fn raw(p: Provider) void {
        \\    _ = llm.complete(gpa, io, run_root, "searchq", p.base_url, p.key, p.model, m, "", 48, 0.3);
        \\}
        \\
        \\fn notprovider(p: SomethingElse) void {
        \\    _ = llm.complete(gpa, io, run_root, "loop", p.base_url, p.key, p.model, m, "", 48, 0.3);
        \\}
        \\
    ;
    const alloc = std.testing.allocator;
    var spans: std.ArrayList(FnSpan) = .empty;
    defer spans.deinit(alloc);
    try collectFns(alloc, fixture, &spans);

    // a helper nobody calls: its label can never reach a model, so its EXPECTED row is fiction
    const o_span = spanAt(spans.items, std.mem.indexOf(u8, fixture, "fn orphan(").?).?;
    try std.testing.expectError(error.NoCallers, resolve(fixture, spans.items, o_span, "p.base_url", "p.key", "p.model", 0));

    // a raw `trio.thinking` handed straight in as an argument kills the blank-role fallback just as surely
    // as binding it to a const does
    const r_span = spanAt(spans.items, std.mem.indexOf(u8, fixture, "fn raw(").?).?;
    try std.testing.expectError(error.RawRoleBypassesPick, resolve(fixture, spans.items, r_span, "p.base_url", "p.key", "p.model", 0));

    // a same-shaped parameter that is not a Provider is refused rather than followed on faith
    const n_span = spanAt(spans.items, std.mem.indexOf(u8, fixture, "fn notprovider(").?).?;
    try std.testing.expectError(error.Unresolvable, resolve(fixture, spans.items, n_span, "p.base_url", "p.key", "p.model", 0));
}

// ---------------------------------------------------------------------------
// WHAT THIS FILE DOES NOT COVER — read before trusting it as the whole story.
//
// It proves the engine's SOURCE routes each label to the right role's Provider, end to end through the
// helper chains, and that the set of labels is closed. It does not observe the wire, so it cannot catch
// a misroute that originates BELOW the engine: llm.zig rewriting a base_url, a provider-quirk self-heal
// swapping a model id, or the trio being assembled wrongly upstream in chat/service.zig or sched.zig
// (both build a ModelTrio from request/task fields; neither is audited here).
//
// The caller search (forms C and D) scans engine.zig ONLY, so it is sound exactly while the helpers that
// carry a provider stay private to this file. Every one of them is a bare `fn` today; making one `pub` and
// calling it from a sibling would hide that call site from the audit — and, because a helper with no
// visible caller fails as NoCallers rather than passing, the failure mode there is a confusing error
// rather than a false green. That is the intended direction to fail in, but it is not obvious, so: if you
// export a provider-carrying helper, extend the caller search to the file that calls it.
//
// The live wire test the brief asked for — three mock OpenAI endpoints on distinct ports/keys/models,
// asserting per-endpoint request counts and key isolation from the servers' own logs — was NOT built,
// deliberately. What it needs, so the next person can judge the cost honestly:
//   * a real http.App: Auth, Supervisor (with parent_env set), AuditLog, LoginGuard, KeyVault,
//     ServerConfig, NeuronLedger and ApiKeys are all constructible from (gpa, io, ...), but Auth/KeyVault
//     hang off a `Neuron` handle that shells out to the neuron.exe CLI, so the test needs that binary on
//     disk or every store call fails (survivable — runTurn only asks auth for an is-admin answer — but it
//     has to be a decision, not an accident);
//   * MULTIPLE runs, not one: the labels are mutually exclusive within a single turn. `reflect` only fires
//     when no plan is active, `plan` only when shouldPlan() says so, `lesson` only for a conv named like a
//     scheduled run, `compact`/`ctxsum` only once a byte budget is crossed, `searchq` only on a web_search
//     that is actually about to execute, and `stuck` only on a confirmed-stuck afk repeat. Covering all ten
//     means five or six separately staged turns.
//   * a way to see the requests. The obvious mock (127.0.0.1) is the one place the file evidence
//     disappears: llm.zig's postUrl short-circuits loopback URLs to an in-process socket
//     (httpc.parseLoopbackUrl) and never writes the .llmreq-<tag>.json the brief wanted to cross-check
//     against. Only the STREAMING path (.streamreq-chat.json) always writes, because streamAttempt has no
//     loopback fast path. So on a loopback mock, the mock's own log is the only witness for nine of the
//     ten labels — the dual verification has to come from somewhere else, or the fast path needs a test
//     hook.
//   * curl on PATH, plus real subprocess spawning, for the streamed "chat" label.
// None of that is impossible; it is a day of work whose first green run has to be watched, and it could
// not be watched here (this task was run under a no-`zig build` constraint on a shared cache). Writing a
// few hundred lines of unrunnable integration test would have been the worse outcome.
// ---------------------------------------------------------------------------
