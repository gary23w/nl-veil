//! chat.zig — the chat worker thread: the third thread beside the UI and the poller, same discipline
//! (owns its own std.Io, talks to the UI only through the Store). It runs the Chat tab's brain:
//!   - model turns: streams /chat/completions through llm.zig, deltas land in Store.stream_text
//!   - swarm casting: a reply whose first line is "CAST: <goal>" fires the EXISTING casting mechanism —
//!     POST /api/v1/swarms via netcli (the same door the Deploy tab uses) — then this thread WATCHES the
//!     run's events.jsonl (scan.tailEvents, filesystem-first) for the right-hand activity pane, and when
//!     the swarm stops it folds the findings back into the conversation and asks the model to answer.
//!   - persistence: conversations are JSONL files under <data>/.veil-desk/chats/, chat settings JSON at
//!     <data>/.veil-desk/settings.json, the API key sealed via secrets.zig. All chat-side io lives here.

const std = @import("std");
const Io = std.Io;
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const netcli = @import("netcli.zig");
const llm = @import("llm.zig");
const secrets = @import("secrets.zig");
const catalog = @import("catalog.zig");
const log = @import("log.zig");

const Store = store_mod.Store;

const SYSTEM_PROMPT =
    "You are the Veil, the chat mind of this nl-veil host. You command a hive-mind swarm engine; " ++
    "casting a swarm is your primary reasoning tool for real work.\n" ++
    "To cast, make the FIRST line of your reply exactly:\n" ++
    "CAST: <one-line goal for the hive>\n" ++
    "After that line you may add a short note to the user. Only one cast runs at a time.\n" ++
    "WHEN TO CAST (cast — do NOT answer from memory):\n" ++
    "- ANY question about current events, news, or the state of the world (you have NO live knowledge and " ++
    "would otherwise hallucinate — cast so the hive researches it on the web).\n" ++
    "- Anything time-sensitive or that could have changed since your training, or that asks 'latest', " ++
    "'recent', 'today', 'now', prices, scores, releases, who currently holds a role.\n" ++
    "- Specific facts about a named person, place, product, or org you are not certain of.\n" ++
    "- Multi-step research, building or fixing code or files, verification against a real codebase.\n" ++
    "NEVER fabricate current events, dates, statistics, or news. If you cannot answer from durable, " ++
    "general knowledge with high confidence, CAST instead of guessing.\n" ++
    "DO NOT cast for greetings, small talk, definitions, or timeless facts you know confidently.\n" ++
    "A cast runs for minutes; the user watches its live activity beside this chat. When it finishes you " ++
    "receive its findings in a [cast] message and must then answer the user's request from them.\n" ++
    "Otherwise reply normally in plain text.";

const CAST_MINUTES: u32 = 8; // v1 fixed budget; the engine self-crunches to fit
const MAX_TOKENS: u32 = 2048;

const Turn = enum { idle, user, collect };

