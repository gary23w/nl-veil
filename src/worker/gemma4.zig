//! Gemma-4 wire-format rendering and parsing, so the engine can prompt a local Gemma-4
//! WITHOUT going through Ollama's built-in `gemma4` renderer.
//!
//! Why this exists. Measured on 30 harness drills, same Q4_K_M weights and the same
//! Ollama server, changing only who renders the prompt:
//!
//!   * `/api/chat` + `tools` (Ollama's RENDERER gemma4) -> 18/30, and FIVE calls naming
//!     tools that were never on the belt (`Browser`, `StopProcess`, `Read`, `Observe`,
//!     `Browser::browser_type`) — names the model memorised in pretraining.
//!   * `/api/generate` with `raw:true`, prompt rendered in this format -> 27/30, zero
//!     invented names.
//!
//! The tools array does reach the model either way (drop it and the model emits no calls
//! at all), but under Ollama's renderer the model does not bind to the NAMES. An explicit
//! Modelfile TEMPLATE was tried first and is not a fix — Go templates cannot reproduce
//! the parameter-schema encoding below, and that attempt scored 15/30.
//!
//! Correctness contract: this renderer is verified BYTE-FOR-BYTE against renders produced
//! by the model's own `chat_template.jinja` (fixtures embedded in the tests). That is what
//! makes bypassing Ollama safe — matching bytes means matching the format the model was
//! trained on, which is the configuration that measured 27/30.
//!
//! The format, for reference:
//!
//!   <bos><|turn>system\n{system}{tool decls}<turn|>\n
//!   <|turn>user\n{text}<turn|>\n
//!   <|turn>model\n{text}<turn|>\n                          (assistant prose)
//!   <|turn>model\n<|tool_call>call:NAME{args}<tool_call|>  (assistant tool call)
//!   <|tool_response>response:NAME{value:<|"|>…<|"|>}<tool_response|>
//!   <|turn>model\n<|channel>thought\n<channel|>            (generation prompt)
//!
//! Strings are delimited by the escape token `<|"|>` rather than quotes, so their content
//! is emitted RAW — embedded quotes and newlines need no escaping. Object keys are sorted
//! alphabetically and JSON Schema `type` values are upper-cased, both of which the jinja
//! template does via `dictsort`/`upper` and both of which the fixtures pin.

const std = @import("std");

pub const BOS = "<bos>";
pub const ESC = "<|\"|>";
pub const MODEL_TURN = "<|turn>model\n";
pub const EOT = "<turn|>\n";
/// enable_thinking=false pre-fills a CLOSED, empty thought channel; the model then goes
/// straight to its answer. This is the exact generation prompt the fixtures end with.
pub const GEN_SUFFIX = "<|turn>model\n<|channel>thought\n<channel|>";

/// Whether this module knows a family's wire format well enough to render it.
///
/// This asks only "have we implemented this format", which is a fact about THIS FILE. It
/// is NOT a decision about which models need engine-side rendering — that rides a
/// measured probe (`Caps.name_binding_ok` in llm.zig), because a backend that binds tool
/// names correctly should be left alone whatever family it is. The family itself is
/// DISCOVERED from the backend (`/api/show` -> details.family), never matched against a
/// model id.
pub fn canRenderFamily(family: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(family.len, buf.len);
    const low = std.ascii.lowerString(buf[0..n], family[0..n]);
    return std.mem.eql(u8, low, "gemma4");
}

const W = std.ArrayListUnmanaged(u8);

fn str(gpa: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.appendSlice(gpa, ESC);
    try w.appendSlice(gpa, s);
    try w.appendSlice(gpa, ESC);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Object keys in alphabetical order — the template's `| dictsort`.
fn sortedKeys(gpa: std.mem.Allocator, obj: std.json.ObjectMap) ![][]const u8 {
    var keys = try gpa.alloc([]const u8, obj.count());
    var i: usize = 0;
    var it = obj.iterator();
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThan);
    return keys;
}

