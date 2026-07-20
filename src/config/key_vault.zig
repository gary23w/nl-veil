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

const StoredKey = struct {
    key: []const u8 = "",
    base_url: []const u8 = "",
    created: i64 = 0,
    // OAuth-only fields (empty/0 for a plain BYOK key). ignore_unknown_fields keeps old blobs readable.
    refresh_token: []const u8 = "",
    expires_at: i64 = 0,
    account_id: []const u8 = "",
};

/// The full OAuth bundle a logged-in provider stores (Cloudflare today). `key` is the current access token.
pub const OAuthBundle = struct {
    key: []const u8,
    refresh_token: []const u8,
    expires_at: i64,
    account_id: []const u8,
    base_url: []const u8,
};

pub const KeyMeta = struct {
    provider: []const u8,
    last4: []const u8,
    fingerprint: []const u8,
    base_url: []const u8,
    created: i64,
};

/// A remembered answer for one (uid, provider). `used` is the emptiness flag, NOT uid: uid 0 is the real
/// shared-server-key namespace (chat/service.zig:30), so it can't double as a sentinel.
const CachedResolve = struct {
    used: bool = false,
    uid: u64 = 0,
    provider: []const u8 = "",
    found: bool = false, // false = "this scope is definitively empty", cached just like a hit
    key: []const u8 = "",
    base_url: []const u8 = "",
    at: i64 = 0,
};

/// resolve() reads through Neuron, and Neuron.get FORKS neuron.exe (worker/neuron/client.zig:16) — a
/// process spawn, taken while this vault's global mutex is held. A chat turn resolves once per model role
/// (coding/thinking/prompting), and each role can miss the user's own vault and fall through to the shared
/// server key, so one turn paid for up to six spawns serialized behind one lock. Hence a small TTL cache.
///
/// The TTL is deliberately short, and it is NOT what protects a rotated key: every in-process mutation
/// (put/putOAuth/del — the only writers of a kv_ scope) drops the affected entry immediately, so a rotation
/// through the API or the admin routes takes effect on the next resolve. The TTL only bounds staleness
/// against a writer we cannot observe — someone running the neuron CLI against the same db while the server
/// is up. It also bounds how long unsealed key material sits resident in process memory.
const RESOLVE_TTL_S: i64 = 20;
const RESOLVE_SLOTS = 16;

