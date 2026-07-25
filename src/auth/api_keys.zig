//! API keys — programmatic auth for the public API (alongside the SPA session cookie); only SHA-256 hashes are stored.

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

    /// The caller owns everything returned, allocated from `gpa` — the slice AND the strings.
    ///
    /// They used to be borrowed straight out of the map (`e.key_ptr.*`, `.prefix`, `.name`), which
    /// revoke() frees: any list -> revoke -> read-an-earlier-view sequence was a use-after-free on
    /// all three fields. Unreachable as the HTTP routes stand (keyList serialises into res.arena
    /// before returning, and revoke is a separate request), but it is a landmine for the next
    /// caller — outliving the lock is the only sane contract for data handed out from under it.
    pub fn list(self: *ApiKeys, gpa: std.mem.Allocator, uid: u64) ![]View {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var out: std.ArrayListUnmanaged(View) = .empty;
        var it = self.keys.iterator();
        while (it.next()) |e| if (e.value_ptr.uid == uid)
            try out.append(gpa, .{
                .id = try gpa.dupe(u8, e.key_ptr.*),
                .prefix = try gpa.dupe(u8, e.value_ptr.prefix),
                .name = try gpa.dupe(u8, e.value_ptr.name),
                .created = e.value_ptr.created,
            });
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

// An API key is a bearer credential for the WHOLE public API, so what these pin is the security contract
// rather than the plumbing: the shape of the minted key, that only its SHA-256 is ever retained (in memory
// and, when a neuron.exe is around, on disk), that verify() is exact-match, and that revoke() really ends
// acceptance — including across a restart. All but the last run without a live neuron.exe: a handle whose
// binary cannot be spawned makes every nb.put/get/del fail into the module's own `catch`es, which leaves
// the in-memory half under test. The one round-trip test that needs the real store skips when bin/ is bare.

/// TEST ONLY. ApiKeys owns every map key (the hash) plus both heap fields of each Info, and has no deinit —
/// in main.zig it is a process-lifetime singleton, so nothing ever tears it down. Tests run on
/// std.testing.allocator, which counts, so they hand the map back themselves.
fn drainKeysForTest(self: *ApiKeys) void {
    var it = self.keys.iterator();
    while (it.next()) |e| {
        self.gpa.free(e.key_ptr.*);
        self.gpa.free(e.value_ptr.name);
        self.gpa.free(e.value_ptr.prefix);
    }
    self.keys.deinit(self.gpa);
}

/// TEST ONLY. A neuron handle whose binary cannot be spawned — see the note above.
fn deadNeuronForTest(gpa: std.mem.Allocator, io: std.Io) Neuron {
    return Neuron.init(gpa, io, "__nl_no_such_neuron_bin__", "__nl_no_such_db__");
}

test "minted key: nlk_ prefix + 48 lowercase hex, and two mints never collide" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ks = ApiKeys.init(gpa, deadNeuronForTest(gpa, io));
    defer drainKeysForTest(&ks);

    try std.testing.expectEqualStrings("nlk_", PREFIX); // the marker clients and the bearer parser match on

    const a = try ks.create(7, "laptop");
    defer gpa.free(a);
    const b = try ks.create(7, "phone");
    defer gpa.free(b);

    // 24 CSPRNG bytes rendered lowercase hex behind the prefix — 192 bits of secret, 52 chars total.
    try std.testing.expectEqual(@as(usize, PREFIX.len + 48), a.len);
    try std.testing.expect(std.mem.startsWith(u8, a, PREFIX));
    for (a[PREFIX.len..]) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));

    // Two keys that came out equal would mean the randomness never ran; those 24 bytes ARE the credential.
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expectEqual(@as(usize, 2), ks.keys.count());
}

