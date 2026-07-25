//! AES-256-GCM at-rest sealing + a write-only BYOK key vault (seal/open primitives + per-user provider keys).

const std = @import("std");
const log = std.log.scoped(.vault);
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
        // Both gates have to pass, and the decode has to SUCCEED. calcSizeForSlice only measures length and
        // trailing padding — it never looks at the alphabet — so a file with one bad character still sizes as
        // 32 and then fails to decode with InvalidCharacter. The old `!= error.InvalidPadding` spelling read
        // that failure as a pass and returned `key` still holding undefined stack bytes: an at-rest key nobody
        // generated and nobody persisted, which seals this boot's writes and cannot open the last boot's.
        // A file we cannot decode must fall through and be regenerated below.
        if ((dec.calcSizeForSlice(b64) catch 0) == 32) {
            if (dec.decode(key[0..], b64)) |_| return key else |_| {}
        }
    } else |_| {}
    io.random(&key);
    var b64buf: [64]u8 = undefined;
    const b64 = b64buf[0..enc.calcSize(32)];
    _ = enc.encode(b64, &key);
    // A swallowed failure here is the worst kind: this boot seals every BYOK key with a key that was
    // never written down, so the NEXT boot generates a different one and nothing sealed today can be
    // opened again — permanently, with no error anywhere. The function still returns the key (the
    // server must run), but the operator has to be TOLD, because the damage accrues silently for as
    // long as the process lives and only surfaces after a restart, far from the cause. (Ledger 0070;
    // the swallow itself was found by sweeping for writes whose failure goes unreported.)
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b64 }) catch |e| {
        // warn, not err, on this repo's own precedent: `seedDefaultAdmin` logs the default-password
        // condition at warn — serious, security-relevant, operator-fixable, server keeps running.
        // Same shape. It also keeps the case testable: Zig's runner fails any test that logs an err,
        // so an `err` here could only be asserted by never exercising it, which is the wrong trade
        // for a diagnostic whose whole job is to fire.
        log.warn(
            "at-rest key could not be persisted to {s} ({t}) — this boot's stored provider keys will NOT be readable after a restart. Fix the data dir's permissions, or set NL_SECRET so the key is derived instead of stored.",
            .{ path, e },
        );
    };
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

    /// Teardown. In main.zig the vault is a process-lifetime singleton and nothing calls this, but the resolve
    /// cache owns three heap strings per occupied slot — so without it the only way to exercise resolve() is a
    /// test-only drain helper, which harness/TESTING.md says not to write. Takes no lock: it runs when the last
    /// user is gone.
    pub fn deinit(self: *KeyVault) void {
        for (&self.cache) |*e| self.cacheFree(e);
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
    /// The record is built by interpolating this value straight into a JSON string and read back
    /// through `std.json`, so what this admits has to be what the READER can recover. Quotes,
    /// backslashes and control bytes would break out of the string; invalid UTF-8 passes every
    /// byte check but makes std.json reject the whole record with SyntaxError — which meant a key
    /// could be accepted, sealed, answered 201 Created, and then be permanently unresolvable, with
    /// the miss cached as "no key here". Valid multi-byte UTF-8 is unaffected.
    fn cleanValue(s: []const u8) bool {
        for (s) |c| if (c == '"' or c == '\\' or c < 0x20) return false;
        return std.unicode.utf8ValidateSlice(s);
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
            // Built field by field so a partial failure frees what it already took. The old form
            // duped all four inside the struct literal with `catch continue`, which abandoned every
            // earlier dupe of that row on the way out. Production passes res.arena, so nothing was
            // ever actually lost — but the signature takes any Allocator, and a caller that frees
            // its own memory (a test, or any future in-process use) would have paid for it.
            const provider = alloc.dupe(u8, sc[prefix.len..]) catch continue;
            const l4 = alloc.dupe(u8, last4) catch {
                alloc.free(provider);
                continue;
            };
            const fpz = alloc.dupe(u8, fp[0..]) catch {
                alloc.free(provider);
                alloc.free(l4);
                continue;
            };
            const burl = alloc.dupe(u8, parsed.value.base_url) catch "";
            out.append(alloc, .{
                .provider = provider,
                .last4 = l4,
                .fingerprint = fpz,
                .base_url = burl,
                .created = parsed.value.created,
            }) catch {
                alloc.free(provider);
                alloc.free(l4);
                alloc.free(fpz);
                if (burl.len > 0) alloc.free(burl);
                continue;
            };
        }
        return out.toOwnedSlice(alloc);
    }
};

// ====================================================================================================
// This module is the BYOK secret store, so what the tests below pin is the cryptographic and structural
// contract rather than the plumbing: that seal/open is a lossless round trip, that everything OTHER than
// the right key — a wrong key, a bent nonce, a bent tag, a bent ciphertext byte — fails CLOSED instead of
// handing back plausible garbage, that no two seals ever reuse a nonce, that the at-rest key a boot hands
// out is the one the next boot will read back, and that what actually lands in the datastore carries no
// plaintext secret. The pure-crypto half runs everywhere; the half that needs a real store drives the
// neuron.exe CLI against a throwaway db and skips when the checkout has no binary (bin/ is gitignored).
// ====================================================================================================

