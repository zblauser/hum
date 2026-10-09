const std = @import("std");
const proc = @import("proc.zig");
const txt = @import("text.zig");
const fsutil = @import("fsutil.zig");
const track_mod = @import("track.zig");

const INNERTUBE_KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30";
const SEARCH_URL = "https://music.youtube.com/youtubei/v1/search?key=" ++ INNERTUBE_KEY ++ "&prettyPrint=false";

const CLIENT_CONTEXT =
    \\"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20240101.00.00","hl":"en","gl":"US"},"user":{}}
;

const c = fsutil.c;
const SEARCH_TIMEOUT_S = "20";

pub const Track = track_mod.Track;
pub const Source = track_mod.Source;

pub const Filter = enum {
    all,
    songs,
    videos,
    albums,
    artists,

    pub fn label(self: Filter) []const u8 {
        return switch (self) {
            .all => "all",
            .songs => "songs",
            .videos => "videos",
            .albums => "albums",
            .artists => "artists",
        };
    }

    pub fn params(self: Filter) []const u8 {
        return switch (self) {
            .all => "",
            .songs => "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D",
            .videos => "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D",
            .albums => "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D",
            .artists => "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D",
        };
    }
};

pub const Error = error{
    TempFileOpen,
    TempFileWrite,
    NoResult,
} || std.mem.Allocator.Error || proc.Error;

pub fn search(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, query: []const u8, max: usize) ![]Track {
    return searchFiltered(arena, gpa, io, query, max, .all);
}

pub fn searchFiltered(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    max: usize,
    filter: Filter,
) ![]Track {
    const body = try buildBodyFiltered(arena, query, filter);
    const resp = try postJson(arena, gpa, io, SEARCH_URL, body);
    defer gpa.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});

    var out: std.ArrayList(Track) = .empty;
    try collectTracks(arena, parsed.value, &out, max, "");
    if (out.items.len == 0) return error.NoResult;
    return out.toOwnedSlice(arena);
}

