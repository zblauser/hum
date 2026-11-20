const std = @import("std");
const proc = @import("proc.zig");
const txt = @import("text.zig");
const fsutil = @import("fsutil.zig");
const track_mod = @import("track.zig");
const job = @import("job.zig");

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
    return (try searchPage(arena, gpa, io, query, max, filter)).tracks;
}

pub const More = union(enum) {
    none,
    search: []const u8,
    browse: []const u8,
    songs: []const u8,
};

pub const Page = struct {
    tracks: []Track,
    more: More = .none,
};

pub const BROWSE_MAX: usize = 256;

pub fn searchPage(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    max: usize,
    filter: Filter,
) !Page {
    const body = try buildBodyFiltered(arena, query, filter);
    const page = try fetchPage(arena, gpa, io, SEARCH_URL, body, max, false, .search);
    if (page.more == .none and filter == .all) {
        return .{ .tracks = page.tracks, .more = .{ .songs = try arena.dupe(u8, query) } };
    }
    return page;
}

pub fn morePage(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, more: More, max: usize) !Page {
    return switch (more) {
        .none => error.NoResult,
        .songs => |q| searchPage(arena, gpa, io, q, max, .songs),
        .search => |tok| fetchPage(arena, gpa, io, SEARCH_URL, try continuationBody(arena, tok), max, false, .search),
        .browse => |tok| fetchPage(arena, gpa, io, BROWSE_URL, try continuationBody(arena, tok), max, false, .browse),
    };
}

pub fn browsePage(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, browse_id: []const u8) !Page {
    if (std.mem.startsWith(u8, browse_id, "MPRE")) {
        return .{ .tracks = try browseAlbum(arena, gpa, io, browse_id) };
    }
    const id = try std.json.Stringify.valueAlloc(arena, browse_id, .{});
    const body = try std.fmt.allocPrint(arena, "{{{s},\"browseId\":{s}}}", .{ CLIENT_CONTEXT, id });
    const rich = std.mem.startsWith(u8, browse_id, "UC") or std.mem.startsWith(u8, browse_id, "MPAD");
    return fetchPage(arena, gpa, io, BROWSE_URL, body, BROWSE_MAX, rich, if (rich) .none else .browse);
}

const NEXT_URL = "https://music.youtube.com/youtubei/v1/next?key=" ++ INNERTUBE_KEY ++ "&prettyPrint=false";

pub fn radio(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, video_id: []const u8, max: usize) ![]Track {
    const id = try std.json.Stringify.valueAlloc(arena, video_id, .{});
    const body = try std.fmt.allocPrint(arena, "{{{s},\"videoId\":{s},\"playlistId\":\"RDAMVM{s}\",\"isAudioOnly\":true}}", .{ CLIENT_CONTEXT, id, video_id });
    const resp = try postJson(arena, gpa, io, NEXT_URL, body);
    defer gpa.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});
    return radioOf(arena, parsed.value, video_id, max);
}

fn radioOf(arena: std.mem.Allocator, root: std.json.Value, seed: []const u8, max: usize) ![]Track {
    var out: std.ArrayList(Track) = .empty;
    try collectRadio(arena, root, seed, max, &out);
    if (out.items.len == 0) return error.NoResult;
    return out.toOwnedSlice(arena);
}

fn collectRadio(arena: std.mem.Allocator, v: std.json.Value, seed: []const u8, max: usize, out: *std.ArrayList(Track)) !void {
    if (out.items.len >= max) return;
    switch (v) {
        .object => |obj| {
            if (obj.get("playlistPanelVideoRenderer")) |r| {
                if (radioTrack(arena, r)) |t| if (!std.mem.eql(u8, t.video_id, seed) and !contains(out.items, t)) try out.append(arena, t);
                return;
            }
            var it = obj.iterator();
            while (it.next()) |e| try collectRadio(arena, e.value_ptr.*, seed, max, out);
        },
        .array => |arr| for (arr.items) |x| try collectRadio(arena, x, seed, max, out),
        else => {},
    }
}