const builtin = @import("builtin");

/// TEST ONLY. A fixed at-rest key, so a test can open the stored bytes itself and see what is really there.
/// It is a constant in a public source file — which is exactly why it must never be anything but test data.
const TEST_SERVER_KEY: [32]u8 = @splat(0x5a);

/// TEST ONLY. Decode a sealed blob, flip one bit at `idx`, re-encode. `idx` selects the region: [0, NL) is
/// the nonce, [NL, NL+TL) the tag, [NL+TL, …) the ciphertext.
fn bendSealed(gpa: std.mem.Allocator, b64: []const u8, idx: usize) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(b64);
    const blob = try gpa.alloc(u8, n);
    defer gpa.free(blob);
    try dec.decode(blob, b64);
    blob[idx] ^= 0x01;
    const out = try gpa.alloc(u8, enc.calcSize(n));
    _ = enc.encode(out, blob);
    return out;
}

/// TEST ONLY. The nonce a sealed blob carries — the thing that must never repeat under one key.
fn nonceOf(b64: []const u8) ![NL]u8 {
    const dec = std.base64.standard.Decoder;
    var full: [512]u8 = undefined;
    const n = try dec.calcSizeForSlice(b64);
    if (n > full.len) return error.BlobTooBigForThisHelper;
    try dec.decode(full[0..n], b64);
    return full[0..NL].*;
}

test "seal/open round-trips byte for byte — empty, short, long and binary payloads alike" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A NUL and a 0xff in the middle are the ones that catch a C-string or a text-only assumption; the long
    // one crosses many AES blocks; the empty one is the degenerate blob of exactly nonce+tag and nothing else.
    var binary: [256]u8 = undefined;
    for (&binary, 0..) |*b, i| b.* = @intCast(i);
    var long: [3000]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @intCast((i * 7) % 251);

    const cases = [_][]const u8{
        "",
        "x",
        "not-a-real-key-just-test-data-0123456789",
        &binary,
        &long,
    };
    for (cases) |pt| {
        const sealed = try seal(gpa, io, TEST_SERVER_KEY, pt);
        defer gpa.free(sealed);
        const back = open(gpa, TEST_SERVER_KEY, sealed) orelse return error.RoundTripFailed;
        defer gpa.free(back);
        try std.testing.expectEqualSlices(u8, pt, back);
        // The blob is exactly nonce + tag + ciphertext, and the ciphertext is the plaintext's own length —
        // GCM is a stream mode, so a sealed value's size leaks nothing but the size.
        const dec = std.base64.standard.Decoder;
        try std.testing.expectEqual(NL + TL + pt.len, try dec.calcSizeForSlice(sealed));
    }
}

test "open fails closed for the wrong key — including a key that is one bit off" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = "test-vault-payload-not-a-credential";
    const sealed = try seal(gpa, io, TEST_SERVER_KEY, secret);
    defer gpa.free(sealed);

    const right = open(gpa, TEST_SERVER_KEY, sealed) orelse return error.ControlRoundTripFailed;
    defer gpa.free(right);
    try std.testing.expectEqualStrings(secret, right);

    const other: [32]u8 = @splat(0xa5);
    try std.testing.expect(open(gpa, other, sealed) == null);

    // One flipped bit, in every byte of the key in turn. A mode without authentication would return 35 bytes
    // of plausible-looking rubbish here, and the caller — resolve() — would hand it to a provider as a key.
    for (0..32) |i| {
        var near = TEST_SERVER_KEY;
        near[i] ^= 0x01;
        try std.testing.expect(open(gpa, near, sealed) == null);
    }
}

test "a tampered blob never opens — nonce, tag and ciphertext regions, truncation and junk alike" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = "test-vault-payload-not-a-credential";
    const sealed = try seal(gpa, io, TEST_SERVER_KEY, secret);
    defer gpa.free(sealed);
    const blob_len = NL + TL + secret.len;

    // One bit, anywhere in the blob — the nonce it was sealed under, the authentication tag, or the body.
    // This is the whole reason the store uses an AEAD: an attacker with write access to the datastore must
    // not be able to steer what comes back out of it.
    for (0..blob_len) |i| {
        const bent = try bendSealed(gpa, sealed, i);
        defer gpa.free(bent);
        try std.testing.expect(open(gpa, TEST_SERVER_KEY, bent) == null);
    }

    // …and the malformed shapes that reach open() from a corrupted or half-written store.
    try std.testing.expect(open(gpa, TEST_SERVER_KEY, "") == null);
    try std.testing.expect(open(gpa, TEST_SERVER_KEY, "this is not base64 at all") == null);
    try std.testing.expect(open(gpa, TEST_SERVER_KEY, sealed[0 .. sealed.len - 4]) == null); // truncated
    try std.testing.expect(open(gpa, TEST_SERVER_KEY, sealed[4..]) == null); // head chopped off

    // A well-formed base64 string that is shorter than a nonce + tag can be: below the floor open() checks.
    const enc = std.base64.standard.Encoder;
    const runt: [NL + TL - 1]u8 = @splat('z');
    var runt_b64: [64]u8 = undefined;
    const rb = runt_b64[0..enc.calcSize(runt.len)];
    _ = enc.encode(rb, &runt);
    try std.testing.expect(open(gpa, TEST_SERVER_KEY, rb) == null);
}

