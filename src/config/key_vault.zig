//! AES-256-GCM at-rest sealing + a write-only BYOK key vault (seal/open primitives + per-user provider keys).

const std = @import("std");
const Neuron = @import("../worker/neuron/client.zig").Neuron;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const NL = Aes256Gcm.nonce_length;
const TL = Aes256Gcm.tag_length;

pub fn deriveServerKey(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, data_dir: []const u8) [32]u8 {
    var key: [32]u8 = undefined;
    if (environ.get("NL_SECRET")) |s| {
        if (s.len > 0) {
            std.crypto.hash.sha2.Sha256.hash(s, &key, .{});
            return key;
        }
    }
    const path = std.fmt.allocPrint(gpa, "{s}/.server.key", .{data_dir}) catch {
        io.random(&key);
        return key;
    };
    defer gpa.free(path);
    const enc = std.base64.standard.Encoder;
    const dec = std.base64.standard.Decoder;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(128))) |b64raw| {
        defer gpa.free(b64raw);
        const b64 = std.mem.trim(u8, b64raw, " \r\n\t");
        if ((dec.calcSizeForSlice(b64) catch 0) == 32 and dec.decode(key[0..], b64) != error.InvalidPadding) return key;
    } else |_| {}
    io.random(&key);
    var b64buf: [64]u8 = undefined;
    const b64 = b64buf[0..enc.calcSize(32)];
    _ = enc.encode(b64, &key);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b64 }) catch {};
    return key;
}

pub fn seal(gpa: std.mem.Allocator, io: std.Io, key: [32]u8, plaintext: []const u8) ![]u8 {
    var nonce: [NL]u8 = undefined;
    io.random(&nonce);
    var tag: [TL]u8 = undefined;
    const ct = try gpa.alloc(u8, plaintext.len);
    defer gpa.free(ct);
    Aes256Gcm.encrypt(ct, &tag, plaintext, "", nonce, key);
    const blob = try gpa.alloc(u8, NL + TL + ct.len);
    defer gpa.free(blob);
    @memcpy(blob[0..NL], &nonce);
    @memcpy(blob[NL..][0..TL], &tag);
    @memcpy(blob[NL + TL ..], ct);
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(blob.len));
    _ = enc.encode(out, blob);
    return out;
}

pub fn open(gpa: std.mem.Allocator, key: [32]u8, b64: []const u8) ?[]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return null;
    if (n < NL + TL) return null;
    const blob = gpa.alloc(u8, n) catch return null;
    defer gpa.free(blob);
    dec.decode(blob, b64) catch return null;
    const nonce: [NL]u8 = blob[0..NL].*;
    const tag: [TL]u8 = blob[NL..][0..TL].*;
    const ct = blob[NL + TL ..];
    const pt = gpa.alloc(u8, ct.len) catch return null;
    Aes256Gcm.decrypt(pt, ct, tag, "", nonce, key) catch {
        gpa.free(pt);
        return null;
    };
    return pt;
}

const StoredKey = struct { key: []const u8 = "", base_url: []const u8 = "", created: i64 = 0 };

pub const KeyMeta = struct {
    provider: []const u8,
    last4: []const u8,
    fingerprint: []const u8,
    base_url: []const u8,
    created: i64,
};

