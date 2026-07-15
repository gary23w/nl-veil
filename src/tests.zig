//! Test root for `zig build test`. Zig only collects `test` blocks from files the test root references, so
//! every test-bearing file in src/ is listed here explicitly — a new module's tests do NOT run in CI until
//! it is added to this list.

test {
    _ = @import("cli.zig");
    _ = @import("config/cf_oauth.zig");
    _ = @import("worker/agi.zig");
    _ = @import("worker/bufedit.zig");
    _ = @import("worker/chat/context.zig");
    _ = @import("worker/chat/plan.zig");
    _ = @import("worker/control/supervisor.zig");
    _ = @import("worker/crawl.zig");
    _ = @import("worker/httpc.zig");
    _ = @import("worker/hyperspace.zig");
    _ = @import("worker/llm.zig");
    _ = @import("worker/locs/atlas.zig");
    _ = @import("worker/rerank.zig");
    _ = @import("worker/rsi.zig");
    _ = @import("worker/run.zig");
    _ = @import("worker/sched.zig");
    _ = @import("worker/tools.zig");
    _ = @import("worker/vcs.zig");
}