fn radioTrack(arena: std.mem.Allocator, r: std.json.Value) ?Track {
    const id = stringAt(r, "videoId") orelse return null;
    const title_runs = arrayAt(objAt(r, "title") orelse return null, "runs") orelse return null;
    if (title_runs.len == 0) return null;
    var t: Track = .{ .video_id = id, .title = textOfRun(title_runs[0]) orelse return null, .artist = "" };
    if (objAt(r, "lengthText")) |lt| if (arrayAt(lt, "runs")) |runs| if (runs.len > 0) if (textOfRun(runs[0])) |d| {
        t.duration_s = track_mod.parseDuration(d);
    };
    const by = arrayAt(objAt(r, "longBylineText") orelse return t, "runs") orelse return t;
    var seg: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    var n: usize = 0;
    for (by) |run| {
        const text = textOfRun(run) orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, text, " "), "•")) {
            n += 1;
            if (n >= seg.len) break;
            continue;
        }
        seg[n].appendSlice(arena, text) catch return null;
    }
    t.artist = seg[0].items;
    if (n >= 2 and !isYear(seg[1].items)) t.album = seg[1].items;
    return t;
}

pub const LyricsJob = job.Job(lyricsFor);

fn lyricsFor(gpa: std.mem.Allocator, io: std.Io, t: Track) anyerror![]u8 {
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    var id = t.video_id;
    if (t.source != .youtube) {
        if (t.title.len == 0) return error.NoResult;
        const q = try std.fmt.allocPrint(a, "{s} {s}", .{ t.artist, t.title });
        const hits = try searchFiltered(a, gpa, io, q, 5, .songs);
        id = for (hits) |h| {
            if (h.video_id.len > 0) break h.video_id;
        } else return error.NoResult;
    }
    const body = try std.fmt.allocPrint(a, "{{{s},\"videoId\":{s}}}", .{ CLIENT_CONTEXT, try std.json.Stringify.valueAlloc(a, id, .{}) });
    const next = try postJson(a, gpa, io, NEXT_URL, body);
    defer gpa.free(next);
    const browse_id = lyricsBrowseId(try std.json.parseFromSliceLeaky(std.json.Value, a, next, .{})) orelse return error.NoLyrics;
    const page = try postJson(a, gpa, io, BROWSE_URL, try std.fmt.allocPrint(a, "{{{s},\"browseId\":\"{s}\"}}", .{ CLIENT_CONTEXT, browse_id }));
    defer gpa.free(page);
    return lyricsText(gpa, try std.json.parseFromSliceLeaky(std.json.Value, a, page, .{})) orelse error.NoLyrics;
}

fn lyricsBrowseId(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .object => |obj| {
            if (obj.get("browseEndpoint")) |be| if (stringAt(be, "browseId")) |id| if (std.mem.startsWith(u8, id, "MPLY") and id.len < 64) return id;
            var it = obj.iterator();
            while (it.next()) |e| if (lyricsBrowseId(e.value_ptr.*)) |id| return id;
        },
        .array => |arr| for (arr.items) |x| if (lyricsBrowseId(x)) |id| return id,
        else => {},
    }
    return null;
}

fn lyricsText(gpa: std.mem.Allocator, v: std.json.Value) ?[]u8 {
    switch (v) {
        .object => |obj| {
            if (obj.get("musicDescriptionShelfRenderer")) |r| {
                const runs = arrayAt(objAt(r, "description") orelse return null, "runs") orelse return null;
                var out: std.ArrayList(u8) = .empty;
                for (runs) |run| if (textOfRun(run)) |t| for (t) |ch| {
                    if (ch == '\r') continue;
                    out.append(gpa, if ((ch < 0x20 and ch != '\n') or ch == 0x7f) ' ' else ch) catch return null;
                };
                if (objAt(r, "footer")) |f| if (arrayAt(f, "runs")) |fr| if (fr.len > 0) if (textOfRun(fr[0])) |src| {
                    out.print(gpa, "\n\n{s}", .{src}) catch {};
                };
                return out.toOwnedSlice(gpa) catch null;
            }
            var it = obj.iterator();
            while (it.next()) |e| if (lyricsText(gpa, e.value_ptr.*)) |t| return t;
        },
        .array => |arr| for (arr.items) |x| if (lyricsText(gpa, x)) |t| return t,
        else => {},
    }
    return null;
}

pub fn merge(arena: std.mem.Allocator, have: []const Track, more: []const Track) ![]Track {
    var out: std.ArrayList(Track) = .empty;
    try out.appendSlice(arena, have);
    for (more) |t| if (!contains(out.items, t)) try out.append(arena, t);
    return out.toOwnedSlice(arena);
}

const MoreKind = enum { none, search, browse };

