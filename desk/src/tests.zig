//! Test root for `zig build test` (desk). Zig only collects `test` blocks from files the test root
//! references, so every test-bearing desk file is listed here explicitly — tests in a file that is not
//! on this list never run.

test {
    // Registered EXPLICITLY even though theme.zig imports it: Zig collects tests only from imports it
    // ANALYZES, and nothing in a test build reaches theme's icon paths, so that import never pulls
    // assets in. Its tests were silently not running. Textual reachability is not collection.
    _ = @import("assets.zig");
    _ = @import("catalog.zig");
    _ = @import("chat.zig");
    _ = @import("gitvc.zig");
    _ = @import("httpc.zig");
    _ = @import("llm.zig");
    _ = @import("log.zig");
    _ = @import("mdutil.zig");
    _ = @import("netcli.zig");
    _ = @import("poller.zig"); // the server-reply parsers: user text can't imitate a field
    _ = @import("runner.zig"); // vtable dispatch fidelity: every verb reaches its own slot
    _ = @import("neuron.zig");
    _ = @import("scan.zig");
    _ = @import("secrets.zig");
    _ = @import("store.zig");
    _ = @import("theme.zig");
}