test "every seal draws a fresh nonce, so sealing one secret twice never produces one blob twice" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // If two seals of the same plaintext under the same key were equal, the store would leak equality of
    // secrets — anyone reading it could tell that two users brought the SAME key. Under GCM a repeated
    // (key, nonce) is worse than that: it hands out the keystream.
    const secret = "test-vault-payload-not-a-credential";
    const n = 8;
    var blobs: [n][]u8 = undefined;
    var nonces: [n][NL]u8 = undefined;
    for (0..n) |i| {
        blobs[i] = try seal(gpa, io, TEST_SERVER_KEY, secret);
        nonces[i] = try nonceOf(blobs[i]);
    }
    defer for (blobs) |b| gpa.free(b);

    for (0..n) |i| {
        for (i + 1..n) |j| {
            try std.testing.expect(!std.mem.eql(u8, blobs[i], blobs[j]));
            try std.testing.expect(!std.mem.eql(u8, &nonces[i], &nonces[j]));
        }
        // …and every one of them still opens to the same plaintext.
        const back = open(gpa, TEST_SERVER_KEY, blobs[i]) orelse return error.RoundTripFailed;
        defer gpa.free(back);
        try std.testing.expectEqualStrings(secret, back);
    }
}

test "a sealed blob survives the datastore's line-oriented pipe: one line of standard base64, no plaintext" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Neuron.get (worker/neuron/client.zig) returns the first non-empty, non-'#' TRIMMED LINE of an export,
    // and resolve() trims again before opening. A sealed value that carried a newline, a leading '#' or
    // surrounding whitespace would come back clipped and silently unopenable.
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 13) % 256);
    const sealed = try seal(gpa, io, TEST_SERVER_KEY, &payload);
    defer gpa.free(sealed);

    for (sealed) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=');
    try std.testing.expect(sealed[0] != '#');
    try std.testing.expectEqualStrings(sealed, std.mem.trim(u8, sealed, " \r\n\t"));

    // And the ciphertext is genuinely ciphertext: none of the plaintext shows through the encoding.
    const marker = "sk-test-marker-not-a-real-key";
    const sealed2 = try seal(gpa, io, TEST_SERVER_KEY, marker);
    defer gpa.free(sealed2);
    try std.testing.expect(std.mem.indexOf(u8, sealed2, marker) == null);
}

test "deriveServerKey: NL_SECRET is the whole input — same secret same key, different secret different key" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const phrase = "test-phrase-not-a-real-secret-aaaa";
    try env.put("NL_SECRET", phrase);

    // Deterministic and portable: it is exactly SHA-256 of the variable, so two nodes given the same
    // NL_SECRET can open each other's vault and nothing on disk is consulted at all.
    const k1 = deriveServerKey(gpa, io, &env, "no/such/dir/for/this/test");
    const k2 = deriveServerKey(gpa, io, &env, "another/nonexistent/dir");
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(phrase, &want, .{});
    try std.testing.expectEqualSlices(u8, &want, &k1);
    try std.testing.expectEqualSlices(u8, &k1, &k2);

    try env.put("NL_SECRET", "test-phrase-not-a-real-secret-aaab"); // one character apart
    const k3 = deriveServerKey(gpa, io, &env, "no/such/dir/for/this/test");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k3));
}

/// TEST ONLY. The invariant every deriveServerKey path owes the vault: the key it hands back is the key the
/// NEXT boot will read out of {data_dir}/.server.key. The moment those two differ, every secret this process
/// sealed becomes permanently unopenable — the vault survives a restart or it is not a vault.
fn expectPersistedKeyMatches(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, key: [32]u8) !void {
    var pb: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/.server.key", .{dir});
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(128));
    defer gpa.free(raw);
    const b64 = std.mem.trim(u8, raw, " \r\n\t");
    const dec = std.base64.standard.Decoder;
    try std.testing.expectEqual(@as(usize, 32), dec.calcSizeForSlice(b64) catch 0);
    var disk: [32]u8 = undefined;
    try dec.decode(disk[0..], b64);
    try std.testing.expectEqualSlices(u8, &key, &disk);
}