fn fetchPage(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    max: usize,
    rich: bool,
    more_kind: MoreKind,
) !Page {
    const resp = try postJson(arena, gpa, io, url, body);
    defer gpa.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});
    return pageOf(arena, parsed.value, max, rich, more_kind);
}

fn pageOf(arena: std.mem.Allocator, root: std.json.Value, max: usize, rich: bool, more_kind: MoreKind) !Page {
    var col: Collector = .{ .arena = arena, .max = max, .rich = rich };
    const inherited = if (rich) (pageTitle(root) orelse "") else "";
    try col.walk(root, inherited);
    if (col.out.items.len == 0) return error.NoResult;

    var page: Page = .{ .tracks = try col.out.toOwnedSlice(arena) };
    if (continuationOf(root)) |tok| {
        const t = try arena.dupe(u8, tok);
        page.more = switch (more_kind) {
            .none => .none,
            .search => .{ .search = t },
            .browse => .{ .browse = t },
        };
    }
    return page;
}

fn continuationBody(arena: std.mem.Allocator, token: []const u8) ![]u8 {
    const tok = try std.json.Stringify.valueAlloc(arena, token, .{});
    return std.fmt.allocPrint(arena, "{{{s},\"continuation\":{s}}}", .{ CLIENT_CONTEXT, tok });
}

fn continuationOf(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .object => |obj| {
            if (obj.get("nextContinuationData")) |n| if (stringAt(n, "continuation")) |t| return t;
            if (obj.get("continuationCommand")) |n| if (stringAt(n, "token")) |t| return t;
            var it = obj.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "reloadContinuationData")) continue;
                if (continuationOf(e.value_ptr.*)) |t| return t;
            }
        },
        .array => |arr| for (arr.items) |item| if (continuationOf(item)) |t| return t,
        else => {},
    }
    return null;
}

fn pageTitle(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const header = root.object.get("header") orelse return null;
    if (header != .object) return null;
    var it = header.object.iterator();
    while (it.next()) |e| {
        const title = objAt(e.value_ptr.*, "title") orelse continue;
        const runs = arrayAt(title, "runs") orelse continue;
        if (runs.len > 0) if (textOfRun(runs[0])) |t| return t;
    }
    return null;
}

