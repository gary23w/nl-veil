//! Auth — register / login / sessions, backed by neuron-db (dogfooded) with an in-memory user + session cache.

const std = @import("std");
const Neuron = @import("../worker/neuron/client.zig").Neuron;

const log = std.log.scoped(.auth);

pub const Plan = @import("../plan/entitlements.zig").Plan;

pub const User = struct {
    id: u64,
    email: []const u8,
    pwhash: []const u8,
    plan: Plan,
    created: i64,
    banned: bool = false,
};

pub const UserInfo = struct { id: u64, email: []const u8, plan: Plan, created: i64, banned: bool = false };

const SessionVal = struct { email: []const u8, created: i64 };

pub const AuthError = error{ EmailTaken, BadCredentials, WeakInput, BadEmail };

pub const DEFAULT_ADMIN_EMAIL = "admin@neuron-loops.local";

pub const Auth = struct {
    gpa: std.mem.Allocator,
    nb: Neuron,
    mu: std.Io.Mutex = .init,
    users: std.StringHashMapUnmanaged(User) = .empty,
    sessions: std.StringHashMapUnmanaged([]const u8) = .empty,
    next_id: u64 = 1,
    admin_email: ?[]const u8 = null,
    dummy: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, nb: Neuron) Auth {
        return .{ .gpa = gpa, .nb = nb };
    }

    pub fn setAdminEmail(self: *Auth, email: ?[]const u8) void {
        const e = email orelse DEFAULT_ADMIN_EMAIL;
        self.admin_email = self.gpa.dupe(u8, e) catch null;
    }

    pub fn isAdmin(self: *Auth, u: User) bool {
        if (self.admin_email) |e| return std.ascii.eqlIgnoreCase(u.email, e);
        return u.id == 1;
    }

    fn isAdminEmail(self: *Auth, email: []const u8) bool {
        if (self.admin_email) |e| return std.ascii.eqlIgnoreCase(email, e);
        return self.next_id == 1;
    }

    pub fn seedDefaultAdmin(self: *Auth, password: ?[]const u8) void {
        const email = self.admin_email orelse DEFAULT_ADMIN_EMAIL;
        const pw = password orelse "changeme";
        self.register(email, pw) catch |e| {
            if (e != AuthError.EmailTaken) log.err("seed admin {s}: {t}", .{ email, e });
            return;
        };
        if (password == null)
            log.warn("*** DEFAULT ADMIN SEEDED: {s} / changeme — set NL_ADMIN_PASSWORD and change this ***", .{email})
        else
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

    fn persistUser(self: *Auth, u: User) !void {
        const json = try std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"email\":\"{s}\",\"pwhash\":\"{s}\",\"plan\":\"{s}\",\"created\":{d},\"banned\":{}}}", .{ u.id, u.email, u.pwhash, @tagName(u.plan), u.created, u.banned });
        defer self.gpa.free(json);
        const enc = try b64(self.gpa, json);
        defer self.gpa.free(enc);
        var sbuf: [16]u8 = undefined;
        try self.nb.put(userScope(u.email, &sbuf), enc);
    }

    pub fn warm(self: *Auth) !void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const uscopes = self.nb.scopes("u_") catch return;
        defer {
            for (uscopes) |s| self.gpa.free(s);
            self.gpa.free(uscopes);
        }
        for (uscopes) |scope| {
            const enc = (self.nb.get(scope) catch continue) orelse continue;
            defer self.gpa.free(enc);
            const json = unb64(self.gpa, enc) catch continue;
            defer self.gpa.free(json);
            const parsed = std.json.parseFromSlice(struct { id: u64, email: []const u8, pwhash: []const u8, plan: []const u8, created: i64, banned: bool = false }, self.gpa, json, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const v = parsed.value;
            const u = User{
                .id = v.id,
                .email = try self.gpa.dupe(u8, v.email),
                .pwhash = try self.gpa.dupe(u8, v.pwhash),
                .plan = if (std.mem.eql(u8, v.plan, "max")) .max else if (std.mem.eql(u8, v.plan, "pro")) .pro else .free,
                .created = v.created,
                .banned = v.banned,
            };
            try self.users.put(self.gpa, u.email, u);
            if (v.id >= self.next_id) self.next_id = v.id + 1;
        }
    }

    pub fn register(self: *Auth, email: []const u8, password: []const u8) AuthError!void {
        if (!validEmail(email)) return AuthError.BadEmail;
        if (password.len < 8 or password.len > 200) return AuthError.WeakInput;
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        if (self.users.contains(email)) return AuthError.EmailTaken;

        var hbuf: [128]u8 = undefined;
        const phc = std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = self.gpa,
            .params = .{ .t = 2, .m = 19456, .p = 1 },
            .mode = .argon2id,
        }, &hbuf, self.nb.io) catch return AuthError.WeakInput;

        const u = User{
            .id = self.next_id,
            .email = self.gpa.dupe(u8, email) catch return AuthError.WeakInput,
            .pwhash = self.gpa.dupe(u8, phc) catch return AuthError.WeakInput,
            .plan = if (self.isAdminEmail(email)) .pro else .free,
            .created = std.Io.Timestamp.now(self.nb.io, .real).toSeconds(),
        };
        self.next_id += 1;
        self.persistUser(u) catch {};
        self.users.put(self.gpa, u.email, u) catch return AuthError.WeakInput;
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
        var raw: [24]u8 = undefined;
        self.nb.io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        const token = try self.gpa.dupe(u8, &hex);
        try self.sessions.put(self.gpa, token, try self.gpa.dupe(u8, email));
        const sv = try std.fmt.allocPrint(self.gpa, "{{\"email\":\"{s}\",\"created\":{d}}}", .{ email, std.Io.Timestamp.now(self.nb.io, .real).toSeconds() });
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
        const email = self.sessions.get(token) orelse return null;
        return self.users.get(email);
    }

    pub fn logout(self: *Auth, token: []const u8) void {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        if (self.sessions.fetchRemove(token)) |kv| {
            self.gpa.free(kv.value);
            self.gpa.free(kv.key);
            var sbuf: [64]u8 = undefined;
            const scope = std.fmt.bufPrint(&sbuf, "s_{s}", .{token}) catch return;
            self.nb.del(scope);
        }
    }

    pub fn userById(self: *Auth, uid: u64) ?User {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var it = self.users.valueIterator();
        while (it.next()) |u| if (u.id == uid) return u.*;
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

    pub fn setPlan(self: *Auth, email: []const u8, plan: Plan) bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.getPtr(email) orelse return false;
        u.plan = plan;
        self.persistUser(u.*) catch {};
        return true;
    }

    fn dropSessions(self: *Auth, email: []const u8) void {
        var toremove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer toremove.deinit(self.gpa);
        var it = self.sessions.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, email)) toremove.append(self.gpa, e.key_ptr.*) catch {};
        for (toremove.items) |tok| {
            if (self.sessions.fetchRemove(tok)) |kv| {
                var sbuf: [64]u8 = undefined;
                if (std.fmt.bufPrint(&sbuf, "s_{s}", .{kv.key})) |scope| self.nb.del(scope) else |_| {}
                self.gpa.free(kv.value);
                self.gpa.free(kv.key);
            }
        }
    }

    pub fn setBanned(self: *Auth, email: []const u8, banned: bool) bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        const u = self.users.getPtr(email) orelse return false;
        u.banned = banned;
        self.persistUser(u.*) catch {};
        if (banned) self.dropSessions(email);
        return true;
    }

    pub fn deleteUser(self: *Auth, email: []const u8) bool {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        self.dropSessions(email);
        if (self.users.fetchRemove(email)) |kv| {
            var sbuf: [16]u8 = undefined;
            self.nb.del(userScope(kv.value.email, &sbuf));
            self.gpa.free(kv.value.email);
            self.gpa.free(kv.value.pwhash);
            return true;
        }
        return false;
    }

    pub fn listUsers(self: *Auth, gpa: std.mem.Allocator) ![]UserInfo {
        self.mu.lockUncancelable(self.nb.io);
        defer self.mu.unlock(self.nb.io);
        var list: std.ArrayListUnmanaged(UserInfo) = .empty;
        var it = self.users.valueIterator();
        while (it.next()) |u| try list.append(gpa, .{ .id = u.id, .email = u.email, .plan = u.plan, .created = u.created, .banned = u.banned });
        return list.toOwnedSlice(gpa);
    }
};