pub const KeyVault = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    nb: Neuron,
    server_key: [32]u8,
    mu: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, nb: Neuron, server_key: [32]u8) KeyVault {
        return .{ .gpa = gpa, .io = io, .nb = nb, .server_key = server_key };
    }

    fn validProvider(p: []const u8) bool {
        if (p.len == 0 or p.len > 32) return false;
        for (p) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
        return true;
    }
    fn cleanValue(s: []const u8) bool {
        for (s) |c| if (c == '"' or c == '\\' or c < 0x20) return false;
        return true;
    }
    fn scopeKey(uid: u64, provider: []const u8, buf: *[80]u8) []const u8 {
        return std.fmt.bufPrint(buf, "kv_{d}_{s}", .{ uid, provider }) catch "";
    }

    pub fn put(self: *KeyVault, uid: u64, provider: []const u8, key: []const u8, base_url: []const u8) !void {
        if (!validProvider(provider)) return error.BadProvider;
        if (key.len == 0 or key.len > 512 or !cleanValue(key)) return error.BadKey;
        if (base_url.len > 512 or !cleanValue(base_url)) return error.BadBaseUrl;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const json = try std.fmt.allocPrint(self.gpa, "{{\"key\":\"{s}\",\"base_url\":\"{s}\",\"created\":{d}}}", .{ key, base_url, std.Io.Timestamp.now(self.io, .real).toSeconds() });
        defer self.gpa.free(json);
        const sealed = seal(self.gpa, self.io, self.server_key, json) catch return error.SealFailed;
        defer self.gpa.free(sealed);
        var sb: [80]u8 = undefined;
        try self.nb.put(scopeKey(uid, provider, &sb), sealed);
    }

    pub const Resolved = struct { key: []const u8, base_url: []const u8 };

    pub fn resolve(self: *KeyVault, uid: u64, provider: []const u8, alloc: std.mem.Allocator) ?Resolved {
        if (!validProvider(provider)) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var sb: [80]u8 = undefined;
        const sealed = (self.nb.get(scopeKey(uid, provider, &sb)) catch return null) orelse return null;
        defer self.gpa.free(sealed);
        const pt = open(self.gpa, self.server_key, std.mem.trim(u8, sealed, " \r\n\t")) orelse return null;
        defer self.gpa.free(pt);
        const parsed = std.json.parseFromSlice(StoredKey, self.gpa, pt, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        return .{
            .key = alloc.dupe(u8, parsed.value.key) catch return null,
            .base_url = alloc.dupe(u8, parsed.value.base_url) catch "",
        };
    }

    pub fn has(self: *KeyVault, uid: u64, provider: []const u8) bool {
        if (!validProvider(provider)) return false;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var sb: [80]u8 = undefined;
        const v = (self.nb.get(scopeKey(uid, provider, &sb)) catch return false) orelse return false;
        self.gpa.free(v);
        return true;
    }

    pub fn del(self: *KeyVault, uid: u64, provider: []const u8) void {
        if (!validProvider(provider)) return;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var sb: [80]u8 = undefined;
        self.nb.del(scopeKey(uid, provider, &sb));
    }

    pub fn list(self: *KeyVault, uid: u64, alloc: std.mem.Allocator) ![]KeyMeta {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var pb: [40]u8 = undefined;
        const prefix = std.fmt.bufPrint(&pb, "kv_{d}_", .{uid}) catch return &.{};
        const scs = self.nb.scopes(prefix) catch return &.{};
        defer {
            for (scs) |s| self.gpa.free(s);
            self.gpa.free(scs);
        }
        var out: std.ArrayListUnmanaged(KeyMeta) = .empty;
        for (scs) |sc| {
            const sealed = (self.nb.get(sc) catch continue) orelse continue;
            defer self.gpa.free(sealed);
            const pt = open(self.gpa, self.server_key, std.mem.trim(u8, sealed, " \r\n\t")) orelse continue;
            defer self.gpa.free(pt);
            const parsed = std.json.parseFromSlice(StoredKey, self.gpa, pt, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const k = parsed.value.key;
            var dig: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(k, &dig, .{});
            const fp = std.fmt.bytesToHex(dig[0..8], .lower);
            const last4 = if (k.len >= 4) k[k.len - 4 ..] else k;
            try out.append(alloc, .{
                .provider = alloc.dupe(u8, sc[prefix.len..]) catch continue,
                .last4 = alloc.dupe(u8, last4) catch continue,
                .fingerprint = alloc.dupe(u8, fp[0..]) catch continue,
                .base_url = alloc.dupe(u8, parsed.value.base_url) catch "",
                .created = parsed.value.created,
            });
        }
        return out.toOwnedSlice(alloc);
    }
};
