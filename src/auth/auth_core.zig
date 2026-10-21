//! Auth — register / login / sessions, backed by neuron-db (dogfooded) with an in-memory user + session cache.

const std = @import("std");
const Neuron = @import("../worker/neuron/client.zig").Neuron;

const log = std.log.scoped(.auth);

const ent = @import("../plan/entitlements.zig");
pub const Plan = ent.Plan;

pub const User = struct {
    id: u64,
    email: []const u8,
    pwhash: []const u8,
    plan: Plan,
    created: i64,
    banned: bool = false,
    session_generation: u64 = 0,
    // Recipe tools this user may run. DATA, not capability: a name here only lets runRecipe dispatch that
    // recipe's steps under the user's OWN caps — it never widens the sandbox gate. Owned exactly like email/
    // pwhash on a loaded/mutated User (each name duped, the backing slice duped); freed via freeGrants. The
    // shared empty-slice default is the "no grants" sentinel and is safe to free (a no-op on len 0).
    tool_grants: []const []const u8 = &.{},
};

pub const UserInfo = struct { id: u64, email: []const u8, plan: Plan, created: i64, banned: bool = false, tool_grants: []const []const u8 = &.{} };

const SessionVal = struct { email: []const u8, created: i64, uid: u64, generation: u64 };

pub const AuthError = error{ EmailTaken, BadCredentials, WeakInput, BadEmail, StorageFailure };

pub const DEFAULT_ADMIN_EMAIL = "admin@neuron-loops.local";

// User IDs cross a JSON/JavaScript boundary. Keep new IDs exactly representable there.
const MAX_USER_ID: u64 = 9_007_199_254_740_991;
// Old releases could delete the highest user and then reuse its ID after restart. Neuron's
// deleted scopes usually remain listed, but do not encode the deleted ID. Move legacy stores
// with account-related records into an unused, still JS-safe range before issuing new IDs.
const LEGACY_USER_ID_FLOOR: u64 = 1 << 40;
const ID_RESERVATION_PREFIX = "auth_uid_reserved_";
const ID_RESERVATION_VALUE = "reserved-v1";
const USER_INDEX_GUARD_SCOPE = "auth_user_index_guard_v1";
const USER_INDEX_SCOPE = "auth_user_index_v1";
const USER_INDEX_GUARD_VALUE = "eyJhdXRoX3VzZXJfaW5kZXgiOjF9"; // {"auth_user_index":1}
const UserIndexEntry = struct { id: u64, email: []const u8 };