pub fn contains(rows: []const Track, t: Track) bool {
    const key = if (t.video_id.len > 0) t.video_id else t.browse_id;
    if (key.len == 0) return false;
    for (rows) |r| {
        const k = if (r.video_id.len > 0) r.video_id else r.browse_id;
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

const Collector = struct {
    arena: std.mem.Allocator,
    max: usize,
    rich: bool = false,
    out: std.ArrayList(Track) = .empty,

    fn full(self: *const Collector) bool {
        return self.out.items.len >= self.max;
    }

    fn add(self: *Collector, t: Track) !void {
        if (self.full() or contains(self.out.items, t)) return;
        try self.out.append(self.arena, t);
    }

    fn walk(self: *Collector, v: std.json.Value, inherited: []const u8) std.mem.Allocator.Error!void {
        if (self.full()) return;
        switch (v) {
            .object => |obj| {
                var artist_ctx = inherited;
                if (obj.get("musicCardShelfRenderer")) |card| {
                    if (cardArtist(card)) |a| artist_ctx = a;
                    if (extractTile(self.arena, card, inherited)) |t| try self.add(t);
                }
                if (obj.get("musicResponsiveListItemRenderer")) |item| {
                    if (extractTrack(self.arena, item, artist_ctx)) |t| try self.add(t);
                }
                if (self.rich) if (obj.get("musicTwoRowItemRenderer")) |item| {
                    if (extractTile(self.arena, item, artist_ctx)) |t| try self.add(t);
                };
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try self.walk(entry.value_ptr.*, artist_ctx);
                    if (self.full()) return;
                    if (self.rich and isShelfKey(entry.key_ptr.*)) {
                        if (shelfLink(self.arena, entry.value_ptr.*)) |t| try self.add(t);
                    }
                }
            },
            .array => |arr| for (arr.items) |item| {
                try self.walk(item, inherited);
                if (self.full()) return;
            },
            else => {},
        }
    }
};

fn collectTracks(
    arena: std.mem.Allocator,
    v: std.json.Value,
    out: *std.ArrayList(Track),
    max: usize,
    inherited: []const u8,
) !void {
    var col: Collector = .{ .arena = arena, .max = max, .out = out.* };
    try col.walk(v, inherited);
    out.* = col.out;
}

fn isShelfKey(k: []const u8) bool {
    return std.mem.eql(u8, k, "musicShelfRenderer") or std.mem.eql(u8, k, "musicCarouselShelfRenderer");
}

fn shelfLink(arena: std.mem.Allocator, shelf: std.json.Value) ?Track {
    const title_node = objAt(shelf, "title") orelse
        (objAt(objAt(objAt(shelf, "header") orelse return null, "musicCarouselShelfBasicHeaderRenderer") orelse return null, "title") orelse return null);
    const runs = arrayAt(title_node, "runs") orelse return null;
    if (runs.len == 0) return null;
    const title = textOfRun(runs[0]) orelse return null;

    const nav = objAt(shelf, "bottomEndpoint") orelse
        (if (objAt(shelf, "header")) |h| navOfMoreButton(h) else null) orelse return null;
    const bid = stringAt(objAt(nav, "browseEndpoint") orelse return null, "browseId") orelse return null;

    return .{
        .browse_id = txt.sanitizeDupe(arena, bid) orelse return null,
        .title = txt.sanitizeDupe(arena, title) orelse return null,
        .artist = "show all",
        .kind = "More",
    };
}

fn navOfMoreButton(header: std.json.Value) ?std.json.Value {
    const basic = objAt(header, "musicCarouselShelfBasicHeaderRenderer") orelse return null;
    const button = objAt(objAt(basic, "moreContentButton") orelse return null, "buttonRenderer") orelse return null;
    return objAt(button, "navigationEndpoint");
}

fn extractTile(arena: std.mem.Allocator, tile: std.json.Value, inherited: []const u8) ?Track {
    const title_runs = arrayAt(objAt(tile, "title") orelse return null, "runs") orelse return null;
    if (title_runs.len == 0) return null;
    const title = textOfRun(title_runs[0]) orelse return null;
    const nav = objAt(tile, "navigationEndpoint") orelse objAt(title_runs[0], "navigationEndpoint") orelse return null;

    var video_id: []const u8 = "";
    var browse_id: []const u8 = "";
    if (objAt(nav, "watchEndpoint")) |we| video_id = stringAt(we, "videoId") orelse "";
    if (objAt(nav, "browseEndpoint")) |be| browse_id = stringAt(be, "browseId") orelse "";
    if (video_id.len == 0 and browse_id.len == 0) return null;

    const sub: []std.json.Value = if (objAt(tile, "subtitle")) |s| arrayAt(s, "runs") orelse &.{} else &.{};
    var kind: []const u8 = if (video_id.len > 0)
        "Video"
    else if (std.mem.startsWith(u8, browse_id, "UC"))
        "Artist"
    else if (std.mem.startsWith(u8, browse_id, "MPRE"))
        "Album"
    else
        "Playlist";
    if (sub.len > 0) if (textOfRun(sub[0])) |t0| if (isKindWord(t0)) {
        kind = t0;
    };

    var linked: []const u8 = "";
    var detail: []const u8 = "";
    var year: []const u8 = "";
    var duration: u32 = 0;
    for (sub) |run| {
        const t = textOfRun(run) orelse continue;
        if (isKindWord(t) or std.mem.trim(u8, t, " \t•·").len == 0) continue;
        if (looksLikeDuration(t)) {
            duration = track_mod.parseDuration(t);
        } else if (isYear(t)) {
            year = t;
        } else if (linked.len == 0 and runHasNav(run)) {
            linked = t;
        } else if (detail.len == 0) {
            detail = t;
        }
    }

    const album_like = std.mem.eql(u8, kind, "Album") or std.mem.eql(u8, kind, "Single") or std.mem.eql(u8, kind, "EP");
    const who = if (std.mem.eql(u8, kind, "Artist"))
        detail
    else if (linked.len > 0)
        linked
    else if (inherited.len > 0)
        inherited
    else
        detail;
    const artist = if (album_like and year.len > 0)
        (if (who.len > 0) std.fmt.allocPrint(arena, "{s} · {s}", .{ who, year }) catch return null else year)
    else
        who;

    return .{
        .video_id = txt.sanitizeDupe(arena, video_id) orelse return null,
        .browse_id = txt.sanitizeDupe(arena, browse_id) orelse return null,
        .title = txt.sanitizeDupe(arena, title) orelse return null,
        .artist = txt.sanitizeDupe(arena, artist) orelse return null,
        .duration_s = duration,
        .kind = txt.sanitizeDupe(arena, kind) orelse return null,
    };
}

fn isYear(t: []const u8) bool {
    if (t.len != 4) return false;
    for (t) |b| if (b < '0' or b > '9') return false;
    return t[0] == '1' or t[0] == '2';
}

fn objAt(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .object) x else null;
}

