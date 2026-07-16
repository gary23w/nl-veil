//! One headless browser session: process + CDP connection + an attached page, plus the high-level surface
//! everything above uses. Pixel RAG calls screenshotBase64() to tile a page; the RSI browser tools call
//! navigate/snapshot/clickRef/typeRef/evaluate. Build ONE of these per feature-run — see
//! PIXEL_BROWSER_BLUEPRINT.md (the shared-infrastructure flag) — and close() it on teardown.
//!
//! The page is driven at the DOM level (JS via Runtime.evaluate) rather than by synthetic input coordinates:
//! it is simpler and more robust for headless automation, and it gives every interactive element a stable
//! `data-nlref` id that snapshot() returns and clickRef()/typeRef() act on — the same ref model the app's own
//! browser tooling exposes.

const std = @import("std");
const launch = @import("launch.zig");
const cdpm = @import("cdp.zig");
const Cdp = cdpm.Cdp;

const log = std.log.scoped(.browser);

pub const Error = error{
    NoBrowserFound,
    Launch,
    PortTimeout,
    Connect,
    Protocol,
    EvalFailed,
    OutOfMemory,
};

pub const OpenOpts = struct {
    user_data_dir: []const u8, // required; caller owns the string, Session dupes it
    headless: bool = true,
    width: u32 = 1280,
    height: u32 = 2000,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    cdp: Cdp,
    session_id: []u8, // flattened page-target session (gpa-owned)
    user_data_dir: []u8, // gpa-owned copy

    pub fn open(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: OpenOpts) Error!Session {
        const bin = launch.discover(gpa, io, env) catch return error.NoBrowserFound;
        defer gpa.free(bin);

        // Resolve the profile dir to an absolute path: the browser resolves a relative --user-data-dir against
        // ITS cwd while readEndpoint() resolves the port file against OURS, and a mismatch reads as a timeout.
        const udd = if (std.fs.path.isAbsolute(opts.user_data_dir))
            gpa.dupe(u8, opts.user_data_dir) catch return error.OutOfMemory
        else blk: {
            const base = std.process.executableDirPathAlloc(io, gpa) catch return error.OutOfMemory;
            defer gpa.free(base);
            break :blk std.fs.path.join(gpa, &.{ base, opts.user_data_dir }) catch return error.OutOfMemory;
        };
        errdefer gpa.free(udd);

        var child = launch.spawn(gpa, io, bin, udd, .{ .headless = opts.headless, .width = opts.width, .height = opts.height }) catch return error.Launch;
        errdefer child.kill(io);

        const ep = launch.readEndpoint(gpa, io, udd, 20_000) catch return error.PortTimeout;
        defer gpa.free(ep.ws_path);

        var cdp = Cdp.connect(gpa, io, ep.port, ep.ws_path) catch return error.Connect;
        errdefer cdp.deinit();

        // Create a page target and attach to it with flatten:true, so page commands ride this one ws with a
        // sessionId. Then enable the Page/Runtime domains on that session.
        const created = cdp.call("Target.createTarget", "{\"url\":\"about:blank\"}", null) catch return error.Protocol;
        defer gpa.free(created);
        const target_id = getStr(gpa, created, "targetId") orelse return error.Protocol;
        defer gpa.free(target_id);

        const attach_params = std.fmt.allocPrint(gpa, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{target_id}) catch return error.OutOfMemory;
        defer gpa.free(attach_params);
        const attached = cdp.call("Target.attachToTarget", attach_params, null) catch return error.Protocol;
        defer gpa.free(attached);
        const sid = getStr(gpa, attached, "sessionId") orelse return error.Protocol;
        errdefer gpa.free(sid);

        _ = cdp.call("Page.enable", "{}", sid) catch {};
        _ = cdp.call("Runtime.enable", "{}", sid) catch {};

        return .{ .gpa = gpa, .io = io, .child = child, .cdp = cdp, .session_id = sid, .user_data_dir = udd };
    }

    pub fn close(self: *Session) void {
        // Browser.close shuts down the WHOLE browser cleanly — the reliable kill, since headless Edge
        // daemonizes (the process we spawned exits immediately, handing off to detached children that our
        // Child handle no longer refers to). Then tear down the ws and reap the (already-dead) launch handle.
        const bye = self.cdp.call("Browser.close", "{}", null) catch "";
        if (bye.len > 0) self.gpa.free(bye);
        self.cdp.deinit();
        self.child.kill(self.io);
        self.gpa.free(self.session_id);
        self.gpa.free(self.user_data_dir);
    }

    /// Navigate and wait for document.readyState === "complete" (bounded). Returns the final URL.
    pub fn navigate(self: *Session, url: []const u8) Error![]u8 {
        const params = jsonObj(self.gpa, .{ .url = url }) catch return error.OutOfMemory;
        defer self.gpa.free(params);
        const res = self.cdp.callTimeout("Page.navigate", params, self.session_id, 30_000) catch return error.Protocol;
        self.gpa.free(res);
        self.waitReady(20_000);
        return self.evalString("location.href") catch self.gpa.dupe(u8, url) catch error.OutOfMemory;
    }

    fn waitReady(self: *Session, timeout_ms: u32) void {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 250) {
            const st = self.evalString("document.readyState") catch {
                self.io.sleep(.{ .nanoseconds = 250 * std.time.ns_per_ms }, .awake) catch {};
                continue;
            };
            defer self.gpa.free(st);
            if (std.mem.eql(u8, st, "complete")) return;
            self.io.sleep(.{ .nanoseconds = 250 * std.time.ns_per_ms }, .awake) catch {};
        }
    }

    /// Evaluate a JS expression and return its `result.value` as a gpa-owned JSON string. A string value is
    /// returned as its raw bytes (not re-quoted), so a JS expression that itself returns JSON round-trips.
    pub fn evaluate(self: *Session, expr: []const u8) Error![]u8 {
        const params = jsonObj(self.gpa, .{ .expression = expr, .returnByValue = true, .awaitPromise = true }) catch return error.OutOfMemory;
        defer self.gpa.free(params);
        const res = self.cdp.callTimeout("Runtime.evaluate", params, self.session_id, 30_000) catch return error.EvalFailed;
        defer self.gpa.free(res);

        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, res, .{}) catch return error.EvalFailed;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.EvalFailed,
        };
        if (obj.get("exceptionDetails") != null) return error.EvalFailed;
        const result = obj.get("result") orelse return error.EvalFailed;
        const rv = switch (result) {
            .object => |ro| ro.get("value") orelse std.json.Value{ .null = {} },
            else => return error.EvalFailed,
        };
        return switch (rv) {
            .string => |s| self.gpa.dupe(u8, s) catch error.OutOfMemory,
            else => std.json.Stringify.valueAlloc(self.gpa, rv, .{}) catch error.OutOfMemory,
        };
    }

    /// evaluate() for an expression already known to return a string primitive (readyState, location.href).
    fn evalString(self: *Session, expr: []const u8) Error![]u8 {
        return self.evaluate(expr);
    }

    /// Capture the current page as a PNG and return the raw base64 (no `data:` prefix). Caller frees. The
    /// bytes are never decoded server-side — Pixel RAG persists this base64 as-is and hands it to a vision
    /// model verbatim.
    pub fn screenshotBase64(self: *Session) Error![]u8 {
        const res = self.cdp.callTimeout("Page.captureScreenshot", "{\"format\":\"png\",\"captureBeyondViewport\":true}", self.session_id, 30_000) catch return error.Protocol;
        defer self.gpa.free(res);
        return getStr(self.gpa, res, "data") orelse error.Protocol;
    }

    /// Tag every visible interactive element with a `data-nlref` id and return a compact JSON snapshot
    /// {url,title,count,elements:[{ref,tag,type,name,text}]}. clickRef/typeRef act on those ref ids.
    pub fn snapshot(self: *Session) Error![]u8 {
        return self.evaluate(SNAPSHOT_JS);
    }

    /// Full document pixel size {w,h} (for Pixel RAG tiling). Returns a gpa-owned JSON string.
    pub fn pageMetrics(self: *Session) Error![]u8 {
        return self.evaluate("JSON.stringify({w:document.documentElement.scrollWidth,h:Math.max(document.documentElement.scrollHeight,document.body?document.body.scrollHeight:0)})");
    }

    /// Capture a clipped region of the (beyond-viewport) page as a PNG; returns the raw base64. Used to tile a
    /// tall page into fixed-height screenshot tiles without any client-side image decoding.
    pub fn screenshotClipBase64(self: *Session, x: f64, y: f64, wd: f64, ht: f64) Error![]u8 {
        const params = jsonObj(self.gpa, .{
            .format = "png",
            .captureBeyondViewport = true,
            .clip = .{ .x = x, .y = y, .width = wd, .height = ht, .scale = 1 },
        }) catch return error.OutOfMemory;
        defer self.gpa.free(params);
        const res = self.cdp.callTimeout("Page.captureScreenshot", params, self.session_id, 30_000) catch return error.Protocol;
        defer self.gpa.free(res);
        return getStr(self.gpa, res, "data") orelse error.Protocol;
    }

    /// The visible text of leaf elements whose absolute top falls in the document band [y0, y1) — the text that
    /// corresponds to a screenshot tile. Clipped browser-side. Returns a gpa-owned plain string.
    pub fn bandText(self: *Session, y0: i64, y1: i64) Error![]u8 {
        const js = std.fmt.allocPrint(self.gpa,
            \\(function(){{var y0={d},y1={d};var out=[];var els=document.body?document.body.querySelectorAll('*'):[];for(var i=0;i<els.length;i++){{var el=els[i];if(el.children.length>0)continue;var r=el.getBoundingClientRect();var top=r.top+window.scrollY;if(top>=y0&&top<y1){{var t=(el.innerText||el.textContent||'').trim();if(t)out.push(t);}}}}return out.join(' ').replace(/\s+/g,' ').slice(0,3000);}})()
        , .{ y0, y1 }) catch return error.OutOfMemory;
        defer self.gpa.free(js);
        return self.evaluate(js);
    }

    /// Click the element previously tagged `ref` by snapshot(). Returns a small JSON status.
    pub fn clickRef(self: *Session, ref: u32) Error![]u8 {
        const js = std.fmt.allocPrint(self.gpa,
            \\(function(){{var el=document.querySelector('[data-nlref="{d}"]');if(!el)return JSON.stringify({{ok:false,error:'ref not found'}});el.scrollIntoView({{block:'center'}});el.click();return JSON.stringify({{ok:true,tag:el.tagName.toLowerCase()}});}})()
        , .{ref}) catch return error.OutOfMemory;
        defer self.gpa.free(js);
        return self.evaluate(js);
    }

    /// Type `text` into the element tagged `ref` (input/textarea value + input/change events, or a
    /// contenteditable's text). The text is passed as a JSON string literal, so it is not JS-interpolated. When
    /// `submit` is set, an Enter keydown is dispatched and the enclosing form (if any) is submitted afterwards.
    pub fn typeRef(self: *Session, ref: u32, text: []const u8, submit: bool) Error![]u8 {
        const tlit = std.json.Stringify.valueAlloc(self.gpa, text, .{}) catch return error.OutOfMemory;
        defer self.gpa.free(tlit);
        const submit_js = if (submit)
            \\try{el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',keyCode:13,bubbles:true}));if(el.form&&el.form.requestSubmit)el.form.requestSubmit();}catch(e){}
        else
            "";
        const js = std.fmt.allocPrint(self.gpa,
            \\(function(){{var el=document.querySelector('[data-nlref="{d}"]');if(!el)return JSON.stringify({{ok:false,error:'ref not found'}});var v={s};el.focus();if('value' in el){{el.value=v;el.dispatchEvent(new Event('input',{{bubbles:true}}));el.dispatchEvent(new Event('change',{{bubbles:true}}));}}else{{el.textContent=v;el.dispatchEvent(new Event('input',{{bubbles:true}}));}}{s}return JSON.stringify({{ok:true,tag:el.tagName.toLowerCase()}});}})()
        , .{ ref, tlit, submit_js }) catch return error.OutOfMemory;
        defer self.gpa.free(js);
        return self.evaluate(js);
    }
};

