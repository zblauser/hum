const std = @import("std");
const txt = @import("text.zig");
const track_mod = @import("track.zig");
const fsutil = @import("fsutil.zig");
const proc = @import("proc.zig");

/// One playable episode from a feed.
pub const Episode = struct {
    title: []const u8,
    /// The enclosure. Always http(s) — see `validUrl`.
    url: []const u8,
    published: []const u8 = "",
    duration_s: u32 = 0,
};

pub const Feed = struct {
    title: []const u8 = "",
    episodes: []Episode = &.{},
};

// A feed is a stranger's XML; these are the ceilings it cannot exceed.
pub const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_ITEMS: usize = 500;
const MAX_TEXT: usize = 512;
const MAX_URL: usize = 2048;
const MAX_ENTITY: usize = 12;

/// Deliberately not a general XML parser: it scans for the few elements a feed must have and ignores the rest. No DTDs, entity definitions, namespaces, recursion or external references, so expansion bombs have nothing to expand.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ?Feed {
    if (bytes.len == 0 or bytes.len > MAX_BYTES) return null;
    const is_rss = std.mem.indexOf(u8, bytes, "<item") != null;
    const is_atom = std.mem.indexOf(u8, bytes, "<entry") != null;
    if (!is_rss and !is_atom) return null;

    const open = if (is_rss) "<item" else "<entry";
    const close = if (is_rss) "</item>" else "</entry>";

    var out: std.ArrayList(Episode) = .empty;
    var feed_title: []const u8 = "";

    // the channel title precedes the first item
    const first_item = std.mem.indexOf(u8, bytes, open) orelse return null;
    if (tagText(bytes[0..first_item], "title")) |t| {
        feed_title = clean(arena, t) orelse "";
    }

    var cursor = first_item;
    var seen: usize = 0;
    while (seen < MAX_ITEMS) : (seen += 1) {
        const start = std.mem.indexOfPos(u8, bytes, cursor, open) orelse break;
        const end_rel = std.mem.indexOfPos(u8, bytes, start, close) orelse break;
        const chunk = bytes[start..end_rel];
        cursor = end_rel + close.len;

        if (episodeOf(arena, chunk)) |ep| out.append(arena, ep) catch break;
    }

    return .{ .title = feed_title, .episodes = out.items };
}

fn episodeOf(arena: std.mem.Allocator, chunk: []const u8) ?Episode {
    const url = enclosureUrl(chunk) orelse return null;
    if (!validUrl(url)) return null;

    const title = tagText(chunk, "title") orelse "(untitled)";
    var ep: Episode = .{
        .title = clean(arena, title) orelse return null,
        .url = arena.dupe(u8, url) catch return null,
    };
    if (tagText(chunk, "pubDate") orelse tagText(chunk, "published")) |d| {
        ep.published = clean(arena, d) orelse "";
    }
    if (tagText(chunk, "itunes:duration")) |d| {
        ep.duration_s = parseDuration(std.mem.trim(u8, d, " \t\r\n"));
    }
    return ep;
}

/// RSS uses <enclosure url>; Atom uses a link with rel="enclosure" or an audio type.
fn enclosureUrl(chunk: []const u8) ?[]const u8 {
    if (findTag(chunk, "<enclosure")) |tag| {
        if (attr(tag, "url")) |u| return u;
    }
    var pos: usize = 0;
    while (findTagPos(chunk, "<link", pos)) |found| {
        pos = found.end;
        const is_enclosure = if (attr(found.tag, "rel")) |rel|
            std.mem.eql(u8, rel, "enclosure")
        else
            false;
        const is_audio = if (attr(found.tag, "type")) |ty|
            std.mem.startsWith(u8, ty, "audio/")
        else
            false;
        if (is_enclosure or is_audio) {
            if (attr(found.tag, "href")) |h| return h;
        }
    }
    return null;
}

const Found = struct { tag: []const u8, end: usize };

fn findTagPos(hay: []const u8, name: []const u8, from: usize) ?Found {
    if (from >= hay.len) return null;
    const at = std.mem.indexOfPos(u8, hay, from, name) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, hay, at, '>') orelse return null;
    return .{ .tag = hay[at..gt], .end = gt + 1 };
}

fn findTag(hay: []const u8, name: []const u8) ?[]const u8 {
    const f = findTagPos(hay, name, 0) orelse return null;
    return f.tag;
}

/// name="value" or name='value', bounded. Returns a slice of `tag`.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        const at = std.mem.indexOfPos(u8, tag, i, name) orelse return null;
        i = at + name.len;
        // must be a whole attribute name, not a suffix of another
        if (at == 0 or (tag[at - 1] != ' ' and tag[at - 1] != '\t')) continue;
        var j = i;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len) return null;
        const quote = tag[j];
        if (quote != '"' and quote != '\'') return null;
        j += 1;
        const close = std.mem.indexOfScalarPos(u8, tag, j, quote) orelse return null;
        if (close - j > MAX_URL) return null;
        return tag[j..close];
    }
    return null;
}

