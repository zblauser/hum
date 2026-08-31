const std = @import("std");
const proc = @import("proc.zig");
const text = @import("text.zig");

pub const Error = error{
    BadResponse,
} || std.mem.Allocator.Error || proc.Error;

pub fn fetch(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, query: []const u8, max: usize) ![][]const u8 {
    if (query.len == 0) return &.{};

    const escaped = try urlEscape(arena, query);
    // ie/oe are not optional: without them the endpoint answers in latin-1
    const url = try std.fmt.allocPrint(
        arena,
        "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&ie=utf-8&oe=utf-8&q={s}",
        .{escaped},
    );

    const resp = try proc.runCapture(gpa, io, &.{ "curl", "-sS", "--max-time", "3", url });
    defer gpa.free(resp);

    const parsed = std.json.parseFromSlice(std.json.Value, arena, resp, .{}) catch return error.BadResponse;
    if (parsed.value != .array or parsed.value.array.items.len < 2) return error.BadResponse;
    const sugs = parsed.value.array.items[1];
    if (sugs != .array) return error.BadResponse;

    var out: std.ArrayList([]const u8) = .empty;
    for (sugs.array.items) |s| {
        if (out.items.len >= max) break;
        if (s != .string) continue;
        try out.append(arena, try text.sanitize(arena, s.string));
    }
    return out.toOwnedSlice(arena);
}

fn urlEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            try buf.append(arena, ch);
        } else {
            var hex: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "%{X:0>2}", .{ch});
            try buf.appendSlice(arena, &hex);
        }
    }
    return buf.toOwnedSlice(arena);
}

const testing = std.testing;

test "urlEscape leaves unreserved chars and percent-encodes the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("aZ0-_.~", try urlEscape(a, "aZ0-_.~"));
    try testing.expectEqualStrings("daft%20punk", try urlEscape(a, "daft punk"));
    try testing.expectEqualStrings("c%2B%2B", try urlEscape(a, "c++"));
    try testing.expectEqualStrings("%26%3D%2F", try urlEscape(a, "&=/"));
}