pub const Chat = struct {
    io: Io,
    gpa: std.mem.Allocator,
    store: *Store,
    stop: std.atomic.Value(bool) = .init(false),

    stream: llm.Stream = .{},
    turn: Turn = .idle,
    first_byte_logged: bool = false, // one timing line per turn
    parallel_tip: bool = false, // shown the OLLAMA_NUM_PARALLEL tip once

    // active cast bookkeeping (one at a time)
    cast_active: bool = false,
    cast_hex: [32]u8 = [_]u8{0} ** 32,
    cast_hex_len: usize = 0,
    cast_rel: [96]u8 = [_]u8{0} ** 96, // resolved run path relative to data dir
    cast_rel_len: usize = 0,
    cast_deadline_s: i64 = 0,
    cast_stop_sent: bool = false,

    // scratch (thread-owned)
    ev_scratch: [store_mod.CAST_TAIL]scan.Ev = undefined,
    sw_scratch: [scan.MAX_SWARMS]scan.SwarmSummary = undefined,
    file_scratch: [scan.MAX_FILES]scan.FileRow = undefined,

    pub fn run(self: *Chat) void {
        var dbuf: [512]u8 = undefined;
        const dd0 = self.dataDir(&dbuf);
        self.ensureDirs(dd0);
        self.loadSettings(dd0);
        self.loadKey(dd0);
        self.refreshConvs(dd0, true);

        var tick: u32 = 0;
        while (!self.stop.load(.monotonic)) {
            var db: [512]u8 = undefined;
            const dd = self.dataDir(&db);
            self.drainCommands(dd);
            self.pumpStream(dd);
            if (tick % 10 == 0) self.watchCast(dd); // ~1Hz beside the 10Hz stream pump
            if (tick % 50 == 0) self.refreshConvs(dd, false); // ~5s: pick up external changes
            tick +%= 1;
            self.io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        llm.abort(&self.stream, self.io);
        self.stream.deinit(self.gpa);
    }

    // ------------------------------------------------------------------------------ plumbing

    fn dataDir(self: *Chat, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        const d = self.store.settings.dataDir();
        const n = @min(d.len, buf.len);
        @memcpy(buf[0..n], d[0..n]);
        return buf[0..n];
    }

    fn nowS(self: *Chat) i64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
    }

    /// Is the chat model the local Ollama backend (where NUM_PARALLEL contention applies)?
    fn isLocalChat(self: *Chat) bool {
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        if (s.chat_kind == 0) return true; // local (Ollama) provider
        if (s.chat_kind == 2) return std.mem.indexOf(u8, s.chatBase(), "11434") != null; // custom URL at Ollama
        return false;
    }

    fn ensureDirs(self: *Chat, dd: []const u8) void {
        var pbuf: [600]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/.veil-desk/chats", .{dd}) catch return;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, p, .default_dir) catch {};
    }

    fn sideDir(dd: []const u8, buf: []u8) []const u8 {
        const p = std.fmt.bufPrint(buf, "{s}/.veil-desk", .{dd}) catch return dd;
        return p;
    }

    fn setStatus(self: *Chat, s: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        const n = @min(s.len, self.store.chat_status.len);
        @memcpy(self.store.chat_status[0..n], s[0..n]);
        self.store.chat_status_len = @intCast(n);
    }

    fn setBusy(self: *Chat, v: bool) void {
        self.store.lock();
        defer self.store.unlock();
        self.store.chat_busy = v;
        if (!v) {
            self.store.stream_len = 0;
            self.store.chat_status_len = 0;
        }
    }

    // ------------------------------------------------------------------------------ commands

    fn drainCommands(self: *Chat, dd: []const u8) void {
        while (self.store.popChatCmd()) |c| {
            switch (c.kind) {
                .none => {},
                .send => self.cmdSend(dd, c.textStr()),
                .new_conv => self.cmdNewConv(dd),
                .select_conv => self.cmdSelectConv(dd, c.idStr()),
                .rename_conv => self.cmdRenameConv(dd, c.idStr(), c.textStr()),
                .delete_conv => self.cmdDeleteConv(dd, c.idStr()),
                .stop_cast => self.cmdStopCast(dd, c.idStr()),
                .save_settings => self.saveSettings(dd),
                .save_key => self.cmdSaveKey(dd, c.textStr()),
            }
        }
    }

    pub fn cmdSend(self: *Chat, dd: []const u8, text: []const u8) void {
        if (text.len == 0 or self.turn != .idle) return;
        // a conversation's FIRST message names it — whether the user typed straight away (auto-create)
        // or clicked + first (the "new chat" placeholder title gets replaced here).
        var have_conv = false;
        var fresh = false;
        {
            self.store.lock();
            have_conv = self.store.conv_active_len > 0;
            fresh = self.store.msg_count == 0;
            self.store.unlock();
        }
        if (!have_conv) {
            self.cmdNewConv(dd);
            fresh = true;
        }
        if (fresh) {
            var tb: [42]u8 = undefined;
            const n = @min(text.len, tb.len);
            @memcpy(tb[0..n], text[0..n]);
            for (tb[0..n]) |*c| {
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
            self.renameActive(dd, tb[0..n]);
        }
        self.appendMsg(dd, .user, text);
        self.startTurn(dd, .user);
    }

    pub fn cmdNewConv(self: *Chat, dd: []const u8) void {
        var idb: [32]u8 = undefined;
        const now = self.nowS();
        const id = std.fmt.bufPrint(&idb, "c{x}", .{@as(u64, @intCast(now))}) catch return;
        // collision (two in one second) → suffix
        var pb: [700]u8 = undefined;
        var path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch return;
        if (Io.Dir.cwd().statFile(self.io, path, .{})) |_| {
            const id2 = std.fmt.bufPrint(&idb, "c{x}b", .{@as(u64, @intCast(now))}) catch return;
            path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id2 }) catch return;
        } else |_| {}
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "{\"title\":\"new chat\"}\n" }) catch {
            log.err("chat: cannot create conversation file", .{});
            return;
        };
        const stem = std.fs.path.stem(std.fs.path.basename(path));
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(stem.len, self.store.conv_active.len);
            @memcpy(self.store.conv_active[0..n], stem[0..n]);
            self.store.conv_active_len = @intCast(n);
            self.store.msg_count = 0;
        }
        self.refreshConvs(dd, true);
    }

    fn cmdSelectConv(self: *Chat, dd: []const u8, id: []const u8) void {
        if (id.len == 0 or self.turn != .idle) return;
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(id.len, self.store.conv_active.len);
            @memcpy(self.store.conv_active[0..n], id[0..n]);
            self.store.conv_active_len = @intCast(n);
            self.store.msg_count = 0;
        }
        self.loadMsgs(dd, id);
    }

    fn cmdRenameConv(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        if (id.len == 0 or title.len == 0) return;
        self.rewriteTitle(dd, id, title);
        self.refreshConvs(dd, true);
    }

    fn renameActive(self: *Chat, dd: []const u8, title: []const u8) void {
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            self.store.unlock();
        }
        if (idn > 0) self.cmdRenameConv(dd, idb[0..idn], title);
    }

    fn cmdDeleteConv(self: *Chat, dd: []const u8, id: []const u8) void {
        if (id.len == 0) return;
        // Refuse to delete the conversation whose turn is streaming: cmdSend/cmdSelectConv already guard
        // on turn==idle, but without this guard deleting the ACTIVE chat mid-turn clears conv_active, the
        // fallback select silently no-ops (its own guard), and the in-flight reply lands with no active
        // conversation — appendMsg writes it to a stranded Store slot and never persists it (lost). A
        // background conversation is always safe to delete.
        if (self.turn != .idle) {
            var active = false;
            {
                self.store.lock();
                active = std.mem.eql(u8, self.store.conv_active[0..self.store.conv_active_len], id);
                self.store.unlock();
            }
            if (active) {
                self.store.pushNotif("Busy", "let the reply finish before deleting this chat", 2);
                return;
            }
        }
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch return;
        Io.Dir.cwd().deleteFile(self.io, path) catch {};
        var was_active = false;
        {
            self.store.lock();
            defer self.store.unlock();
            was_active = std.mem.eql(u8, self.store.conv_active[0..self.store.conv_active_len], id);
            if (was_active) {
                self.store.conv_active_len = 0;
                self.store.msg_count = 0;
            }
        }
        self.refreshConvs(dd, true);
        if (was_active) {
            // fall back to the newest remaining conversation
            var nid: [32]u8 = undefined;
            var nn: usize = 0;
            {
                self.store.lock();
                defer self.store.unlock();
                if (self.store.conv_count > 0) {
                    nn = self.store.convs[0].id_len;
                    @memcpy(nid[0..nn], self.store.convs[0].id[0..nn]);
                }
            }
            if (nn > 0) self.cmdSelectConv(dd, nid[0..nn]);
        }
    }

    pub fn cmdStopCast(self: *Chat, dd: []const u8, rel: []const u8) void {
        if (rel.len == 0) return;
        _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}");
        self.store.pushNotif("Stop sent", rel, 2);
        self.cast_stop_sent = true;
    }

    fn cmdSaveKey(self: *Chat, dd: []const u8, key: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        const ok = secrets.save(self.io, self.gpa, side, key);
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(key.len, self.store.settings.chat_key.len);
            @memcpy(self.store.settings.chat_key[0..n], key[0..n]);
            self.store.settings.chat_key_len = @intCast(n);
        }
        if (ok) self.store.pushNotif("Key saved", "stored in the OS-protected local store", 1) else self.store.pushNotif("Key NOT saved", "could not write the secure store", 2);
    }

    // ------------------------------------------------------------------------------ settings persistence

    fn saveSettings(self: *Chat, dd: []const u8) void {
        var kind: u8 = 0;
        var byok: u8 = 0;
        var base: [192]u8 = undefined;
        var base_n: usize = 0;
        var model: [96]u8 = undefined;
        var model_n: usize = 0;
        var lopen = true;
        var ropen = true;
        {
            self.store.lock();
            defer self.store.unlock();
            const s = &self.store.settings;
            kind = s.chat_kind;
            byok = s.chat_byok;
            base_n = s.chat_base_len;
            @memcpy(base[0..base_n], s.chat_base[0..base_n]);
            model_n = s.chat_model_len;
            @memcpy(model[0..model_n], s.chat_model[0..model_n]);
            lopen = s.chat_left_open;
            ropen = s.chat_right_open;
        }
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"kind\":") catch return;
        jb.print(self.gpa, "{d},\"byok\":{d},\"base\":\"", .{ kind, byok }) catch return;
        escJson(&jb, self.gpa, base[0..base_n]);
        jb.appendSlice(self.gpa, "\",\"model\":\"") catch return;
        escJson(&jb, self.gpa, model[0..model_n]);
        jb.print(self.gpa, "\",\"left\":{},\"right\":{}}}", .{ lopen, ropen }) catch return;
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist settings", .{});
        };
    }

    fn loadSettings(self: *Chat, dd: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(8 << 10)) catch return;
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        if (jInt(data, "kind")) |v| s.chat_kind = @intCast(@max(0, @min(v, 2)));
        if (jInt(data, "byok")) |v| s.chat_byok = @intCast(@max(0, @min(v, @as(i64, @intCast(catalog.providers.len - 1)))));
        if (llm.jsonUnescape(self.gpa, data, "base")) |b| {
            defer self.gpa.free(b);
            const n = @min(b.len, s.chat_base.len);
            @memcpy(s.chat_base[0..n], b[0..n]);
            s.chat_base_len = @intCast(n);
        }
        if (llm.jsonUnescape(self.gpa, data, "model")) |m| {
            defer self.gpa.free(m);
            const n = @min(m.len, s.chat_model.len);
            @memcpy(s.chat_model[0..n], m[0..n]);
            s.chat_model_len = @intCast(n);
        }
        s.chat_left_open = std.mem.indexOf(u8, data, "\"left\":false") == null;
        s.chat_right_open = std.mem.indexOf(u8, data, "\"right\":false") == null;
    }

    fn loadKey(self: *Chat, dd: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        var kb: [192]u8 = undefined;
        const n = secrets.load(self.io, self.gpa, side, &kb);
        if (n == 0) return;
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.settings.chat_key[0..n], kb[0..n]);
        self.store.settings.chat_key_len = @intCast(n);
    }

    // ------------------------------------------------------------------------------ conversations on disk

    fn refreshConvs(self: *Chat, dd: []const u8, force: bool) void {
        _ = force;
        var rows: [store_mod.MAX_CONVS]store_mod.ConvRow = undefined;
        var n: usize = 0;
        var pb: [700]u8 = undefined;
        const cdir = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats", .{dd}) catch return;
        var dir = Io.Dir.cwd().openDir(self.io, cdir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (n < rows.len) {
            const e = (it.next(self.io) catch break) orelse break;
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".jsonl")) continue;
            const stem = e.name[0 .. e.name.len - 6];
            var row: store_mod.ConvRow = .{};
            const idn = @min(stem.len, row.id.len);
            @memcpy(row.id[0..idn], stem[0..idn]);
            row.id_len = @intCast(idn);
            var fpb: [760]u8 = undefined;
            const fp = std.fmt.bufPrint(&fpb, "{s}/{s}", .{ cdir, e.name }) catch continue;
            if (Io.Dir.cwd().statFile(self.io, fp, .{})) |st| {
                row.mtime_s = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            } else |_| {}
            // title = first line's {"title":"..."}
            if (Io.Dir.cwd().readFileAlloc(self.io, fp, self.gpa, .limited(4 << 10)) catch null) |head| {
                defer self.gpa.free(head);
                const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
                if (llm.jsonUnescape(self.gpa, head[0..nl], "title")) |t| {
                    defer self.gpa.free(t);
                    const tn = @min(t.len, row.title.len);
                    @memcpy(row.title[0..tn], t[0..tn]);
                    row.title_len = @intCast(tn);
                }
            }
            rows[n] = row;
            n += 1;
        }
        std.mem.sort(store_mod.ConvRow, rows[0..n], {}, struct {
            fn lt(_: void, a: store_mod.ConvRow, b: store_mod.ConvRow) bool {
                return a.mtime_s > b.mtime_s;
            }
        }.lt);
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.convs[0..n], rows[0..n]);
        self.store.conv_count = n;
    }

    fn convPath(dd: []const u8, id: []const u8, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch null;
    }

    fn loadMsgs(self: *Chat, dd: []const u8, id: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        self.store.msg_count = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        _ = it.next(); // title line
        while (it.next()) |line| {
            if (line.len < 4 or self.store.msg_count >= store_mod.MAX_CHAT_MSGS) continue;
            const r = jInt(line, "r") orelse continue;
            const t = llm.jsonUnescape(self.gpa, line, "t") orelse continue;
            defer self.gpa.free(t);
            var m: store_mod.ChatMsg = .{ .role = switch (r) {
                1 => .veil,
                2 => .cast_note,
                else => .user,
            } };
            const tn = @min(t.len, m.text.len);
            @memcpy(m.text[0..tn], t[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
        }
    }

    fn rewriteTitle(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
        defer self.gpa.free(data);
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return;
        escJson(&jb, self.gpa, title);
        jb.appendSlice(self.gpa, "\"}") catch return;
        if (nl < data.len) jb.appendSlice(self.gpa, data[nl..]) catch return else jb.append(self.gpa, '\n') catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {};
    }

    /// Append to the ACTIVE conversation: into the Store (render copy, oldest evicted at cap) and rewrite
    /// its file (title + the retained messages — the file mirrors what the app can re-show).
    pub fn appendMsg(self: *Chat, dd: []const u8, role: store_mod.ChatRole, text: []const u8) void {
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        var titleb: [64]u8 = undefined;
        var title_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            if (self.store.msg_count >= store_mod.MAX_CHAT_MSGS) {
                std.mem.copyForwards(store_mod.ChatMsg, self.store.msgs[0 .. store_mod.MAX_CHAT_MSGS - 1], self.store.msgs[1..store_mod.MAX_CHAT_MSGS]);
                self.store.msg_count = store_mod.MAX_CHAT_MSGS - 1;
            }
            var m: store_mod.ChatMsg = .{ .role = role };
            const tn = @min(text.len, m.text.len);
            @memcpy(m.text[0..tn], text[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
            // keep the sidebar title in sync (it lives in convs; find it)
            var i: usize = 0;
            while (i < self.store.conv_count) : (i += 1) {
                if (std.mem.eql(u8, self.store.convs[i].idStr(), idb[0..idn])) {
                    title_n = self.store.convs[i].title_len;
                    @memcpy(titleb[0..title_n], self.store.convs[i].title[0..title_n]);
                    break;
                }
            }
        }
        if (idn == 0) return;
        // rewrite the file from the Store copy
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return;
        escJson(&jb, self.gpa, if (title_n > 0) titleb[0..title_n] else "chat");
        jb.appendSlice(self.gpa, "\"}\n") catch return;
        {
            self.store.lock();
            defer self.store.unlock();
            var i: usize = 0;
            while (i < self.store.msg_count) : (i += 1) {
                const m = &self.store.msgs[i];
                jb.print(self.gpa, "{{\"r\":{d},\"t\":\"", .{@intFromEnum(m.role)}) catch return;
                escJson(&jb, self.gpa, m.textStr());
                jb.appendSlice(self.gpa, "\"}\n") catch return;
            }
        }
        var pb: [700]u8 = undefined;
        const path = convPath(dd, idb[0..idn], &pb) orelse return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist conversation", .{});
        };
    }

    // ------------------------------------------------------------------------------ the model turn

    fn resolveProvider(self: *Chat, base_buf: *[256]u8, key_buf: *[192]u8, model_buf: *[96]u8) llm.Provider {
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        var base: []const u8 = undefined;
        var key: []const u8 = "";
        switch (s.chat_kind) {
            1 => {
                base = catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)].base_url;
                key = s.chatKey();
            },
            2 => {
                base = s.chatBase();
                key = s.chatKey();
            },
            else => base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1",
        }
        const bn = @min(base.len, base_buf.len);
        @memcpy(base_buf[0..bn], base[0..bn]);
        const kn = @min(key.len, key_buf.len);
        @memcpy(key_buf[0..kn], key[0..kn]);
        var model: []const u8 = s.chatModel();
        if (model.len == 0) model = if (s.chat_kind == 1) catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)].models[0].id else "gpt-oss:20b";
        const mn = @min(model.len, model_buf.len);
        @memcpy(model_buf[0..mn], model[0..mn]);
        return .{ .base_url = base_buf[0..bn], .key = key_buf[0..kn], .model = model_buf[0..mn] };
    }

    /// "Sunday 2026-07-05 14:03 UTC" — the model gets a real clock every turn (it has no other one).
    fn dateLine(self: *Chat, buf: []u8) []const u8 {
        const now = self.nowS();
        if (now <= 0) return "";
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
        const ed = es.getEpochDay();
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" }; // epoch day 0 = Thu 1970-01-01
        const wd = weekdays[@intCast(@mod(ed.day, 7))];
        return std.fmt.bufPrint(buf, "\nCurrent date and time: {s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC.", .{ wd, yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
    }

    fn startTurn(self: *Chat, dd: []const u8, kind: Turn) void {
        var msgs: std.ArrayListUnmanaged(u8) = .empty;
        defer msgs.deinit(self.gpa);
        var dbuf: [96]u8 = undefined;
        msgs.appendSlice(self.gpa, "{\"role\":\"system\",\"content\":\"") catch return;
        escJson(&msgs, self.gpa, SYSTEM_PROMPT);
        escJson(&msgs, self.gpa, self.dateLine(&dbuf));
        msgs.appendSlice(self.gpa, "\"}") catch return;
        {
            self.store.lock();
            defer self.store.unlock();
            // include from the tail while the budget lasts (the newest matter most)
            var budget: usize = 24 * 1024;
            var first: usize = 0;
            var i: usize = self.store.msg_count;
            while (i > 0) {
                i -= 1;
                const l = self.store.msgs[i].text_len;
                if (budget < l) {
                    first = i + 1;
                    break;
                }
                budget -= l;
            }
            var k = first;
            while (k < self.store.msg_count) : (k += 1) {
                const m = &self.store.msgs[k];
                const role = switch (m.role) {
                    .veil => "assistant",
                    else => "user",
                };
                msgs.print(self.gpa, ",{{\"role\":\"{s}\",\"content\":\"", .{role}) catch return;
                escJson(&msgs, self.gpa, m.textStr());
                msgs.appendSlice(self.gpa, "\"}") catch return;
            }
        }
        if (kind == .collect) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"The cast has finished. Using the [cast] findings above, give the user a direct, complete answer to their original request. Do not cast again.\"}") catch return;
        }
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        if (!llm.start(&self.stream, self.io, self.gpa, side, prov, msgs.items, MAX_TOKENS, self.nowS())) {
            self.store.pushNotif("Chat failed", "could not start the model call (is curl available?)", 2);
            return;
        }
        self.turn = kind;
        self.first_byte_logged = false;
        self.setBusy(true);
        self.setStatus("thinking...");
        log.info("chat turn start: kind={t} prompt={d}b model_msgs history", .{ kind, msgs.items.len });
    }

    pub fn pumpStream(self: *Chat, dd: []const u8) void {
        if (self.turn == .idle) return;
        const now = self.nowS();
        // While a cast runs, the chat call shares the local backend with the whole swarm — long silence
        // is queueing. The stream gets a longer first-byte leash and the status line says so honestly.
        llm.poll(&self.stream, self.io, self.gpa, now, self.cast_active);
        // publish the partial + a live status with elapsed time
        {
            self.store.lock();
            defer self.store.unlock();
            const src = self.stream.content.items;
            const n = @min(src.len, self.store.stream_text.len);
            @memcpy(self.store.stream_text[0..n], src[0..n]);
            self.store.stream_len = n;
        }
        if (!self.stream.done) {
            const el = now - self.stream.started_s;
            var sb: [96]u8 = undefined;
            const st = if (!self.stream.saw_any and self.cast_active)
                std.fmt.bufPrint(&sb, "queued behind the hive... {d}s", .{el}) catch "queued behind the hive..."
            else if (!self.stream.saw_any)
                std.fmt.bufPrint(&sb, "thinking... {d}s", .{el}) catch "thinking..."
            else
                std.fmt.bufPrint(&sb, "writing... {d}s", .{el}) catch "writing...";
            self.setStatus(st);
            // Ollama serializes requests unless OLLAMA_NUM_PARALLEL is set, so a chat call waits out the
            // swarm's whole generation. Once it's clearly queued behind a cast on the local backend, tip
            // the user (once) — this is the real lever for concurrent chat + hive, not anything in-app.
            if (self.cast_active and !self.stream.saw_any and el > 6 and !self.parallel_tip and self.isLocalChat()) {
                self.parallel_tip = true;
                self.store.pushNotif("Chat is waiting on Ollama", "set OLLAMA_NUM_PARALLEL=2 (then restart Ollama) so chat and the hive run at once", 0);
            }
            if (self.stream.saw_any and !self.first_byte_logged) {
                self.first_byte_logged = true;
                log.info("chat turn: first byte after {d}s", .{el});
            }
            return;
        }
        llm.finish(&self.stream, self.io);
        const kind = self.turn;
        self.turn = .idle;
        if (self.stream.failed) {
            var eb: [260]u8 = undefined;
            const emsg = std.fmt.bufPrint(&eb, "(model error: {s})", .{self.stream.errStr()}) catch "(model error)";
            log.err("chat turn FAILED after {d}s: {s}", .{ now - self.stream.started_s, self.stream.errStr() });
            self.appendMsg(dd, .veil, emsg);
            self.store.pushNotif("Chat model error", self.stream.errStr(), 2);
            self.stream.deinit(self.gpa);
            self.setBusy(false);
            return;
        }
        log.info("chat turn done in {d}s ({d} chars)", .{ now - self.stream.started_s, self.stream.content.items.len });
        const full = std.mem.trim(u8, self.stream.content.items, " \r\n\t");
        if (kind == .collect) {
            self.appendMsg(dd, .veil, full);
        } else if (castGoal(full)) |goal| {
            var nb: [3072]u8 = undefined;
            const note = noteWithoutCast(full, &nb);
            if (self.cast_active) {
                if (note.len > 0) self.appendMsg(dd, .veil, note) else self.appendMsg(dd, .veil, full);
                self.appendMsg(dd, .cast_note, "[cast] a cast is already running — new cast ignored");
            } else {
                if (note.len > 0) self.appendMsg(dd, .veil, note);
                self.fireCast(dd, goal);
            }
        } else {
            self.appendMsg(dd, .veil, full);
        }
        self.stream.deinit(self.gpa);
        self.setBusy(false);
    }

    // ------------------------------------------------------------------------------ casting (the existing door)

    /// CAST through the server's cast endpoint (POST /api/v1/cast) — the server owns the cast defaults
    /// (minutes budget, minds, autonomy dials); the chat only says WHAT to cast and WITH WHICH provider.
    pub fn fireCast(self: *Chat, dd: []const u8, goal: []const u8) void {
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var kind: u8 = 0;
        var byok: u8 = 0;
        var port: u16 = 8787;
        var tokb: [128]u8 = undefined;
        var tok_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            kind = self.store.settings.chat_kind;
            byok = self.store.settings.chat_byok;
            port = self.store.settings.port;
            tok_n = self.store.settings.token_len;
            @memcpy(tokb[0..tok_n], self.store.settings.token[0..tok_n]);
        }
        const prov_key = switch (kind) {
            1 => catalog.providers[@min(byok, catalog.providers.len - 1)].key,
            2 => "openai", // custom endpoints are OpenAI-compatible; the URL carries the truth
            else => "ollama",
        };

        var body: [2048]u8 = undefined;
        var w = Io.Writer.fixed(&body);
        w.print("{{\"provider\":\"{s}\",\"model\":\"{s}\",\"base_url\":\"{s}\",\"minutes\":{d},\"api_key\":\"", .{ prov_key, prov.model, prov.base_url, CAST_MINUTES }) catch return;
        wesc(&w, prov.key);
        w.writeAll("\",\"goal\":\"") catch return;
        wesc(&w, goal);
        w.writeAll("\"}") catch return;

        self.setStatus("casting the hive...");
        const resp = netcli.cast(self.io, self.gpa, port, tokb[0..tok_n], w.buffered()) orelse {
            self.appendMsg(dd, .cast_note, "[cast] failed — the veil server is unreachable (start it, then ask again)");
            self.store.pushNotif("Cast failed", "server unreachable", 2);
            self.setStatus("");
            return;
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        if (resp.status != 200 and resp.status != 201) {
            var nb: [200]u8 = undefined;
            const msg = std.fmt.bufPrint(&nb, "[cast] rejected by the server (HTTP {d})", .{resp.status}) catch "[cast] rejected";
            self.appendMsg(dd, .cast_note, msg);
            self.store.pushNotif("Cast rejected", if (resp.status == 401 or resp.status == 403) "set an API token in Settings" else "server error", 2);
            self.setStatus("");
            return;
        }
        var idb: [64]u8 = undefined;
        const hex = jStr(resp.body, "id", &idb) orelse "";
        if (hex.len == 0) {
            self.appendMsg(dd, .cast_note, "[cast] deploy answered without an id — check the server log");
            self.setStatus("");
            return;
        }
        self.cast_active = true;
        self.cast_stop_sent = false;
        self.cast_hex_len = @min(hex.len, self.cast_hex.len);
        @memcpy(self.cast_hex[0..self.cast_hex_len], hex[0..self.cast_hex_len]);
        self.cast_rel_len = 0;
        self.cast_deadline_s = self.nowS() + @as(i64, CAST_MINUTES) * 60 + 120;
        var gb: [200]u8 = undefined;
        const note = std.fmt.bufPrint(&gb, "[cast] hive deployed ({s}) — watching", .{hex}) catch "[cast] hive deployed";
        self.appendMsg(dd, .cast_note, note);
        // right-pane row
        {
            self.store.lock();
            defer self.store.unlock();
            if (self.store.cast_count >= store_mod.MAX_CASTS) {
                std.mem.copyForwards(store_mod.CastRow, self.store.casts[0 .. store_mod.MAX_CASTS - 1], self.store.casts[1..store_mod.MAX_CASTS]);
                self.store.cast_count = store_mod.MAX_CASTS - 1;
            }
            var row: store_mod.CastRow = .{ .status = .deploying };
            const rn = @min(hex.len, row.run.len);
            @memcpy(row.run[0..rn], hex[0..rn]);
            row.run_len = @intCast(rn);
            const gn = @min(goal.len, row.goal.len);
            @memcpy(row.goal[0..gn], goal[0..gn]);
            row.goal_len = @intCast(gn);
            self.store.casts[self.store.cast_count] = row;
            self.store.cast_count += 1;
        }
        self.store.pushNotif("Hive cast", goal, 1);
        log.info("chat cast: id={s} goal={s}", .{ hex, goal[0..@min(goal.len, 80)] });
    }

    pub fn watchCast(self: *Chat, dd: []const u8) void {
        if (!self.cast_active) return;
        const now = self.nowS();
        // resolve the run dir once the scanner can see it (server writes u<uid>/<hex>)
        if (self.cast_rel_len == 0) {
            const n = scan.listSwarms(self.io, self.gpa, dd, &self.sw_scratch, now, 45);
            const hex = self.cast_hex[0..self.cast_hex_len];
            for (self.sw_scratch[0..n]) |*sw| {
                const id = sw.idStr();
                const base = if (std.mem.lastIndexOfScalar(u8, id, '/')) |sl| id[sl + 1 ..] else id;
                if (std.mem.eql(u8, base, hex)) {
                    self.cast_rel_len = @min(id.len, self.cast_rel.len);
                    @memcpy(self.cast_rel[0..self.cast_rel_len], id[0..self.cast_rel_len]);
                    self.updateCastRow(.running, 0, -1, "", id);
                    break;
                }
            }
            if (self.cast_rel_len == 0) {
                if (now > self.cast_deadline_s) self.failCast(dd, "[cast] the run directory never appeared — check the server");
                return;
            }
        }
        const rel = self.cast_rel[0..self.cast_rel_len];
        var m: scan.Metrics = .{};
        var ep_buf: [700]u8 = undefined;
        const ep = std.fmt.bufPrint(&ep_buf, "{s}/{s}/events.jsonl", .{ dd, rel }) catch return;
        const ev_n = scan.tailEvents(self.io, self.gpa, ep, &self.ev_scratch, &m);
        // publish tail + row
        {
            self.store.lock();
            defer self.store.unlock();
            @memcpy(self.store.cast_tail[0..ev_n], self.ev_scratch[0..ev_n]);
            self.store.cast_tail_count = ev_n;
        }
        var last: []const u8 = "";
        if (ev_n > 0) last = self.ev_scratch[ev_n - 1].textStr();
        self.updateCastRow(if (m.stopped) .done else .running, m.round, m.pct, last, rel);
        if (!m.stopped) {
            var sbuf: [96]u8 = undefined;
            const st = std.fmt.bufPrint(&sbuf, "hive running - r{d} {d}%", .{ m.round, if (m.pct < 0) 0 else m.pct }) catch "hive running";
            self.setStatus(st);
        }

        if (m.stopped) {
            // a user turn may still be streaming — keep cast_active and collect on a later tick
            if (self.turn == .idle) self.collectCast(dd, rel, &m, ev_n);
            return;
        }
        if (now > self.cast_deadline_s) {
            if (!self.cast_stop_sent) {
                _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}");
                self.cast_stop_sent = true;
                self.cast_deadline_s = now + 90; // grace for the round boundary
                self.updateCastRow(.collecting, m.round, m.pct, last, rel);
                self.setStatus("asking the hive to stop...");
            } else if (self.turn == .idle) {
                // it never stopped cleanly — collect what exists
                self.collectCast(dd, rel, &m, ev_n);
            }
        }
    }

    fn failCast(self: *Chat, dd: []const u8, msg: []const u8) void {
        self.appendMsg(dd, .cast_note, msg);
        self.updateCastRow(.failed, 0, -1, "", self.cast_hex[0..self.cast_hex_len]);
        self.cast_active = false;
        self.setStatus("");
    }

    /// Fold the finished cast into the conversation as a [cast] findings digest, then ask the model to
    /// answer from it.
    fn collectCast(self: *Chat, dd: []const u8, rel: []const u8, m: *const scan.Metrics, ev_n: usize) void {
        self.cast_active = false;
        self.updateCastRow(.done, m.round, m.pct, "", rel);
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.print(self.gpa, "[cast] finished run {s}: rounds {d}, score {d}% (best {d}%)", .{ rel, m.round, if (m.pct < 0) 0 else m.pct, m.best_pct }) catch return;
        if (m.stop_reason_len > 0) jb.print(self.gpa, ", stopped: {s}", .{m.stop_reason[0..m.stop_reason_len]}) catch {};
        // built files
        const fn_ = scan.listWorkFiles(self.io, self.gpa, dd, rel, &self.file_scratch);
        if (fn_ > 0) {
            jb.appendSlice(self.gpa, "\nfiles built:") catch {};
            var i: usize = 0;
            while (i < @min(fn_, 20)) : (i += 1) {
                jb.print(self.gpa, " {s}({d}b)", .{ self.file_scratch[i].pathStr(), self.file_scratch[i].size }) catch {};
            }
        }
        // the tail of what the hive said/did
        if (ev_n > 0) {
            jb.appendSlice(self.gpa, "\nrecent hive activity:") catch {};
            const start = if (ev_n > 14) ev_n - 14 else 0;
            var i = start;
            while (i < ev_n) : (i += 1) {
                const e = &self.ev_scratch[i];
                jb.print(self.gpa, "\n- {s} {s}: {s}", .{ e.kindStr(), e.mindStr(), e.textStr() }) catch {};
            }
        }
        const digest = jb.items[0..@min(jb.items.len, 3000)];
        self.appendMsg(dd, .cast_note, digest);
        self.setStatus("composing the answer...");
        self.startTurn(dd, .collect);
    }

    fn updateCastRow(self: *Chat, status: store_mod.CastStatus, round: i64, pct: i32, last: []const u8, run_id: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        if (self.store.cast_count == 0) return;
        // the newest row is this thread's active cast
        const row = &self.store.casts[self.store.cast_count - 1];
        row.status = status;
        row.round = round;
        row.pct = pct;
        if (run_id.len > 0) {
            const rn = @min(run_id.len, row.run.len);
            @memcpy(row.run[0..rn], run_id[0..rn]);
            row.run_len = @intCast(rn);
        }
        if (last.len > 0) {
            const ln = @min(last.len, row.last.len);
            @memcpy(row.last[0..ln], last[0..ln]);
            row.last_len = @intCast(ln);
        }
    }
};

