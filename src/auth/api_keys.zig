//! API keys — programmatic auth for the public API (alongside the session cookie the SPA uses). A user mints a key

const std = @import("std");
const Neuron = @import("../worker/neuron/client.zig").Neuron;

pub const PREFIX = "nlk_";

const Info = struct { uid: u64, name: []const u8, created: i64, prefix: []const u8 };
pub const View = struct { id: []const u8, prefix: []const u8, name: []const u8, created: i64 };

pub const ApiKeys = struct {
    gpa: std.mem.Allocator,
    nb: Neuron,
    mu: std.Io.Mutex = .init,
    keys: std.StringHashMapUnmanaged(Info) = .empty,

    pub fn init(gpa: std.mem.Allocator, nb: Neuron) ApiKeys {
        return .{ .gpa = gpa, .nb = nb };
    }

    fn hashHex(raw: []const u8, out: *[64]u8) []const u8 {
        var dig: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &dig, .{});
        const hex = std.fmt.bytesToHex(dig, .lower);
        @memcpy(out, &hex);
        return out[0..64];
    }

    fn b64(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
        const enc = std.base64.standard.Encoder;
        const buf = try gpa.alloc(u8, enc.calcSize(raw.len));
        _ = enc.encode(buf, raw);
        return buf;
    }
    fn unb64(gpa: std.mem.Allocator, b: []const u8) ![]u8 {
        const dec = std.base64.standard.Decoder;
        const n = try dec.calcSizeForSlice(b);
        const buf = try gpa.alloc(u8, n);
        try dec.decode(buf, b);
        return buf;
    }

    pub fn warm(self: *ApiKeys) !void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const scopes = self.nb.scopes("k_") catch return;
        defer {
            for (scopes) |s| self.gpa.free(s);
            self.gpa.free(scopes);
        }
        for (scopes) |scope| {
            if (scope.len < 3) continue;
            const hashhex = scope[2..];
            const enc = (self.nb.get(scope) catch continue) orelse continue;
            defer self.gpa.free(enc);
            const json = unb64(self.gpa, enc) catch continue;
            defer self.gpa.free(json);
            const P = struct { uid: u64, name: []const u8 = "", created: i64 = 0, prefix: []const u8 = "" };
            const parsed = std.json.parseFromSlice(P, self.gpa, json, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const v = parsed.value;
            const info = Info{
                .uid = v.uid,
                .name = self.gpa.dupe(u8, v.name) catch continue,
                .created = v.created,
                .prefix = self.gpa.dupe(u8, v.prefix) catch continue,
            };
            self.keys.put(self.gpa, self.gpa.dupe(u8, hashhex) catch continue, info) catch {};
        }
    }

    pub fn create(self: *ApiKeys, uid: u64, name: []const u8) ![]u8 {
        var rnd: [24]u8 = undefined;
        self.nb.io.random(&rnd);
        const hex = std.fmt.bytesToHex(rnd, .lower);
        const raw = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ PREFIX, hex });
        errdefer self.gpa.free(raw);
        var hbuf: [64]u8 = undefined;
        const hash = hashHex(raw, &hbuf);
        const created = std.Io.Timestamp.now(self.nb.io, .real).toSeconds();
        const prefix = try std.fmt.allocPrint(self.gpa, "{s}…", .{raw[0 .. PREFIX.len + 8]});
        var namebuf: [60]u8 = undefined;
        var nl: usize = 0;
        for (name) |c| {
            if (nl >= namebuf.len) break;
            if (std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '_' or c == '.') {
                namebuf[nl] = c;
                nl += 1;
            }
        }
        const safe_name = if (nl > 0) namebuf[0..nl] else "key";
        const json = try std.fmt.allocPrint(self.gpa, "{{\"uid\":{d},\"name\":\"{s}\",\"created\":{d},\"prefix\":\"{s}\"}}", .{ uid, safe_name, created, prefix });
        defer self.gpa.free(json);
        const enc = try b64(self.gpa, json);
        defer self.gpa.free(enc);
        var sbuf: [80]u8 = undefined;
        const scope = std.fmt.bufPrint(&sbuf, "k_{s}", .{hash}) catch return raw;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        self.nb.put(scope, enc) catch {};
        const info = Info{ .uid = uid, .name = try self.gpa.dupe(u8, safe_name), .created = created, .prefix = prefix };
        self.keys.put(self.gpa, try self.gpa.dupe(u8, hash), info) catch {};
        return raw;
    }

    pub fn verify(self: *ApiKeys, raw: []const u8) ?u64 {
        if (raw.len < PREFIX.len + 16 or !std.mem.startsWith(u8, raw, PREFIX)) return null;
        var hbuf: [64]u8 = undefined;
        const hash = hashHex(raw, &hbuf);
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const info = self.keys.get(hash) orelse return null;
        return info.uid;
    }

    pub fn list(self: *ApiKeys, gpa: std.mem.Allocator, uid: u64) ![]View {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var out: std.ArrayListUnmanaged(View) = .empty;
        var it = self.keys.iterator();
        while (it.next()) |e| if (e.value_ptr.uid == uid)
            try out.append(gpa, .{ .id = e.key_ptr.*, .prefix = e.value_ptr.prefix, .name = e.value_ptr.name, .created = e.value_ptr.created });
        return out.toOwnedSlice(gpa);
    }

    pub fn revoke(self: *ApiKeys, uid: u64, id: []const u8) bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const info = self.keys.get(id) orelse return false;
        if (info.uid != uid) return false;
        var sbuf: [80]u8 = undefined;
        if (std.fmt.bufPrint(&sbuf, "k_{s}", .{id})) |scope| self.nb.del(scope) else |_| {}
        if (self.keys.fetchRemove(id)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.name);
            self.gpa.free(kv.value.prefix);
        }
        return true;
    }
};
