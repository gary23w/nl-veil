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

    model_buf: [MODEL_MAX]u8 = undefined,
    model_len: usize = 0,
    base_buf: [BASE_MAX]u8 = undefined,
    base_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data: []const u8) ServerConfig {
        return .{ .io = io, .gpa = gpa, .data = data };
    }

    /// The configured default, copied into `alloc`. Empty strings mean "no default set" — callers
    /// treat that as "the user must choose", which is the pre-existing behaviour.
    pub fn defaults(self: *ServerConfig, alloc: std.mem.Allocator) struct { model: []const u8, base_url: []const u8 } {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const m = alloc.dupe(u8, self.model_buf[0..self.model_len]) catch "";
        const b = alloc.dupe(u8, self.base_buf[0..self.base_len]) catch "";
        return .{ .model = m, .base_url = b };
    }

    /// Set and persist. Over-long input is REJECTED rather than truncated: a silently clipped model id
    /// would fail later as a confusing 404 from the provider instead of an error here.
    pub fn set(self: *ServerConfig, model: []const u8, base_url: []const u8) !void {
        const m = std.mem.trim(u8, model, " \r\n\t");
        const b = std.mem.trim(u8, base_url, " \r\n\t");
        if (m.len > MODEL_MAX or b.len > BASE_MAX) return error.TooLong;
        // No control characters: this lands in a JSON file and in an HTTP request body.
        for (m) |c| if (c < 0x20 or c == '"' or c == '\\') return error.BadInput;
        for (b) |c| if (c < 0x20 or c == '"' or c == '\\') return error.BadInput;

        self.mu.lockUncancelable(self.io);
        @memcpy(self.model_buf[0..m.len], m);
        self.model_len = m.len;
        @memcpy(self.base_buf[0..b.len], b);
        self.base_len = b.len;
        self.mu.unlock(self.io);

        self.save() catch {}; // a failed write must not fail the request; the value is already live
    }

    fn path(self: *ServerConfig, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/server-config.json", .{self.data}) catch null;
    }

    fn save(self: *ServerConfig) !void {
        var pb: [700]u8 = undefined;
        const p = self.path(&pb) orelse return;
        self.mu.lockUncancelable(self.io);
        var body_buf: [MODEL_MAX + BASE_MAX + 64]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"default_model\":\"{s}\",\"default_base_url\":\"{s}\"}}\n", .{
            self.model_buf[0..self.model_len], self.base_buf[0..self.base_len],
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
                const P = struct { default_model: []const u8 = "", default_base_url: []const u8 = "" };
                if (std.json.parseFromSlice(P, self.gpa, data, .{ .ignore_unknown_fields = true })) |parsed| {
                    defer parsed.deinit();
                    self.set(parsed.value.default_model, parsed.value.default_base_url) catch {};
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