fn arrayAt(v: std.json.Value, key: []const u8) ?[]std.json.Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .array) x.array.items else null;
}

fn stringAt(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
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
            if (std.mem.eql(u8, kind, "Artist")) artist = "";
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
    const words = [_][]const u8{ "Song", "Video", "Album", "Single", "EP", "Artist", "Playlist", "Episode", "Podcast", "Profile" };
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
        if (looksLikeDuration(t) or isYear(t)) continue;
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

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("Artist", out.items[0].kind);
    try testing.expectEqualStrings("UCRr1", out.items[0].browse_id);
    try testing.expectEqualStrings("80.5M monthly audience", out.items[0].artist);
    try testing.expectEqualStrings("Daft Punk", out.items[1].artist);
    try testing.expectEqual(@as(u32, 338), out.items[1].duration_s);
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

test "an artist page yields songs, a show-all link, then dated albums under the header name" {
    const json =
        \\{"header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"Coil"}]}}},
        \\ "contents":[
        \\  {"musicShelfRenderer":{"title":{"runs":[{"text":"Top songs"}]},
        \\    "bottomEndpoint":{"browseEndpoint":{"browseId":"VLOLAK1"}},
        \\    "contents":[{"musicResponsiveListItemRenderer":{
        \\      "playlistItemData":{"videoId":"v1"},
        \\      "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Going Up"}]}}}]}}]}},
        \\  {"musicCarouselShelfRenderer":{
        \\    "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Albums"}]},
        \\      "moreContentButton":{"buttonRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"MPADUC1"}}}}}},
        \\    "contents":[
        \\      {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Backwards"}]},"subtitle":{"runs":[{"text":"2016"}]},
        \\        "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_1"}}}},
        \\      {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Desert"}]},"subtitle":{"runs":[{"text":"Single"},{"text":" • "},{"text":"2022"}]},
        \\        "navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_2"}}}}]}},
        \\  {"musicCarouselShelfRenderer":{
        \\    "header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Fans might also like"}]}}},
        \\    "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Can"}]},"subtitle":{"runs":[{"text":"22K subscribers"}]},
        \\      "navigationEndpoint":{"browseEndpoint":{"browseId":"UC6j"}}}}]}}
        \\ ],
        \\ "nextContinuationData":{"continuation":"ignored"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const page = try pageOf(a, parsed.value, BROWSE_MAX, true, .none);
    const rows = page.tracks;

    try testing.expectEqual(@as(usize, 6), rows.len);
    try testing.expect(page.more == .none);
    try testing.expectEqualStrings("Going Up", rows[0].title);
    try testing.expectEqualStrings("Coil", rows[0].artist);
    try testing.expectEqualStrings("More", rows[1].kind);
    try testing.expectEqualStrings("VLOLAK1", rows[1].browse_id);
    try testing.expectEqualStrings("Album", rows[2].kind);
    try testing.expectEqualStrings("Coil · 2016", rows[2].artist);
    try testing.expectEqualStrings("Single", rows[3].kind);
    try testing.expectEqualStrings("Coil · 2022", rows[3].artist);
    try testing.expectEqualStrings("MPADUC1", rows[4].browse_id);
    try testing.expectEqualStrings("Artist", rows[5].kind);
    try testing.expectEqualStrings("22K subscribers", rows[5].artist);
}