/// Text of the first <name> element, CDATA unwrapped. Never crosses into a nested element.
fn tagText(hay: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (name.len + 2 > buf.len) return null;
    const open = std.fmt.bufPrint(&buf, "<{s}", .{name}) catch return null;

    var from: usize = 0;
    while (findTagPos(hay, open, from)) |found| {
        from = found.end;
        // "<title" must not match "<titleFoo"
        const after = found.tag[open.len..];
        if (after.len > 0 and after[0] != ' ' and after[0] != '\t' and after[0] != '/') continue;
        if (std.mem.endsWith(u8, found.tag, "/")) continue; // self-closing: no text

        var close_buf: [64]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
        const end = std.mem.indexOfPos(u8, hay, found.end, close) orelse return null;
        var text = hay[found.end..end];

        if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t\r\n"), "<![CDATA[")) {
            const s = std.mem.indexOf(u8, text, "<![CDATA[").? + "<![CDATA[".len;
            const e = std.mem.indexOfPos(u8, text, s, "]]>") orelse return null;
            text = text[s..e];
        }
        if (text.len > MAX_TEXT * 4) text = text[0 .. MAX_TEXT * 4];
        return text;
    }
    return null;
}

/// Only the five predefined entities and bounded numeric refs; definitions are never looked up.
fn decodeEntities(arena: std.mem.Allocator, s: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, s.len) catch return null;

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            out.append(arena, s[i]) catch return null;
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, s, i, ';') orelse {
            out.append(arena, s[i]) catch return null;
            i += 1;
            continue;
        };
        if (semi - i > MAX_ENTITY) {
            out.append(arena, s[i]) catch return null;
            i += 1;
            continue;
        }
        const name = s[i + 1 .. semi];
        const replacement: ?[]const u8 = if (std.mem.eql(u8, name, "amp"))
            "&"
        else if (std.mem.eql(u8, name, "lt"))
            "<"
        else if (std.mem.eql(u8, name, "gt"))
            ">"
        else if (std.mem.eql(u8, name, "quot"))
            "\""
        else if (std.mem.eql(u8, name, "apos"))
            "'"
        else
            null;

        if (replacement) |r| {
            out.appendSlice(arena, r) catch return null;
            i = semi + 1;
            continue;
        }
        if (name.len > 1 and name[0] == '#') {
            const digits = if (name[1] == 'x' or name[1] == 'X') name[2..] else name[1..];
            const base: u8 = if (name[1] == 'x' or name[1] == 'X') 16 else 10;
            if (std.fmt.parseInt(u21, digits, base)) |cp| {
                var enc: [4]u8 = undefined;
                if (std.unicode.utf8Encode(cp, &enc)) |n| {
                    out.appendSlice(arena, enc[0..n]) catch return null;
                    i = semi + 1;
                    continue;
                } else |_| {}
            } else |_| {}
        }
        // unknown entity: keep the text, expand nothing
        out.append(arena, s[i]) catch return null;
        i += 1;
    }
    return out.items;
}

/// Decode, sanitize, cap: feed text is remote text like any other.
fn clean(arena: std.mem.Allocator, s: []const u8) ?[]const u8 {
    const decoded = decodeEntities(arena, s) orelse return null;
    const safe = txt.sanitize(arena, decoded) catch return null;
    const trimmed = std.mem.trim(u8, safe, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len <= MAX_TEXT) return trimmed;
    var end: usize = MAX_TEXT;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    return trimmed[0..end];
}

/// Handed to mpv, so http(s) only — never a path, a scheme, or anything quotable.
pub fn validUrl(u: []const u8) bool {
    if (u.len == 0 or u.len > MAX_URL) return false;
    if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) return false;
    for (u) |b| {
        if (b <= 0x20 or b >= 0x7f) return false;
        if (b == '"' or b == '\'' or b == '\\') return false;
    }
    return true;
}

/// `<itunes:duration>` is seconds, or mm:ss, or hh:mm:ss.
fn parseDuration(s: []const u8) u32 {
    if (std.mem.indexOfScalar(u8, s, ':') != null) return track_mod.parseDuration(s);
    return std.fmt.parseInt(u32, s, 10) catch 0;
}

/// Episode → queue row.
pub fn toTrack(ep: Episode, feed_title: []const u8) track_mod.Track {
    return .{
        .source = .url,
        .uri = ep.url,
        .title = ep.title,
        .artist = feed_title,
        .duration_s = ep.duration_s,
        .kind = "Episode",
    };
}

