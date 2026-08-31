const std = @import("std");
const proc = @import("proc.zig");
const track_mod = @import("track.zig");

pub const Error = error{ NoVideoId, NoUri } || proc.Error || std.mem.Allocator.Error;

/// Only a YouTube row costs a subprocess; local files and URLs resolve offline.
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
        "--no-warnings", "--socket-timeout", "15",
        "-g",            "--",               video_id,
    });
    defer gpa.free(out);

    var url = std.mem.trim(u8, out, " \r\n\t");
    if (std.mem.indexOfScalar(u8, url, '\n')) |nl| url = url[0..nl];

    return gpa.dupe(u8, url);
}

const testing = std.testing;

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