fn collectTracks(
    arena: std.mem.Allocator,
    v: std.json.Value,
    out: *std.ArrayList(Track),
    max: usize,
    inherited: []const u8,
) !void {
    if (out.items.len >= max) return;
    switch (v) {
        .object => |obj| {
            var artist_ctx = inherited;
            if (obj.get("musicCardShelfRenderer")) |card| {
                if (cardArtist(card)) |a| artist_ctx = a;
            }
            if (obj.get("musicResponsiveListItemRenderer")) |item| {
                if (extractTrack(arena, item, artist_ctx)) |t| {
                    try out.append(arena, t);
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                try collectTracks(arena, entry.value_ptr.*, out, max, artist_ctx);
                if (out.items.len >= max) return;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                try collectTracks(arena, item, out, max, inherited);
                if (out.items.len >= max) return;
            }
        },
        else => {},
    }
}

fn cardArtist(card: std.json.Value) ?[]const u8 {
    if (card != .object) return null;
    inline for (.{ "title", "subtitle" }) |key| {
        if (card.object.get(key)) |node| {
            if (node == .object) {
                if (node.object.get("runs")) |runs| {
                    if (runs == .array) {
                        for (runs.array.items) |run| {
                            const bid = browseIdOfRun(run) orelse continue;
                            if (std.mem.startsWith(u8, bid, "UC")) {
                                if (textOfRun(run)) |t| return t;
                            }
                        }
                    }
                }
            }
        }
    }
    return null;
}

fn extractTrack(arena: std.mem.Allocator, item: std.json.Value, inherited: []const u8) ?Track {
    if (item != .object) return null;
    const obj = item.object;

    var video_id_str: []const u8 = "";
    var browse_id_str: []const u8 = "";
    if (obj.get("playlistItemData")) |pid| {
        if (pid == .object) {
            if (pid.object.get("videoId")) |vid| {
                if (vid == .string) video_id_str = vid.string;
            }
        }
    }
    if (obj.get("navigationEndpoint")) |nav| {
        if (nav == .object) {
            if (nav.object.get("browseEndpoint")) |be| {
                if (be == .object) {
                    if (be.object.get("browseId")) |bid| {
                        if (bid == .string) browse_id_str = bid.string;
                    }
                }
            }
        }
    }
    if (video_id_str.len == 0 and browse_id_str.len == 0) return null;

    const flex = obj.get("flexColumns") orelse return null;
    if (flex != .array or flex.array.items.len == 0) return null;

    const title = flexText(flex.array.items[0]) orelse return null;
    var artist: []const u8 = if (inherited.len > 0) inherited else "unknown";
    var kind: []const u8 = "Song";
    if (flex.array.items.len > 1) {
        if (flexRuns(flex.array.items[1])) |r| {
            if (r.len >= 1) {
                if (textOfRun(r[0])) |t0| {
                    if (isKindWord(t0)) kind = t0;
                }
            }
            artist = firstLinkedRunText(r) orelse positionalArtist(r) orelse artist;
        }
    }

    var album: []const u8 = "";
    if (flex.array.items.len > 1) {
        if (flexRuns(flex.array.items[1])) |r| album = albumOfRuns(r) orelse "";
    }

    return .{
        .source = .youtube,
        .video_id = txt.sanitizeDupe(arena, video_id_str) orelse return null,
        .browse_id = txt.sanitizeDupe(arena, browse_id_str) orelse return null,
        .title = txt.sanitizeDupe(arena, title) orelse return null,
        .artist = txt.sanitizeDupe(arena, artist) orelse return null,
        .album = txt.sanitizeDupe(arena, album) orelse "",
        .duration_s = durationOf(obj),
        .kind = txt.sanitizeDupe(arena, kind) orelse return null,
    };
}

const BROWSE_URL = "https://music.youtube.com/youtubei/v1/browse?key=" ++ INNERTUBE_KEY ++ "&prettyPrint=false";

pub fn browseAlbum(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, browse_id: []const u8) ![]Track {
    const id = try std.json.Stringify.valueAlloc(arena, browse_id, .{});
    const body = try std.fmt.allocPrint(arena, "{{{s},\"browseId\":{s}}}", .{ CLIENT_CONTEXT, id });
    const resp = try postJson(arena, gpa, io, BROWSE_URL, body);
    defer gpa.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});
    var out: std.ArrayList(Track) = .empty;
    try collectTracks(arena, parsed.value, &out, 256, "");
    if (out.items.len == 0) return error.NoResult;

    if (findAlbumArtist(parsed.value)) |alb| {
        const dup = txt.sanitizeDupe(arena, alb) orelse alb;
        for (out.items) |*t| {
            if (std.mem.eql(u8, t.artist, "unknown")) t.artist = dup;
        }
    }
    return out.toOwnedSlice(arena);
}

fn durationOf(obj: std.json.ObjectMap) u32 {
    if (obj.get("fixedColumns")) |fixed| {
        if (fixed == .array) {
            for (fixed.array.items) |col| {
                if (col != .object) continue;
                const inner = col.object.get("musicResponsiveListItemFixedColumnRenderer") orelse continue;
                if (inner != .object) continue;
                const text = inner.object.get("text") orelse continue;
                if (text != .object) continue;
                const runs = text.object.get("runs") orelse continue;
                if (runs != .array or runs.array.items.len == 0) continue;
                if (textOfRun(runs.array.items[0])) |t| {
                    if (looksLikeDuration(t)) return track_mod.parseDuration(t);
                }
            }
        }
    }
    const flex = obj.get("flexColumns") orelse return 0;
    if (flex != .array) return 0;
    for (flex.array.items) |col| {
        const runs = flexRuns(col) orelse continue;
        for (runs) |run| {
            if (textOfRun(run)) |t| {
                if (looksLikeDuration(t)) return track_mod.parseDuration(t);
            }
        }
    }
    return 0;
}

fn albumOfRuns(runs: []std.json.Value) ?[]const u8 {
    for (runs) |run| {
        const bid = browseIdOfRun(run) orelse continue;
        if (std.mem.startsWith(u8, bid, "MPRE")) return textOfRun(run);
    }
    return null;
}

