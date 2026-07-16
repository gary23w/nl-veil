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
const util = @import("util.zig");
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
        // Clear the navigator.webdriver automation fingerprint at PARSE time (before any page script), so the
        // user's own assistive session isn't pre-emptively refused/degraded by a naive webdriver sniff. Persists
        // across navigations (unlike HARDEN_JS, which runs post-load and re-arms per document). Deliberately
        // scoped to this ONE property — this is not, and must not become, CAPTCHA/anti-bot evasion.
        _ = cdp.call("Page.addScriptToEvaluateOnNewDocument", "{\"source\":\"try{Object.defineProperty(navigator,'webdriver',{get:()=>false});}catch(e){}\"}", sid) catch {};

        var s: Session = .{ .gpa = gpa, .io = io, .child = child, .cdp = cdp, .session_id = sid, .user_data_dir = udd };
        s.harden(); // arm dialog/popup neutralization before the first navigate (see harden()'s note)
        return s;
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
        self.harden(); // re-arm on the freshly loaded document (each navigation is a fresh JS context)
        return self.evalString("location.href") catch self.gpa.dupe(u8, url) catch error.OutOfMemory;
    }

    /// Neutralize the two things that silently break headless click-through: modal JS dialogs and popups. Our
    /// CDP client is request/response and DISCARDS event frames (see cdp.zig), so it never answers
    /// Page.javascriptDialogOpening — a native alert()/confirm()/beforeunload would block the renderer and hang
    /// the next Runtime.evaluate. So we defang them at the JS layer instead: alert/confirm/prompt become
    /// non-blocking, beforeunload can't veto a navigation, and popups (target=_blank / window.open) are coerced
    /// into the SAME tab the session drives — otherwise a click would spawn a tab this single-page session never
    /// sees. Best-effort and idempotent (guarded by __nlHardened); re-run after every navigation.
    pub fn harden(self: *Session) void {
        const r = self.evaluate(HARDEN_JS) catch return;
        self.gpa.free(r);
    }

    fn waitReady(self: *Session, timeout_ms: u32) void {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 250) {
            const st = self.evalString("document.readyState") catch {
                util.sleepMs(250);
                continue;
            };
            defer self.gpa.free(st);
            if (std.mem.eql(u8, st, "complete")) return;
            util.sleepMs(250);
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

    /// Dispatch one Input.dispatchMouseEvent to the page session. Unlike a JS el.click(), these carry
    /// isTrusted:true — real browser-level input that bot-protection and strict event validators accept. Coords
    /// are CSS pixels in the viewport frame (the space getBoundingClientRect reports) — NO devicePixelRatio.
    fn dispatchMouse(self: *Session, kind: []const u8, x: i64, y: i64, button: []const u8, buttons: u8, clicks: u8) Error!void {
        const p = std.fmt.allocPrint(self.gpa, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"buttons\":{d},\"clickCount\":{d},\"pointerType\":\"mouse\"}}", .{ kind, x, y, button, buttons, clicks }) catch return error.OutOfMemory;
        defer self.gpa.free(p);
        const r = self.cdp.callTimeout("Input.dispatchMouseEvent", p, self.session_id, 5_000) catch return error.Protocol;
        self.gpa.free(r);
    }

    /// Dispatch one Input.dispatchKeyEvent (raw params JSON) to the page session — a real, trusted keystroke.
    fn dispatchKey(self: *Session, params_json: []const u8) Error!void {
        const r = self.cdp.callTimeout("Input.dispatchKeyEvent", params_json, self.session_id, 5_000) catch return error.Protocol;
        self.gpa.free(r);
    }

    /// Trusted left click on the element tagged `ref`: scroll it into view, resolve its viewport-center point,
    /// then move → press → dwell → release via the Input domain (isTrusted:true), then SETTLE any navigation so a
    /// following browser_read sees the landing page. Falls back to a synthetic el.click() only when the element
    /// can't be localized in the viewport. Returns {ok,tag,navigated,url}; a missing ref returns
    /// {ok:false,error:'ref not found'} unchanged.
    pub fn clickRef(self: *Session, ref: u32) Error![]u8 {
        const before = self.evalString("location.href") catch (self.gpa.dupe(u8, "") catch return error.OutOfMemory);
        defer self.gpa.free(before);
        const rjs = std.fmt.allocPrint(self.gpa, RESOLVE_CLICK_JS, .{ref}) catch return error.OutOfMemory;
        defer self.gpa.free(rjs);
        const raw = try self.evaluate(rjs);
        const R = struct { ok: bool = false, x: i64 = 0, y: i64 = 0, hit: bool = false, tag: []const u8 = "" };
        const parsed = std.json.parseFromSlice(R, self.gpa, raw, .{ .ignore_unknown_fields = true }) catch return raw;
        if (!parsed.value.ok) {
            parsed.deinit(); // missing ref → the resolve JSON already carries {ok:false,error:'ref not found'}
            return raw;
        }
        const hit = parsed.value.hit;
        const x = parsed.value.x;
        const y = parsed.value.y;
        const tag = self.gpa.dupe(u8, parsed.value.tag) catch {
            parsed.deinit();
            return raw;
        };
        parsed.deinit();
        self.gpa.free(raw);
        defer self.gpa.free(tag);

        if (hit) {
            self.dispatchMouse("mouseMoved", x, y, "none", 0, 0) catch {};
            self.dispatchMouse("mousePressed", x, y, "left", 1, 1) catch {};
            util.sleepMs(40); // a real press→release gap; some UIs debounce a zero-duration press
            self.dispatchMouse("mouseReleased", x, y, "left", 0, 1) catch {};
        } else {
            // Couldn't place an in-viewport click point (element off-screen in a scroll container we couldn't
            // fully center) — fall back to a synthetic click so the action still fires.
            const cjs = std.fmt.allocPrint(self.gpa, "(function(){{var el=document.querySelector('[data-nlref=\"{d}\"]');if(el)el.click();}})()", .{ref}) catch return error.OutOfMemory;
            defer self.gpa.free(cjs);
            const cr = self.evaluate(cjs) catch (self.gpa.dupe(u8, "") catch "");
            if (cr.len > 0) self.gpa.free(cr);
        }

        const navigated = self.settleAfterClick(before);
        if (navigated) self.harden(); // the landing page is a fresh JS context — re-arm before the next click
        const url = self.evalString("location.href") catch (self.gpa.dupe(u8, before) catch return error.OutOfMemory);
        defer self.gpa.free(url);
        return jsonObj(self.gpa, .{ .ok = true, .tag = tag, .navigated = navigated, .url = url }) catch error.OutOfMemory;
    }

    /// After a click, wait briefly for the URL to change (a navigation) and, if it does, for the new document to
    /// finish loading. A pure in-page click (button, JS handler) never changes the URL, so this returns false
    /// after the short grace window without over-waiting. Returns true iff a navigation occurred.
    fn settleAfterClick(self: *Session, before: []const u8) bool {
        var waited: u32 = 0;
        while (waited < 1500) : (waited += 100) {
            util.sleepMs(100);
            const cur = self.evalString("location.href") catch continue;
            defer self.gpa.free(cur);
            if (!std.mem.eql(u8, cur, before)) {
                self.waitReady(8000);
                return true;
            }
        }
        return false;
    }

    /// Type `text` into the element tagged `ref` using TRUSTED input: focus + clear the field, place the caret
    /// with a real click, then Input.insertText (isTrusted:true, unicode-safe, fast — the right choice for an
    /// assistive agent). When `submit` is set, a real Enter key event is dispatched (native form submission) and
    /// the resulting navigation is settled. Returns {ok,tag} or {ok,tag,navigated,url}; a missing ref returns
    /// {ok:false,error:'ref not found'} unchanged.
    pub fn typeRef(self: *Session, ref: u32, text: []const u8, submit: bool) Error![]u8 {
        const before = if (submit) (self.evalString("location.href") catch (self.gpa.dupe(u8, "") catch return error.OutOfMemory)) else "";
        defer if (submit) self.gpa.free(before);

        const rjs = std.fmt.allocPrint(self.gpa, RESOLVE_TYPE_JS, .{ref}) catch return error.OutOfMemory;
        defer self.gpa.free(rjs);
        const raw = try self.evaluate(rjs);
        const R = struct { ok: bool = false, x: i64 = 0, y: i64 = 0, hit: bool = false, tag: []const u8 = "" };
        const parsed = std.json.parseFromSlice(R, self.gpa, raw, .{ .ignore_unknown_fields = true }) catch return raw;
        if (!parsed.value.ok) {
            parsed.deinit();
            return raw;
        }
        const hit = parsed.value.hit;
        const x = parsed.value.x;
        const y = parsed.value.y;
        const tag = self.gpa.dupe(u8, parsed.value.tag) catch {
            parsed.deinit();
            return raw;
        };
        parsed.deinit();
        self.gpa.free(raw);
        defer self.gpa.free(tag);

        // A genuine click places the caret — contenteditable / rich editors (search boxes, chat inputs) accept
        // insertText only after a real pointer focus. RESOLVE_TYPE_JS already focused + cleared the field.
        if (hit) {
            self.dispatchMouse("mouseMoved", x, y, "none", 0, 0) catch {};
            self.dispatchMouse("mousePressed", x, y, "left", 1, 1) catch {};
            util.sleepMs(30);
            self.dispatchMouse("mouseReleased", x, y, "left", 0, 1) catch {};
        }
        if (text.len > 0) {
            const tp = jsonObj(self.gpa, .{ .text = text }) catch return error.OutOfMemory; // {"text":"..."} escaped
            defer self.gpa.free(tp);
            const ir = self.cdp.callTimeout("Input.insertText", tp, self.session_id, 10_000) catch return error.Protocol;
            self.gpa.free(ir);
        }
        if (submit) {
            self.dispatchKey("{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13,\"text\":\"\\r\"}") catch {};
            util.sleepMs(20);
            self.dispatchKey("{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}") catch {};
        }

        if (!submit) return jsonObj(self.gpa, .{ .ok = true, .tag = tag }) catch error.OutOfMemory;
        const navigated = self.settleAfterClick(before);
        if (navigated) self.harden();
        const url = self.evalString("location.href") catch (self.gpa.dupe(u8, before) catch return error.OutOfMemory);
        defer self.gpa.free(url);
        return jsonObj(self.gpa, .{ .ok = true, .tag = tag, .navigated = navigated, .url = url }) catch error.OutOfMemory;
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

// Resolve a data-nlref element to a viewport-center click point for trusted Input.dispatchMouseEvent. Scrolls
// it into view FIRST (scrollIntoView updates layout synchronously, so the getBoundingClientRect on the next
// line already reflects the scroll), clamps the point into the viewport, and reports whether the box actually
// intersects it (`hit`) so the caller can fall back to a synthetic click when it can't be localized. Used via
// allocPrint with the ref, so `{{`/`}}` are literal braces and `{d}` is the ref.
const RESOLVE_CLICK_JS =
    \\(function(){{var el=document.querySelector('[data-nlref="{d}"]');if(!el)return JSON.stringify({{ok:false,error:'ref not found'}});try{{if(el.tagName==='A'&&el.target&&el.target!=='_self')el.target='_self';}}catch(e){{}}el.scrollIntoView({{block:'center',inline:'center'}});var r=el.getBoundingClientRect();var vw=window.innerWidth||1,vh=window.innerHeight||1;var x=Math.min(Math.max(r.left+r.width/2,1),vw-1);var y=Math.min(Math.max(r.top+r.height/2,1),vh-1);var _tp=document.elementFromPoint(x,y);var hit=(r.width>0&&r.height>0&&r.bottom>0&&r.top<vh&&r.right>0&&r.left<vw&&!!_tp&&(_tp===el||el.contains(_tp)));return JSON.stringify({{ok:true,x:Math.round(x),y:Math.round(y),hit:hit,tag:el.tagName.toLowerCase()}});}})()
;

// Like RESOLVE_CLICK_JS but for typing: also focuses the element and clears any existing value (so insertText
// replaces rather than appends). Returns the same {ok,x,y,hit,tag} shape.
const RESOLVE_TYPE_JS =
    \\(function(){{var el=document.querySelector('[data-nlref="{d}"]');if(!el)return JSON.stringify({{ok:false,error:'ref not found'}});el.scrollIntoView({{block:'center',inline:'center'}});try{{el.focus();}}catch(e){{}}try{{if('value' in el)el.value='';}}catch(e){{}}var r=el.getBoundingClientRect();var vw=window.innerWidth||1,vh=window.innerHeight||1;var x=Math.min(Math.max(r.left+r.width/2,1),vw-1);var y=Math.min(Math.max(r.top+r.height/2,1),vh-1);var _tp=document.elementFromPoint(x,y);var hit=(r.width>0&&r.height>0&&r.bottom>0&&r.top<vh&&r.right>0&&r.left<vw&&!!_tp&&(_tp===el||el.contains(_tp)));return JSON.stringify({{ok:true,x:Math.round(x),y:Math.round(y),hit:hit,tag:el.tagName.toLowerCase()}});}})()
;

// Injected after every navigation (and at open). Makes headless click-through robust: modal dialogs become
// non-blocking (our CDP client can't answer them), beforeunload can't veto a navigation, and popups are kept
// in the driven tab. Idempotent per document via __nlHardened.
const HARDEN_JS =
    \\(function(){if(window.__nlHardened)return 'already';window.__nlHardened=true;try{window.alert=function(){};}catch(e){}try{window.confirm=function(){return true;};}catch(e){}try{window.prompt=function(){return null;};}catch(e){}try{window.print=function(){};}catch(e){}try{window.open=function(u){try{if(u)location.href=u;}catch(e){}return null;};}catch(e){}try{document.addEventListener('click',function(e){try{var a=e.target&&e.target.closest?e.target.closest('a[target]'):null;if(a&&a.target&&a.target!=='_self')a.target='_self';}catch(_){}} ,true);}catch(e){}try{window.onbeforeunload=null;var _ael=window.addEventListener;window.addEventListener=function(t,f,o){try{if(String(t).toLowerCase()==='beforeunload')return;}catch(e){}return _ael.call(window,t,f,o);};}catch(e){}return 'ok';})()
;

// Snapshot the interactive elements (tagged data-nlref) + page text, PLUS the decision signals manager.read
// uses in one round-trip: textLen (full pre-clip innerText length — the clipped `text` can't signal "thin"),
// visualScore (largest canvas/svg/video as a fraction of the viewport → canvas/SPA pages), and challenge
// (CAPTCHA / human-verification). STRONG (suppresses the read → human handoff) is anchored to a Cloudflare
// interstitial NODE, or a challenge WIDGET (turnstile/recaptcha-frame/hcaptcha) on an otherwise-empty page — a
// full-page WALL, NOT a captcha embedded in a content-rich form (which stays readable). This avoids false
// positives from page titles or HTML text merely mentioning a challenge. SUSPECTED is a narrow block-page
// phrase (non-blocking marker). Scope: Cloudflare/Turnstile/reCAPTCHA/hCaptcha; other vendors (AWS WAF,
// DataDome, Akamai, …) aren't fingerprinted — a miss just reads the wall as content, never a false handoff.
const SNAPSHOT_JS =
    \\(function(){var out=[];var i=0;var nodes=document.querySelectorAll('a,button,input,textarea,select,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[onclick]');for(var k=0;k<nodes.length;k++){var el=nodes[k];var r=el.getBoundingClientRect();if(r.width===0&&r.height===0)continue;var st=getComputedStyle(el);if(st.visibility==='hidden'||st.display==='none')continue;i++;el.setAttribute('data-nlref',String(i));var tag=el.tagName.toLowerCase();var label=((el.getAttribute&&el.getAttribute('aria-label'))||el.placeholder||el.value||el.innerText||(el.getAttribute&&el.getAttribute('title'))||'').trim().slice(0,80);out.push({ref:i,tag:tag,type:(el.getAttribute&&el.getAttribute('type'))||'',name:(el.getAttribute&&el.getAttribute('name'))||'',text:label});}var _ft=(document.body?document.body.innerText:'').replace(/\s+/g,' ').trim();var vw=window.innerWidth||1,vh=window.innerHeight||1;var vis=0;var vels=document.querySelectorAll('canvas,svg,video');for(var vi=0;vi<vels.length;vi++){var vr=vels[vi].getBoundingClientRect();var iw=Math.max(0,Math.min(vr.right,vw)-Math.max(vr.left,0));var ih=Math.max(0,Math.min(vr.bottom,vh)-Math.max(vr.top,0));var f=(iw*ih)/(vw*vh);if(f>vis)vis=f;}var chSig=[];var chKind='unknown';var strong=false;var suspected=false;try{var _wq=null;if(document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile'))_wq='turnstile';else if(document.querySelector('iframe[src*="recaptcha/api2/anchor"],iframe[src*="recaptcha/api2/bframe"],iframe[src*="recaptcha/enterprise/anchor"],iframe[src*="recaptcha/enterprise/bframe"]'))_wq='recaptcha';else if(document.querySelector('iframe[src*="hcaptcha.com"],.h-captcha'))_wq='hcaptcha';if(document.querySelector('#challenge-running,#cf-please-wait,#cf-challenge-running,#challenge-stage,#challenge-form,.cf-browser-verification')){strong=true;chKind='cloudflare';chSig.push('cf-interstitial');}if(_wq){chSig.push('widget:'+_wq);if(_ft.length<200){strong=true;if(chKind==='unknown')chKind=_wq;}}}catch(e){}try{if(!strong){var _bt=_ft.slice(0,4000);if(/verify (you are|you'?re) (a )?human/i.test(_bt)||/detected unusual traffic/i.test(_bt)||/enable javascript and cookies to continue/i.test(_bt)){suspected=true;chSig.push('text');}}}catch(e){}var challenge={detected:(strong||suspected),kind:chKind,confidence:(strong?'strong':(suspected?'suspected':'none')),signals:chSig};return JSON.stringify({url:location.href,title:document.title,count:out.length,elements:out,text:_ft.slice(0,4000),textLen:_ft.length,visualScore:Math.round(vis*100)/100,challenge:challenge});})()
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