test "deriveServerKey: the key it returns is the key it persisted — for a fresh, a corrupt and a short file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-keyvault-derive-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    inline for (.{ "/a", "/b", "/corrupt", "/short" }) |sub|
        _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ sub, .default_dir) catch {};

    var env = std.process.Environ.Map.init(gpa); // no NL_SECRET: the on-disk path
    defer env.deinit();

    // FRESH: generate, persist, and hand back what was persisted.
    const a1 = deriveServerKey(gpa, io, &env, root ++ "/a");
    try expectPersistedKeyMatches(gpa, io, root ++ "/a", a1);
    // RESTART: the same directory yields the same key, or every sealed secret in it is lost.
    const a2 = deriveServerKey(gpa, io, &env, root ++ "/a");
    try std.testing.expectEqualSlices(u8, &a1, &a2);
    // A different data dir is a different vault.
    const b1 = deriveServerKey(gpa, io, &env, root ++ "/b");
    try std.testing.expect(!std.mem.eql(u8, &a1, &b1));

    // CORRUPT: 44 characters, correct padding, one character outside the base64 alphabet. calcSizeForSlice
    // sizes this at 32 (it only measures length and padding), so the length gate alone lets it through and
    // the decode is what has to catch it. An accepted-but-undecodable file used to return undefined stack
    // bytes as the server's AES key — random, unpersisted, and different on the next call.
    const enc = std.base64.standard.Encoder;
    const seed: [32]u8 = @splat(0x11);
    var cbuf: [64]u8 = undefined;
    const corrupt = cbuf[0..enc.calcSize(32)];
    _ = enc.encode(corrupt, &seed);
    corrupt[10] = '!';
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/corrupt/.server.key", .data = corrupt });
    const c1 = deriveServerKey(gpa, io, &env, root ++ "/corrupt");
    try expectPersistedKeyMatches(gpa, io, root ++ "/corrupt", c1);
    const c2 = deriveServerKey(gpa, io, &env, root ++ "/corrupt");
    try std.testing.expectEqualSlices(u8, &c1, &c2);

    // SHORT: valid base64 of the wrong length — rejected by the size gate, regenerated the same way.
    const half: [16]u8 = @splat(0x22);
    var hbuf: [32]u8 = undefined;
    const short = hbuf[0..enc.calcSize(16)];
    _ = enc.encode(short, &half);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/short/.server.key", .data = short });
    const s1 = deriveServerKey(gpa, io, &env, root ++ "/short");
    try expectPersistedKeyMatches(gpa, io, root ++ "/short", s1);

    // An EMPTY NL_SECRET is not a secret: it must fall through to the file, not seal everything under
    // SHA-256(""), which is a constant every reader of this source already knows.
    try env.put("NL_SECRET", "");
    var empty_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &empty_hash, .{});
    const e1 = deriveServerKey(gpa, io, &env, root ++ "/a");
    try std.testing.expect(!std.mem.eql(u8, &empty_hash, &e1));
    try std.testing.expectEqualSlices(u8, &a1, &e1);
}

test "scopeKey addresses exactly one (uid, provider) — no user's list prefix can reach another's scope" {
    // list() sweeps "kv_{uid}_" and takes everything after it as the provider name. The trailing underscore
    // is the entire reason uid 1 cannot read uid 11's vault, and providers may themselves contain digits and
    // underscores — so the separation is worth proving rather than eyeballing.
    var sb: [80]u8 = undefined;
    try std.testing.expectEqualStrings("kv_1_openai", KeyVault.scopeKey(1, "openai", &sb));
    try std.testing.expectEqualStrings("kv_11_openai", KeyVault.scopeKey(11, "openai", &sb));
    try std.testing.expectEqualStrings("kv_0_a", KeyVault.scopeKey(0, "a", &sb));

    const uids = [_]u64{ 0, 1, 2, 11, 111, 1_000_000, std.math.maxInt(u64) };
    const providers = [_][]const u8{ "openai", "o", "1_openai", "a_b_c", "cloudflare" };
    for (uids) |mine| {
        var pb: [40]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&pb, "kv_{d}_", .{mine}); // exactly what list() builds
        for (uids) |theirs| {
            for (providers) |p| {
                var tb: [80]u8 = undefined;
                const scope = KeyVault.scopeKey(theirs, p, &tb);
                try std.testing.expect(scope.len > 0);
                if (mine == theirs) {
                    try std.testing.expect(std.mem.startsWith(u8, scope, prefix));
                    try std.testing.expectEqualStrings(p, scope[prefix.len..]); // list()'s provider slice
                } else {
                    try std.testing.expect(!std.mem.startsWith(u8, scope, prefix));
                }
            }
        }
    }

    // The widest key validProvider can admit still fits the buffer. Were it ever narrowed, bufPrint would
    // fail and scopeKey would return "" — one shared scope for every user and every provider at once.
    const widest = KeyVault.scopeKey(std.math.maxInt(u64), "a" ** 32, &sb);
    try std.testing.expectEqual(@as(usize, 3 + 20 + 1 + 32), widest.len);
    try std.testing.expect(std.mem.startsWith(u8, widest, "kv_18446744073709551615_"));
}

test "validProvider is the scope-name boundary: only a-zA-Z0-9-_ , 1..32 characters" {
    try std.testing.expect(KeyVault.validProvider("openai"));
    try std.testing.expect(KeyVault.validProvider("a"));
    try std.testing.expect(KeyVault.validProvider("Anthropic-2_x"));
    try std.testing.expect(KeyVault.validProvider("a" ** 32));

    try std.testing.expect(!KeyVault.validProvider("")); // would address "kv_7_"
    try std.testing.expect(!KeyVault.validProvider("a" ** 33)); // one over the cap the buffer is sized for
    try std.testing.expect(!KeyVault.validProvider("../../etc")); // the provider is pasted into a scope name
    try std.testing.expect(!KeyVault.validProvider("open ai"));
    try std.testing.expect(!KeyVault.validProvider("open\"ai"));
    try std.testing.expect(!KeyVault.validProvider("open\nai"));
    try std.testing.expect(!KeyVault.validProvider("open.ai"));
    try std.testing.expect(!KeyVault.validProvider("open/ai"));
    try std.testing.expect(!KeyVault.validProvider("ünïcode"));
}