fn isKindWord(s: []const u8) bool {
    const words = [_][]const u8{ "Song", "Video", "Album", "Single", "EP", "Artist", "Playlist", "Episode", "Podcast" };
    for (words) |w| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

fn runHasNav(v: std.json.Value) bool {
    if (v != .object) return false;
    const nav = v.object.get("navigationEndpoint") orelse return false;
    return nav == .object;
}

fn browseIdOfRun(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const nav = v.object.get("navigationEndpoint") orelse return null;
    if (nav != .object) return null;
    const be = nav.object.get("browseEndpoint") orelse return null;
    if (be != .object) return null;
    const bid = be.object.get("browseId") orelse return null;
    if (bid != .string) return null;
    return bid.string;
}

fn firstLinkedRunText(runs: []std.json.Value) ?[]const u8 {
    for (runs) |run| {
        if (runHasNav(run)) {
            if (textOfRun(run)) |t| return t;
        }
    }
    return null;
}

fn positionalArtist(runs: []std.json.Value) ?[]const u8 {
    for (runs) |run| {
        const t = textOfRun(run) orelse continue;
        if (isKindWord(t)) continue;
        if (looksLikeDuration(t)) continue;
        if (std.mem.trim(u8, t, " \t•·-—").len == 0) continue;
        return t;
    }
    return null;
}

fn looksLikeDuration(t: []const u8) bool {
    return std.mem.indexOfScalar(u8, t, ':') != null and track_mod.parseDuration(t) > 0;
}

fn findAlbumArtist(v: std.json.Value) ?[]const u8 {
    const hdr = findHeaderRenderer(v) orelse return null;
    return artistFromHeader(hdr);
}

fn findHeaderRenderer(v: std.json.Value) ?std.json.Value {
    switch (v) {
        .object => |obj| {
            if (obj.get("musicResponsiveHeaderRenderer")) |h| return h;
            if (obj.get("musicDetailHeaderRenderer")) |h| return h;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (findHeaderRenderer(entry.value_ptr.*)) |h| return h;
            }
        },
        .array => |arr| {
            for (arr.items) |item| if (findHeaderRenderer(item)) |h| return h;
        },
        else => {},
    }
    return null;
}

