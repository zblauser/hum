const std = @import("std");

pub fn sanitize(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len);

    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x20 or b == 0x7f) {
            out.appendAssumeCapacity(' ');
            i += 1;
            continue;
        }
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (cp >= 0x80 and cp <= 0x9f) {
            out.appendAssumeCapacity(' ');
        } else if (isBidiControl(cp)) {} else {
            out.appendSliceAssumeCapacity(s[i .. i + len]);
        }
        i += len;
    }
    return out.toOwnedSlice(arena);
}

fn isBidiControl(cp: u21) bool {
    return (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069);
}

pub fn sanitizeDupe(arena: std.mem.Allocator, s: []const u8) ?[]const u8 {
    return sanitize(arena, s) catch null;
}

const Range = struct { u21, u21 };

const zero_ranges = [_]Range{
    .{ 0x300, 0x36f },   .{ 0x1160, 0x11ff }, .{ 0x1ab0, 0x1aff }, .{ 0x1dc0, 0x1dff },
    .{ 0x200b, 0x200f }, .{ 0x20d0, 0x20ff }, .{ 0xfe00, 0xfe0f }, .{ 0xfe20, 0xfe2f },
    .{ 0xfeff, 0xfeff },
};

const wide_ranges = [_]Range{
    .{ 0x1100, 0x115f },   .{ 0x2e80, 0x303e },   .{ 0x3041, 0x33ff },   .{ 0x3400, 0x4dbf },
    .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },   .{ 0xa960, 0xa97f },   .{ 0xac00, 0xd7a3 },
    .{ 0xf900, 0xfaff },   .{ 0xfe10, 0xfe19 },   .{ 0xfe30, 0xfe6f },   .{ 0xff00, 0xff60 },
    .{ 0xffe0, 0xffe6 },   .{ 0x1f300, 0x1f64f }, .{ 0x1f680, 0x1f6ff }, .{ 0x1f900, 0x1f9ff },
    .{ 0x20000, 0x3fffd },
};

fn inRanges(cp: u21, ranges: []const Range) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

pub fn cpWidth(cp: u21) usize {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (cp < 0x300) return 1;
    if (inRanges(cp, &zero_ranges)) return 0;
    return if (inRanges(cp, &wide_ranges)) 2 else 1;
}

const testing = std.testing;

test "sanitize neutralizes terminal escapes and row separators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("plain title", try sanitize(a, "plain title"));
    try testing.expectEqualStrings(" [31mred", try sanitize(a, "\x1b[31mred"));
    try testing.expectEqualStrings("a b c", try sanitize(a, "a\tb\nc"));
    try testing.expectEqualStrings("motörhead", try sanitize(a, "motörhead"));
    try testing.expectEqualStrings("漢字 ok", try sanitize(a, "漢字 ok"));
}

test "sanitize drops malformed UTF-8 instead of passing it through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("motrhead", try sanitize(a, "mot\xfcrhead"));
    try testing.expectEqualStrings("ab", try sanitize(a, "a\x80b"));
    try testing.expectEqualStrings("ab", try sanitize(a, "a\xf0\x9fb"));
    try testing.expectEqualStrings(" ", try sanitize(a, "\xc2\x9b"));
}

test "sanitize drops bidi overrides so a title cannot reorder its row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try sanitize(arena.allocator(), "song\u{202e}3pm.exe\u{2066}x\u{2069}");
    try std.testing.expectEqualStrings("song3pm.exex", got);
}