test "cleanValue is the record's JSON boundary: what it accepts round-trips through a real parser" {
    const gpa = std.testing.allocator;

    // put()/putOAuth() interpolate the key and base_url straight into a hand-rolled JSON object with no
    // escaping whatsoever, so this predicate IS the boundary. Proving it by round trip rather than by
    // string-matching an escaped form: what has to hold is that a user's value cannot forge structure.
    var accepted: [96]u8 = undefined;
    var n: usize = 0;
    var c: u8 = 0x20;
    while (c < 0x7f) : (c += 1) {
        if (c == '"' or c == '\\') continue;
        accepted[n] = c;
        n += 1;
    }
    const value = accepted[0..n];
    try std.testing.expect(KeyVault.cleanValue(value));
    const doc = try std.fmt.allocPrint(gpa, "{{\"key\":\"{s}\",\"base_url\":\"{s}\",\"created\":7}}", .{ value, value });
    defer gpa.free(doc);
    const parsed = try std.json.parseFromSlice(StoredKey, gpa, doc, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(value, parsed.value.key);
    try std.testing.expectEqualStrings(value, parsed.value.base_url);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.created);

    // The rejected set, and WHY it is rejected — the counterfactual. A value carrying one quote does not
    // merely produce ugly JSON: it parses cleanly as a different record, setting a field the caller was
    // never handed. (A test that only checked "the escaper ran" would pass against a no-op escaper.)
    try std.testing.expect(!KeyVault.cleanValue("a\"b"));
    try std.testing.expect(!KeyVault.cleanValue("a\\b"));
    try std.testing.expect(!KeyVault.cleanValue("a\nb"));
    try std.testing.expect(!KeyVault.cleanValue("a\tb"));
    try std.testing.expect(!KeyVault.cleanValue("a\x00b"));

    const forger = "x\",\"account_id\":\"forged";
    try std.testing.expect(!KeyVault.cleanValue(forger));
    const bad = try std.fmt.allocPrint(gpa, "{{\"key\":\"{s}\",\"base_url\":\"\",\"created\":7}}", .{forger});
    defer gpa.free(bad);
    const forged = try std.json.parseFromSlice(StoredKey, gpa, bad, .{ .ignore_unknown_fields = true });
    defer forged.deinit();
    try std.testing.expectEqualStrings("x", forged.value.key); // not what was submitted
    try std.testing.expectEqualStrings("forged", forged.value.account_id); // a field the caller cannot set

    // Valid multi-byte UTF-8 is inside the accepted set and survives the same round trip.
    try std.testing.expect(KeyVault.cleanValue("clé-café"));
    const utf = try std.fmt.allocPrint(gpa, "{{\"key\":\"{s}\"}}", .{"clé-café"});
    defer gpa.free(utf);
    const up = try std.json.parseFromSlice(StoredKey, gpa, utf, .{ .ignore_unknown_fields = true });
    defer up.deinit();
    try std.testing.expectEqualStrings("clé-café", up.value.key);
}

test "cleanValue rejects invalid UTF-8, because the reader would refuse the record it produces" {
    const gpa = std.testing.allocator;
    // Bytes that clear every character check (no quote, no backslash, nothing under 0x20) but do
    // not form UTF-8: a lone continuation byte, a truncated two- and three-byte sequence, a raw
    // 0xFF, and a valid key with one stray high byte pasted into the middle.
    const bad = [_][]const u8{
        "\x80",
        "sk-live\xC3",
        "\xE2\x82",
        "\xFF\xFE",
        "sk-live-\xC0\xAFabc",
    };
    for (bad) |b| {
        try std.testing.expect(!KeyVault.cleanValue(b));

        // THE COUNTERFACTUAL, and the reason this is a rejection rather than a nicety: the old
        // check passed these, the record was sealed and stored, 201 Created was returned — and
        // then every read of it failed here, permanently, with the miss cached as "no key".
        const rec = try std.fmt.allocPrint(gpa, "{{\"key\":\"{s}\",\"base_url\":\"\",\"created\":7}}", .{b});
        defer gpa.free(rec);
        try std.testing.expectError(
            error.SyntaxError,
            std.json.parseFromSlice(StoredKey, gpa, rec, .{ .ignore_unknown_fields = true }),
        );
    }
    // The boundary stays where it was for everything legitimate: ASCII and real multi-byte UTF-8.
    try std.testing.expect(KeyVault.cleanValue("sk-live-0123456789"));
    try std.testing.expect(KeyVault.cleanValue("clé-café-日本語-🔑"));
}

// ------------------------------------------------------------------ the half that needs a real datastore

const NEURON_BIN = if (builtin.os.tag == .windows) "bin/neuron.exe" else "bin/neuron";