test "hash-only retention: nothing kept in memory carries the key's secret body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ks = ApiKeys.init(gpa, deadNeuronForTest(gpa, io));
    defer drainKeysForTest(&ks);

    const raw = try ks.create(42, "ci runner");
    defer gpa.free(raw);

    // The record is filed under the SHA-256 of the key, and under nothing else.
    var want: [64]u8 = undefined;
    _ = ApiKeys.hashHex(raw, &want);
    try std.testing.expect(ks.keys.contains(&want));
    try std.testing.expect(!ks.keys.contains(raw));
    const info = ks.keys.get(&want).?;
    try std.testing.expectEqual(@as(u64, 42), info.uid);

    // The display prefix deliberately shows the first 8 hex digits so a user can tell two keys apart. The
    // other 40 (160 bits) are the secret and must appear in NOTHING that is retained — not the lookup key,
    // not the prefix, not the name. Those three are also exactly the fields the stored record is built from.
    const secret_body = raw[PREFIX.len + 8 ..];
    try std.testing.expectEqual(@as(usize, 40), secret_body.len);
    try std.testing.expect(std.mem.indexOf(u8, &want, secret_body) == null);
    try std.testing.expect(std.mem.indexOf(u8, info.prefix, secret_body) == null);
    try std.testing.expect(std.mem.indexOf(u8, info.name, secret_body) == null);

    const shown = try std.fmt.allocPrint(gpa, "{s}…", .{raw[0 .. PREFIX.len + 8]});
    defer gpa.free(shown);
    try std.testing.expectEqualStrings(shown, info.prefix);
}

test "key names are sanitised before they reach the hand-rolled record JSON" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ks = ApiKeys.init(gpa, deadNeuronForTest(gpa, io));
    defer drainKeysForTest(&ks);

    // create() interpolates the name straight into "name":"{s}" with no escaping, so the character filter
    // IS the boundary: a quote or backslash that got through would corrupt — or forge — the stored record.
    const raw = try ks.create(3, "ev\"il\\,{\"uid\":999}\nname");
    defer gpa.free(raw);
    var hb: [64]u8 = undefined;
    const name = ks.keys.get(ApiKeys.hashHex(raw, &hb)).?.name;
    for (name) |c|
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '_' or c == '.');
    try std.testing.expectEqualStrings("eviluid999name", name);

    // A name with nothing legal left falls back to a placeholder rather than an empty JSON string.
    const raw2 = try ks.create(3, "!!!@@@");
    defer gpa.free(raw2);
    var hb2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("key", ks.keys.get(ApiKeys.hashHex(raw2, &hb2)).?.name);

    // …and an over-long name is clipped to the 60-byte buffer instead of running past it.
    const raw3 = try ks.create(3, "n" ** 200);
    defer gpa.free(raw3);
    var hb3: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 60), ks.keys.get(ApiKeys.hashHex(raw3, &hb3)).?.name.len);
}

test "verify: the exact key only — empty, short, truncated, unprefixed, bent and never-minted all fail" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ks = ApiKeys.init(gpa, deadNeuronForTest(gpa, io));
    defer drainKeysForTest(&ks);

    const raw = try ks.create(9001, "cli");
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(?u64, 9001), ks.verify(raw));

    try std.testing.expectEqual(@as(?u64, null), ks.verify(""));
    try std.testing.expectEqual(@as(?u64, null), ks.verify(PREFIX)); // prefix alone: under the length floor
    try std.testing.expectEqual(@as(?u64, null), ks.verify(raw[0 .. PREFIX.len + 15])); // one byte under the floor
    try std.testing.expectEqual(@as(?u64, null), ks.verify(raw[0 .. raw.len - 1])); // truncated: passes the gate, wrong hash
    try std.testing.expectEqual(@as(?u64, null), ks.verify(raw[PREFIX.len..])); // the real secret, prefix stripped
    try std.testing.expectEqual(@as(?u64, null), ks.verify(PREFIX ++ "0" ** 48)); // well-formed, never minted

    // One flipped hex digit. (A prefix-compare or a length-only check would let this through.)
    const bent = try gpa.dupe(u8, raw);
    defer gpa.free(bent);
    bent[bent.len - 1] = if (bent[bent.len - 1] == 'a') 'b' else 'a';
    try std.testing.expectEqual(@as(?u64, null), ks.verify(bent));

    // A string that merely BEGINS with the real key — trailing junk must not be tolerated.
    const trailing = try std.fmt.allocPrint(gpa, "{s}00", .{raw});
    defer gpa.free(trailing);
    try std.testing.expectEqual(@as(?u64, null), ks.verify(trailing));
}

