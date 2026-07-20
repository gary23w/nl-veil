//! server_config.zig — the handful of settings a SERVER ADMIN owns, changeable while running.
//!
//! Today that is the default model every web user falls back to when they have chosen nothing. It
//! started as NL_DEFAULT_MODEL / NL_DEFAULT_BASE_URL read once at boot, which is right for
//! provisioning a container and wrong for a person: it meant knowing the exact model id and base URL
//! strings, editing a launch script, and restarting the server to change a dropdown's worth of state.
//!
//! So: the env vars still SEED the config the first time (a fresh install with NL_DEFAULT_MODEL set
//! comes up configured, unattended), and after that the admin sets it from the web UI and it persists
//! to {data}/server-config.json. The file is plain JSON on purpose — an operator with no UI access can
//! still read and edit it, and it is obvious in a backup what it holds.
//!
//! CONCURRENCY. This is read on EVERY chat turn, from httpz worker threads, while an admin may be
//! writing it from another. Fixed-size buffers behind a mutex, copied in and out — no slice handed out
//! that could dangle when the value changes underneath a request, and no allocation on the read path.

const std = @import("std");

pub const MODEL_MAX = 160; // longest catalog id today is ~55 bytes (@cf/... slugs); generous
pub const BASE_MAX = 256;

pub const ServerConfig = struct {
    mu: std.Io.Mutex = .init,
    io: std.Io,
    gpa: std.mem.Allocator,
    data: []const u8,

    // Three roles, mirroring the per-user trio: coding is the fallback for the other two, exactly as
    // ModelTrio.pick already resolves them. An admin who wants one model for everything simply leaves
    // thinking and prompting empty — the same shape a user's own settings take.
    model_buf: [MODEL_MAX]u8 = undefined,
    model_len: usize = 0,
    base_buf: [BASE_MAX]u8 = undefined,
    base_len: usize = 0,
    think_model_buf: [MODEL_MAX]u8 = undefined,
    think_model_len: usize = 0,
    think_base_buf: [BASE_MAX]u8 = undefined,
    think_base_len: usize = 0,
    prompt_model_buf: [MODEL_MAX]u8 = undefined,
    prompt_model_len: usize = 0,
    prompt_base_buf: [BASE_MAX]u8 = undefined,
    prompt_base_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data: []const u8) ServerConfig {
        return .{ .io = io, .gpa = gpa, .data = data };
    }

    /// The configured default, copied into `alloc`. Empty strings mean "no default set" — callers
    /// treat that as "the user must choose", which is the pre-existing behaviour.
    pub const Defaults = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        think_model: []const u8 = "",
        think_base_url: []const u8 = "",
        prompt_model: []const u8 = "",
        prompt_base_url: []const u8 = "",
    };

    pub fn defaults(self: *ServerConfig, alloc: std.mem.Allocator) Defaults {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return .{
            .model = alloc.dupe(u8, self.model_buf[0..self.model_len]) catch "",
            .base_url = alloc.dupe(u8, self.base_buf[0..self.base_len]) catch "",
            .think_model = alloc.dupe(u8, self.think_model_buf[0..self.think_model_len]) catch "",
            .think_base_url = alloc.dupe(u8, self.think_base_buf[0..self.think_base_len]) catch "",
            .prompt_model = alloc.dupe(u8, self.prompt_model_buf[0..self.prompt_model_len]) catch "",
            .prompt_base_url = alloc.dupe(u8, self.prompt_base_buf[0..self.prompt_base_len]) catch "",
        };
    }

    /// Validate one model/base pair. Rejects rather than truncates: a silently clipped model id would
    /// fail later as a confusing 404 from the provider instead of an error where it was typed.
    fn check(model: []const u8, base_url: []const u8) !void {
        if (model.len > MODEL_MAX or base_url.len > BASE_MAX) return error.TooLong;
        // This lands in a JSON file and in an HTTP response body, so no quotes or control bytes.
        for (model) |c| if (c < 0x20 or c == '"' or c == '\\') return error.BadInput;
        for (base_url) |c| if (c < 0x20 or c == '"' or c == '\\') return error.BadInput;
    }

    fn put(buf: []u8, len: *usize, v: []const u8) void {
        @memcpy(buf[0..v.len], v);
        len.* = v.len;
    }

    /// Set the coding role only, leaving thinking/prompting untouched.
    pub fn set(self: *ServerConfig, model: []const u8, base_url: []const u8) !void {
        const d = self.defaultsRaw();
        try self.setAll(model, base_url, d.think_model, d.think_base_url, d.prompt_model, d.prompt_base_url);
    }

    /// Set all three roles at once. Thinking and prompting may be empty — they then fall back to the
    /// coding model inside ModelTrio.pick, which is exactly how a user's own trio behaves.
    pub fn setAll(
        self: *ServerConfig,
        model: []const u8,
        base_url: []const u8,
        think_model: []const u8,
        think_base_url: []const u8,
        prompt_model: []const u8,
        prompt_base_url: []const u8,
    ) !void {
        const WS = " \r\n\t";
        const m = std.mem.trim(u8, model, WS);
        const b = std.mem.trim(u8, base_url, WS);
        const tm = std.mem.trim(u8, think_model, WS);
        const tb = std.mem.trim(u8, think_base_url, WS);
        const pm = std.mem.trim(u8, prompt_model, WS);
        const pb2 = std.mem.trim(u8, prompt_base_url, WS);
        try check(m, b);
        try check(tm, tb);
        try check(pm, pb2);

        self.mu.lockUncancelable(self.io);
        put(&self.model_buf, &self.model_len, m);
        put(&self.base_buf, &self.base_len, b);
        put(&self.think_model_buf, &self.think_model_len, tm);
        put(&self.think_base_buf, &self.think_base_len, tb);
        put(&self.prompt_model_buf, &self.prompt_model_len, pm);
        put(&self.prompt_base_buf, &self.prompt_base_len, pb2);
        self.mu.unlock(self.io);

        self.save() catch {}; // a failed write must not fail the request; the value is already live
    }

    /// Snapshot WITHOUT allocating — used internally where a caller already holds no lock.
    fn defaultsRaw(self: *ServerConfig) Defaults {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return .{
            .model = self.model_buf[0..self.model_len],
            .base_url = self.base_buf[0..self.base_len],
            .think_model = self.think_model_buf[0..self.think_model_len],
            .think_base_url = self.think_base_buf[0..self.think_base_len],
            .prompt_model = self.prompt_model_buf[0..self.prompt_model_len],
            .prompt_base_url = self.prompt_base_buf[0..self.prompt_base_len],
        };
    }

    fn path(self: *ServerConfig, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/server-config.json", .{self.data}) catch null;
    }

    fn save(self: *ServerConfig) !void {
        var pb: [700]u8 = undefined;
        const p = self.path(&pb) orelse return;
        self.mu.lockUncancelable(self.io);
        var body_buf: [(MODEL_MAX + BASE_MAX) * 3 + 256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            "{{\"default_model\":\"{s}\",\"default_base_url\":\"{s}\"," ++
            "\"think_model\":\"{s}\",\"think_base_url\":\"{s}\"," ++
            "\"prompt_model\":\"{s}\",\"prompt_base_url\":\"{s}\"}}\n", .{
            self.model_buf[0..self.model_len],        self.base_buf[0..self.base_len],
            self.think_model_buf[0..self.think_model_len],  self.think_base_buf[0..self.think_base_len],
            self.prompt_model_buf[0..self.prompt_model_len], self.prompt_base_buf[0..self.prompt_base_len],
        }) catch {
            self.mu.unlock(self.io);
            return;
        };
        self.mu.unlock(self.io);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = body });
    }

    /// Load from disk, falling back to the env vars when there is no file yet. The env is a SEED, not
    /// an override: once an admin has set a value in the UI, a stale NL_DEFAULT_MODEL in some launch
    /// script must not silently win on the next restart and undo them.
    pub fn load(self: *ServerConfig, environ: *const std.process.Environ.Map) void {
        var pb: [700]u8 = undefined;
        if (self.path(&pb)) |p| {
            if (std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(8 << 10))) |data| {
                defer self.gpa.free(data);
                const P = struct {
                    default_model: []const u8 = "",
                    default_base_url: []const u8 = "",
                    think_model: []const u8 = "",
                    think_base_url: []const u8 = "",
                    prompt_model: []const u8 = "",
                    prompt_base_url: []const u8 = "",
                };
                if (std.json.parseFromSlice(P, self.gpa, data, .{ .ignore_unknown_fields = true })) |parsed| {
                    defer parsed.deinit();
                    const v = parsed.value;
                    self.setAll(v.default_model, v.default_base_url, v.think_model, v.think_base_url, v.prompt_model, v.prompt_base_url) catch {};
                    return;
                } else |_| {}
            } else |_| {}
        }
        const m = environ.get("NL_DEFAULT_MODEL") orelse "";
        const b = environ.get("NL_DEFAULT_BASE_URL") orelse "";
        if (m.len > 0) self.set(m, b) catch {};
    }
};