fn artistFromHeader(hdr: std.json.Value) ?[]const u8 {
    if (hdr != .object) return null;
    inline for (.{ "straplineTextOne", "subtitle" }) |key| {
        if (hdr.object.get(key)) |node| {
            if (node == .object) {
                if (node.object.get("runs")) |runs| {
                    if (runs == .array) {
                        for (runs.array.items) |run| {
                            if (browseIdOfRun(run)) |bid| {
                                if (std.mem.startsWith(u8, bid, "UC")) {
                                    if (textOfRun(run)) |t| return t;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (hdr.object.get("straplineTextOne")) |node| {
        if (node == .object) {
            if (node.object.get("runs")) |runs| {
                if (runs == .array and runs.array.items.len > 0) {
                    return textOfRun(runs.array.items[0]);
                }
            }
        }
    }
    return null;
}

fn flexRuns(v: std.json.Value) ?[]std.json.Value {
    if (v != .object) return null;
    const inner = v.object.get("musicResponsiveListItemFlexColumnRenderer") orelse return null;
    if (inner != .object) return null;
    const text = inner.object.get("text") orelse return null;
    if (text != .object) return null;
    const runs = text.object.get("runs") orelse return null;
    if (runs != .array) return null;
    return runs.array.items;
}

fn textOfRun(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const s = v.object.get("text") orelse return null;
    if (s != .string) return null;
    return s.string;
}

fn flexText(v: std.json.Value) ?[]const u8 {
    const runs = flexRuns(v) orelse return null;
    if (runs.len == 0) return null;
    return textOfRun(runs[0]);
}

fn buildBodyFiltered(arena: std.mem.Allocator, query: []const u8, filter: Filter) ![]u8 {
    const escaped = try std.json.Stringify.valueAlloc(arena, query, .{});
    const params = filter.params();
    if (params.len == 0) {
        return std.fmt.allocPrint(arena, "{{{s},\"query\":{s}}}", .{ CLIENT_CONTEXT, escaped });
    }
    return std.fmt.allocPrint(arena, "{{{s},\"query\":{s},\"params\":\"{s}\"}}", .{ CLIENT_CONTEXT, escaped, params });
}

fn postJson(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8) ![]u8 {
    const body_path = try fsutil.makeTemp(arena, "hum_body", body);
    defer _ = c.unlink(body_path.ptr);
    const data_arg = try std.fmt.allocPrint(arena, "@{s}", .{body_path});

    return proc.runCapture(gpa, io, &.{
        "curl",          "-sS",
        "--max-time",    SEARCH_TIMEOUT_S,
        "-H",            "Content-Type: application/json",
        "-H",            "User-Agent: Mozilla/5.0",
        "-X",            "POST",
        "--data-binary", data_arg,
        url,
    });
}

const testing = std.testing;

test "Track.isPlayable, Filter labels/params, isKindWord" {
    try testing.expect((Track{ .video_id = "abc", .title = "t", .artist = "a" }).isPlayable());
    try testing.expect(!(Track{ .title = "t", .artist = "a" }).isPlayable());

    try testing.expectEqualStrings("songs", Filter.songs.label());
    try testing.expectEqualStrings("", Filter.all.params());
    try testing.expect(Filter.albums.params().len > 0);

    try testing.expect(isKindWord("Album"));
    try testing.expect(!isKindWord("album"));
    try testing.expect(!isKindWord("Nonsense"));
}

test "buildBodyFiltered emits valid JSON with shared context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = try buildBodyFiltered(a, "daft punk", .all);
    const p1 = try std.json.parseFromSlice(std.json.Value, a, plain, .{});
    try testing.expectEqualStrings("daft punk", p1.value.object.get("query").?.string);
    try testing.expect(p1.value.object.get("params") == null);

    const filtered = try buildBodyFiltered(a, "x", .songs);
    const p2 = try std.json.parseFromSlice(std.json.Value, a, filtered, .{});
    try testing.expect(p2.value.object.get("params") != null);

    try testing.expectEqualStrings(
        "WEB_REMIX",
        p2.value.object.get("context").?.object.get("client").?.object.get("clientName").?.string,
    );
}

test "collectTracks extracts a song from an InnerTube fixture" {
    const json =
        \\{"contents":[{"musicResponsiveListItemRenderer":{
        \\  "playlistItemData":{"videoId":"abc123"},
        \\  "flexColumns":[
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"My Song"}]}}},
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
        \\      {"text":"My Artist","navigationEndpoint":{"browseEndpoint":{"browseId":"UCxyz"}}}
        \\    ]}}}
        \\  ]
        \\}}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    var out: std.ArrayList(Track) = .empty;
    try collectTracks(a, parsed.value, &out, 10, "");

    try testing.expectEqual(@as(usize, 1), out.items.len);
    const t = out.items[0];
    try testing.expectEqualStrings("My Song", t.title);
    try testing.expectEqualStrings("My Artist", t.artist);
    try testing.expectEqualStrings("abc123", t.video_id);
    try testing.expect(t.isPlayable());
}

test "findAlbumArtist reads the header, not a related-artist carousel" {
    const json =
        \\{"contents":{"sectionListRenderer":{"contents":[
        \\  {"musicCarouselShelfRenderer":{"contents":[
        \\    {"musicTwoRowItemRenderer":{"title":{"runs":[
        \\      {"text":"Dead Can Dance","navigationEndpoint":{"browseEndpoint":{"browseId":"UCdead"}}}
        \\    ]}}}
        \\  ]}}
        \\]}},
        \\"header":{"musicResponsiveHeaderRenderer":{"straplineTextOne":{"runs":[
        \\  {"text":"Bohren & der Club of Gore","navigationEndpoint":{"browseEndpoint":{"browseId":"UCbohren"}}}
        \\]}}}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    try testing.expectEqualStrings(
        "Bohren & der Club of Gore",
        findAlbumArtist(parsed.value).?,
    );
}

test "findAlbumArtist reads legacy musicDetailHeaderRenderer subtitle" {
    const json =
        \\{"header":{"musicDetailHeaderRenderer":{"subtitle":{"runs":[
        \\  {"text":"Bohren & der Club of Gore","navigationEndpoint":{"browseEndpoint":{"browseId":"UCbohren"}}},
        \\  {"text":" • "},{"text":"Album"},{"text":" • "},{"text":"2002"}
        \\]}}}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    try testing.expectEqualStrings(
        "Bohren & der Club of Gore",
        findAlbumArtist(parsed.value).?,
    );
}

test "a subtitle of `Song • 5:38` yields no artist and a duration" {
    const json =
        \\{"musicResponsiveListItemRenderer":{
        \\  "playlistItemData":{"videoId":"abc123"},
        \\  "flexColumns":[
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Instant Crush"}]}}},
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
        \\      {"text":"Song"},{"text":" • "},{"text":"5:38"}
        \\    ]}}},
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"1.2B plays"}]}}}
        \\  ]
        \\}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const t = extractTrack(a, parsed.value.object.get("musicResponsiveListItemRenderer").?, "").?;
    try testing.expectEqualStrings("unknown", t.artist);
    try testing.expectEqualStrings("Song", t.kind);
    try testing.expectEqual(@as(u32, 338), t.duration_s);
}

