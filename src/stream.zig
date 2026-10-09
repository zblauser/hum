const std = @import("std");
const proc = @import("proc.zig");
const track_mod = @import("track.zig");
const RESOLVE_TIMEOUT_S = "15";

pub const Error = error{ NoVideoId, NoUri } || proc.Error || std.mem.Allocator.Error;

pub fn resolve(gpa: std.mem.Allocator, io: std.Io, t: track_mod.Track) Error![]u8 {
    return switch (t.source) {
        .youtube => resolveAudioUrl(gpa, io, t.video_id),
        .local, .url => blk: {
            if (t.uri.len == 0) return error.NoUri;
            break :blk gpa.dupe(u8, t.uri);
        },
    };
}

pub fn resolveAudioUrl(gpa: std.mem.Allocator, io: std.Io, video_id: []const u8) ![]u8 {
    if (video_id.len == 0) return error.NoVideoId;

    const out = try proc.runCapture(gpa, io, &.{
        "yt-dlp",        "-f",               "bestaudio",
        "--no-warnings", "--socket-timeout", RESOLVE_TIMEOUT_S,
        "-g",            "--",               video_id,
    });
    defer gpa.free(out);

    var url = std.mem.trim(u8, out, " \r\n\t");
    if (std.mem.indexOfScalar(u8, url, '\n')) |nl| url = url[0..nl];

    return gpa.dupe(u8, url);
}

pub const STALE_DAYS = 60;

pub fn ytdlpAgeDays(version: []const u8, now_s: i64) ?u32 {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, version, " \r\n\t"), '.');
    const y = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const d = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    if (y < 2000 or y > 9999 or m < 1 or m > 12 or d < 1 or d > 31) return null;
    const age = @divFloor(now_s, std.time.s_per_day) - daysFromCivil(y, m, d);
    return if (age < 0) 0 else @intCast(age);
}

fn daysFromCivil(year: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn ytdlpVersion(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    return proc.runCapture(gpa, io, &.{ "yt-dlp", "--version" }) catch null;
}

const testing = std.testing;

test "yt-dlp age is counted in days from its date version" {
    const oct_5_2026 = 1791158400;
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(?u32, 0), ytdlpAgeDays("2026.10.05\n", oct_5_2026));
    try testing.expectEqual(@as(?u32, 48), ytdlpAgeDays("2026.08.18.122307", oct_5_2026));
    try testing.expectEqual(@as(?u32, 0), ytdlpAgeDays("2027.01.01", oct_5_2026));
    try testing.expectEqual(@as(?u32, null), ytdlpAgeDays("garbage", oct_5_2026));
    try testing.expectEqual(@as(?u32, null), ytdlpAgeDays("2026.13.01", oct_5_2026));
    try testing.expectEqual(@as(?u32, null), ytdlpAgeDays("2026.10", oct_5_2026));
}

test "resolve hands back local paths and URLs without a subprocess" {
    const local: track_mod.Track = .{ .source = .local, .uri = "/music/a.flac", .title = "t", .artist = "a" };
    const got = try resolve(testing.allocator, undefined, local);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/music/a.flac", got);

    const url: track_mod.Track = .{ .source = .url, .uri = "https://s/live", .title = "t", .artist = "a" };
    const got2 = try resolve(testing.allocator, undefined, url);
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings("https://s/live", got2);
}

test "resolve rejects an empty target instead of spawning anything" {
    const empty_local: track_mod.Track = .{ .source = .local, .title = "t", .artist = "a" };
    try testing.expectError(error.NoUri, resolve(testing.allocator, undefined, empty_local));

    const empty_yt: track_mod.Track = .{ .title = "t", .artist = "a" };
    try testing.expectError(error.NoVideoId, resolve(testing.allocator, undefined, empty_yt));
}