pub const KeyVault = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    nb: Neuron,
    server_key: [32]u8,
    mu: std.Io.Mutex = .init,
    cache: [RESOLVE_SLOTS]CachedResolve = @splat(.{}),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, nb: Neuron, server_key: [32]u8) KeyVault {
        return .{ .gpa = gpa, .io = io, .nb = nb, .server_key = server_key };
    }

    // --- resolve cache. Every one of these runs with `mu` already held by the calling method. ---

    fn cacheFree(self: *KeyVault, e: *CachedResolve) void {
        if (!e.used) return;
        self.gpa.free(e.provider);
        self.gpa.free(e.key);
        self.gpa.free(e.base_url);
        e.* = .{};
    }

    fn cacheFind(self: *KeyVault, uid: u64, provider: []const u8) ?*CachedResolve {
        for (&self.cache) |*e| {
            if (e.used and e.uid == uid and std.mem.eql(u8, e.provider, provider)) return e;
        }
        return null;
    }

    /// Forget any remembered answer for (uid, provider). Sweeps ALL slots rather than stopping at the first
    /// match: a single missed duplicate is a rotated key that keeps getting served, so this errs on paranoid.
    fn cacheDrop(self: *KeyVault, uid: u64, provider: []const u8) void {
        for (&self.cache) |*e| {
            if (e.used and e.uid == uid and std.mem.eql(u8, e.provider, provider)) self.cacheFree(e);
        }
    }

    /// Remember `r` (null = definitively absent) for (uid, provider). Dropping first is what keeps the
    /// no-duplicates invariant cacheDrop relies on. On an allocation failure the entry is simply not
    /// cached — a slow resolve is always preferable to a wrong one.
    fn cacheStore(self: *KeyVault, uid: u64, provider: []const u8, r: ?Resolved, now: i64) void {
        self.cacheDrop(uid, provider);
        // Take a free slot, else evict the oldest. The live working set is a handful of (uid, provider)
        // pairs, so a linear scan beats any index here.
        var slot: *CachedResolve = &self.cache[0];
        var oldest: i64 = std.math.maxInt(i64);
        for (&self.cache) |*e| {
            if (!e.used) {
                slot = e;
                break;
            }
            if (e.at < oldest) {
                oldest = e.at;
                slot = e;
            }
        }
        self.cacheFree(slot);
        const p = self.gpa.dupe(u8, provider) catch return;
        const k = self.gpa.dupe(u8, if (r) |v| v.key else "") catch {
            self.gpa.free(p);
            return;
        };
        const b = self.gpa.dupe(u8, if (r) |v| v.base_url else "") catch {
            self.gpa.free(p);
            self.gpa.free(k);
            return;
        };
        slot.* = .{ .used = true, .uid = uid, .provider = p, .found = r != null, .key = k, .base_url = b, .at = now };
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
        // Invalidate on EVERY exit, not just the happy one: nb.put forgets the scope before it stores the new
        // value, so even a failed write can have already changed what's on disk. Defers unwind LIFO, so this
        // runs before the unlock — i.e. still under the lock, as the cache requires.
        defer self.cacheDrop(uid, provider);
        const json = try std.fmt.allocPrint(self.gpa, "{{\"key\":\"{s}\",\"base_url\":\"{s}\",\"created\":{d}}}", .{ key, base_url, std.Io.Timestamp.now(self.io, .real).toSeconds() });
        defer self.gpa.free(json);
        const sealed = seal(self.gpa, self.io, self.server_key, json) catch return error.SealFailed;
        defer self.gpa.free(sealed);
        var sb: [80]u8 = undefined;
        try self.nb.put(scopeKey(uid, provider, &sb), sealed);
    }

    /// Store an OAuth bundle (access + refresh token, expiry, account id) sealed under `provider`. Same
    /// at-rest sealing as a BYOK key; the extra fields ride in the same JSON blob. Values are size/charset
    /// checked like a key so a malformed token can't break the JSON.
    pub fn putOAuth(self: *KeyVault, uid: u64, provider: []const u8, access: []const u8, refresh: []const u8, expires_at: i64, account_id: []const u8, base_url: []const u8) !void {
        if (!validProvider(provider)) return error.BadProvider;
        if (access.len == 0 or access.len > 4096 or !cleanValue(access)) return error.BadKey;
        if (refresh.len > 4096 or !cleanValue(refresh)) return error.BadKey;
        if (account_id.len > 64 or !cleanValue(account_id)) return error.BadKey;
        if (base_url.len > 512 or !cleanValue(base_url)) return error.BadBaseUrl;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        defer self.cacheDrop(uid, provider); // OAuth refresh rotates the access token — see put()
        const json = try std.fmt.allocPrint(self.gpa, "{{\"key\":\"{s}\",\"base_url\":\"{s}\",\"created\":{d},\"refresh_token\":\"{s}\",\"expires_at\":{d},\"account_id\":\"{s}\"}}", .{ access, base_url, std.Io.Timestamp.now(self.io, .real).toSeconds(), refresh, expires_at, account_id });
        defer self.gpa.free(json);
        const sealed = seal(self.gpa, self.io, self.server_key, json) catch return error.SealFailed;
        defer self.gpa.free(sealed);
        var sb: [80]u8 = undefined;
        try self.nb.put(scopeKey(uid, provider, &sb), sealed);
    }

    /// Read back an OAuth bundle (null if absent/unsealable). `account_id`/`refresh_token` are empty for a
    /// plain BYOK key stored under the same provider, so a caller can tell the two apart by refresh_token.len.
    pub fn resolveOAuth(self: *KeyVault, uid: u64, provider: []const u8, alloc: std.mem.Allocator) ?OAuthBundle {
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
            .refresh_token = alloc.dupe(u8, parsed.value.refresh_token) catch "",
            .expires_at = parsed.value.expires_at,
            .account_id = alloc.dupe(u8, parsed.value.account_id) catch "",
            .base_url = alloc.dupe(u8, parsed.value.base_url) catch "",
        };
    }

    pub const Resolved = struct { key: []const u8, base_url: []const u8 };

    /// The hot read: chat resolves this once per model role per turn. Served from the TTL cache above when
    /// fresh, so the usual turn pays for one neuron.exe spawn instead of one per role. Returned strings are
    /// always `alloc`-owned copies — the cache keeps its own, so a caller's arena can die whenever it likes.
    pub fn resolve(self: *KeyVault, uid: u64, provider: []const u8, alloc: std.mem.Allocator) ?Resolved {
        if (!validProvider(provider)) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        if (self.cacheFind(uid, provider)) |e| {
            if (now - e.at < RESOLVE_TTL_S) {
                if (!e.found) return null;
                return .{
                    .key = alloc.dupe(u8, e.key) catch return null,
                    .base_url = alloc.dupe(u8, e.base_url) catch "",
                };
            }
            self.cacheFree(e);
        }
        var sb: [80]u8 = undefined;
        // A neuron.exe FAILURE is deliberately not cached. It means "we don't know", and remembering it as
        // "no key" would silently downgrade every turn for the rest of the TTL. Only definitive answers —
        // a stored key, or an empty scope — get remembered. An empty one is worth caching precisely because
        // it's the common case: chat/service.zig:59 misses here for every user who hasn't brought a key.
        const sealed = (self.nb.get(scopeKey(uid, provider, &sb)) catch return null) orelse {
            self.cacheStore(uid, provider, null, now);
            return null;
        };
        defer self.gpa.free(sealed);
        var out: ?Resolved = null;
        unseal: {
            const pt = open(self.gpa, self.server_key, std.mem.trim(u8, sealed, " \r\n\t")) orelse break :unseal;
            defer self.gpa.free(pt);
            const parsed = std.json.parseFromSlice(StoredKey, self.gpa, pt, .{ .ignore_unknown_fields = true }) catch break :unseal;
            defer parsed.deinit();
            out = .{
                .key = alloc.dupe(u8, parsed.value.key) catch return null,
                .base_url = alloc.dupe(u8, parsed.value.base_url) catch "",
            };
        }
        self.cacheStore(uid, provider, out, now);
        return out;
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
        defer self.cacheDrop(uid, provider); // a revoked key must stop being served immediately, not in TTL seconds
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
