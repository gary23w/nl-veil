const std = @import("std");

const Io = std.Io;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    count: u32,
    backlog: u32,
    buffer_size: usize,
};

// ONE SHARED QUEUE, NOT ONE QUEUE PER WORKER - the local patch this vendored copy exists for.
//
// Upstream deals every accepted socket round-robin onto a specific worker's private queue, and a worker only
// ever looks at one designated peer's queue, once, on its way to sleep. In the blocking model a worker runs ONE
// connection at a time for that connection's whole life - a keep-alive client polling every half second pins
// its worker for request_count requests - so the next socket dealt to that worker waited in its queue for the
// life of that connection while the other 127 workers idled. Odd-numbered workers had no peer that could steal
// from them at all (peer = 2i mod n is always even). Measured on the idle server: about one new connection in
// twelve took 12.5-13 s to its first byte, which is request_count (25) polls at 0.5 s. That was the "server
// wedged/slow" the desk logged 2,111 times, the sim driver's stalled turns, and the CLOSE_WAIT sockets left
// behind by clients that gave up.
//
// Here an accepted socket goes onto one queue and the first idle worker takes it. The per-thread buffer is
// still per worker; only the dispatch is shared. The public surface (init/deinit/stop/spawn/spawnOne/flush/
// empty) is unchanged.
pub fn ThreadPool(comptime F: anytype) type {
    const BATCH_SIZE = 16;

    // When the worker thread calls F, it injects its static buffer.
    // So F would be: handle(server: *Server, conn: *Conn, buf: []u8)
    // and FullArgs would be our 3 args....
    const FullArgs = std.meta.ArgsTuple(@TypeOf(F));
    const Args = SpawnArgs(FullArgs);

    return struct {
        stopped: bool,
        threads: []Thread,
        workers: []Worker(F),
        shared: *Shared,
        arena: std.heap.ArenaAllocator,

        // we queue jobs here before batching them to the shared queue, to
        // minimize the amount of locking we need to do (nonblocking path).
        batch: [BATCH_SIZE]Args,
        batch_size: usize,

        const Self = @This();
        const Shared = SharedQueue(Args);

        // we expect allocator to be an Arena
        pub fn init(io: Io, allocator: Allocator, opts: Opts) !Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const aa = arena.allocator();

            const shared = try aa.create(Shared);
            shared.* = .{
                .io = io,
                .queue = try aa.alloc(Args, if (opts.backlog < 2) 2 else opts.backlog),
            };

            const threads = try aa.alloc(Thread, opts.count);
            const workers = try aa.alloc(Worker(F), opts.count);

            var started: usize = 0;
            errdefer {
                shared.stop();
                for (0..started) |i| threads[i].join();
            }

            for (0..workers.len) |i| {
                workers[i] = .{ .shared = shared, .buffer = try aa.alloc(u8, opts.buffer_size) };
            }
            for (0..workers.len) |i| {
                threads[i] = try Thread.spawn(.{}, Worker(F).run, .{&workers[i]});
                started += 1;
            }

            return .{
                .arena = arena,
                .stopped = false,
                .workers = workers,
                .threads = threads,
                .shared = shared,
                .batch = undefined,
                .batch_size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn stop(self: *Self) void {
            if (@atomicRmw(bool, &self.stopped, .Xchg, true, .monotonic) == true) {
                return;
            }
            self.shared.stop();
            for (self.threads) |*thread| {
                thread.join();
            }
        }

        pub fn spawn(self: *Self, args: Args) void {
            var i = self.batch_size;
            self.batch[i] = args;
            i += 1;

            if (i == BATCH_SIZE) {
                self.flush(i);
                i = 0;
            }
            self.batch_size = i;
        }

        pub fn spawnOne(self: *Self, args: Args) void {
            self.shared.push(&.{args});
        }

        pub fn flush(self: *Self, batch_size: usize) void {
            self.batch_size = 0;
            self.shared.push(self.batch[0..batch_size]);
        }

        pub fn empty(self: *Self) bool {
            return self.shared.isEmpty();
        }
    };
}

fn SharedQueue(comptime Args: type) type {
    return struct {
        io: Io,
        queue: []Args,
        head: usize = 0,
        tail: usize = 0,
        stopped: bool = false,
        mutex: Io.Mutex = .init,
        read_cond: Io.Condition = .init,
        write_cond: Io.Condition = .init,

        const Self = @This();

        fn stop(self: *Self) void {
            const io = self.io;
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                self.stopped = true;
            }
            self.read_cond.broadcast(io);
        }

        fn isEmpty(self: *Self) bool {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.head == self.tail;
        }

        /// Queue every item, blocking while the ring is full. Wakes one idle worker PER ITEM: a single
        /// signal would wake one worker for a whole batch and leave the rest queued until it finished.
        fn push(self: *Self, args: []const Args) void {
            const io = self.io;
            var pending = args;
            const queue = self.queue;
            const queue_end = queue.len - 1;

            while (pending.len > 0) {
                self.mutex.lockUncancelable(io);
                var head = self.head;
                var tail = self.tail;
                var capacity: usize = 0;
                while (true) {
                    capacity = if (head < tail) tail - head - 1 else queue_end - head + tail;
                    if (capacity > 0) {
                        break;
                    }
                    self.write_cond.waitUncancelable(io, &self.mutex);
                    head = self.head;
                    tail = self.tail;
                }

                const ready = if (capacity >= pending.len) pending else pending[0..capacity];
                for (ready) |a| {
                    queue[head] = a;
                    head = if (head == queue_end) 0 else head + 1;
                }
                self.head = head;
                self.mutex.unlock(io);
                for (ready) |_| self.read_cond.signal(io);
                pending = pending[ready.len..];
            }
        }

        /// The next item, blocking until one arrives; null once stopped and drained.
        fn pop(self: *Self) ?Args {
            const io = self.io;
            const queue = self.queue;
            const queue_end = queue.len - 1;

            self.mutex.lockUncancelable(io);
            while (self.tail == self.head) {
                if (self.stopped) {
                    self.mutex.unlock(io);
                    return null;
                }
                self.read_cond.waitUncancelable(io, &self.mutex);
            }
            const tail = self.tail;
            const args = queue[tail];
            self.tail = if (tail == queue_end) 0 else tail + 1;
            self.mutex.unlock(io);
            self.write_cond.signal(io);
            return args;
        }
    };
}