// ------------------------------------------------------------------------------ pure helpers (tested)

/// If a "CAST: goal" line appears within the reply's first few substantive lines, return the goal.
/// Tolerant on purpose: reasoning models often put a short preamble ("Sure — this needs the hive.")
/// above the tag even when told to lead with it.
pub fn castGoal(full: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, full, '\n');
    var seen: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "CAST:")) {
            const g = std.mem.trim(u8, line[5..], " \r\t");
            return if (g.len > 0) g else null;
        }
        seen += 1;
        if (seen >= 5) return null; // a CAST mention deep in prose is narration, not an action
    }
    return null;
}

/// The reply minus its CAST line — the note shown to the user beside the cast.
pub fn noteWithoutCast(full: []const u8, buf: []u8) []const u8 {
    var w: usize = 0;
    var removed = false;
    var it = std.mem.splitScalar(u8, full, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!removed and std.mem.startsWith(u8, line, "CAST:")) {
            removed = true;
            continue;
        }
        if (w + raw.len + 1 > buf.len) break;
        if (w > 0) {
            buf[w] = '\n';
            w += 1;
        }
        @memcpy(buf[w .. w + raw.len], raw);
        w += raw.len;
    }
    return std.mem.trim(u8, buf[0..w], " \r\n\t");
}

