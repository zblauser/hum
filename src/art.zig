const std = @import("std");
const proc = @import("proc.zig");
const track_mod = @import("track.zig");
const job = @import("job.zig");

pub const SIZE = 512;
const SQUARE = std.fmt.comptimePrint("crop='min(iw,ih)':'min(iw,ih)',scale={d}:{d}:flags=lanczos,format=gray", .{ SIZE, SIZE });
const WIDE = std.fmt.comptimePrint("crop='iw*9/16':'iw*9/16',scale={d}:{d}:flags=lanczos,format=gray", .{ SIZE, SIZE });
const THUMBS = [_][]const u8{ "maxresdefault", "sddefault", "hqdefault", "mqdefault" };
const COVER_NAMES = [_][]const u8{ "cover.jpg", "cover.png", "folder.jpg", "front.jpg", "album.jpg", "Cover.jpg", "Folder.jpg", "Front.jpg" };

pub const Error = error{ NoArt, NoFfmpeg } || std.mem.Allocator.Error;

pub fn fetch(gpa: std.mem.Allocator, io: std.Io, t: track_mod.Track) Error![]u8 {
    var buf: [128]u8 = undefined;
    switch (t.source) {
        .youtube => {
            if (t.video_id.len == 0 or t.video_id.len > 32) return error.NoArt;
            for (THUMBS) |q| {
                const url = std.fmt.bufPrint(&buf, "https://i.ytimg.com/vi/{s}/{s}.jpg", .{ t.video_id, q }) catch return error.NoArt;
                return finish(decode(gpa, io, url, WIDE, SIZE) catch |err| if (err == error.NoFfmpeg) return err else continue);
            }
            return error.NoArt;
        },
        .local => {
            if (decode(gpa, io, t.uri, SQUARE, SIZE)) |px| return finish(px) else |err| if (err == error.NoFfmpeg) return err;
            const dir = std.fs.path.dirname(t.uri) orelse return error.NoArt;
            for (COVER_NAMES) |n| {
                const p = std.fs.path.join(gpa, &.{ dir, n }) catch continue;
                defer gpa.free(p);
                std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
                return finish(try decode(gpa, io, p, SQUARE, SIZE));
            }
            return error.NoArt;
        },
        .url => return error.NoArt,
    }
}

fn decode(gpa: std.mem.Allocator, io: std.Io, input: []const u8, filter: []const u8, side: usize) Error![]u8 {
    const out = proc.runCapture(gpa, io, &.{
        "ffmpeg", "-v",        "error", "-nostdin", "-i",   input, "-map",     "0:v:0",
        "-an",    "-frames:v", "1",     "-vf",      filter, "-f",  "rawvideo", "-",
    }) catch |err| return if (err == error.FileNotFound) error.NoFfmpeg else error.NoArt;
    if (out.len != side * side) {
        gpa.free(out);
        return error.NoArt;
    }
    return out;
}

fn finish(px: []u8) []u8 {
    stretch(px);
    lightOnDark(px);
    equalize(px);
    return px;
}

fn equalize(px: []u8) void {
    var hist: [256]usize = @splat(0);
    for (px) |p| hist[p] += 1;
    var total: usize = 0;
    for (&hist) |*n| {
        n.* = @min(n.*, px.len / 64);
        total += n.*;
    }
    var map: [256]u8 = undefined;
    var acc: usize = 0;
    for (&map, hist, 0..) |*m, n, i| {
        m.* = @intCast((i + acc * 255 / total) / 2);
        acc += n;
    }
    for (px) |*p| p.* = map[p.*];
}

fn lightOnDark(px: []u8) void {
    var sum: usize = 0;
    for (px) |p| sum += p;
    if (sum / px.len < 140) return;
    for (px) |*p| p.* = 255 - p.*;
}

fn stretch(px: []u8) void {
    var hist: [256]usize = @splat(0);
    for (px) |p| hist[p] += 1;
    const cut = px.len / 100;
    var lo: usize = 0;
    var acc: usize = 0;
    while (lo < 255 and acc + hist[lo] <= cut) : (lo += 1) acc += hist[lo];
    var hi: usize = 255;
    acc = 0;
    while (hi > lo and acc + hist[hi] <= cut) : (hi -= 1) acc += hist[hi];
    if (hi <= lo + 16) return;
    for (px) |*p| p.* = @intCast(std.math.clamp((@as(usize, p.*) -| lo) * 255 / (hi - lo), 0, 255));
}

pub const Job = job.Job(fetchAny);

fn fetchAny(gpa: std.mem.Allocator, io: std.Io, t: track_mod.Track) anyerror![]u8 {
    return fetch(gpa, io, t);
}

test "stretch widens a washed-out image to the full range" {
    var px: [200]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(100 + i % 50);
    stretch(&px);
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (px) |p| {
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    try std.testing.expect(lo < 10);
    try std.testing.expect(hi > 245);
}

test "stretch leaves a flat image alone" {
    var px: [64]u8 = @splat(128);
    stretch(&px);
    try std.testing.expectEqual(@as(u8, 128), px[0]);
}

test "a mostly white cover is drawn as light on dark" {
    var px: [100]u8 = @splat(240);
    px[0] = 10;
    lightOnDark(&px);
    try std.testing.expectEqual(@as(u8, 15), px[1]);
    try std.testing.expectEqual(@as(u8, 245), px[0]);
    var dark: [100]u8 = @splat(20);
    lightOnDark(&dark);
    try std.testing.expectEqual(@as(u8, 20), dark[0]);
}

test "equalize lifts detail without turning a black background gray" {
    var px: [1000]u8 = @splat(0);
    for (px[0..200], 0..) |*p, i| p.* = @intCast(40 + i % 40);
    equalize(&px);
    try std.testing.expectEqual(@as(u8, 0), px[999]);
    try std.testing.expect(px[39] - px[0] > 80);
}
