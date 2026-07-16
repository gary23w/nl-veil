//! Test root for `zig build test` (desk). Zig only collects `test` blocks from files the test root
//! references, so every test-bearing desk file is listed here explicitly — tests in a file that is not
//! on this list never run.

test {
    _ = @import("chat.zig");
    _ = @import("gitvc.zig");
    _ = @import("httpc.zig");
    _ = @import("llm.zig");
    _ = @import("mdutil.zig");
    _ = @import("netcli.zig");
    _ = @import("scan.zig");
    _ = @import("secrets.zig");
    _ = @import("store.zig");
    _ = @import("theme.zig");
}