fn escJson(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => list.appendSlice(gpa, "\\\"") catch {},
            '\\' => list.appendSlice(gpa, "\\\\") catch {},
            '\n' => list.appendSlice(gpa, "\\n") catch {},
            '\r' => {},
            '\t' => list.appendSlice(gpa, "\\t") catch {},
            else => {
                if (c < 0x20) list.appendSlice(gpa, " ") catch {} else list.append(gpa, c) catch {};
            },
        }
    }
}

fn wesc(w: *Io.Writer, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => {},
            '\t' => w.writeAll(" ") catch {},
            else => {
                if (c < 0x20) w.writeAll(" ") catch {} else w.writeByte(c) catch {};
            },
        }
    }
}

fn jInt(line: []const u8, key: []const u8) ?i64 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = at + needle.len;
    while (i < line.len and line[i] == ' ') i += 1;
    var neg = false;
    if (i < line.len and line[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

var jstr_buf: [64]u8 = undefined;
fn jStr(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    _ = out;
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and body[i] == ' ') i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < body.len and body[i] != '"' and w < jstr_buf.len) : (i += 1) {
        jstr_buf[w] = body[i];
        w += 1;
    }
    return jstr_buf[0..w];
}

// ------------------------------------------------------------------------------ tests

test "first message auto-titles the conversation (both the type-first and +-first flows)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-title-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    // dead endpoint so startTurn's curl goes nowhere — the title path is what's under test
    const base = "http://127.0.0.1:1/v1";
    @memcpy(store.settings.chat_base[0..base.len], base);
    store.settings.chat_base_len = base.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    // flow 1: user types first (no conversation yet)
    chat.cmdSend(dd, "hello there veil, how are you?");
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
    chat.turn = .idle;
    var found_title = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.conv_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.convs[i].titleStr(), "hello there veil")) found_title = true;
        }
    }
    try std.testing.expect(found_title);

    // flow 2: user clicks + first, then sends
    chat.cmdNewConv(dd);
    chat.cmdSend(dd, "second conversation opener");
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
    chat.turn = .idle;
    var found2 = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.conv_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.convs[i].titleStr(), "second conversation")) found2 = true;
        }
    }
    try std.testing.expect(found2);
}