pub const Auth = struct {
    gpa: std.mem.Allocator,
    nb: Neuron,
    mu: std.Io.Mutex = .init,
    users: std.StringHashMapUnmanaged(User) = .empty,
    sessions: std.StringHashMapUnmanaged(SessionVal) = .empty,
    next_id: u64 = 1,
    admin_email: ?[]const u8 = null,
    dummy: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, nb: Neuron) Auth {
        return .{ .gpa = gpa, .nb = nb };
    }

    /// Free both maps and everything they own. In main.zig the Auth is a process-lifetime
    /// singleton, so this exists for tests and any future scoped instance — without it an
    /// authenticated handler test cannot run leak-free under std.testing.allocator.
    ///
    /// NOTE the aliasing: `users` is keyed on the User's OWN email slice (`users.put(gpa, u.email,
    /// u)`), so the key and `u.email` are one allocation and must be freed exactly once — hence
    /// iterating values here, never keys.
    pub fn deinit(self: *Auth) void {
        var sit = self.sessions.iterator();
        while (sit.next()) |e| {
            self.gpa.free(e.key_ptr.*); // the token
            self.gpa.free(e.value_ptr.email); // its email dupe
        }
        self.sessions.deinit(self.gpa);

        var uit = self.users.valueIterator();
        while (uit.next()) |u| {
            self.gpa.free(u.email); // ALSO the map key — one allocation, freed once
            self.gpa.free(u.pwhash);
            freeGrants(self.gpa, u.tool_grants); // the &.{} sentinel frees as a no-op
        }
        self.users.deinit(self.gpa);

        if (self.admin_email) |e| self.gpa.free(e);
        if (self.dummy) |d| self.gpa.free(d);
        self.users = .empty;
        self.sessions = .empty;
        self.admin_email = null;
        self.dummy = null;
    }

    pub fn setAdminEmail(self: *Auth, email: ?[]const u8) void {
        const e = email orelse DEFAULT_ADMIN_EMAIL;
        self.admin_email = self.gpa.dupe(u8, e) catch null;
    }

    /// EXACT match, deliberately — this compared with `eqlIgnoreCase` and that was an admin-takeover hole.
    ///
    /// The user map is keyed on the email's exact bytes (`users.contains(email)` in register, `users.get`
    /// in login), so a case variant of the admin address is a DIFFERENT key. Registering
    /// "Admin@host" against a seeded "admin@host" sailed past the EmailTaken check and created a second
    /// account — and then this predicate, comparing case-INsensitively, declared it an admin. That is
    /// `.caps = .full`, every admin route, run_python and patch_system: full host code execution from a
    /// self-service signup. The same insensitive compare in isAdminEmail also minted it `.pro` on the way
    /// in, one line from the check that had just missed it.
    ///
    /// Exact is safe here because seedDefaultAdmin registers `admin_email` VERBATIM (just below), so the
    /// stored account email is byte-identical to the configured one — there is no lockout path.
    /// Case-variant DUPLICATE accounts can still be created; that is an identity nuisance rather than an
    /// escalation, and canonicalizing the map key is the durable follow-up.
    pub fn isAdmin(self: *Auth, u: User) bool {
        if (self.admin_email) |e| return std.mem.eql(u8, u.email, e);
        return u.id == 1;
    }

    fn isAdminEmail(self: *Auth, email: []const u8) bool {
        if (self.admin_email) |e| return std.mem.eql(u8, email, e);
        return self.next_id == 1;
    }

    pub fn seedDefaultAdmin(self: *Auth, password: []const u8) void {
        const email = self.admin_email orelse DEFAULT_ADMIN_EMAIL;
        self.register(email, password) catch |e| {
            if (e != AuthError.EmailTaken) log.err("seed admin {s}: {t}", .{ email, e });
            return;
        };
        log.info("admin account ready: {s}", .{email});
    }

    fn userScope(email: []const u8, out: *[16]u8) []const u8 {
        var dig: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(email, &dig, .{});
        const hex = std.fmt.bytesToHex(dig[0..6], .lower);
        out[0] = 'u';
        out[1] = '_';
        @memcpy(out[2..14], &hex);
        return out[0..14];
    }

    fn reservationScope(id: u64, out: *[48]u8) ![]const u8 {
        return std.fmt.bufPrint(out, "{s}{d}", .{ ID_RESERVATION_PREFIX, id });
    }

    /// Each ID gets one immutable record. It is confirmed before a user can be created or
    /// deleted, so a later startup cannot attach old API keys or u{uid} data to another account.
    fn reserveId(self: *Auth, id: u64, allow_existing: bool) !void {
        if (id == 0 or id > MAX_USER_ID) return error.UserIdExhausted;
        var sbuf: [48]u8 = undefined;
        const scope = try reservationScope(id, &sbuf);
        if (try self.nb.get(scope)) |existing| {
            defer self.gpa.free(existing);
            if (!std.mem.eql(u8, existing, ID_RESERVATION_VALUE)) return error.InvalidIdReservation;
            if (!allow_existing) return error.UserIdAlreadyReserved;
            return;
        }
        // This scope has never held a value. Neuron.put's forget-first behavior is harmless
        // here: even an interrupted write leaves the scope name as a consumed ID.
        try self.nb.put(scope, ID_RESERVATION_VALUE);
        const got = (try self.nb.get(scope)) orelse return error.IdReservationNotPersisted;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, ID_RESERVATION_VALUE)) return error.IdReservationNotPersisted;
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

    fn validEmail(email: []const u8) bool {
        if (email.len < 3 or email.len > 254) return false;
        const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
        if (at == 0 or at == email.len - 1) return false;
        if (std.mem.indexOfScalar(u8, email, '@') != std.mem.lastIndexOfScalar(u8, email, '@')) return false;
        for (email) |c| if (c == '"' or c == '\\' or c < 0x20 or c == ' ') return false;
        return std.mem.indexOfScalar(u8, email[at..], '.') != null;
    }

    fn grantsContain(grants: []const []const u8, name: []const u8) bool {
        for (grants) |g| if (std.mem.eql(u8, g, name)) return true;
        return false;
    }

    /// Serialize the grant list as a JSON string array — `["a","b"]`. Recipe names are [a-z0-9_], so the
    /// escape never fires today, but we escape `"` and `\` anyway: a name is spliced into the record JSON
    /// as a value, and a value that could smuggle a quote must not be able to break the record or inject a
    /// sibling field. Caller frees the result.
    fn grantsJson(gpa: std.mem.Allocator, grants: []const []const u8) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.append(gpa, '[');
        for (grants, 0..) |g, i| {
            if (i != 0) try buf.append(gpa, ',');
            try buf.append(gpa, '"');
            for (g) |c| {
                if (c == '"' or c == '\\') try buf.append(gpa, '\\');
                try buf.append(gpa, c);
            }
            try buf.append(gpa, '"');
        }
        try buf.append(gpa, ']');
        return buf.toOwnedSlice(gpa);
    }

    /// The full on-disk record for a User (base64-wrapped by the caller). Kept as its own fn so the persist
    /// format has ONE definition — the round-trip test emits through this exact path rather than a replica.
    /// Caller frees the result.
    fn recordJson(gpa: std.mem.Allocator, u: User) ![]u8 {
        const garr = try grantsJson(gpa, u.tool_grants);
        defer gpa.free(garr);
        return std.fmt.allocPrint(gpa, "{{\"id\":{d},\"email\":\"{s}\",\"pwhash\":\"{s}\",\"plan\":\"{s}\",\"created\":{d},\"banned\":{},\"session_generation\":{d},\"tool_grants\":{s}}}", .{ u.id, u.email, u.pwhash, @tagName(u.plan), u.created, u.banned, u.session_generation, garr });
    }

    /// Deep-copy a parsed grant list into gpa-owned memory: each name duped AND the backing slice duped, so
    /// a loaded User's grants are owned exactly like its email/pwhash and free uniformly (see freeGrants).
    /// An empty source returns the shared empty-slice sentinel — no allocation, a no-op to free.
    fn dupGrants(gpa: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
        if (src.len == 0) return &.{};
        const out = try gpa.alloc([]const u8, src.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |g| gpa.free(g);
            gpa.free(out);
        }
        for (src) |g| {
            out[n] = try gpa.dupe(u8, g);
            n += 1;
        }
        return out;
    }

    /// Free a grant list owned by dupGrants/setToolGrant: every name, then the backing slice. Safe on the
    /// empty-slice sentinel — the loop runs zero times and free() is a no-op on a zero-length slice.
    fn freeGrants(gpa: std.mem.Allocator, grants: []const []const u8) void {
        for (grants) |g| gpa.free(g);
        gpa.free(grants);
    }

    fn persistUser(self: *Auth, u: User) !void {
        const json = try recordJson(self.gpa, u);
        defer self.gpa.free(json);
        const enc = try b64(self.gpa, json);
        defer self.gpa.free(enc);
        var sbuf: [16]u8 = undefined;
        try self.nb.put(userScope(u.email, &sbuf), enc);
    }

    /// A successful CLI exit does not prove neuron-db retained a record. Critical account changes
    /// read the exact base64 record back before telling an admin that a revocation is durable.
    fn persistUserConfirmed(self: *Auth, u: User) !void {
        const json = try recordJson(self.gpa, u);
        defer self.gpa.free(json);
        const expected = try b64(self.gpa, json);
        defer self.gpa.free(expected);
        try self.persistUser(u);
        var sbuf: [16]u8 = undefined;
        const got = (try self.nb.get(userScope(u.email, &sbuf))) orelse return error.UserRecordNotPersisted;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, expected)) return error.UserRecordNotPersisted;
    }

    /// If an elevation was written but its readback failed, the caller cannot know
    /// whether it will reappear on restart. Restore the previous, lesser-privileged
    /// record and confirm that rollback before returning the original error.
    fn persistPrivilegeIncrease(self: *Auth, previous: User, candidate: User) !void {
        self.persistUserConfirmed(candidate) catch |err| {
            self.persistUserConfirmed(previous) catch return error.PrivilegeWriteUncertain;
            return err;
        };
    }

    /// The index is a fixed-key source of expected accounts. A successful but incomplete
    /// neuron `list`, or an empty export for a live row, must not produce a partial user map.
    /// The guard is written once and never replaced: an interrupted index update then stops
    /// startup instead of silently treating this as an old store with no index.
    fn writeUserIndex(self: *Auth, add: ?User, remove: ?[]const u8) !void {
        var entries: std.ArrayList(UserIndexEntry) = .empty;
        defer entries.deinit(self.gpa);
        var it = self.users.valueIterator();
        while (it.next()) |u| {
            if (remove) |email| {
                if (std.mem.eql(u8, u.email, email)) continue;
            }
            try entries.append(self.gpa, .{ .id = u.id, .email = u.email });
        }
        if (add) |u| try entries.append(self.gpa, .{ .id = u.id, .email = u.email });
        const json = try std.json.Stringify.valueAlloc(self.gpa, entries.items, .{});
        defer self.gpa.free(json);
        const expected = try b64(self.gpa, json);
        defer self.gpa.free(expected);
        try self.nb.put(USER_INDEX_SCOPE, expected);
        const got = (try self.nb.get(USER_INDEX_SCOPE)) orelse return error.UserIndexNotPersisted;
        defer self.gpa.free(got);
        if (!std.mem.eql(u8, got, expected)) return error.UserIndexNotPersisted;
    }

    fn ensureUserIndex(self: *Auth) !void {
        const guard = try self.nb.get(USER_INDEX_GUARD_SCOPE);
        defer if (guard) |value| self.gpa.free(value);
        if (guard) |value| {
            if (!std.mem.eql(u8, value, USER_INDEX_GUARD_VALUE)) return error.InvalidUserIndex;
            const index = (try self.nb.get(USER_INDEX_SCOPE)) orelse return error.InvalidUserIndex;
            self.gpa.free(index);
            return;
        }
        // A guardless index is also an interrupted/corrupt transition, not a legacy store.
        if (try self.nb.get(USER_INDEX_SCOPE)) |index| {
            self.gpa.free(index);
            return error.InvalidUserIndex;
        }
        try self.nb.put(USER_INDEX_GUARD_SCOPE, USER_INDEX_GUARD_VALUE);
        const confirmed = (try self.nb.get(USER_INDEX_GUARD_SCOPE)) orelse return error.UserIndexNotPersisted;
        defer self.gpa.free(confirmed);
        if (!std.mem.eql(u8, confirmed, USER_INDEX_GUARD_VALUE)) return error.UserIndexNotPersisted;
        try self.writeUserIndex(null, null);
    }

    fn validateUserIndex(self: *Auth, encoded: []const u8) !void {
        const json = unb64(self.gpa, encoded) catch return error.InvalidUserIndex;
        defer self.gpa.free(json);
        const parsed = std.json.parseFromSlice([]UserIndexEntry, self.gpa, json, .{}) catch return error.InvalidUserIndex;
        defer parsed.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);
        for (parsed.value) |entry| {
            if (entry.id == 0 or entry.id > MAX_USER_ID or !validEmail(entry.email)) return error.InvalidUserIndex;
            const item = try seen.getOrPut(self.gpa, entry.email);
            if (item.found_existing) return error.InvalidUserIndex;
            const u = self.users.get(entry.email) orelse return error.IncompleteUserIndex;
            if (u.id != entry.id) return error.InvalidUserIndex;
            var sbuf: [16]u8 = undefined;
            const direct = (try self.nb.get(userScope(entry.email, &sbuf))) orelse return error.IncompleteUserIndex;
            self.gpa.free(direct);
        }
        if (seen.count() != self.users.count()) return error.InvalidUserIndex;
    }

    pub fn warm(self: *Auth) !void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        // A partial user map can reuse a missing account's ID or overwrite its stored record.
        // Account loading is therefore required for startup; an empty value remains a deleted scope.
        const uscopes = try self.nb.scopes("");
        defer {
            for (uscopes) |s| self.gpa.free(s);
            self.gpa.free(uscopes);
        }
        var seen_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen_ids.deinit(self.gpa);
        var has_reservations = false;
        var has_legacy_identity_state = false;
        var listed_guard = false;
        var listed_index = false;
        for (uscopes) |scope| {
            if (std.mem.eql(u8, scope, USER_INDEX_GUARD_SCOPE)) listed_guard = true;
            if (std.mem.eql(u8, scope, USER_INDEX_SCOPE)) listed_index = true;
            if (std.mem.startsWith(u8, scope, ID_RESERVATION_PREFIX)) {
                has_reservations = true;
                const suffix = scope[ID_RESERVATION_PREFIX.len..];
                const id = std.fmt.parseInt(u64, suffix, 10) catch return error.InvalidIdReservation;
                var canonical: [48]u8 = undefined;
                if (id == 0 or id > MAX_USER_ID or !std.mem.eql(u8, scope, try reservationScope(id, &canonical))) return error.InvalidIdReservation;
                // An empty scope can be left by an interrupted first write. Its name still
                // consumes the ID. A readable but unexpected value is corruption.
                if (try self.nb.get(scope)) |value| {
                    defer self.gpa.free(value);
                    if (!std.mem.eql(u8, value, ID_RESERVATION_VALUE)) return error.InvalidIdReservation;
                }
                if (id >= self.next_id) self.next_id = id + 1;
            } else if (std.mem.startsWith(u8, scope, "u_") or std.mem.startsWith(u8, scope, "k_") or std.mem.startsWith(u8, scope, "kv_") or std.mem.startsWith(u8, scope, "n_") or std.mem.startsWith(u8, scope, "s_")) {
                has_legacy_identity_state = true;
            }
        }
        for (uscopes) |scope| {
            if (!std.mem.startsWith(u8, scope, "u_")) continue;
            const enc = (try self.nb.get(scope)) orelse continue;
            defer self.gpa.free(enc);
            const json = unb64(self.gpa, enc) catch return error.InvalidUserRecord;
            defer self.gpa.free(json);
            const parsed = std.json.parseFromSlice(struct { id: u64, email: []const u8, pwhash: []const u8, plan: []const u8, created: i64, banned: bool = false, session_generation: u64 = 0, tool_grants: []const []const u8 = &.{} }, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidUserRecord;
            defer parsed.deinit();
            const v = parsed.value;
            var expected_scope: [16]u8 = undefined;
            if (v.id == 0 or v.id > MAX_USER_ID or !validEmail(v.email) or !std.mem.eql(u8, scope, userScope(v.email, &expected_scope))) return error.InvalidUserRecord;
            const id_entry = try seen_ids.getOrPut(self.gpa, v.id);
            if (id_entry.found_existing) return error.InvalidUserRecord;
            const u = User{
                .id = v.id,
                .email = try self.gpa.dupe(u8, v.email),
                .pwhash = try self.gpa.dupe(u8, v.pwhash),
                // Deliberate fall-back to least privilege: an unreadable plan on a stored row must
                // not hand out caps. Shares one spelling table with the admin API, which REJECTS
                // an unknown name rather than coercing it.
                .plan = ent.parsePlan(v.plan) orelse .free,
                .created = v.created,
                .banned = v.banned,
                .session_generation = v.session_generation,
                // dup out of the parse arena before its deinit; owned like email/pwhash from here on.
                .tool_grants = try dupGrants(self.gpa, v.tool_grants),
            };
            try self.users.put(self.gpa, u.email, u);
            if (v.id >= self.next_id) self.next_id = v.id + 1;
        }

        const guard = try self.nb.get(USER_INDEX_GUARD_SCOPE);
        defer if (guard) |value| self.gpa.free(value);
        const index = try self.nb.get(USER_INDEX_SCOPE);
        defer if (index) |value| self.gpa.free(value);
        if (guard) |value| {
            if (!std.mem.eql(u8, value, USER_INDEX_GUARD_VALUE)) return error.InvalidUserIndex;
            try self.validateUserIndex(index orelse return error.InvalidUserIndex);
        } else {
            if (index != null or listed_guard or listed_index) return error.InvalidUserIndex;
            // Legacy migration can only trust the first successful listing. Every later
            // startup compares against this confirmed index before opening the listener.
            try self.ensureUserIndex();
        }

        if (!has_reservations and has_legacy_identity_state and self.next_id < LEGACY_USER_ID_FLOOR) {
            self.next_id = LEGACY_USER_ID_FLOOR;
        }

        // Rehydrate only current session records bound to this account ID and revocation generation.
        // Legacy email-only records are intentionally signed out on upgrade; accepting them would let
        // a missed stored delete restore access after a password change, ban, or account recreation.
        const sscopes = self.nb.scopes("s_") catch return;
        defer {
            for (sscopes) |s| self.gpa.free(s);
            self.gpa.free(sscopes);
        }
        const now = std.Io.Timestamp.now(self.nb.io, .real).toSeconds();
        for (sscopes) |scope| {
            if (scope.len <= 2) continue; // the scope key is "s_" ++ token
            const enc = (self.nb.get(scope) catch continue) orelse continue;
            defer self.gpa.free(enc);
            const json = unb64(self.gpa, enc) catch continue;
            defer self.gpa.free(json);
            const sp = std.json.parseFromSlice(struct { email: []const u8, created: i64 = 0, v: u8 = 0, uid: u64 = 0, generation: u64 = 0 }, self.gpa, json, .{ .ignore_unknown_fields = true }) catch continue;
            defer sp.deinit();
            const owner = self.users.get(sp.value.email);
            if (sessionExpired(sp.value.created, now) or sp.value.v != 2 or owner == null or owner.?.banned or owner.?.id != sp.value.uid or owner.?.session_generation != sp.value.generation) {
                self.nb.del(scope);
                continue;
            }
            const tok = self.gpa.dupe(u8, scope[2..]) catch continue;
            const email = self.gpa.dupe(u8, sp.value.email) catch {
                self.gpa.free(tok);
                continue;
            };
            // Keep the persisted creation time so a long-running process can enforce expiry on lookup.
            self.sessions.put(self.gpa, tok, .{ .email = email, .created = sp.value.created, .uid = sp.value.uid, .generation = sp.value.generation }) catch {
                self.gpa.free(tok);
                self.gpa.free(email);
            };
        }
    }

    /// The cookie's Max-Age is only a browser hint; the server enforces the same age on every lookup.
    const SESSION_TTL_S: i64 = 30 * 24 * 60 * 60;

    fn sessionExpired(created: i64, now: i64) bool {
        if (created <= 0 or created > now) return true; // unknown or future age cannot be trusted
        return now - created >= SESSION_TTL_S;
    }

    fn nextSessionGeneration(self: *Auth, old: u64) u64 {
        var generation: u64 = undefined;
        while (true) {
            self.nb.io.random(std.mem.asBytes(&generation));
            if (generation != 0 and generation != old) return generation;
        }
    }

    pub fn register(self: *Auth, email: []const u8, password: []const u8) AuthError!void {
        if (!validEmail(email)) return AuthError.BadEmail;
        if (password.len < 8 or password.len > 200) return AuthError.WeakInput;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        if (self.users.contains(email)) return AuthError.EmailTaken;
        var existing_scope_buf: [16]u8 = undefined;
        const existing = self.nb.get(userScope(email, &existing_scope_buf)) catch return AuthError.StorageFailure;
        if (existing) |value| {
            self.gpa.free(value);
            return AuthError.StorageFailure;
        }

        var hbuf: [128]u8 = undefined;
        const phc = std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = self.gpa,
            .params = .{ .t = 2, .m = 19456, .p = 1 },
            .mode = .argon2id,
        }, &hbuf, self.nb.io) catch return AuthError.WeakInput;

        const owned_email = self.gpa.dupe(u8, email) catch return AuthError.WeakInput;
        errdefer self.gpa.free(owned_email);
        const owned_hash = self.gpa.dupe(u8, phc) catch return AuthError.WeakInput;
        errdefer self.gpa.free(owned_hash);
        const u = User{
            .id = self.next_id,
            .email = owned_email,
            .pwhash = owned_hash,
            .plan = if (self.isAdminEmail(email)) .pro else .free,
            .created = std.Io.Timestamp.now(self.nb.io, .real).toSeconds(),
            .session_generation = self.nextSessionGeneration(0),
        };
        // Reserve the live-map slot before writing: once storage is confirmed, insertion cannot fail.
        self.users.ensureUnusedCapacity(self.gpa, 1) catch return AuthError.WeakInput;
        self.ensureUserIndex() catch return AuthError.StorageFailure;
        self.reserveId(self.next_id, false) catch return AuthError.StorageFailure;
        // A failed user write must leave a gap, never an ID that can be reassigned.
        self.next_id += 1;
        self.persistUserConfirmed(u) catch return AuthError.StorageFailure;
        self.writeUserIndex(u, null) catch return AuthError.StorageFailure;
        self.users.putAssumeCapacityNoClobber(u.email, u);
    }

    /// Set the password on an account that ALREADY EXISTS.
    ///
    /// There was no such path, and its absence was load-bearing in the wrong direction: seedDefaultAdmin
    /// calls register, register returns EmailTaken for an existing account, and the caller returns — so
    /// any password handed to it after the first boot was silently discarded. A caller that then told
    /// the user "your password is X" was lying, and the account kept whatever it had, up to and
    /// including the published default. Rotation needs to be expressible for that to be fixable.
    ///
    /// Sessions are dropped on success: a password change that leaves existing sessions live has not
    /// really changed anything for whoever is already holding one.
    pub fn setPassword(self: *Auth, email: []const u8, password: []const u8) bool {
        if (password.len < 8 or password.len > 200) return false;
        self.mu.lockUncancelable(self.nb.io);
        const u = self.users.getPtr(email) orelse {
            self.mu.unlock(self.nb.io);
            return false;
        };
        var hbuf: [128]u8 = undefined;
        const phc = std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = self.gpa,
            .params = .{ .t = 2, .m = 19456, .p = 1 },
            .mode = .argon2id,
        }, &hbuf, self.nb.io) catch {
            self.mu.unlock(self.nb.io);
            return false;
        };
        const dup = self.gpa.dupe(u8, phc) catch {
            self.mu.unlock(self.nb.io);
            return false;
        };
        var candidate = u.*;
        candidate.pwhash = dup;
        candidate.session_generation = self.nextSessionGeneration(u.session_generation);
        self.persistUserConfirmed(candidate) catch {
            self.gpa.free(dup);
            self.mu.unlock(self.nb.io);
            return false;
        };
        const old_hash = u.pwhash;
        u.pwhash = dup;
        u.session_generation = candidate.session_generation;
        self.gpa.free(old_hash);
        self.dropSessions(email);
        self.mu.unlock(self.nb.io);
        return true;
    }

    /// Before the listener starts, confirm that the admin record on disk agrees with the password
    /// hash in memory. A Neuron write may fail or report success without storing a record, so a
    /// successful in-memory password check alone cannot establish that a restart stays secure.
    pub fn adminRecordPersisted(self: *Auth, email: []const u8) !bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.get(email) orelse return false;
        var scope_buf: [16]u8 = undefined;
        const enc = (try self.nb.get(userScope(email, &scope_buf))) orelse return false;
        defer self.gpa.free(enc);
        const json = try unb64(self.gpa, enc);
        defer self.gpa.free(json);
        const parsed = try std.json.parseFromSlice(struct { id: u64, email: []const u8, pwhash: []const u8 }, self.gpa, json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return parsed.value.id == u.id and
            std.mem.eql(u8, parsed.value.email, email) and
            std.mem.eql(u8, parsed.value.pwhash, u.pwhash);
    }

    /// Boot uses this to distinguish a password mismatch from a verifier failure. Login deliberately
    /// reports both as BadCredentials, which is right for a remote caller but unsafe when deciding
    /// whether an existing account still has the published default password.
    pub fn passwordMatches(self: *Auth, email: []const u8, password: []const u8) !bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.get(email) orelse return false;
        std.crypto.pwhash.argon2.strVerify(u.pwhash, password, .{ .allocator = self.gpa }, self.nb.io) catch |e| switch (e) {
            error.PasswordVerificationFailed => return false,
            else => return e,
        };
        return true;
    }

    pub fn login(self: *Auth, email: []const u8, password: []const u8) AuthError![]u8 {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.get(email);
        const hash = if (u) |uu| (if (uu.banned) self.dummyHash() else uu.pwhash) else self.dummyHash();
        std.crypto.pwhash.argon2.strVerify(hash, password, .{ .allocator = self.gpa }, self.nb.io) catch return AuthError.BadCredentials;
        if (u == null or u.?.banned) return AuthError.BadCredentials;
        return self.mintSession(email) catch return AuthError.BadCredentials;
    }

    fn dummyHash(self: *Auth) []const u8 {
        if (self.dummy) |d| return d;
        var hbuf: [128]u8 = undefined;
        const phc = std.crypto.pwhash.argon2.strHash("nl-dummy-verify-target", .{
            .allocator = self.gpa,
            .params = .{ .t = 2, .m = 19456, .p = 1 },
            .mode = .argon2id,
        }, &hbuf, self.nb.io) catch return "";
        self.dummy = self.gpa.dupe(u8, phc) catch return "";
        return self.dummy.?;
    }

    fn mintSession(self: *Auth, email: []const u8) ![]u8 {
        const owner = self.users.get(email).?;
        var raw: [24]u8 = undefined;
        self.nb.io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        const token = try self.gpa.dupe(u8, &hex);
        const created = std.Io.Timestamp.now(self.nb.io, .real).toSeconds();
        try self.sessions.put(self.gpa, token, .{ .email = try self.gpa.dupe(u8, email), .created = created, .uid = owner.id, .generation = owner.session_generation });
        const sv = try std.fmt.allocPrint(self.gpa, "{{\"v\":2,\"email\":\"{s}\",\"created\":{d},\"uid\":{d},\"generation\":{d}}}", .{ email, created, owner.id, owner.session_generation });
        defer self.gpa.free(sv);
        const enc = try b64(self.gpa, sv);
        defer self.gpa.free(enc);
        var sbuf: [64]u8 = undefined;
        const scope = std.fmt.bufPrint(&sbuf, "s_{s}", .{token}) catch token;
        self.nb.put(scope, enc) catch {};
        return self.gpa.dupe(u8, token);
    }

    pub fn whoami(self: *Auth, token: []const u8) ?User {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const session = self.sessions.get(token) orelse return null;
        if (sessionExpired(session.created, std.Io.Timestamp.now(self.nb.io, .real).toSeconds())) {
            self.removeSessionLocked(token);
            return null;
        }
        const owner = self.users.get(session.email) orelse {
            self.removeSessionLocked(token);
            return null;
        };
        if (owner.banned or owner.id != session.uid or owner.session_generation != session.generation) {
            self.removeSessionLocked(token);
            return null;
        }
        return owner;
    }

    fn removeSessionLocked(self: *Auth, token: []const u8) void {
        if (self.sessions.fetchRemove(token)) |kv| {
            var sbuf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&sbuf, "s_{s}", .{kv.key})) |scope| self.nb.del(scope) else |_| {}
            self.gpa.free(kv.value.email);
            self.gpa.free(kv.key);
        }
    }

    pub fn logout(self: *Auth, token: []const u8) void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        self.removeSessionLocked(token);
    }

    fn validSessionToken(token: []const u8) bool {
        if (token.len != 48) return false;
        for (token) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
        return true;
    }

    /// A browser logout must not claim revocation while a persisted session can return on restart.
    /// Remove live acceptance first, then confirm the stored token is gone. Retrying the same token
    /// still checks storage even when its live entry was removed by an earlier failed attempt.
    pub fn logoutChecked(self: *Auth, token: []const u8) !void {
        if (!validSessionToken(token)) return;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        if (self.sessions.fetchRemove(token)) |kv| {
            self.gpa.free(kv.value.email);
            self.gpa.free(kv.key);
        }
        var sbuf: [64]u8 = undefined;
        const scope = try std.fmt.bufPrint(&sbuf, "s_{s}", .{token});
        try self.nb.delChecked(scope);
        if (try self.nb.get(scope)) |remaining| {
            self.gpa.free(remaining);
            return error.SessionNotDeleted;
        }
    }

    pub fn userById(self: *Auth, uid: u64) ?User {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var it = self.users.valueIterator();
        while (it.next()) |u| if (u.id == uid) return u.*;
        return null;
    }

    pub const BillingIdentity = struct { plan: Plan, admin: bool, banned: bool };

    /// Copy only the billing fields while holding the account lock. A returned
    /// User borrows its email and can race with deletion after the lock drops.
    pub fn billingIdentity(self: *Auth, uid: u64) ?BillingIdentity {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var it = self.users.valueIterator();
        while (it.next()) |u| {
            if (u.id == uid) return .{ .plan = u.plan, .admin = self.isAdmin(u.*), .banned = u.banned };
        }
        return null;
    }

    pub fn idForEmail(self: *Auth, email: []const u8) ?u64 {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.get(email) orelse return null;
        return u.id;
    }

    pub fn userCount(self: *Auth) usize {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        return self.users.count();
    }

    pub fn setPlan(self: *Auth, email: []const u8, plan: Plan) !bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.getPtr(email) orelse return false;
        if (@intFromEnum(plan) > @intFromEnum(u.plan)) {
            var candidate = u.*;
            candidate.plan = plan;
            try self.persistPrivilegeIncrease(u.*, candidate);
            u.plan = plan;
        } else {
            // A downgrade takes effect live even when storage cannot confirm it.
            u.plan = plan;
            try self.persistUserConfirmed(u.*);
        }
        return true;
    }

    fn dropSessions(self: *Auth, email: []const u8) void {
        var toremove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer toremove.deinit(self.gpa);
        var it = self.sessions.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.email, email)) toremove.append(self.gpa, e.key_ptr.*) catch {};
        for (toremove.items) |tok| self.removeSessionLocked(tok);
    }

    pub fn setBanned(self: *Auth, email: []const u8, banned: bool) !bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.getPtr(email) orelse return false;
        if (banned) {
            // Deny access immediately even if storage is down; report the failed write to the admin.
            u.banned = true;
            u.session_generation = self.nextSessionGeneration(u.session_generation);
            self.dropSessions(email);
            try self.persistUserConfirmed(u.*);
        } else {
            // An unban must survive a restart before the live account regains access.
            var candidate = u.*;
            candidate.banned = false;
            try self.persistPrivilegeIncrease(u.*, candidate);
            u.banned = false;
        }
        return true;
    }

    /// Does this user hold a grant for recipe tool `name`? The turn-start resolve (engine.zig) intersects
    /// the recipe registry with each sandboxed caller's grants through this; a free fn (no lock) so it can
    /// be asked about a User already read out under the caller's own snapshot.
    pub fn hasToolGrant(u: User, name: []const u8) bool {
        return grantsContain(u.tool_grants, name);
    }

    /// Grant (`on`) or revoke a recipe-tool name for a user, confirming the stored record. Returns whether
    /// anything changed; an already-satisfied request returns false. Storage failures are reported to the
    /// admin. Revocation takes effect in memory first, while a new grant is withheld until persistence.
    ///
    /// The grant list is rebuilt immutably on each change — a fresh backing slice is allocated, the old one
    /// freed — so a concurrent reader that snapshotted the User (hasToolGrant above) keeps walking the slice
    /// it already holds rather than one being mutated underfoot. Names are duped on add and freed on remove,
    /// keeping the same whole-User ownership every other field follows.
    pub fn setToolGrant(self: *Auth, email: []const u8, name: []const u8, on: bool) !bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.getPtr(email) orelse return false;
        if (on) {
            if (grantsContain(u.tool_grants, name)) {
                try self.persistUserConfirmed(u.*); // a retry must repair/check an earlier failed write
                return false;
            }
            const nw = try self.gpa.alloc([]const u8, u.tool_grants.len + 1);
            errdefer self.gpa.free(nw);
            for (u.tool_grants, 0..) |g, i| nw[i] = g; // carry the existing names by reference
            nw[u.tool_grants.len] = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(nw[u.tool_grants.len]);
            var candidate = u.*;
            candidate.tool_grants = nw;
            try self.persistPrivilegeIncrease(u.*, candidate);
            self.gpa.free(u.tool_grants); // free ONLY the old backing slice; its names moved into nw
            u.tool_grants = nw;
        } else {
            var idx: ?usize = null;
            for (u.tool_grants, 0..) |g, i| if (std.mem.eql(u8, g, name)) {
                idx = i;
                break;
            };
            const j = idx orelse {
                try self.persistUserConfirmed(u.*); // live revoke may still be absent from storage
                return false;
            };
            if (u.tool_grants.len == 1) {
                self.gpa.free(u.tool_grants[0]);
                self.gpa.free(u.tool_grants);
                u.tool_grants = &.{};
            } else {
                // Alloc the smaller slice FIRST; only once it exists do we free the removed name and the old
                // backing, so an OOM here leaves the grant list intact rather than half-torn.
                const nw = try self.gpa.alloc([]const u8, u.tool_grants.len - 1);
                var k: usize = 0;
                for (u.tool_grants, 0..) |g, i| {
                    if (i == j) continue;
                    nw[k] = g;
                    k += 1;
                }
                self.gpa.free(u.tool_grants[j]); // the removed name
                self.gpa.free(u.tool_grants); // the old backing slice
                u.tool_grants = nw;
            }
            // Keep the live capability revoked even when storage fails, and tell the admin it may
            // still reappear after a restart instead of answering success.
            try self.persistUserConfirmed(u.*);
        }
        return true;
    }

    pub fn deleteUser(self: *Auth, email: []const u8) !bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.getPtr(email) orelse return false;
        // A failed delete must leave no live access and no unbanned record to reload on restart.
        u.banned = true;
        u.session_generation = self.nextSessionGeneration(u.session_generation);
        self.dropSessions(email);
        try self.persistUserConfirmed(u.*);
        // Old user rows may predate reservations. Confirm one before removing the only
        // remaining record that carries this ID.
        try self.reserveId(u.id, true);
        var sbuf: [16]u8 = undefined;
        const scope = userScope(email, &sbuf);
        try self.nb.delChecked(scope);
        if (try self.nb.get(scope)) |remaining| {
            self.gpa.free(remaining);
            return error.UserRecordNotDeleted;
        }
        try self.writeUserIndex(null, email);
        const kv = self.users.fetchRemove(email).?;
        self.gpa.free(kv.value.email);
        self.gpa.free(kv.value.pwhash);
        freeGrants(self.gpa, kv.value.tool_grants);
        return true;
    }

    pub fn listUsers(self: *Auth, gpa: std.mem.Allocator) ![]UserInfo {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var list: std.ArrayListUnmanaged(UserInfo) = .empty;
        var it = self.users.valueIterator();
        while (it.next()) |u| try list.append(gpa, .{ .id = u.id, .email = u.email, .plan = u.plan, .created = u.created, .banned = u.banned, .tool_grants = u.tool_grants });
        return list.toOwnedSlice(gpa);
    }
};