/// TEST ONLY. The vault keeps NOTHING in memory but a 20-second resolve cache — every value goes out through
/// the neuron.exe CLI — so these drive the real store against a throwaway db under cwd, and skip if the
/// checkout has no binary where the test runner can reach it (bin/ is gitignored).
const Live = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    root: []const u8,
    dbbuf: [96]u8,
    vault: KeyVault,

    /// Starts in place: `io` and the db path both point back into this struct, so it must not be copied.
    fn start(self: *Live, root: []const u8) !void {
        self.gpa = std.testing.allocator;
        // The REAL process environ, exactly as main.zig builds it. `Io.Threaded.init(gpa, .{})` hands spawned
        // children an EMPTY environment, and under `zig build test` neuron.exe then comes up with no TEMP and
        // no SystemRoot: every write fails into a `catch`, and the assertions below would be measuring a store
        // that is not there (harness/TESTING.md, ledger 0015).
        const environ: std.process.Environ = if (builtin.os.tag == .windows)
            .{ .block = .global }
        else
            .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
        self.threaded = std.Io.Threaded.init(self.gpa, .{ .environ = environ });
        self.root = root;
        const io = self.threaded.io();
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
        const db = std.fmt.bufPrint(&self.dbbuf, "{s}/vault.db", .{root}) catch unreachable;
        self.vault = KeyVault.init(self.gpa, io, Neuron.init(self.gpa, io, NEURON_BIN, db), TEST_SERVER_KEY);
        self.probe() catch |e| {
            self.stop(); // the caller's `defer stop()` never registers on an error return
            return e;
        };
    }

    /// A real WRITE→READ round trip, not just "the binary spawned": a neuron.exe that starts but cannot
    /// persist would make every scope read as empty, and "the plaintext is not in the store" would pass
    /// trivially against a store with nothing in it at all.
    fn probe(self: *Live) !void {
        const val = "bmxfdmVpbF92YXVsdF9wcm9iZQ";
        self.vault.nb.put("nl_probe", val) catch return error.SkipZigTest;
        const got = (self.vault.nb.get("nl_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, val)) return error.SkipZigTest;
    }

    fn stop(self: *Live) void {
        self.vault.deinit();
        std.Io.Dir.cwd().deleteTree(self.threaded.io(), self.root) catch {};
        self.threaded.deinit();
    }
};

test "live neuron-db: the vault is write-only — the stored bytes and the listed metadata carry no key" {
    var h: Live = undefined;
    try h.start("zig-keyvault-store-tmp");
    defer h.stop();
    const gpa = h.gpa;
    const V = &h.vault;

    const FAKE_KEY = "sk-test-not-a-real-credential-000000000000c0ffee";
    try V.put(7, "openai", FAKE_KEY, "https://api.example.invalid/v1");

    var sb: [80]u8 = undefined;
    const scope = KeyVault.scopeKey(7, "openai", &sb);
    const stored = (try V.nb.get(scope)) orelse return error.NothingWasStored;
    defer gpa.free(stored);

    // The bytes actually on disk, decoded — this is the assertion that matters: whoever reads the datastore
    // gets ciphertext, not a key. Checking the decoded blob and not just the base64 text is the point; a
    // "sealing" that merely base64-encoded the record would sail through a text search for the key.
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(stored);
    const raw = try gpa.alloc(u8, n);
    defer gpa.free(raw);
    try dec.decode(raw, stored);
    try std.testing.expect(n > NL + TL);
    try std.testing.expect(std.mem.indexOf(u8, stored, FAKE_KEY) == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, FAKE_KEY) == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, FAKE_KEY[3..]) == null); // nor the body without its prefix
    try std.testing.expect(std.mem.indexOf(u8, scope, FAKE_KEY) == null); // nor the addressing

    // …and it IS the record, held shut by the server key alone.
    const pt = open(gpa, TEST_SERVER_KEY, stored) orelse return error.StoredBlobWouldNotOpen;
    defer gpa.free(pt);
    try std.testing.expect(std.mem.indexOf(u8, pt, FAKE_KEY) != null);
    var wrong = TEST_SERVER_KEY;
    wrong[0] ^= 0x01;
    try std.testing.expect(open(gpa, wrong, stored) == null);

    // The metadata the API hands back is a deliberate, bounded disclosure: the last four characters, and a
    // fingerprint any client can recompute from the key it holds. Nothing else of the key may appear in it.
    const metas = try V.list(7, gpa);
    defer {
        for (metas) |m| {
            gpa.free(m.provider);
            gpa.free(m.last4);
            gpa.free(m.fingerprint);
            gpa.free(m.base_url);
        }
        gpa.free(metas);
    }
    try std.testing.expectEqual(@as(usize, 1), metas.len);
    const m = metas[0];
    try std.testing.expectEqualStrings("openai", m.provider);
    try std.testing.expectEqualStrings("https://api.example.invalid/v1", m.base_url);
    try std.testing.expectEqualStrings(FAKE_KEY[FAKE_KEY.len - 4 ..], m.last4);
    try std.testing.expect(m.created > 0);

    var dig: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(FAKE_KEY, &dig, .{});
    const want_fp = std.fmt.bytesToHex(dig[0..8], .lower); // config/keys_api.zig recomputes this same value
    try std.testing.expectEqualStrings(&want_fp, m.fingerprint);

    const body = FAKE_KEY[0 .. FAKE_KEY.len - 4]; // everything the last4 disclosure does not cover
    for ([_][]const u8{ m.provider, m.last4, m.fingerprint, m.base_url }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, field, body) == null);
        try std.testing.expect(std.mem.indexOf(u8, field, FAKE_KEY) == null);
    }
}