fn Worker(comptime F: anytype) type {
    const FullArgs = std.meta.ArgsTuple(@TypeOf(F));
    const Args = SpawnArgs(FullArgs);

    return struct {
        shared: *SharedQueue(Args),
        // A re-usable buffer per thread is the most efficient way to do any dynamic allocation;
        // it stays per worker even though the dispatch is shared.
        buffer: []u8,

        const Self = @This();

        fn run(self: *Self) void {
            const buffer = self.buffer;
            while (self.shared.pop()) |args| {
                // convert Args to FullArgs, i.e. inject buffer as the last argument
                var full_args: FullArgs = undefined;
                const ARG_COUNT = std.meta.fields(FullArgs).len - 1;
                full_args[ARG_COUNT] = buffer;
                inline for (0..ARG_COUNT) |i| {
                    full_args[i] = args[i];
                }
                @call(.auto, F, full_args);
            }
        }
    };
}

fn SpawnArgs(FullArgs: anytype) type {
    const full_fields = std.meta.fields(FullArgs);
    const ARG_COUNT = full_fields.len - 1;

    // Args will be FullArgs[0..len-1], so in the above example, args would be
    // (*Server, *Conn)
    // Args is what we expect the caller to pass to spawn. The worker thread
    // will convert an Args into FullArgs by injecting its static buffer as
    // the final argument.

    // TODO: We could verify that the last argument to FullArgs is, in fact, a
    // []u8. But this ThreadPool is private and being used for 2 specific cases
    // that we control.

    var field_types: [ARG_COUNT]type = undefined;
    inline for (full_fields[0..ARG_COUNT], 0..) |field, i| {
        field_types[i] = field.type;
    }
    return @Tuple(&field_types);
}