test "warm fails closed when user enumeration is unavailable" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const nb = Neuron.init(gpa, threaded.io(), "__nl_no_such_neuron_bin__", "__nl_no_such_db__");
    var auth = Auth.init(gpa, nb);
    defer auth.deinit();
    try std.testing.expectError(error.FileNotFound, auth.warm());
    try std.testing.expectEqual(@as(usize, 0), auth.userCount());
}

// Exercise the live lookup: startup cleanup alone cannot expire a token on a long-running server.

test "whoami expires loaded sessions during a long-running process" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const nb = Neuron.init(gpa, io, "__nl_no_such_neuron_bin__", "__nl_no_such_db__");
    var auth = Auth.init(gpa, nb);
    defer auth.deinit();

    const email = try gpa.dupe(u8, "u@x.co");
    try auth.users.put(gpa, email, .{
        .id = 1,
        .email = email,
        .pwhash = try gpa.dupe(u8, "stub"),
        .plan = .free,
        .created = 1,
    });
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    try auth.sessions.put(gpa, try gpa.dupe(u8, "fresh"), .{
        .email = try gpa.dupe(u8, email),
        .created = now - 60,
        .uid = 1,
        .generation = 0,
    });
    try auth.sessions.put(gpa, try gpa.dupe(u8, "expired"), .{
        .email = try gpa.dupe(u8, email),
        .created = now - Auth.SESSION_TTL_S - 10,
        .uid = 1,
        .generation = 0,
    });

    try std.testing.expect(auth.whoami("fresh") != null);
    try std.testing.expect(auth.whoami("expired") == null);
    try std.testing.expect(!auth.sessions.contains("expired"));
    try std.testing.expect(auth.whoami("fresh") != null);
    try std.testing.expect(Auth.sessionExpired(now - Auth.SESSION_TTL_S, now));
    try std.testing.expect(!Auth.sessionExpired(now - Auth.SESSION_TTL_S + 1, now));
    try std.testing.expect(Auth.sessionExpired(0, now));
    try std.testing.expect(Auth.sessionExpired(now + 1, now));
}