// --------------------------------------------------------- subscriptions

/// One subscribed feed: the URL we fetch and the title it reported.
pub const Sub = struct { url: []const u8, title: []const u8 = "" };

/// $XDG_DATA_HOME/hum/feeds — data worth keeping, so not the cache.
pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![:0]const u8 {
    return fsutil.xdgPath(arena, env, "XDG_DATA_HOME", ".local/share", "feeds");
}

pub fn loadSubs(arena: std.mem.Allocator, file_path: []const u8) []Sub {
    const bytes = fsutil.readFileAlloc(arena, file_path) orelse return &.{};
    var out: std.ArrayList(Sub) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const url = f.next() orelse continue;
        if (!validUrl(url)) continue; // a hand-edited file is still input
        const title = f.next() orelse "";
        out.append(arena, .{ .url = url, .title = title }) catch return out.items;
    }
    return out.items;
}

pub fn saveSubs(arena: std.mem.Allocator, file_path: []const u8, subs: []const Sub) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (subs) |sub| {
        if (!validUrl(sub.url)) continue;
        try buf.print(arena, "{s}\t{s}\n", .{ sub.url, try txt.sanitize(arena, sub.title) });
    }
    return fsutil.writeFile(arena, file_path, buf.items);
}

/// Redirects followed (feed hosts move), time-boxed, size-capped, URL validated before argv.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    if (!validUrl(url)) return error.BadUrl;
    return proc.runCapture(gpa, io, &.{
        "curl",          "-sSL",
        "--max-time",    "25",
        "--max-filesize", "16777216",
        "-H",            "User-Agent: hum/podcast",
        "--",            url,
    });
}

const testing = std.testing;

const RSS =
    \\<?xml version="1.0"?>
    \\<rss version="2.0"><channel>
    \\<title>Some Podcast</title>
    \\<item>
    \\  <title>Episode One &amp; Only</title>
    \\  <pubDate>Tue, 01 Apr 2025 10:00:00 GMT</pubDate>
    \\  <itunes:duration>1:02:03</itunes:duration>
    \\  <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" length="123"/>
    \\</item>
    \\<item>
    \\  <title><![CDATA[Episode Two <with> markup]]></title>
    \\  <itunes:duration>95</itunes:duration>
    \\  <enclosure url="https://example.com/ep2.mp3" type="audio/mpeg"/>
    \\</item>
    \\</channel></rss>
;

test "rss: channel title, episodes, entities, CDATA, durations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f = parse(a, RSS).?;
    try testing.expectEqualStrings("Some Podcast", f.title);
    try testing.expectEqual(@as(usize, 2), f.episodes.len);

    try testing.expectEqualStrings("Episode One & Only", f.episodes[0].title);
    try testing.expectEqualStrings("https://example.com/ep1.mp3", f.episodes[0].url);
    try testing.expectEqual(@as(u32, 3723), f.episodes[0].duration_s);
    try testing.expect(f.episodes[0].published.len > 0);

    try testing.expectEqualStrings("Episode Two <with> markup", f.episodes[1].title);
    try testing.expectEqual(@as(u32, 95), f.episodes[1].duration_s); // bare seconds
}

test "atom entries with an audio link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const atom =
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Atom Cast</title>
        \\<entry>
        \\  <title>First</title>
        \\  <published>2025-04-01T10:00:00Z</published>
        \\  <link rel="enclosure" type="audio/mpeg" href="https://example.com/a1.mp3"/>
        \\</entry>
        \\</feed>
    ;
    const f = parse(a, atom).?;
    try testing.expectEqualStrings("Atom Cast", f.title);
    try testing.expectEqual(@as(usize, 1), f.episodes.len);
    try testing.expectEqualStrings("https://example.com/a1.mp3", f.episodes[0].url);
}

test "an episode with no usable enclosure is dropped, not guessed at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const feed =
        \\<rss><channel><title>T</title>
        \\<item><title>No audio here</title><link>https://example.com/page.html</link></item>
        \\<item><title>Good</title><enclosure url="https://example.com/ok.mp3"/></item>
        \\</channel></rss>
    ;
    const f = parse(a, feed).?;
    try testing.expectEqual(@as(usize, 1), f.episodes.len);
    try testing.expectEqualStrings("Good", f.episodes[0].title);
}