/// A JSON Schema fragment. `type` is upper-cased; empty `properties`/`required` are
/// omitted entirely (the template skips falsy values), which is why a no-argument tool
/// renders as `parameters:{type:<|"|>OBJECT<|"|>}`.
fn writeSchema(gpa: std.mem.Allocator, w: *W, v: std.json.Value) !void {
    switch (v) {
        .object => |obj| {
            const keys = try sortedKeys(gpa, obj);
            defer gpa.free(keys);
            try w.append(gpa, '{');
            var first = true;
            for (keys) |k| {
                const val = obj.get(k).?;
                if (isEmptyish(val)) continue;
                if (!first) try w.append(gpa, ',');
                first = false;
                try w.appendSlice(gpa, k);
                try w.append(gpa, ':');
                if (std.mem.eql(u8, k, "type") and val == .string) {
                    var tb: [32]u8 = undefined;
                    const t = val.string;
                    const n = @min(t.len, tb.len);
                    try str(gpa, w, std.ascii.upperString(tb[0..n], t[0..n]));
                } else {
                    try writeSchema(gpa, w, val);
                }
            }
            try w.append(gpa, '}');
        },
        .array => |arr| {
            try w.append(gpa, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.append(gpa, ',');
                try writeSchema(gpa, w, item);
            }
            try w.append(gpa, ']');
        },
        .string => |s| try str(gpa, w, s),
        .integer => |n| try w.print(gpa, "{d}", .{n}),
        .float => |f| try w.print(gpa, "{d}", .{f}),
        .bool => |b| try w.appendSlice(gpa, if (b) "true" else "false"),
        .null => try w.appendSlice(gpa, "null"),
        else => try w.appendSlice(gpa, "null"),
    }
}

fn isEmptyish(v: std.json.Value) bool {
    return switch (v) {
        .object => |o| o.count() == 0,
        .array => |a| a.items.len == 0,
        .string => |s| s.len == 0,
        .null => true,
        else => false,
    };
}

/// Tool-call arguments: same shape as a schema fragment, but `type` is an ordinary key
/// here (an argument may legitimately be named "type"), so no upper-casing.
fn writeArgs(gpa: std.mem.Allocator, w: *W, v: std.json.Value) !void {
    switch (v) {
        .object => |obj| {
            const keys = try sortedKeys(gpa, obj);
            defer gpa.free(keys);
            try w.append(gpa, '{');
            for (keys, 0..) |k, i| {
                if (i > 0) try w.append(gpa, ',');
                try w.appendSlice(gpa, k);
                try w.append(gpa, ':');
                try writeArgs(gpa, w, obj.get(k).?);
            }
            try w.append(gpa, '}');
        },
        .array => |arr| {
            try w.append(gpa, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.append(gpa, ',');
                try writeArgs(gpa, w, item);
            }
            try w.append(gpa, ']');
        },
        .string => |s| try str(gpa, w, s),
        .integer => |n| try w.print(gpa, "{d}", .{n}),
        .float => |f| try w.print(gpa, "{d}", .{f}),
        .bool => |b| try w.appendSlice(gpa, if (b) "true" else "false"),
        .null => try w.appendSlice(gpa, "null"),
        else => try w.appendSlice(gpa, "null"),
    }
}

fn fnObj(t: std.json.Value) ?std.json.ObjectMap {
    const o = switch (t) {
        .object => |x| x,
        else => return null,
    };
    if (o.get("function")) |f| {
        return switch (f) {
            .object => |x| x,
            else => null,
        };
    }
    return o; // bare {name,description,parameters}, as tools.zig writes them
}