test "logoutChecked rejects live token use and reports a failed stored delete on retry" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const nb = Neuron.init(gpa, io, "__nl_no_such_neuron_bin__", "__nl_no_such_db__");
    var auth = Auth.init(gpa, nb);
    defer auth.deinit();
    const token = "a" ** 48;
    try auth.sessions.put(gpa, try gpa.dupe(u8, token), .{
        .email = try gpa.dupe(u8, "u@x.co"),
        .created = std.Io.Timestamp.now(io, .real).toSeconds(),
        .uid = 1,
        .generation = 0,
    });
    if (auth.logoutChecked(token)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(!auth.sessions.contains(token));
    if (auth.logoutChecked(token)) |_| return error.TestExpectedError else |_| {} // retry still checks storage
}

test "moderation storage failure keeps bans effective and refuses an unban" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const nb = Neuron.init(gpa, io, "__nl_no_such_neuron_bin__", "__nl_no_such_db__");
    var auth = Auth.init(gpa, nb);
    defer auth.deinit();

    const email = try gpa.dupe(u8, "u@x.co");
    try auth.users.put(gpa, email, .{
        .id = 1,
        .email = email,
        .pwhash = try gpa.dupe(u8, "stub"),
        .plan = .free,
        .created = 1,
    });
    try auth.sessions.put(gpa, try gpa.dupe(u8, "active"), .{
        .email = try gpa.dupe(u8, email),
        .created = std.Io.Timestamp.now(io, .real).toSeconds(),
        .uid = 1,
        .generation = 0,
    });

    if (auth.setBanned(email, true)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(auth.users.get(email).?.banned);
    try std.testing.expect(auth.whoami("active") == null);
    if (auth.setBanned(email, false)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(auth.users.get(email).?.banned);
    if (auth.deleteUser(email)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(auth.users.get(email).?.banned);
}

// Grant persistence is the load-bearing half of the recipe-tool feature: the run gate trusts what warm()
// loaded. These tests pin both the serialized record and fail-closed behavior when storage is unavailable.

test "tool_grants record contract: a granted list serializes and re-loads; an empty list stays empty" {
    const gpa = std.testing.allocator;

    // GRANT → PERSIST: recordJson is the exact bytes persistUser stores. Re-parsing them through the shape
    // warm() loads with (ignore_unknown_fields lets this subset stand in for the whole record) is the
    // "reload" step — the two grants must come back.
    const granted = User{ .id = 7, .email = "u@x.co", .pwhash = "argon2id$stub", .plan = .free, .created = 0, .tool_grants = &.{ "research_brief", "cite_check" } };
    const j1 = try Auth.recordJson(gpa, granted);
    defer gpa.free(j1);
    const Loaded = struct { tool_grants: []const []const u8 = &.{} };
    {
        const parsed = try std.json.parseFromSlice(Loaded, gpa, j1, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.tool_grants.len);
        try std.testing.expect(Auth.grantsContain(parsed.value.tool_grants, "research_brief"));
        try std.testing.expect(Auth.grantsContain(parsed.value.tool_grants, "cite_check"));
    }

    // REVOKE-to-none → PERSIST: an empty grant list serializes to `[]` and re-loads as no grants.
    const revoked = User{ .id = 7, .email = "u@x.co", .pwhash = "argon2id$stub", .plan = .free, .created = 0 };
    const j2 = try Auth.recordJson(gpa, revoked);
    defer gpa.free(j2);
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"tool_grants\":[]") != null);
    const parsed = try std.json.parseFromSlice(Loaded, gpa, j2, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tool_grants.len);
}