test "cast watch resolves the run dir, tails it, and collects on stop (no server needed)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/u1/cafe01/work", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe01/events.jsonl", .data = "{\"seq\":1,\"kind\":\"act\",\"round\":1,\"mind\":\"nova\",\"tool\":\"observe\",\"result\":\"looked around\"}\n" ++
        "{\"seq\":2,\"kind\":\"score\",\"round\":2,\"passed\":2,\"total\":3,\"pct\":66}\n" ++
        "{\"seq\":3,\"kind\":\"stopped\",\"reason\":\"complete\"}\n" }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe01/swarm.json", .data = "{\"swarm\":\"chat-test\"}" }) catch unreachable;

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    {
        const d = dd;
        @memcpy(store.settings.data_dir[0..d.len], d);
        store.settings.data_dir_len = d.len;
    }
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    // an active conversation to receive the [cast] digest
    chat.cmdNewConv(dd);
    // pretend a cast was fired: hex known, rel not yet resolved, one right-pane row
    chat.cast_active = true;
    const hex = "cafe01";
    @memcpy(chat.cast_hex[0..hex.len], hex);
    chat.cast_hex_len = hex.len;
    chat.cast_deadline_s = chat.nowS() + 600;
    store.casts[0] = .{ .status = .deploying };
    store.cast_count = 1;

    chat.watchCast(dd); // resolves u1/cafe01 and sees `stopped` → collect fires a model turn
    try std.testing.expect(!chat.cast_active);
    try std.testing.expectEqualStrings("u1/cafe01", chat.cast_rel[0..chat.cast_rel_len]);
    try std.testing.expect(store.casts[0].status == .done);
    try std.testing.expect(store.cast_tail_count >= 2);
    // the digest message landed in the conversation
    var found = false;
    var i: usize = 0;
    while (i < store.msg_count) : (i += 1) {
        if (store.msgs[i].role == .cast_note and std.mem.indexOf(u8, store.msgs[i].textStr(), "score 66%") != null) found = true;
    }
    try std.testing.expect(found);
    // the collect turn started a model call (against the default local endpoint) — abort it either way
    try std.testing.expect(chat.turn == .collect or chat.turn == .idle);
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
}