/// Build a JSON object string from a struct value (gpa-owned). Field names become keys; strings are escaped.
fn jsonObj(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

/// Extract a top-level string field from a JSON object string as a gpa-owned copy, or null.
fn getStr(gpa: std.mem.Allocator, json: []const u8, key: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| gpa.dupe(u8, s) catch null,
        else => null,
    };
}

const SNAPSHOT_JS =
    \\(function(){var out=[];var i=0;var nodes=document.querySelectorAll('a,button,input,textarea,select,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[onclick]');for(var k=0;k<nodes.length;k++){var el=nodes[k];var r=el.getBoundingClientRect();if(r.width===0&&r.height===0)continue;var st=getComputedStyle(el);if(st.visibility==='hidden'||st.display==='none')continue;i++;el.setAttribute('data-nlref',String(i));var tag=el.tagName.toLowerCase();var label=((el.getAttribute&&el.getAttribute('aria-label'))||el.placeholder||el.value||el.innerText||(el.getAttribute&&el.getAttribute('title'))||'').trim().slice(0,80);out.push({ref:i,tag:tag,type:(el.getAttribute&&el.getAttribute('type'))||'',name:(el.getAttribute&&el.getAttribute('name'))||'',text:label});}var txt=(document.body?document.body.innerText:'').replace(/\s+/g,' ').trim().slice(0,4000);return JSON.stringify({url:location.href,title:document.title,count:out.length,elements:out,text:txt});})()