/// Render messages + tools into the raw prompt string for /api/generate.
///
/// `messages_json` and `tools_json` are the INNER text of their arrays (no brackets) —
/// the same slices ollamaNativeBody splices into the /api/chat body.
pub fn renderPrompt(
    gpa: std.mem.Allocator,
    messages_json: []const u8,
    tools_json: []const u8,
) ![]u8 {
    const msgs_txt = try std.fmt.allocPrint(gpa, "[{s}]", .{messages_json});
    defer gpa.free(msgs_txt);
    const parsed_msgs = try std.json.parseFromSlice(std.json.Value, gpa, msgs_txt, .{});
    defer parsed_msgs.deinit();

    var parsed_tools: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_tools) |p| p.deinit();
    var tools_txt: ?[]u8 = null;
    defer if (tools_txt) |t| gpa.free(t);
    if (tools_json.len > 0) {
        tools_txt = try std.fmt.allocPrint(gpa, "[{s}]", .{tools_json});
        parsed_tools = try std.json.parseFromSlice(std.json.Value, gpa, tools_txt.?, .{});
    }

    var w: W = .empty;
    errdefer w.deinit(gpa);
    try w.appendSlice(gpa, BOS);

    // ---- system turn: system text, then every tool declaration, in one turn
    var system_text: []const u8 = "";
    for (parsed_msgs.value.array.items) |m| {
        const o = switch (m) {
            .object => |x| x,
            else => continue,
        };
        const role = if (o.get("role")) |r| (if (r == .string) r.string else "") else "";
        if (std.mem.eql(u8, role, "system")) {
            if (o.get("content")) |c| if (c == .string) {
                system_text = c.string;
            };
            break; // the leading system block is one message by the time it reaches here
        }
    }
    const have_tools = parsed_tools != null and parsed_tools.?.value.array.items.len > 0;
    if (system_text.len > 0 or have_tools) {
        try w.appendSlice(gpa, "<|turn>system\n");
        try w.appendSlice(gpa, system_text);
        if (have_tools) {
            for (parsed_tools.?.value.array.items) |t| {
                const f = fnObj(t) orelse continue;
                const name = if (f.get("name")) |n| (if (n == .string) n.string else "") else "";
                if (name.len == 0) continue;
                try w.appendSlice(gpa, "<|tool>declaration:");
                try w.appendSlice(gpa, name);
                try w.append(gpa, '{');
                var wrote = false;
                if (f.get("description")) |d| if (d == .string and d.string.len > 0) {
                    try w.appendSlice(gpa, "description:");
                    try str(gpa, &w, d.string);
                    wrote = true;
                };
                if (f.get("parameters")) |p| {
                    if (wrote) try w.append(gpa, ',');
                    try w.appendSlice(gpa, "parameters:");
                    try writeSchema(gpa, &w, p);
                }
                try w.appendSlice(gpa, "}<tool|>");
            }
        }
        try w.appendSlice(gpa, EOT);
    }

    // ---- conversation
    var last_call_name: []const u8 = "";
    for (parsed_msgs.value.array.items) |m| {
        const o = switch (m) {
            .object => |x| x,
            else => continue,
        };
        const role = if (o.get("role")) |r| (if (r == .string) r.string else "") else "";
        const content = if (o.get("content")) |c| (if (c == .string) c.string else "") else "";
        if (std.mem.eql(u8, role, "system")) continue; // already folded above
        if (std.mem.eql(u8, role, "user")) {
            try w.appendSlice(gpa, "<|turn>user\n");
            try w.appendSlice(gpa, content);
            try w.appendSlice(gpa, EOT);
        } else if (std.mem.eql(u8, role, "assistant")) {
            const tcs = o.get("tool_calls");
            const has_calls = tcs != null and tcs.? == .array and tcs.?.array.items.len > 0;
            try w.appendSlice(gpa, MODEL_TURN);
            if (has_calls) {
                for (tcs.?.array.items) |tc| {
                    const f = fnObj(tc) orelse continue;
                    const name = if (f.get("name")) |n| (if (n == .string) n.string else "") else "";
                    try w.appendSlice(gpa, "<|tool_call>call:");
                    try w.appendSlice(gpa, name);
                    if (f.get("arguments")) |a| {
                        // OpenAI ships arguments as a STRING; native wants the object.
                        if (a == .string) {
                            const inner = std.json.parseFromSlice(std.json.Value, gpa, a.string, .{}) catch null;
                            if (inner) |p| {
                                defer p.deinit();
                                try writeArgs(gpa, &w, p.value);
                            } else try w.appendSlice(gpa, "{}");
                        } else try writeArgs(gpa, &w, a);
                    } else try w.appendSlice(gpa, "{}");
                    try w.appendSlice(gpa, "<tool_call|>");
                    last_call_name = name;
                }
            } else {
                try w.appendSlice(gpa, content);
                try w.appendSlice(gpa, EOT);
            }
        } else if (std.mem.eql(u8, role, "tool")) {
            try w.appendSlice(gpa, "<|tool_response>response:");
            try w.appendSlice(gpa, last_call_name);
            try w.appendSlice(gpa, "{value:");
            try str(gpa, &w, content);
            try w.appendSlice(gpa, "}<tool_response|>");
        }
    }

    try w.appendSlice(gpa, GEN_SUFFIX);
    return w.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- parsing the reply

