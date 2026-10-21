//! Small on-disk usage sample shared by the worker and its supervisor.
const std = @import("std");

pub const Sample = struct { run_id: []const u8 = "", neurons: u64 };

pub fn parse(data: []const u8) !Sample {
    const s = std.mem.trim(u8, data, " \r\n\t");
    if (std.mem.startsWith(u8, s, "v1 ")) {
        var fields = std.mem.tokenizeScalar(u8, s, ' ');
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidUsageRecord, "v1")) return error.InvalidUsageRecord;
        const id = fields.next() orelse return error.InvalidUsageRecord;
        const value = fields.next() orelse return error.InvalidUsageRecord;
        if (fields.next() != null or id.len != 17) return error.InvalidUsageRecord;
        return .{ .run_id = id, .neurons = std.fmt.parseInt(u64, value, 10) catch return error.InvalidUsageRecord };
    }
    return .{ .neurons = std.fmt.parseInt(u64, s, 10) catch return error.InvalidUsageRecord };
}

pub fn format(out: *[64]u8, id: []const u8, neurons: u64) ![]const u8 {
    return if (id.len == 0)
        std.fmt.bufPrint(out, "{d}", .{neurons})
    else
        std.fmt.bufPrint(out, "v1 {s} {d}", .{ id, neurons });
}

pub fn baseForRun(data: ?[]const u8, id: []const u8) !u64 {
    const sample = try parse(data orelse return 0);
    return if (std.mem.eql(u8, sample.run_id, id)) sample.neurons else 0;
}

test "usage samples keep legacy numbers readable and bind new samples to a run" {
    try std.testing.expectEqual(@as(u64, 123), (try parse("123\n")).neurons);
    var buf: [64]u8 = undefined;
    const text = try format(&buf, "r0123456789abcdef", 456);
    const sample = try parse(text);
    try std.testing.expectEqualStrings("r0123456789abcdef", sample.run_id);
    try std.testing.expectEqual(@as(u64, 456), sample.neurons);
    try std.testing.expectError(error.InvalidUsageRecord, parse("v1 r0123456789abcdef nope"));
    try std.testing.expectEqual(@as(u64, 456), try baseForRun(text, "r0123456789abcdef"));
    try std.testing.expectEqual(@as(u64, 0), try baseForRun(text, "r1111111111111111"));
    try std.testing.expectEqual(@as(u64, 123), try baseForRun("123", ""));
    try std.testing.expectEqual(@as(u64, 0), try baseForRun(null, "r0123456789abcdef"));
}