const t = @import("t.zig");
test "ThreadPool: batch add" {
    defer t.reset();

    const counts = [_]u32{ 1, 2, 3, 4, 5, 6 };
    const backlogs = [_]u32{ 1, 2, 3, 4, 5, 6 };
    for (counts) |count| {
        for (backlogs) |backlog| {
            testSum = 0; // global defined near the end of this file
            testCount = 0; // global defined near the end of this file
            testC1 = 0;
            testC2 = 0;
            testC3 = 0;
            testC4 = 0;
            testC5 = 0;
            testC6 = 0;
            var tp = try ThreadPool(testIncr).init(t.io, t.arena.allocator(), .{ .count = count, .backlog = backlog, .buffer_size = 512 });
            defer tp.deinit();

            for (0..1_000) |_| {
                tp.spawn(.{1});
                tp.spawn(.{2});
                tp.spawn(.{3});
                tp.spawn(.{4});
            }
            while (tp.empty() == false) {
                try t.io.sleep(.fromMilliseconds(1), .awake);
            }
            tp.stop();
            try t.expectEqual(10_000, testSum);
            try t.expectEqual(4_000, testCount);

            try t.expectEqual(1000, testC1);
            try t.expectEqual(1000, testC2);
            try t.expectEqual(1000, testC3);
            try t.expectEqual(1000, testC4);
            try t.expectEqual(0, testC5);
            try t.expectEqual(0, testC6);
        }
    }
}

test "ThreadPool: small fuzz" {
    defer t.reset();

    testSum = 0; // global defined near the end of this file
    testCount = 0; // global defined near the end of this file
    testC1 = 0;
    testC2 = 0;
    testC3 = 0;
    testC4 = 0;
    testC5 = 0;
    testC6 = 0;
    var tp = try ThreadPool(testIncr).init(t.io, t.arena.allocator(), .{ .count = 3, .backlog = 3, .buffer_size = 512 });
    defer tp.deinit();

    for (0..10_000) |_| {
        tp.spawn(.{1});
        tp.spawn(.{2});
        tp.spawn(.{3});
    }
    while (tp.empty() == false) {
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    tp.stop();
    try t.expectEqual(60_000, testSum);
    try t.expectEqual(30_000, testCount);
    try t.expectEqual(10_000, testC1);
    try t.expectEqual(10_000, testC2);
    try t.expectEqual(10_000, testC3);
    try t.expectEqual(0, testC4);
    try t.expectEqual(0, testC5);
    try t.expectEqual(0, testC6);
}

test "ThreadPool: large fuzz" {
    defer t.reset();

    testSum = 0; // global defined near the end of this file
    testCount = 0; // global defined near the end of this file
    testC1 = 0;
    testC2 = 0;
    testC3 = 0;
    testC4 = 0;
    testC5 = 0;
    testC6 = 0;
    var tp = try ThreadPool(testIncr).init(t.io, t.arena.allocator(), .{ .count = 50, .backlog = 1000, .buffer_size = 512 });
    defer tp.deinit();

    for (0..10_000) |_| {
        tp.spawn(.{1});
        tp.spawn(.{2});
        tp.spawn(.{3});
        tp.spawn(.{4});
        tp.spawn(.{5});
        tp.spawn(.{6});
    }
    while (tp.empty() == false) {
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    tp.stop();
    try t.expectEqual(210_000, testSum);
    try t.expectEqual(60_000, testCount);
    try t.expectEqual(10_000, testC1);
    try t.expectEqual(10_000, testC2);
    try t.expectEqual(10_000, testC3);
    try t.expectEqual(10_000, testC4);
    try t.expectEqual(10_000, testC5);
    try t.expectEqual(10_000, testC6);
}

var testSum: u64 = 0;
var testCount: u64 = 0;
var testC1: u64 = 0;
var testC2: u64 = 0;
var testC3: u64 = 0;
var testC4: u64 = 0;
var testC5: u64 = 0;
var testC6: u64 = 0;
fn testIncr(c: u64, buf: []u8) void {
    std.debug.assert(buf.len == 512);
    _ = @atomicRmw(u64, &testSum, .Add, c, .monotonic);
    _ = @atomicRmw(u64, &testCount, .Add, 1, .monotonic);
    switch (c) {
        1 => _ = @atomicRmw(u64, &testC1, .Add, 1, .monotonic),
        2 => _ = @atomicRmw(u64, &testC2, .Add, 1, .monotonic),
        3 => _ = @atomicRmw(u64, &testC3, .Add, 1, .monotonic),
        4 => _ = @atomicRmw(u64, &testC4, .Add, 1, .monotonic),
        5 => _ = @atomicRmw(u64, &testC5, .Add, 1, .monotonic),
        6 => _ = @atomicRmw(u64, &testC6, .Add, 1, .monotonic),
        else => unreachable,
    }
    // let the threadpool queue get backed up
    t.io.sleep(.fromMicroseconds(20), .awake) catch unreachable;
}