;

// ---------------------------------------------------------------------------------------------------- smoke

/// End-to-end exercise of the browser layer, driven from `veil browser-smoke <url>`: launch headless, navigate,
/// snapshot the interactive elements, screenshot to browser-smoke.png in the cwd, then close. Prints a summary.
/// This is how the shared layer is verified without adding a browser-spawning unit test to the suite (which is
/// slow and Defender-flaky on this machine).
pub fn smoke(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, url: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    // Absolute profile dir under TEMP so the browser and the port-file reader never disagree on cwd.
    const tmp = env.get("TEMP") orelse env.get("TMP") orelse ".";
    const udd = std.fmt.allocPrint(gpa, "{s}/veil-browser-smoke", .{tmp}) catch {
        w.print("browser-smoke: out of memory\n", .{}) catch {};
        w.flush() catch {};
        std.process.exit(1);
    };
    defer gpa.free(udd);
    var sess = Session.open(gpa, io, env, .{ .user_data_dir = udd }) catch |e| {
        w.print("browser-smoke: open failed: {t}\n", .{e}) catch {};
        w.flush() catch {};
        std.process.exit(1);
    };
    defer sess.close();

    const final_url = sess.navigate(url) catch |e| {
        w.print("browser-smoke: navigate failed: {t}\n", .{e}) catch {};
        w.flush() catch {};
        std.process.exit(1);
    };
    defer gpa.free(final_url);

    const title = sess.evaluate("document.title") catch gpa.dupe(u8, "(no title)") catch "";
    defer if (title.len > 0) gpa.free(title);

    const snap = sess.snapshot() catch gpa.dupe(u8, "{}") catch "";
    defer if (snap.len > 0) gpa.free(snap);

    var shot_len: usize = 0;
    if (sess.screenshotBase64()) |b64| {
        defer gpa.free(b64);
        const Dec = std.base64.standard.Decoder;
        if (Dec.calcSizeForSlice(b64)) |n| {
            if (gpa.alloc(u8, n)) |png| {
                defer gpa.free(png);
                if ((Dec.decode(png, b64) catch null) != null) {
                    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "browser-smoke.png", .data = png }) catch {};
                    shot_len = png.len;
                }
            } else |_| {}
        } else |_| {}
    } else |e| {
        w.print("browser-smoke: screenshot failed: {t}\n", .{e}) catch {};
    }

    w.print(
        \\browser-smoke OK
        \\  url:        {s}
        \\  title:      {s}
        \\  snapshot:   {s}
        \\  screenshot: browser-smoke.png ({d} bytes PNG)
        \\
    , .{ final_url, title, clip(snap, 600), shot_len }) catch {};
    w.flush() catch {};
    std.process.exit(0);
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}