test "revoke: ends acceptance for that key only, needs the owning uid, and does not repeat" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ks = ApiKeys.init(gpa, deadNeuronForTest(gpa, io));
    defer drainKeysForTest(&ks);

    const mine_a = try ks.create(7, "a");
    defer gpa.free(mine_a);
    const mine_b = try ks.create(7, "b");
    defer gpa.free(mine_b);
    const theirs = try ks.create(8, "c");
    defer gpa.free(theirs);

    const views = try ks.list(gpa, 7);
    defer {
        // The views own their strings now (see list()'s contract), so the test frees them.
        for (views) |v| {
            gpa.free(v.id);
            gpa.free(v.prefix);
            gpa.free(v.name);
        }
        gpa.free(views);
    }
    try std.testing.expectEqual(@as(usize, 2), views.len); // uid 8's key is not in uid 7's list
    for (views) |v| try std.testing.expect(std.mem.indexOf(u8, v.id, mine_a[PREFIX.len..]) == null); // ids are hashes

    // The views OWN their strings now, so they survive a revoke that frees the map's copies — the
    // use-after-free this test used to have to dodge. Re-derived anyway: it proves the id IS the hash.
    var id_a: [64]u8 = undefined;
    _ = ApiKeys.hashHex(mine_a, &id_a);

    try std.testing.expect(!ks.revoke(8, &id_a)); // a different user cannot revoke this key
    try std.testing.expectEqual(@as(?u64, 7), ks.verify(mine_a)); // …and the failed attempt changed nothing
    try std.testing.expect(!ks.revoke(7, "not-an-id")); // unknown id

    try std.testing.expect(ks.revoke(7, &id_a));
    try std.testing.expectEqual(@as(?u64, null), ks.verify(mine_a)); // revoked → rejected from here on
    try std.testing.expectEqual(@as(?u64, 7), ks.verify(mine_b)); // the owner's other key is untouched
    try std.testing.expectEqual(@as(?u64, 8), ks.verify(theirs));

    try std.testing.expect(!ks.revoke(7, &id_a)); // already gone: false, and no double free

    // The point of the ownership change: a view read AFTER its key was revoked is still valid
    // memory. Under the old borrowing contract this line read freed heap.
    for (views) |v| try std.testing.expectEqual(@as(usize, 64), v.id.len);
}

test "live neuron-db: the stored record holds no plaintext, warm() restores by hash, a revoked key stays dead" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-apikeys-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // bin/ is gitignored, so a checkout without a built neuron.exe skips this one instead of failing. A
    // missing binary is the only thing that errors here — the CLI itself reports "no match" in-band.
    const nb = Neuron.init(gpa, io, "bin/neuron.exe", root ++ "/keys.sqlite");
    if (nb.get("nl_probe") catch return error.SkipZigTest) |v| gpa.free(v);

    var ks = ApiKeys.init(gpa, nb);
    defer drainKeysForTest(&ks);
    const raw = try ks.create(4242, "round trip");
    defer gpa.free(raw);

    var idbuf: [64]u8 = undefined;
    const id = ApiKeys.hashHex(raw, &idbuf);
    var scopebuf: [80]u8 = undefined;
    const scope = try std.fmt.bufPrint(&scopebuf, "k_{s}", .{id});
    const stored = (try nb.get(scope)) orelse return error.RecordWasNotStored;
    defer gpa.free(stored);

    // The bytes actually on disk, decoded. This is the assertion that matters: an attacker who reads the
    // datastore gets a hash and a truncated display prefix, never a usable key.
    const json = try ApiKeys.unb64(gpa, stored);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, raw) == null); // not the key
    try std.testing.expect(std.mem.indexOf(u8, json, raw[PREFIX.len + 8 ..]) == null); // not even its secret body
    try std.testing.expect(std.mem.indexOf(u8, scope, raw[PREFIX.len..]) == null); // nor the addressing
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uid\":4242") != null); // …but the record IS there
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"round trip\"") != null);

    // RESTART: a registry that has only ever seen the datastore must accept the same key.
    var warmed = ApiKeys.init(gpa, nb);
    defer drainKeysForTest(&warmed);
    try warmed.warm();
    try std.testing.expectEqual(@as(?u64, 4242), warmed.verify(raw));

    // REVOKE, then restart again. `neuron list` still reports the scope after a forget, so this is a real
    // trap: warm() must skip a scope whose value is gone rather than resurrect a revoked credential.
    try std.testing.expect(warmed.revoke(4242, id));
    var after = ApiKeys.init(gpa, nb);
    defer drainKeysForTest(&after);
    try after.warm();
    try std.testing.expectEqual(@as(?u64, null), after.verify(raw));
}
