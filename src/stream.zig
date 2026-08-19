const std = @import("std");
const proc = @import("proc.zig");

pub const Error = error{NoVideoId} || proc.Error;

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