pub const Call = struct { name: []u8, args_json: []u8 };
pub const Reply = struct {
    content: []u8,
    thinking: []u8,
    calls: []Call,

    pub fn deinit(self: *Reply, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        gpa.free(self.thinking);
        for (self.calls) |c| {
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        gpa.free(self.calls);
    }
};

/// `{k:<|"|>v<|"|>,n:1}` -> strict JSON. The escape token delimits strings, so scanning
/// toggles in/out of string state on it; a regex cannot do this because string CONTENT
/// may contain `{`, `}`, `,` and `:` freely.
fn argsToJson(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var w: W = .empty;
    errdefer w.deinit(gpa);
    var i: usize = 0;
    var in_str = false;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], ESC)) {
            try w.append(gpa, '"');
            in_str = !in_str;
            i += ESC.len;
            continue;
        }
        const c = src[i];
        if (in_str) {
            switch (c) {
                '"' => try w.appendSlice(gpa, "\\\""),
                '\\' => try w.appendSlice(gpa, "\\\\"),
                '\n' => try w.appendSlice(gpa, "\\n"),
                '\r' => try w.appendSlice(gpa, "\\r"),
                '\t' => try w.appendSlice(gpa, "\\t"),
                else => if (c < 0x20) try w.print(gpa, "\\u{x:0>4}", .{c}) else try w.append(gpa, c),
            }
            i += 1;
            continue;
        }
        // bare identifier key -> quoted key
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var j = i;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
            var k = j;
            while (k < src.len and src[k] == ' ') k += 1;
            if (k < src.len and src[k] == ':') {
                try w.append(gpa, '"');
                try w.appendSlice(gpa, src[i..j]);
                try w.appendSlice(gpa, "\":");
                i = k + 1;
                continue;
            }
        }
        try w.append(gpa, c);
        i += 1;
    }
    return w.toOwnedSlice(gpa);
}