test "hostile URLs never reach the player" {
    try testing.expect(validUrl("https://example.com/a.mp3"));
    try testing.expect(validUrl("http://example.com/a.mp3"));
    try testing.expect(!validUrl("javascript:alert(1)"));
    try testing.expect(!validUrl("file:///etc/passwd"));
    try testing.expect(!validUrl("/etc/passwd"));
    try testing.expect(!validUrl("https://example.com/a b.mp3")); // space
    try testing.expect(!validUrl("https://example.com/\"quoted\".mp3"));
    try testing.expect(!validUrl("https://example.com/\x00.mp3"));
    try testing.expect(!validUrl(""));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed =
        \\<rss><channel><title>T</title>
        \\<item><title>Evil</title><enclosure url="javascript:alert(1)"/></item>
        \\<item><title>Also evil</title><enclosure url="file:///etc/passwd"/></item>
        \\</channel></rss>
    ;
    const f = parse(a, feed).?;
    try testing.expectEqual(@as(usize, 0), f.episodes.len);
}

test "entity bombs expand to nothing because definitions are never read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // billion-laughs shape plus an external-entity attempt
    const feed =
        \\<?xml version="1.0"?>
        \\<!DOCTYPE rss [
        \\  <!ENTITY lol "lol">
        \\  <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        \\  <!ENTITY xxe SYSTEM "file:///etc/passwd">
        \\]>
        \\<rss><channel><title>Bomb</title>
        \\<item><title>&lol2; &xxe;</title><enclosure url="https://example.com/x.mp3"/></item>
        \\</channel></rss>
    ;
    const f = parse(a, feed).?;
    try testing.expectEqual(@as(usize, 1), f.episodes.len);
    // references survive as literal text; nothing was expanded or fetched
    try testing.expectEqualStrings("&lol2; &xxe;", f.episodes[0].title);
}

test "titles carrying terminal escapes and tabs are neutralized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const feed = "<rss><channel><title>T</title><item><title>evil\x1b[2Jname\there</title>" ++
        "<enclosure url=\"https://example.com/a.mp3\"/></item></channel></rss>";
    const f = parse(a, feed).?;
    try testing.expectEqualStrings("evil [2Jname here", f.episodes[0].title);
}

test "numeric character references decode, bad ones stay literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const feed = "<rss><channel><title>T</title><item><title>caf&#233; &#x41; &#999999999;</title>" ++
        "<enclosure url=\"https://example.com/a.mp3\"/></item></channel></rss>";
    const f = parse(a, feed).?;
    try testing.expectEqualStrings("café A &#999999999;", f.episodes[0].title);
}

test "junk, truncation and absurd size are all refused quietly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(parse(a, "") == null);
    try testing.expect(parse(a, "not xml at all") == null);
    try testing.expect(parse(a, "<html><body>nope</body></html>") == null);

    // every truncation must return, not crash
    var n: usize = 0;
    while (n <= RSS.len) : (n += 1) _ = parse(a, RSS[0..n]);
}

test "item count is capped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "<rss><channel><title>Many</title>");
    var i: usize = 0;
    while (i < MAX_ITEMS + 50) : (i += 1) {
        try buf.appendSlice(a, "<item><title>x</title><enclosure url=\"https://e.com/a.mp3\"/></item>");
    }
    try buf.appendSlice(a, "</channel></rss>");

    const f = parse(a, buf.items).?;
    try testing.expectEqual(MAX_ITEMS, f.episodes.len);
}

test "toTrack yields a playable url row" {
    const t = toTrack(.{ .title = "Ep", .url = "https://e.com/a.mp3", .duration_s = 60 }, "Show");
    try testing.expectEqual(track_mod.Source.url, t.source);
    try testing.expect(t.isPlayable());
    try testing.expectEqualStrings("Show", t.artist);
    try testing.expectEqualStrings("Episode", t.kind);
}

test "subscription file round-trips and rejects hand-edited junk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try a.dupeZ(u8, "/tmp/hum_feeds_XXXXXX");
    const fd = fsutil.c.mkstemp(p.ptr);
    try testing.expect(fd >= 0);
    _ = fsutil.c.close(fd);
    defer _ = fsutil.c.unlink(p.ptr);

    try saveSubs(a, p, &[_]Sub{
        .{ .url = "https://example.com/feed.xml", .title = "Some\tPodcast" },
        .{ .url = "javascript:alert(1)", .title = "nope" }, // never written
    });

    const back = loadSubs(a, p);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings("https://example.com/feed.xml", back[0].url);
    try testing.expectEqualStrings("Some Podcast", back[0].title); // tab neutralized

    // a hand-edited file can contain anything; bad rows are skipped
    try fsutil.writeFile(a, p, "file:///etc/passwd\tevil\n# comment\n\nhttps://ok.com/f.xml\tOK\n");
    const back2 = loadSubs(a, p);
    try testing.expectEqual(@as(usize, 1), back2.len);
    try testing.expectEqualStrings("https://ok.com/f.xml", back2[0].url);
}