test "live neuron-db: one user's key is unreachable from another uid — uid 1 and uid 11 included" {
    var h: Live = undefined;
    try h.start("zig-keyvault-users-tmp");
    defer h.stop();
    const gpa = h.gpa;
    const V = &h.vault;

    // uid 1 and uid 11 are the trap: "kv_1_" is a prefix of "kv_11_openai" up to the separator, and list()
    // sweeps by prefix. If the underscore ever left the format, one user would enumerate the other's vault.
    const KEY_ONE = "sk-test-uid-one-not-a-real-credential-1111";
    const KEY_ELEVEN = "sk-test-uid-eleven-not-a-real-credential-2222";
    const KEY_ONE_ALT = "sk-test-uid-one-second-provider-3333";
    try V.put(1, "openai", KEY_ONE, "");
    try V.put(11, "openai", KEY_ELEVEN, "");
    try V.put(1, "anthropic", KEY_ONE_ALT, "");

    const r1 = V.resolve(1, "openai", gpa) orelse return error.OwnKeyNotResolvable;
    defer {
        gpa.free(r1.key);
        gpa.free(r1.base_url);
    }
    try std.testing.expectEqualStrings(KEY_ONE, r1.key);

    const r11 = V.resolve(11, "openai", gpa) orelse return error.OwnKeyNotResolvable;
    defer {
        gpa.free(r11.key);
        gpa.free(r11.base_url);
    }
    try std.testing.expectEqualStrings(KEY_ELEVEN, r11.key);

    try std.testing.expect(V.resolve(2, "openai", gpa) == null); // a user who brought no key gets nothing
    try std.testing.expect(V.resolve(1, "gemini", gpa) == null); // …and neither does an unclaimed provider
    try std.testing.expect(V.has(1, "openai"));
    try std.testing.expect(V.has(11, "openai"));
    try std.testing.expect(!V.has(2, "openai"));

    const mine = try V.list(1, gpa);
    defer {
        for (mine) |m| {
            gpa.free(m.provider);
            gpa.free(m.last4);
            gpa.free(m.fingerprint);
            gpa.free(m.base_url);
        }
        gpa.free(mine);
    }
    try std.testing.expectEqual(@as(usize, 2), mine.len);
    var saw_openai = false;
    var saw_anthropic = false;
    for (mine) |m| {
        if (std.mem.eql(u8, m.provider, "openai")) saw_openai = true;
        if (std.mem.eql(u8, m.provider, "anthropic")) saw_anthropic = true;
        // uid 11's key never surfaces in uid 1's listing, not even by its four disclosed characters.
        try std.testing.expect(!std.mem.eql(u8, m.last4, KEY_ELEVEN[KEY_ELEVEN.len - 4 ..]));
    }
    try std.testing.expect(saw_openai and saw_anthropic);

    const theirs = try V.list(11, gpa);
    defer {
        for (theirs) |m| {
            gpa.free(m.provider);
            gpa.free(m.last4);
            gpa.free(m.fingerprint);
            gpa.free(m.base_url);
        }
        gpa.free(theirs);
    }
    try std.testing.expectEqual(@as(usize, 1), theirs.len);
    try std.testing.expectEqualStrings("openai", theirs[0].provider);

    const nobody = try V.list(2, gpa);
    defer gpa.free(nobody);
    try std.testing.expectEqual(@as(usize, 0), nobody.len);
}

test "live neuron-db: a rotation or a revocation is served at once, not RESOLVE_TTL_S later" {
    var h: Live = undefined;
    try h.start("zig-keyvault-rotate-tmp");
    defer h.stop();
    const gpa = h.gpa;
    const V = &h.vault;
    const io = h.threaded.io();

    const OLD = "sk-test-rotated-out-not-a-credential-aaaa";
    const NEW = "sk-test-rotated-in-not-a-credential-bbbb";
    const t0 = std.Io.Timestamp.now(io, .real).toSeconds(); // the same clock resolve() reads

    try V.put(3, "openai", OLD, "");
    const first = V.resolve(3, "openai", gpa) orelse return error.KeyNotResolvable;
    defer {
        gpa.free(first.key);
        gpa.free(first.base_url);
    }
    try std.testing.expectEqualStrings(OLD, first.key); // …and the answer is now in the resolve cache

    // A compromised key is replaced through the API and must stop being served IMMEDIATELY. The cache entry
    // is what could serve the old one, so this is the property put()'s cacheDrop exists for.
    try V.put(3, "openai", NEW, "");
    const second = V.resolve(3, "openai", gpa) orelse return error.RotatedKeyNotResolvable;
    defer {
        gpa.free(second.key);
        gpa.free(second.base_url);
    }
    try std.testing.expectEqualStrings(NEW, second.key);

    // Same for a revocation: gone means gone, this second — including from list(), which still sees the
    // scope id after a forget but must not report a key whose value is no longer there.
    V.del(3, "openai");
    try std.testing.expect(V.resolve(3, "openai", gpa) == null);
    try std.testing.expect(!V.has(3, "openai"));
    const after = try V.list(3, gpa);
    defer gpa.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);

    // The premise: all of that happened inside the window a stale cache entry would still have been served
    // from. If this box was slow enough for the TTL to expire on its own, the run proved nothing — say so.
    const elapsed = std.Io.Timestamp.now(io, .real).toSeconds() - t0;
    if (elapsed >= RESOLVE_TTL_S) return error.SkipZigTest;
}