test "set rejects over-long and control-bearing input rather than truncating" {
    var cfg = ServerConfig{ .io = undefined, .gpa = std.testing.allocator, .data = "." };
    try std.testing.expectError(error.TooLong, cfg.set("x" ** (MODEL_MAX + 1), ""));
    try std.testing.expectError(error.BadInput, cfg.set("gpt\"quote", ""));
    try std.testing.expectError(error.BadInput, cfg.set("gpt\nnewline", ""));
}

test "setAll round-trips every role through defaults()" {
    const t = std.testing;
    // A real Io: setAll takes the mutex, and locking an undefined Io segfaults —
    // the validation-only test above passes solely because check() returns first.
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = ServerConfig{ .io = threaded.io(), .gpa = t.allocator, .data = "." };
    try cfg.setAll("m", "b", "tm", "tb", "pm", "pb");
    const d = cfg.defaultsRaw();
    try t.expectEqualStrings("m", d.model);
    try t.expectEqualStrings("b", d.base_url);
    try t.expectEqualStrings("tm", d.think_model);
    try t.expectEqualStrings("tb", d.think_base_url);
    try t.expectEqualStrings("pm", d.prompt_model);
    try t.expectEqualStrings("pb", d.prompt_base_url);
}

test "clearing is expressible: empty values really do empty the config" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    var cfg = ServerConfig{ .io = threaded.io(), .gpa = t.allocator, .data = "." };
    try cfg.setAll("m", "b", "tm", "tb", "pm", "pb");
    try cfg.setAll("", "", "", "", "", "");
    const d = cfg.defaultsRaw();
    try t.expectEqual(@as(usize, 0), d.model.len);
    try t.expectEqual(@as(usize, 0), d.think_model.len);
    try t.expectEqual(@as(usize, 0), d.prompt_base_url.len);
}
