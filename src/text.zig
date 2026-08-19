const std = @import("std");

/// Text from YouTube (titles, artists, autocomplete) is drawn straight into a raw-mode
/// terminal and written into the tab/newline-delimited history and playlist files, so a
/// title is untrusted input on both counts. Control bytes become spaces (no cursor moves,
/// no colour changes, no forged rows) and malformed UTF-8 is dropped before it can reach
/// the column math.
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
        // C1 controls (U+0080–U+009F) drive a terminal much like the C0 set
        if (cp >= 0x80 and cp <= 0x9f) {
            out.appendAssumeCapacity(' ');
        } else {
            out.appendSliceAssumeCapacity(s[i .. i + len]);
        }
        i += len;
    }
    return out.toOwnedSlice(arena);
}

/// sanitize + dupe in one step for callers that own an arena and want a stored copy.
pub fn sanitizeDupe(arena: std.mem.Allocator, s: []const u8) ?[]const u8 {
    return sanitize(arena, s) catch null;
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

    try testing.expectEqualStrings("motrhead", try sanitize(a, "mot\xfcrhead")); // latin-1 ü
    try testing.expectEqualStrings("ab", try sanitize(a, "a\x80b")); // stray continuation
    try testing.expectEqualStrings("ab", try sanitize(a, "a\xf0\x9fb")); // truncated 4-byte
    try testing.expectEqualStrings(" ", try sanitize(a, "\xc2\x9b")); // C1 CSI
}
