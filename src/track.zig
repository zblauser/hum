const std = @import("std");

/// Where the bytes come from.
pub const Source = enum { youtube, local, url };

pub const Track = struct {
    source: Source = .youtube,
    /// youtube only — the id yt-dlp resolves to a stream
    video_id: []const u8 = "",
    /// local: filesystem path · url: the URL itself. Empty for youtube.
    uri: []const u8 = "",
    browse_id: []const u8 = "",
    title: []const u8,
    artist: []const u8,
    album: []const u8 = "",
    /// 0 = unknown; YouTube rows and untagged files both hit this.
    duration_s: u32 = 0,
    kind: []const u8 = "Song",

    /// Artist and album rows have no playable target, and a local row with no path is a corrupt line.
    pub fn isPlayable(self: Track) bool {
        return switch (self.source) {
            .youtube => self.video_id.len > 0,
            .local, .url => self.uri.len > 0,
        };
    }
};

pub fn sourceName(s: Source) []const u8 {
    return switch (s) {
        .youtube => "youtube",
        .local => "local",
        .url => "url",
    };
}

/// Unknown or missing means youtube: pre-v0.1.7 playlists files have no source column.
pub fn sourceByName(name: []const u8) Source {
    if (std.mem.eql(u8, name, "local")) return .local;
    if (std.mem.eql(u8, name, "url")) return .url;
    return .youtube;
}

/// True for arguments meant to be handed to the player as-is rather than searched.
pub fn isUrl(s: []const u8) bool {
    inline for (.{ "http://", "https://", "file://" }) |scheme| {
        if (std.mem.startsWith(u8, s, scheme)) return true;
    }
    return false;
}

/// Display string to seconds; anything unparseable is 0, never an error.
pub fn parseDuration(s: []const u8) u32 {
    var total: u32 = 0;
    var part: u32 = 0;
    var seen_digit = false;
    var fields: u8 = 1;
    for (s) |b| {
        switch (b) {
            '0'...'9' => {
                part = part *| 10 +| (b - '0');
                if (part > 359999) return 0;
                seen_digit = true;
            },
            ':' => {
                if (!seen_digit) return 0;
                fields += 1;
                if (fields > 3) return 0;
                total = total *| 60 +| part;
                part = 0;
                seen_digit = false;
            },
            ' ' => {},
            else => return 0,
        }
    }
    if (!seen_digit) return 0;
    return total *| 60 +| part;
}

const testing = std.testing;

test "isPlayable follows the source, not just video_id" {
    try testing.expect((Track{ .video_id = "abc", .title = "t", .artist = "a" }).isPlayable());
    try testing.expect(!(Track{ .title = "t", .artist = "a" }).isPlayable());

    const local: Track = .{ .source = .local, .uri = "/music/a.flac", .title = "t", .artist = "a" };
    try testing.expect(local.isPlayable());
    try testing.expect(!(Track{ .source = .local, .title = "t", .artist = "a" }).isPlayable());

    // a local row must not qualify just because some video_id lingers on it
    try testing.expect(!(Track{ .source = .local, .video_id = "abc", .title = "t", .artist = "a" }).isPlayable());
}

test "sourceByName round-trips and defaults old rows to youtube" {
    inline for (.{ Source.youtube, Source.local, Source.url }) |s| {
        try testing.expectEqual(s, sourceByName(sourceName(s)));
    }
    try testing.expectEqual(Source.youtube, sourceByName(""));
    try testing.expectEqual(Source.youtube, sourceByName("Song"));
    try testing.expectEqual(Source.youtube, sourceByName("LOCAL"));
}

test "isUrl accepts the schemes we hand straight to mpv" {
    try testing.expect(isUrl("https://example.com/a.mp3"));
    try testing.expect(isUrl("http://stream.example/live"));
    try testing.expect(isUrl("file:///music/a.flac"));
    try testing.expect(!isUrl("/music/a.flac"));
    try testing.expect(!isUrl("daft punk"));
    try testing.expect(!isUrl("ftp://example.com/a.mp3"));
}

test "parseDuration handles mm:ss, h:mm:ss and junk" {
    try testing.expectEqual(@as(u32, 222), parseDuration("3:42"));
    try testing.expectEqual(@as(u32, 3723), parseDuration("1:02:03"));
    try testing.expectEqual(@as(u32, 5), parseDuration("0:05"));
    try testing.expectEqual(@as(u32, 42), parseDuration("42"));
    try testing.expectEqual(@as(u32, 0), parseDuration(""));
    try testing.expectEqual(@as(u32, 0), parseDuration("Song"));
    try testing.expectEqual(@as(u32, 0), parseDuration("3:"));
    try testing.expectEqual(@as(u32, 0), parseDuration("1:2:3:4"));
    try testing.expectEqual(@as(u32, 0), parseDuration("99999999999"));
}