test "duration parsing never claims a numeric title is a runtime" {
    try testing.expect(looksLikeDuration("5:38"));
    try testing.expect(!looksLikeDuration("1979"));
    try testing.expect(!looksLikeDuration("1.2B plays"));
    try testing.expect(!looksLikeDuration("Song"));
}

test "extractTrack keeps a linked artist and picks up album and duration" {
    const json =
        \\{"musicResponsiveListItemRenderer":{
        \\  "playlistItemData":{"videoId":"abc123"},
        \\  "flexColumns":[
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Midnight"}]}}},
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
        \\      {"text":"Song"},{"text":" • "},
        \\      {"text":"Bohren","navigationEndpoint":{"browseEndpoint":{"browseId":"UCbohren"}}},
        \\      {"text":" • "},
        \\      {"text":"Black Earth","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREblack"}}},
        \\      {"text":" • "},{"text":"3:42"}
        \\    ]}}}
        \\  ]
        \\}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const t = extractTrack(a, parsed.value.object.get("musicResponsiveListItemRenderer").?, "").?;
    try testing.expectEqualStrings("Bohren", t.artist);
    try testing.expectEqualStrings("Black Earth", t.album);
    try testing.expectEqual(@as(u32, 222), t.duration_s);
    try testing.expectEqual(track_mod.Source.youtube, t.source);
}

test "card-shelf rows inherit the artist the card header names" {
    const json =
        \\{"musicCardShelfRenderer":{
        \\  "title":{"runs":[{"text":"Daft Punk","navigationEndpoint":{"browseEndpoint":{"browseId":"UCRr1"}}}]},
        \\  "subtitle":{"runs":[{"text":"Artist"},{"text":" • "},{"text":"80.5M monthly audience"}]},
        \\  "contents":[{"musicResponsiveListItemRenderer":{
        \\    "playlistItemData":{"videoId":"abc123"},
        \\    "flexColumns":[
        \\      {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Instant Crush"}]}}},
        \\      {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
        \\        {"text":"Song"},{"text":" • "},{"text":"5:38"}
        \\      ]}}}
        \\    ]
        \\  }}]
        \\}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    var out: std.ArrayList(Track) = .empty;
    try collectTracks(a, parsed.value, &out, 10, "");

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("Daft Punk", out.items[0].artist);
    try testing.expectEqual(@as(u32, 338), out.items[0].duration_s);
}

test "cardArtist reads a linked subtitle when the card title is not the artist" {
    const json =
        \\{"title":{"runs":[{"text":"Daft Punk - One More Time (Official Video)"}]},
        \\ "subtitle":{"runs":[
        \\   {"text":"Video"},{"text":" • "},
        \\   {"text":"Daft Punk","navigationEndpoint":{"browseEndpoint":{"browseId":"UC_kR"}}},
        \\   {"text":" • "},{"text":"614M views"}
        \\ ]}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    try testing.expectEqualStrings("Daft Punk", cardArtist(parsed.value).?);
}

test "a row with its own artist ignores the inherited one" {
    const json =
        \\{"musicResponsiveListItemRenderer":{
        \\  "playlistItemData":{"videoId":"abc123"},
        \\  "flexColumns":[
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song Title"}]}}},
        \\    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[
        \\      {"text":"Song"},{"text":" • "},
        \\      {"text":"Real Artist","navigationEndpoint":{"browseEndpoint":{"browseId":"UCreal"}}}
        \\    ]}}}
        \\  ]
        \\}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const t = extractTrack(a, parsed.value.object.get("musicResponsiveListItemRenderer").?, "Card Artist").?;
    try testing.expectEqualStrings("Real Artist", t.artist);
}