test "live neuron-db: an OAuth bundle round-trips whole, and its refresh token is not on disk in clear" {
    var h: Live = undefined;
    try h.start("zig-keyvault-oauth-tmp");
    defer h.stop();
    const gpa = h.gpa;
    const V = &h.vault;

    const ACCESS = "test-access-token-not-a-real-credential-aaaa";
    const REFRESH = "test-refresh-token-not-a-real-credential-bbbb";
    try V.putOAuth(5, "cloudflare", ACCESS, REFRESH, 1_700_000_000, "acct-0123", "https://api.example.invalid");

    const b = V.resolveOAuth(5, "cloudflare", gpa) orelse return error.BundleNotResolvable;
    defer {
        gpa.free(b.key);
        gpa.free(b.refresh_token);
        gpa.free(b.account_id);
        gpa.free(b.base_url);
    }
    try std.testing.expectEqualStrings(ACCESS, b.key);
    try std.testing.expectEqualStrings(REFRESH, b.refresh_token);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), b.expires_at);
    try std.testing.expectEqualStrings("acct-0123", b.account_id);
    try std.testing.expectEqualStrings("https://api.example.invalid", b.base_url);

    // The refresh token is the long-lived half of the bundle — it outlives the access token it mints, so it
    // is the one that must never be legible at rest.
    var sb: [80]u8 = undefined;
    const stored = (try V.nb.get(KeyVault.scopeKey(5, "cloudflare", &sb))) orelse return error.NothingWasStored;
    defer gpa.free(stored);
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(stored);
    const raw = try gpa.alloc(u8, n);
    defer gpa.free(raw);
    try dec.decode(raw, stored);
    try std.testing.expect(std.mem.indexOf(u8, raw, REFRESH) == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, ACCESS) == null);
    try std.testing.expect(std.mem.indexOf(u8, stored, REFRESH) == null);

    // The documented discriminator between an OAuth login and a plain BYOK key stored under the same reader:
    // a plain key has no refresh token, and reading it back as a bundle must not invent one.
    try V.put(5, "openai", "sk-test-plain-byok-not-a-credential-cccc", "");
    const plain = V.resolveOAuth(5, "openai", gpa) orelse return error.PlainKeyNotResolvable;
    defer {
        gpa.free(plain.key);
        gpa.free(plain.refresh_token);
        gpa.free(plain.account_id);
        gpa.free(plain.base_url);
    }
    try std.testing.expectEqualStrings("sk-test-plain-byok-not-a-credential-cccc", plain.key);
    try std.testing.expectEqual(@as(usize, 0), plain.refresh_token.len);
    try std.testing.expectEqual(@as(usize, 0), plain.account_id.len);
    try std.testing.expectEqual(@as(i64, 0), plain.expires_at);
}

test "deriveServerKey: an UNPERSISTABLE key is not stable across boots — the case that loses data" {
    // The existing invariant test covers a writable data dir. This is the combination it cannot
    // reach: NO NL_SECRET (so the key comes from the file, not the secret) AND a data dir that
    // cannot be written. deriveServerKey swallows the write error by design — the server still has
    // to boot — so the failure is invisible at the time, and the loss only shows up on the NEXT
    // start, when everything sealed today refuses to open. Pinned so the behaviour is a documented
    // consequence with an operator-visible log.err beside it, rather than a surprise.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // no NL_SECRET on purpose: with one set, the key is derived and the unwritable dir is irrelevant.

    const nowhere = "zig-vault-unwritable/definitely/not/created";
    const k1 = deriveServerKey(gpa, io, &env, nowhere);
    const k2 = deriveServerKey(gpa, io, &env, nowhere);

    // It still returns a USABLE key rather than crashing or handing back zeroes — the server boots.
    var zero = true;
    for (k1) |b| {
        if (b != 0) {
            zero = false;
            break;
        }
    }
    try std.testing.expect(!zero);

    // ...but it is a DIFFERENT key each time, which is precisely the data loss: whatever this boot
    // sealed, the next boot cannot open. If this ever starts passing as equal, the key became
    // stable by some other route and the log.err above is now lying — re-read both.
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));

    // And sealing round-trips WITHIN one boot, so the failure really is confined to restarts.
    const blob = try seal(gpa, io, k1, "provider-key-material");
    defer gpa.free(blob);
    const back = open(gpa, k1, blob) orelse return error.TestUnexpectedResult;
    defer gpa.free(back);
    try std.testing.expectEqualStrings("provider-key-material", back);
    try std.testing.expect(open(gpa, k2, blob) == null); // ...and NOT with the next boot's key
}
