const std = @import("std");
const track_mod = @import("track.zig");

pub fn Job(comptime run: fn (std.mem.Allocator, std.Io, track_mod.Track) anyerror![]u8) type {
    return struct {
        const Self = @This();
        const RUNNING = 0;
        const DONE = 1;
        const ABANDONED = 2;

        gpa: std.mem.Allocator,
        io: std.Io,
        track: track_mod.Track,
        owned: []u8,
        out: ?[]u8 = null,
        err: anyerror = error.NoResult,
        phase: std.atomic.Value(u8) = .init(RUNNING),
        thread: std.Thread = undefined,

        pub fn start(gpa: std.mem.Allocator, io: std.Io, t: track_mod.Track) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const owned = try std.mem.join(gpa, "\x00", &.{ idOf(t), t.title, t.artist, t.album });
            errdefer gpa.free(owned);
            var it = std.mem.splitScalar(u8, owned, 0);
            const id = it.next().?;
            self.* = .{ .gpa = gpa, .io = io, .owned = owned, .track = .{
                .source = t.source,
                .video_id = id,
                .uri = id,
                .title = it.next().?,
                .artist = it.next().?,
                .album = it.next().?,
                .duration_s = t.duration_s,
            } };
            self.thread = try std.Thread.spawn(.{}, work, .{self});
            return self;
        }

        pub fn matches(self: *const Self, t: track_mod.Track) bool {
            return self.track.source == t.source and std.mem.eql(u8, self.track.video_id, idOf(t));
        }

        pub fn ready(self: *const Self) bool {
            return self.phase.load(.acquire) == DONE;
        }

        pub fn result(self: *const Self) ?[]const u8 {
            return if (self.ready()) self.out else null;
        }

        pub fn release(self: *Self) void {
            self.thread.detach();
            if (self.phase.cmpxchgStrong(RUNNING, ABANDONED, .acq_rel, .acquire) == null) return;
            self.free();
        }

        fn work(self: *Self) void {
            if (run(self.gpa, self.io, self.track)) |v| self.out = v else |e| self.err = e;
            if (self.phase.cmpxchgStrong(RUNNING, DONE, .acq_rel, .acquire) != null) self.free();
        }

        fn free(self: *Self) void {
            if (self.out) |v| self.gpa.free(v);
            self.gpa.free(self.owned);
            self.gpa.destroy(self);
        }

        fn idOf(t: track_mod.Track) []const u8 {
            return if (t.source == .youtube) t.video_id else t.uri;
        }
    };
}

fn echo(gpa: std.mem.Allocator, _: std.Io, t: track_mod.Track) anyerror![]u8 {
    if (t.title.len == 0) return error.NoResult;
    return std.fmt.allocPrint(gpa, "{s}|{s}|{s}", .{ t.video_id, t.title, t.artist });
}

test "a job copies its track, runs off-thread, and frees on release either way" {
    const E = Job(echo);
    const t: track_mod.Track = .{ .video_id = "v1", .title = "Song", .artist = "Band" };
    const j = try E.start(std.testing.allocator, undefined, t);
    while (!j.ready()) std.Thread.yield() catch {};
    try std.testing.expectEqualStrings("v1|Song|Band", j.result().?);
    try std.testing.expect(j.matches(t));
    try std.testing.expect(!j.matches(.{ .video_id = "v2", .title = "", .artist = "" }));
    j.release();

    const bad = try E.start(std.testing.allocator, undefined, .{ .video_id = "v3", .title = "", .artist = "" });
    while (!bad.ready()) std.Thread.yield() catch {};
    try std.testing.expect(bad.result() == null);
    try std.testing.expectEqual(error.NoResult, bad.err);
    bad.release();
}