test "LIVE chat turn: streams a real reply from local Ollama (best-effort, skips if down)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    if (!scan.serverOnline(io, 11434)) {
        std.debug.print("\n[chat live test] no Ollama on :11434 — skipping\n", .{});
        return;
    }
    const dd = "zig-chat-live-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    const model = "llama3.1:8b"; // small = fast; this is a plumbing test, not a quality test
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    chat.cmdSend(dd, "Reply with exactly one short sentence: what is the capital of France?");
    try std.testing.expect(chat.turn == .user);
    var waited: usize = 0;
    while (chat.turn != .idle and waited < 1800) : (waited += 1) { // up to ~3min for a cold model
        chat.pumpStream(dd);
        io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(chat.turn == .idle);
    // last message is the veil's reply and it is non-empty, non-error
    try std.testing.expect(store.msg_count >= 2);
    const last = &store.msgs[store.msg_count - 1];
    std.debug.print("[chat live test] veil replied ({d}b): {s}\n", .{ last.text_len, last.textStr()[0..@min(last.text_len, 120)] });
    try std.testing.expect(last.role == .veil);
    try std.testing.expect(last.text_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, last.textStr(), "(model error") == null);
    // and it persisted: the conversation file holds both messages
    var pb: [700]u8 = undefined;
    var idb: [32]u8 = undefined;
    const idn: usize = store.conv_active_len;
    @memcpy(idb[0..idn], store.conv_active[0..idn]);
    const path = Chat.convPath(dd, idb[0..idn], &pb).?;
    const data = Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(1 << 20)) catch unreachable;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "capital of France") != null);
}