test "search pages carry their continuation; an unfiltered search falls back to more songs" {
    const json =
        \\{"contents":[{"musicShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{
        \\  "playlistItemData":{"videoId":"v1"},
        \\  "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"A"}]}}}]}}],
        \\  "continuations":[{"nextContinuationData":{"continuation":"TOK1"}}]}}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const page = try pageOf(a, parsed.value, 50, false, .search);
    try testing.expectEqualStrings("TOK1", page.more.search);

    const cmd = try std.json.parseFromSlice(std.json.Value, a,
        \\{"x":{"reloadContinuationData":{"continuation":"NO"}},"y":{"continuationCommand":{"token":"TOK2"}}}
    , .{});
    try testing.expectEqualStrings("TOK2", continuationOf(cmd.value).?);

    const body = try continuationBody(a, "T\"OK");
    const pb = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    try testing.expectEqualStrings("T\"OK", pb.value.object.get("continuation").?.string);
}

test "merge drops rows already shown, keeping order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const have = [_]Track{ .{ .video_id = "a", .title = "A", .artist = "" }, .{ .browse_id = "MPRE1", .title = "B", .artist = "" } };
    const more = [_]Track{ .{ .video_id = "a", .title = "A2", .artist = "" }, .{ .video_id = "c", .title = "C", .artist = "" }, .{ .browse_id = "MPRE1", .title = "B2", .artist = "" } };
    const got = try merge(arena.allocator(), &have, &more);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("C", got[2].title);
}

test "an artist row never borrows the card's artist, and a year is never an artist" {
    const json =
        \\{"musicCardShelfRenderer":{
        \\  "title":{"runs":[{"text":"coil","navigationEndpoint":{"browseEndpoint":{"browseId":"UC1"}}}]},
        \\  "subtitle":{"runs":[{"text":"Artist"}]},
        \\  "contents":[
        \\    {"musicResponsiveListItemRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"UC2"}},
        \\      "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Coil"}]}}},
        \\        {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"}]}}}]}},
        \\    {"musicResponsiveListItemRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"MPRE9"}},
        \\      "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Gold"}]}}},
        \\        {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Album"},{"text":" • "},{"text":"2026"}]}}}]}}]
        \\}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    var out: std.ArrayList(Track) = .empty;
    try collectTracks(a, parsed.value, &out, 10, "");
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("", out.items[0].artist);
    try testing.expectEqualStrings("", out.items[1].artist);
    try testing.expectEqualStrings("coil", out.items[2].artist);
}

test "radio rows: byline splits into artist and album, seed and repeats dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"contents":{"playlistPanelRenderer":{"contents":[
        \\{"playlistPanelVideoRenderer":{"videoId":"seed","title":{"runs":[{"text":"Seed"}]}}},
        \\{"playlistPanelVideoRenderer":{"videoId":"v1","title":{"runs":[{"text":"Blood"}]},
        \\ "longBylineText":{"runs":[{"text":"Tove Lo"},{"text":" & "},{"text":"GTA"},{"text":" • "},{"text":"The Album"},{"text":" • "},{"text":"2026"}]},
        \\ "lengthText":{"runs":[{"text":"2:42"}]}}},
        \\{"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":{"videoId":"v2","title":{"runs":[{"text":"Clip"}]},
        \\ "longBylineText":{"runs":[{"text":"Someone"},{"text":" • "},{"text":"2024"}]}}}}},
        \\{"playlistPanelVideoRenderer":{"videoId":"v1","title":{"runs":[{"text":"Blood"}]}}}
        \\]}}}
    ;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const rows = try radioOf(a, root, "seed", 10);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Tove Lo & GTA", rows[0].artist);
    try testing.expectEqualStrings("The Album", rows[0].album);
    try testing.expectEqual(@as(u32, 162), rows[0].duration_s);
    try testing.expectEqualStrings("Someone", rows[1].artist);
    try testing.expectEqualStrings("", rows[1].album);
    try testing.expectError(error.NoResult, radioOf(a, root, "seed", 0));
}

test "lyrics: browse id from the watch tabs, text without CR or control bytes, source last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const next = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tabs":[{"tabRenderer":{"title":"Up next"}},{"tabRenderer":{"title":"Lyrics","endpoint":{"browseEndpoint":{"browseId":"MPLYt_abc"}}}},
        \\{"tabRenderer":{"endpoint":{"browseEndpoint":{"browseId":"MPTRt_abc"}}}}]}
    , .{});
    try testing.expectEqualStrings("MPLYt_abc", lyricsBrowseId(next).?);
    try testing.expect(lyricsBrowseId(.null) == null);

    const page = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"contents":{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"Bad boy\r\nOld \u001b[31mtown"}]},
        \\"footer":{"runs":[{"text":"Source: LyricFind"}]}}}}
    , .{});
    const text = lyricsText(testing.allocator, page).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Bad boy\nOld  [31mtown\n\nSource: LyricFind", text);
}