/// Pull the thought channel, the visible text, and any tool calls out of a raw completion.
pub fn parseCompletion(gpa: std.mem.Allocator, text: []const u8) !Reply {
    var thinking: []u8 = try gpa.dupe(u8, "");
    errdefer gpa.free(thinking);
    var rest = text;

    const TH_OPEN = "<|channel>thought\n";
    const TH_CLOSE = "<channel|>";
    if (std.mem.indexOf(u8, rest, TH_OPEN)) |a| {
        if (std.mem.indexOfPos(u8, rest, a + TH_OPEN.len, TH_CLOSE)) |b| {
            gpa.free(thinking);
            thinking = try gpa.dupe(u8, rest[a + TH_OPEN.len .. b]);
            rest = rest[b + TH_CLOSE.len ..];
        }
    }

    var calls: std.ArrayListUnmanaged(Call) = .empty;
    errdefer {
        for (calls.items) |c| {
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        calls.deinit(gpa);
    }
    var content: W = .empty;
    errdefer content.deinit(gpa);

    var i: usize = 0;
    while (i < rest.len) {
        const open = std.mem.indexOfPos(u8, rest, i, "<|tool_call>") orelse {
            try content.appendSlice(gpa, rest[i..]);
            break;
        };
        try content.appendSlice(gpa, rest[i..open]);
        const body_start = open + "<|tool_call>".len;
        const close = std.mem.indexOfPos(u8, rest, body_start, "<tool_call|>") orelse rest.len;
        const body = rest[body_start..@min(close, rest.len)];
        i = @min(close + "<tool_call|>".len, rest.len);

        const cpos = std.mem.indexOf(u8, body, "call:") orelse continue;
        var n = cpos + "call:".len;
        const nstart = n;
        while (n < body.len and (std.ascii.isAlphanumeric(body[n]) or body[n] == '_')) n += 1;
        const name = body[nstart..n];
        if (name.len == 0) continue;
        const brace = std.mem.indexOfScalarPos(u8, body, n, '{');
        const args_src = if (brace) |b| body[b..] else "{}";
        const aj = try argsToJson(gpa, args_src);
        // keep only well-formed objects; a mangled call is better dropped than passed on
        const ok = blk: {
            const p = std.json.parseFromSlice(std.json.Value, gpa, aj, .{}) catch break :blk false;
            defer p.deinit();
            break :blk p.value == .object;
        };
        try calls.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .args_json = if (ok) aj else nblk: {
                gpa.free(aj);
                break :nblk try gpa.dupe(u8, "{}");
            },
        });
    }

    // strip the turn terminator and surrounding whitespace from the visible text
    const out = try content.toOwnedSlice(gpa);
    errdefer gpa.free(out);
    var trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (std.mem.endsWith(u8, trimmed, "<turn|>")) trimmed = trimmed[0 .. trimmed.len - "<turn|>".len];
    trimmed = std.mem.trim(u8, trimmed, " \t\r\n");
    const final = try gpa.dupe(u8, trimmed);
    gpa.free(out);

    return .{ .content = final, .thinking = thinking, .calls = try calls.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------- tests
// The fixtures below are renders produced by the model's OWN chat_template.jinja
// (generated by corpus/emit_zig_tests.py from corpus/goldens/). Byte equality with them
// is the whole safety argument for bypassing Ollama's renderer: same bytes in means the
// same behaviour that measured 27/30 over /api/generate raw, versus 18/30 through
// RENDERER gemma4. If one of these ever fails, the renderer has drifted from the format
// the model was trained on -- do not "fix" it by updating the fixture.

test "renderPrompt matches the model's own chat template byte-for-byte: assistant_text" {
    const gpa = std.testing.allocator;
    const msgs = "{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"assistant\",\"content\":\"b\"},{\"role\":\"user\",\"content\":\"c\"}";
    const tools = "";
    const golden = "<bos><|turn>user\na<turn|>\n<|turn>model\nb<turn|>\n<|turn>user\nc<turn|>\n<|turn>model\n<|channel>thought\n<channel|>";
    const got = try renderPrompt(gpa, msgs, tools);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("\n--- case assistant_text DIFFERS\nexpected: {s}\n\ngot:      {s}\n",
            .{ golden, got });
    }
    try std.testing.expectEqualStrings(golden, got);
}

test "renderPrompt matches the model's own chat template byte-for-byte: desc_with_quotes" {
    const gpa = std.testing.allocator;
    const msgs = "{\"role\":\"user\",\"content\":\"say \\\"hi\\\"\\nand newline\"}";
    const tools = "{\"type\":\"function\",\"function\":{\"name\":\"observe\",\"description\":\"Store a \\\"fact\\\" -- with punctuation, and a\\nnewline.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"fact\":{\"type\":\"string\",\"description\":\"the fact\"}},\"required\":[\"fact\"]}}}";
    const golden = "<bos><|turn>system\n<|tool>declaration:observe{description:<|\"|>Store a \"fact\" -- with punctuation, and a\nnewline.<|\"|>,parameters:{properties:{fact:{description:<|\"|>the fact<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>fact<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|><turn|>\n<|turn>user\nsay \"hi\"\nand newline<turn|>\n<|turn>model\n<|channel>thought\n<channel|>";
    const got = try renderPrompt(gpa, msgs, tools);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("\n--- case desc_with_quotes DIFFERS\nexpected: {s}\n\ngot:      {s}\n",
            .{ golden, got });
    }
    try std.testing.expectEqualStrings(golden, got);
}