test "castGoal fires on a CAST line within the first few lines" {
    try std.testing.expectEqualStrings("map the auth flow", castGoal("CAST: map the auth flow\nOn it.").?);
    try std.testing.expectEqualStrings("x", castGoal("\n  CAST: x").?);
    // tolerant: a short preamble above the tag still casts
    try std.testing.expectEqualStrings("dig into the repo", castGoal("This needs real work.\nCAST: dig into the repo").?);
    try std.testing.expect(castGoal("hello there") == null);
    try std.testing.expect(castGoal("CAST:") == null);
    // a CAST buried deep in prose is narration
    try std.testing.expect(castGoal("a\nb\nc\nd\ne\nf\nCAST: too deep") == null);
}

test "noteWithoutCast drops exactly the tag line" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("On it - casting the hive.", noteWithoutCast("CAST: goal\nOn it - casting the hive.", &b));
    try std.testing.expectEqualStrings("", noteWithoutCast("CAST: goal", &b));
    try std.testing.expectEqualStrings("Preamble.\nAfter.", noteWithoutCast("Preamble.\nCAST: goal\nAfter.", &b));
}

test "jStr and jInt read the deploy response" {
    var b: [64]u8 = undefined;
    const body = "{\"ok\":true,\"id\":\"a1b2c3d4e5f60708\",\"state\":\"running\",\"minds\":3}";
    try std.testing.expectEqualStrings("a1b2c3d4e5f60708", jStr(body, "id", &b).?);
    try std.testing.expectEqual(@as(i64, 3), jInt(body, "minds").?);
}