test "setToolGrant: failed storage withholds grants and revokes existing ones in memory" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // A missing binary makes both the write and its readback fail without a live datastore.
    const nb = Neuron.init(gpa, io, "__nl_no_such_neuron_bin__", "__nl_no_such_db__");
    var auth = Auth.init(gpa, nb);
    defer {
        // The one seeded user's owned fields: its (mutated) grant list and duped pwhash. email + the map key
        // are static literals, not heap. Then tear down the maps themselves so testing.allocator sees no leak.
        if (auth.users.getPtr("u@x.co")) |uu| {
            Auth.freeGrants(gpa, uu.tool_grants);
            gpa.free(uu.pwhash);
        }
        auth.users.deinit(gpa);
        auth.sessions.deinit(gpa);
    }
    try auth.users.put(gpa, "u@x.co", .{
        .id = 1,
        .email = "u@x.co",
        .pwhash = try gpa.dupe(u8, "stub"),
        .plan = .free,
        .created = 0,
        .tool_grants = try Auth.dupGrants(gpa, &.{ "research_brief", "cite_check" }),
    });

    if (auth.setToolGrant("u@x.co", "new_grant", true)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(!Auth.hasToolGrant(auth.users.get("u@x.co").?, "new_grant"));
    if (auth.setToolGrant("u@x.co", "research_brief", true)) |_| return error.TestExpectedError else |_| {}
    if (auth.setToolGrant("u@x.co", "research_brief", false)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(!Auth.hasToolGrant(auth.users.get("u@x.co").?, "research_brief"));
    try std.testing.expect(Auth.hasToolGrant(auth.users.get("u@x.co").?, "cite_check"));
    if (auth.setToolGrant("u@x.co", "research_brief", false)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expect(!(try auth.setToolGrant("nobody@x.co", "new_grant", true))); // unknown user
}