test "renderPrompt matches the model's own chat template byte-for-byte: enum_bool_nested" {
    const gpa = std.testing.allocator;
    const msgs = "{\"role\":\"user\",\"content\":\"hi\"}";
    const tools = "{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"Write a file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"mode\":{\"type\":\"string\",\"enum\":[\"overwrite\",\"append\"]},\"submit\":{\"type\":\"boolean\"}},\"required\":[\"path\"]}}},{\"type\":\"function\",\"function\":{\"name\":\"edit_file\",\"description\":\"Edit.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"ops\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"op\":{\"type\":\"string\",\"enum\":[\"replace\",\"delete\"]},\"anchor\":{\"type\":\"string\"}},\"required\":[\"op\",\"anchor\"]}}},\"required\":[\"path\",\"ops\"]}}}";
    const golden = "<bos><|turn>system\n<|tool>declaration:write_file{description:<|\"|>Write a file.<|\"|>,parameters:{properties:{mode:{enum:[<|\"|>overwrite<|\"|>,<|\"|>append<|\"|>],type:<|\"|>STRING<|\"|>},path:{type:<|\"|>STRING<|\"|>},submit:{type:<|\"|>BOOLEAN<|\"|>}},required:[<|\"|>path<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|><|tool>declaration:edit_file{description:<|\"|>Edit.<|\"|>,parameters:{properties:{ops:{items:{properties:{anchor:{type:<|\"|>STRING<|\"|>},op:{enum:[<|\"|>replace<|\"|>,<|\"|>delete<|\"|>],type:<|\"|>STRING<|\"|>}},required:[<|\"|>op<|\"|>,<|\"|>anchor<|\"|>],type:<|\"|>OBJECT<|\"|>},type:<|\"|>ARRAY<|\"|>},path:{type:<|\"|>STRING<|\"|>}},required:[<|\"|>path<|\"|>,<|\"|>ops<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|><turn|>\n<|turn>user\nhi<turn|>\n<|turn>model\n<|channel>thought\n<channel|>";
    const got = try renderPrompt(gpa, msgs, tools);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("\n--- case enum_bool_nested DIFFERS\nexpected: {s}\n\ngot:      {s}\n",
            .{ golden, got });
    }
    try std.testing.expectEqualStrings(golden, got);
}

test "renderPrompt matches the model's own chat template byte-for-byte: no_tools" {
    const gpa = std.testing.allocator;
    const msgs = "{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"hi\"}";
    const tools = "";
    const golden = "<bos><|turn>system\nS<turn|>\n<|turn>user\nhi<turn|>\n<|turn>model\n<|channel>thought\n<channel|>";
    const got = try renderPrompt(gpa, msgs, tools);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("\n--- case no_tools DIFFERS\nexpected: {s}\n\ngot:      {s}\n",
            .{ golden, got });
    }
    try std.testing.expectEqualStrings(golden, got);
}

test "renderPrompt matches the model's own chat template byte-for-byte: simple" {
    const gpa = std.testing.allocator;
    const msgs = "{\"role\":\"system\",\"content\":\"You are veil.\"},{\"role\":\"user\",\"content\":\"Read a.py\"}";
    const tools = "{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read a text file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"start_line\":{\"type\":\"integer\"}},\"required\":[\"path\"]}}},{\"type\":\"function\",\"function\":{\"name\":\"run_tests\",\"description\":\"Run the suite.\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}}";
    const golden = "<bos><|turn>system\nYou are veil.<|tool>declaration:read_file{description:<|\"|>Read a text file.<|\"|>,parameters:{properties:{path:{type:<|\"|>STRING<|\"|>},start_line:{type:<|\"|>INTEGER<|\"|>}},required:[<|\"|>path<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|><|tool>declaration:run_tests{description:<|\"|>Run the suite.<|\"|>,parameters:{type:<|\"|>OBJECT<|\"|>}}<tool|><turn|>\n<|turn>user\nRead a.py<turn|>\n<|turn>model\n<|channel>thought\n<channel|>";
    const got = try renderPrompt(gpa, msgs, tools);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("\n--- case simple DIFFERS\nexpected: {s}\n\ngot:      {s}\n",
            .{ golden, got });
    }
    try std.testing.expectEqualStrings(golden, got);
}

