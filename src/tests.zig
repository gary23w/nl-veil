//! Test root for `zig build test`. Zig only collects `test` blocks from files the test root references, so
//! every test-bearing file in src/ is listed here explicitly — a new module's tests do NOT run in CI until
//! it is added to this list.

test {
    _ = @import("auth/auth_core.zig"); // tool_grants persistence + the admin-email predicate
    _ = @import("cli.zig");
    _ = @import("config/cf_oauth.zig");
    _ = @import("config/server_config.zig");
    _ = @import("config/lan.zig");
    _ = @import("worker/agi.zig");
    _ = @import("worker/hashline.zig"); // hash-anchored atomic line edits (tag dialect of edit_file)
    _ = @import("worker/browser/manager.zig");
    _ = @import("worker/bufedit.zig");
    _ = @import("worker/chat/context.zig");
    _ = @import("worker/chat/engine.zig");
    _ = @import("worker/chat/paths.zig");
    _ = @import("worker/chat/plan.zig");
    _ = @import("worker/chat/service.zig");
    _ = @import("worker/chat/sync.zig");
    _ = @import("worker/chat/toolperf.zig");
    _ = @import("worker/chat/trio_routing_test.zig"); // label->role routing guard (reads engine.zig as source)
    _ = @import("worker/control/supervisor.zig");
    _ = @import("worker/crawl.zig");
    _ = @import("worker/httpc.zig");
    _ = @import("worker/hyperspace.zig");
    _ = @import("worker/llm.zig");
    _ = @import("worker/locs/atlas.zig");
    _ = @import("worker/mcp/discovery.zig");
    _ = @import("worker/metrics.zig");
    _ = @import("modelcfg"); // its own module now (see build.zig); a path import would double-own the file
    _ = @import("worker/oscillation.zig");
    _ = @import("worker/ragmirror.zig"); // local knowledge-pack mirror: url→disk resolve + atlas extension
    _ = @import("worker/rate.zig");
    _ = @import("worker/recipes.zig"); // parse/substitute/validate — the granted-recipe trust boundary
    _ = @import("worker/rerank.zig");
    _ = @import("worker/rsi.zig");
    _ = @import("worker/run.zig");
    _ = @import("worker/sched.zig");
    _ = @import("worker/toolchain.zig"); // dependency bootstrap + manifest-derived acceptance rows
    _ = @import("worker/tools.zig");
    _ = @import("worker/vcs.zig");
}