test "renderPrompt matches the model's own chat template byte-for-byte: toolcall_roundtrip" {
    const gpa = std.testing.allocator;
    const msgs = "{\"role\":\"user\",\"content\":\"Read a.py\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.py\"}}}]},{\"role\":\"tool\",\"content\":\"line one\"},{\"role\":\"user\",\"content\":\"thanks\"}";
    const tools = "{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read a text file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}";
    const golden = "<bos><|turn>system\n<|tool>declaration:read_file{description:<|\"|>Read a text file.<|\"|>,parameters:{properties:{path:{type:<|\"|>STRING<|\"|>}},required:[<|\"|>path<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|><turn|>\n<|turn>user\nRead a.py<turn|>\n<|turn>model\n<|tool_call>call:read_file{path:<|\"|>a.py<|\"|>}<tool_call|><|tool_response>response:read_file{value:<|\"|>line one<|\"|>}<tool_response|><|turn>user\nthanks<turn|>\n<|turn>model\n<|channel>thought\n<channel|>";
    const got = try renderPrompt(gpa, msgs, tools);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("\n--- case toolcall_roundtrip DIFFERS\nexpected: {s}\n\ngot:      {s}\n",
            .{ golden, got });
    }
    try std.testing.expectEqualStrings(golden, got);
}

test "canRenderFamily answers about the FAMILY the backend reported, not a model id" {
    // /api/show reports details.family; that is the only input. A model id is never
    // consulted, so renaming or forking a model cannot change the decision.
    try std.testing.expect(canRenderFamily("gemma4"));
    try std.testing.expect(canRenderFamily("Gemma4"));
    try std.testing.expect(!canRenderFamily("gemma3"));
    try std.testing.expect(!canRenderFamily("llama"));
    try std.testing.expect(!canRenderFamily(""));
    // a model NAMED gemma-4 whose backend reports another family is not ours to render
    try std.testing.expect(!canRenderFamily("qwen2"));
}

test "parseCompletion pulls a tool call out of raw text, with arguments as an object" {
    const gpa = std.testing.allocator;
    var r = try parseCompletion(gpa,
        "<|tool_call>call:web_search{query:<|\"|>zig 0.16 release<|\"|>}<tool_call|>");
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.calls.len);
    try std.testing.expectEqualStrings("web_search", r.calls[0].name);
    try std.testing.expectEqualStrings("{\"query\":\"zig 0.16 release\"}", r.calls[0].args_json);
    try std.testing.expectEqualStrings("", r.content);
}

test "parseCompletion keeps braces and quotes that live INSIDE an argument string" {
    // The escape token delimits strings, so content may contain { } , : and quotes. A
    // regex-based parser mangles exactly this case.
    const gpa = std.testing.allocator;
    var r = try parseCompletion(gpa,
        "<|tool_call>call:write_file{content:<|\"|>if (x) { y(\"a,b\"); }<|\"|>," ++
        "path:<|\"|>m.zig<|\"|>}<tool_call|>");
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.calls.len);
    const p = try std.json.parseFromSlice(std.json.Value, gpa, r.calls[0].args_json, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("if (x) { y(\"a,b\"); }", p.value.object.get("content").?.string);
    try std.testing.expectEqualStrings("m.zig", p.value.object.get("path").?.string);
}

test "parseCompletion separates the thought channel from the visible answer" {
    const gpa = std.testing.allocator;
    var r = try parseCompletion(gpa,
        "<|channel>thought\nweighing it up<channel|>The answer is 42.<turn|>");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("weighing it up", r.thinking);
    try std.testing.expectEqualStrings("The answer is 42.", r.content);
    try std.testing.expectEqual(@as(usize, 0), r.calls.len);
}

test "parseCompletion returns prose unchanged when there is no tool call" {
    const gpa = std.testing.allocator;
    var r = try parseCompletion(gpa, "I don't have an email tool on this belt.<turn|>");
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), r.calls.len);
    try std.testing.expectEqualStrings("I don't have an email tool on this belt.", r.content);
}

test "renderPrompt replays OpenAI arguments-as-STRING as a native object" {
    // Every conv buffer in this repo is built in the OpenAI wire format, where arguments
    // is a JSON string; the gemma4 format needs the object form.
    const gpa = std.testing.allocator;
    const msgs =
        "{\"role\":\"user\",\"content\":\"go\"}," ++
        "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"type\":\"function\"," ++
        "\"function\":{\"name\":\"recall\",\"arguments\":\"{\\\"query\\\":\\\"ports\\\"}\"}}]}";
    const got = try renderPrompt(gpa, msgs, "");
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "call:recall{query:<|\"|>ports<|\"|>}") != null);
}
