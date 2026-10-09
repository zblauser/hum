const std = @import("std");
const txt = @import("text.zig");
const fsutil = @import("fsutil.zig");

pub const Tags = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    track_no: u16 = 0,
    duration_s: u32 = 0,
};

const HEAD_BYTES: usize = 1024 * 1024;
const MAX_TEXT: usize = 512;
const MAX_FRAMES: usize = 512;
const MAX_ATOM_DEPTH: u8 = 8;

pub fn read(arena: std.mem.Allocator, file_path: []const u8, total_size: u64) ?Tags {
    const bytes = fsutil.readCappedAlloc(arena, file_path, HEAD_BYTES) orelse return null;
    return parse(arena, bytes, total_size);
}

pub fn parse(arena: std.mem.Allocator, bytes: []const u8, total_size: u64) ?Tags {
    if (bytes.len < 12) return null;
    if (std.mem.startsWith(u8, bytes, "ID3")) return parseId3(arena, bytes, total_size);
    if (bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0) {
        const secs = mp3Duration(bytes, 0, total_size);
        return if (secs > 0) Tags{ .duration_s = secs } else null;
    }
    if (std.mem.startsWith(u8, bytes, "fLaC")) return parseFlac(arena, bytes);
    if (std.mem.startsWith(u8, bytes, "OggS")) return parseOgg(arena, bytes);
    if (std.mem.eql(u8, bytes[4..8], "ftyp")) return parseMp4(arena, bytes);
    return null;
}

const Cursor = struct {
    b: []const u8,
    i: usize = 0,

    fn remaining(self: Cursor) usize {
        return self.b.len - self.i;
    }

    fn take(self: *Cursor, n: usize) ?[]const u8 {
        if (n > self.remaining()) return null;
        const out = self.b[self.i .. self.i + n];
        self.i += n;
        return out;
    }

    fn skip(self: *Cursor, n: usize) bool {
        if (n > self.remaining()) return false;
        self.i += n;
        return true;
    }

    fn byte(self: *Cursor) ?u8 {
        const s = self.take(1) orelse return null;
        return s[0];
    }

    fn u16be(self: *Cursor) ?u16 {
        const s = self.take(2) orelse return null;
        return std.mem.readInt(u16, s[0..2], .big);
    }

    fn u32be(self: *Cursor) ?u32 {
        const s = self.take(4) orelse return null;
        return std.mem.readInt(u32, s[0..4], .big);
    }

    fn u64be(self: *Cursor) ?u64 {
        const s = self.take(8) orelse return null;
        return std.mem.readInt(u64, s[0..8], .big);
    }

    fn u32le(self: *Cursor) ?u32 {
        const s = self.take(4) orelse return null;
        return std.mem.readInt(u32, s[0..4], .little);
    }

    fn u24be(self: *Cursor) ?u32 {
        const s = self.take(3) orelse return null;
        return (@as(u32, s[0]) << 16) | (@as(u32, s[1]) << 8) | s[2];
    }
};

fn store(arena: std.mem.Allocator, dst: *[]const u8, raw: []const u8) void {
    if (dst.len > 0) return;
    if (raw.len == 0 or raw.len > MAX_TEXT * 4) return;
    const clean = txt.sanitize(arena, raw) catch return;
    const trimmed = std.mem.trim(u8, clean, " \t\r\n\x00");
    if (trimmed.len == 0) return;
    dst.* = if (trimmed.len > MAX_TEXT) truncateUtf8(trimmed, MAX_TEXT) else trimmed;
}

fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ---------------------------------------------------------------- ID3 (mp3)

fn parseId3(arena: std.mem.Allocator, bytes: []const u8, total_size: u64) ?Tags {
    var c: Cursor = .{ .b = bytes };
    _ = c.take(3) orelse return null;
    const major = c.byte() orelse return null;
    _ = c.byte() orelse return null;
    const flags = c.byte() orelse return null;
    const tag_size = syncsafe(&c) orelse return null;

    if (major != 3 and major != 4) return null;
    if (flags & 0x80 != 0) return null;

    const body_len = @min(tag_size, c.remaining());
    var body: Cursor = .{ .b = c.b[c.i .. c.i + body_len] };

    if (flags & 0x40 != 0 and !skipExtendedHeader(&body, major)) return null;

    var tags: Tags = .{};
    var seen: usize = 0;
    while (seen < MAX_FRAMES) : (seen += 1) {
        const id = body.take(4) orelse break;
        if (id[0] == 0) break;
        const size: usize = if (major == 4)
            syncsafe(&body) orelse break
        else
            body.u32be() orelse break;
        _ = body.u16be() orelse break;
        if (size == 0 or size > body.remaining()) break;
        const frame = body.take(size) orelse break;

        if (std.mem.eql(u8, id, "TIT2")) {
            if (id3Text(arena, frame)) |v| store(arena, &tags.title, v);
        } else if (std.mem.eql(u8, id, "TPE1")) {
            if (id3Text(arena, frame)) |v| store(arena, &tags.artist, v);
        } else if (std.mem.eql(u8, id, "TALB")) {
            if (id3Text(arena, frame)) |v| store(arena, &tags.album, v);
        } else if (std.mem.eql(u8, id, "TRCK")) {
            if (id3Text(arena, frame)) |v| tags.track_no = leadingNumber(v);
        } else if (std.mem.eql(u8, id, "TLEN")) {
            if (id3Text(arena, frame)) |v| {
                const ms = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \x00"), 10) catch 0;
                tags.duration_s = @intCast(@min(ms / 1000, std.math.maxInt(u32)));
            }
        }
    }
    if (tags.duration_s == 0) {
        tags.duration_s = mp3Duration(bytes, 10 + tag_size, total_size);
    }
    return tags;
}

// ------------------------------------------------------------ mp3 duration

const MPEG1_L3_BITRATE = [_]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
const MPEG2_L3_BITRATE = [_]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };
const SAMPLE_RATES = [_]u32{ 44100, 48000, 32000, 0 };

const Frame = struct {
    mpeg1: bool,
    mono: bool,
    kbps: u32,
    sample_rate: u32,
    len: usize,
};

fn frameAt(bytes: []const u8, i: usize) ?Frame {
    if (i + 4 > bytes.len) return null;
    const h = bytes[i .. i + 4];
    if (h[0] != 0xFF or (h[1] & 0xE0) != 0xE0) return null;

    const version: u2 = @intCast((h[1] >> 3) & 0x03);
    const layer: u2 = @intCast((h[1] >> 1) & 0x03);
    if (layer != 1 or version == 1) return null;

    var sample_rate = SAMPLE_RATES[(h[2] >> 2) & 0x03];
    if (sample_rate == 0) return null;
    if (version == 2) sample_rate /= 2;
    if (version == 0) sample_rate /= 4;

    const mpeg1 = version == 3;
    const bitrate_index = (h[2] >> 4) & 0x0F;
    const kbps = if (mpeg1) MPEG1_L3_BITRATE[bitrate_index] else MPEG2_L3_BITRATE[bitrate_index];
    if (kbps == 0) return null;

    const padding: usize = (h[2] >> 1) & 0x01;
    const coeff: usize = if (mpeg1) 144 else 72;
    return .{
        .mpeg1 = mpeg1,
        .mono = ((h[3] >> 6) & 0x03) == 3,
        .kbps = kbps,
        .sample_rate = sample_rate,
        .len = coeff * kbps * 1000 / sample_rate + padding,
    };
}

fn mp3Duration(bytes: []const u8, audio_start: usize, total_size: u64) u32 {
    const at = findFrame(bytes, audio_start) orelse return 0;
    const f = frameAt(bytes, at).?;
    const samples_per_frame: u64 = if (f.mpeg1) 1152 else 576;

    const xing_at = at + 4 + @as(usize, if (f.mpeg1)
        (if (f.mono) 17 else 32)
    else
        (if (f.mono) 9 else 17));
    if (xing_at + 12 <= bytes.len) {
        const tag = bytes[xing_at .. xing_at + 4];
        if (std.mem.eql(u8, tag, "Xing") or std.mem.eql(u8, tag, "Info")) {
            const flags = std.mem.readInt(u32, bytes[xing_at + 4 ..][0..4], .big);
            if (flags & 1 != 0) {
                const frames = std.mem.readInt(u32, bytes[xing_at + 8 ..][0..4], .big);
                const secs = (@as(u64, frames) * samples_per_frame) / f.sample_rate;
                return @intCast(@min(secs, std.math.maxInt(u32)));
            }
        }
    }

    if (total_size <= at) return 0;
    const secs = ((total_size - at) * 8) / (@as(u64, f.kbps) * 1000);
    return @intCast(@min(secs, std.math.maxInt(u32)));
}

fn findFrame(bytes: []const u8, from: usize) ?usize {
    const start = @min(from, bytes.len);
    const limit = @min(bytes.len, start + 64 * 1024);
    var i = start;
    while (i < limit) : (i += 1) {
        const f = frameAt(bytes, i) orelse continue;
        const next = i + f.len;
        if (next + 4 > bytes.len) return i;
        const g = frameAt(bytes, next) orelse continue;
        if (g.mpeg1 == f.mpeg1 and g.sample_rate == f.sample_rate) return i;
    }
    return null;
}

fn syncsafe(c: *Cursor) ?usize {
    const s = c.take(4) orelse return null;
    var out: usize = 0;
    for (s) |b| {
        if (b & 0x80 != 0) return null;
        out = (out << 7) | (b & 0x7f);
    }
    return out;
}

fn skipExtendedHeader(c: *Cursor, major: u8) bool {
    if (major == 4) {
        const size = syncsafe(c) orelse return false;
        if (size < 4) return false;
        return c.skip(size - 4);
    }
    const size = c.u32be() orelse return false;
    return c.skip(size);
}

fn id3Text(arena: std.mem.Allocator, frame: []const u8) ?[]const u8 {
    if (frame.len < 2) return null;
    const body = frame[1..];
    return switch (frame[0]) {
        0 => latin1ToUtf8(arena, body),
        1 => utf16ToUtf8(arena, body, null),
        2 => utf16ToUtf8(arena, body, .big),
        3 => body,
        else => null,
    };
}

fn leadingNumber(s: []const u8) u16 {
    var out: u32 = 0;
    for (s) |b| {
        if (b < '0' or b > '9') break;
        out = out * 10 + (b - '0');
        if (out > std.math.maxInt(u16)) return 0;
    }
    return @intCast(out);
}

fn latin1ToUtf8(arena: std.mem.Allocator, s: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, s.len) catch return null;
    for (s) |b| {
        if (b == 0) break;
        if (b < 0x80) {
            out.append(arena, b) catch return null;
        } else {
            out.appendSlice(arena, &.{ 0xC0 | (b >> 6), 0x80 | (b & 0x3F) }) catch return null;
        }
    }
    return out.items;
}

fn utf16ToUtf8(arena: std.mem.Allocator, s: []const u8, forced: ?std.builtin.Endian) ?[]const u8 {
    var body = s;
    var endian: std.builtin.Endian = forced orelse .little;
    if (forced == null) {
        if (body.len < 2) return null;
        if (body[0] == 0xFF and body[1] == 0xFE) {
            endian = .little;
            body = body[2..];
        } else if (body[0] == 0xFE and body[1] == 0xFF) {
            endian = .big;
            body = body[2..];
        } else return null;
    }
    if (body.len < 2) return null;

    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, body.len) catch return null;

    var i: usize = 0;
    var buf: [4]u8 = undefined;
    while (i + 1 < body.len) : (i += 2) {
        const unit = readUnit(body[i .. i + 2], endian);
        if (unit == 0) break;
        var cp: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 3 >= body.len) break;
            const low = readUnit(body[i + 2 .. i + 4], endian);
            if (low < 0xDC00 or low > 0xDFFF) break;
            cp = 0x10000 + ((@as(u21, unit - 0xD800) << 10) | (low - 0xDC00));
            i += 2;
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            break;
        }
        const n = std.unicode.utf8Encode(cp, &buf) catch break;
        out.appendSlice(arena, buf[0..n]) catch return null;
    }
    return out.items;
}

fn readUnit(pair: []const u8, endian: std.builtin.Endian) u16 {
    return switch (endian) {
        .little => @as(u16, pair[1]) << 8 | pair[0],
        .big => @as(u16, pair[0]) << 8 | pair[1],
    };
}

// ------------------------------------------------------------------- FLAC

fn parseFlac(arena: std.mem.Allocator, bytes: []const u8) ?Tags {
    var c: Cursor = .{ .b = bytes };
    _ = c.take(4) orelse return null;

    var tags: Tags = .{};
    var blocks: usize = 0;
    while (blocks < 128) : (blocks += 1) {
        const header = c.byte() orelse break;
        const last = header & 0x80 != 0;
        const kind = header & 0x7f;
        const len = c.u24be() orelse break;
        if (len > c.remaining()) break;
        const block = c.take(len) orelse break;

        switch (kind) {
            0 => readStreamInfo(block, &tags),
            4 => readVorbisComments(arena, block, &tags),
            else => {},
        }
        if (last) break;
    }
    return tags;
}

fn readStreamInfo(block: []const u8, tags: *Tags) void {
    if (block.len < 18) return;
    const packed_bits = std.mem.readInt(u64, block[10..18], .big);
    const rate: u64 = packed_bits >> 44;
    const total: u64 = packed_bits & 0xF_FFFF_FFFF;
    if (rate == 0 or total == 0) return;
    tags.duration_s = @intCast(@min(total / rate, std.math.maxInt(u32)));
}

fn readVorbisComments(arena: std.mem.Allocator, block: []const u8, tags: *Tags) void {
    var c: Cursor = .{ .b = block };
    const vendor_len = c.u32le() orelse return;
    if (vendor_len > c.remaining()) return;
    _ = c.skip(vendor_len);

    const count = c.u32le() orelse return;
    var seen: usize = 0;
    while (seen < @min(count, MAX_FRAMES)) : (seen += 1) {
        const len = c.u32le() orelse return;
        if (len > c.remaining()) return;
        const item = c.take(len) orelse return;
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const key = item[0..eq];
        const val = item[eq + 1 ..];

        if (eqlIgnoreCase(key, "TITLE")) {
            store(arena, &tags.title, val);
        } else if (eqlIgnoreCase(key, "ARTIST")) {
            store(arena, &tags.artist, val);
        } else if (eqlIgnoreCase(key, "ALBUM")) {
            store(arena, &tags.album, val);
        } else if (eqlIgnoreCase(key, "TRACKNUMBER")) {
            if (tags.track_no == 0) tags.track_no = leadingNumber(val);
        }
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

// -------------------------------------------------------------- Ogg / Opus

fn parseOgg(arena: std.mem.Allocator, bytes: []const u8) ?Tags {
    var tags: Tags = .{};
    if (std.mem.indexOf(u8, bytes, "OpusTags")) |at| {
        readVorbisComments(arena, bytes[at + "OpusTags".len ..], &tags);
        return tags;
    }
    if (std.mem.indexOf(u8, bytes, "\x03vorbis")) |at| {
        readVorbisComments(arena, bytes[at + "\x03vorbis".len ..], &tags);
        return tags;
    }
    return tags;
}

// --------------------------------------------------------------- MP4 / m4a

fn parseMp4(arena: std.mem.Allocator, bytes: []const u8) ?Tags {
    var tags: Tags = .{};
    walkAtoms(arena, bytes, &tags, 0);
    return tags;
}

fn walkAtoms(arena: std.mem.Allocator, bytes: []const u8, tags: *Tags, depth: u8) void {
    if (depth >= MAX_ATOM_DEPTH) return;
    var c: Cursor = .{ .b = bytes };

    while (c.remaining() >= 8) {
        const start = c.i;
        var size: u64 = c.u32be() orelse return;
        const kind = c.take(4) orelse return;
        var header: u64 = 8;
        if (size == 1) {
            size = c.u64be() orelse return;
            header = 16;
        } else if (size == 0) {
            size = @as(u64, bytes.len - start);
        }
        if (size < header) return;
        if (size > bytes.len - start) return;

        const body = bytes[start + header .. start + @as(usize, @intCast(size))];

        if (std.mem.eql(u8, kind, "moov") or
            std.mem.eql(u8, kind, "udta") or
            std.mem.eql(u8, kind, "trak") or
            std.mem.eql(u8, kind, "mdia"))
        {
            walkAtoms(arena, body, tags, depth + 1);
        } else if (std.mem.eql(u8, kind, "meta")) {
            if (body.len > 4) walkAtoms(arena, body[4..], tags, depth + 1);
        } else if (std.mem.eql(u8, kind, "ilst")) {
            readIlst(arena, body, tags, depth + 1);
        } else if (std.mem.eql(u8, kind, "mvhd")) {
            readMvhd(body, tags);
        }

        c.i = start + @as(usize, @intCast(size));
    }
}

fn readIlst(arena: std.mem.Allocator, bytes: []const u8, tags: *Tags, depth: u8) void {
    if (depth >= MAX_ATOM_DEPTH) return;
    var c: Cursor = .{ .b = bytes };

    while (c.remaining() >= 8) {
        const start = c.i;
        const size = c.u32be() orelse return;
        const kind = c.take(4) orelse return;
        if (size < 8 or size > bytes.len - start) return;
        const body = bytes[start + 8 .. start + size];

        if (dataPayload(body)) |payload| {
            if (std.mem.eql(u8, kind, "\xA9nam")) {
                store(arena, &tags.title, payload);
            } else if (std.mem.eql(u8, kind, "\xA9ART")) {
                store(arena, &tags.artist, payload);
            } else if (std.mem.eql(u8, kind, "\xA9alb")) {
                store(arena, &tags.album, payload);
            } else if (std.mem.eql(u8, kind, "trkn")) {
                if (payload.len >= 4 and tags.track_no == 0) {
                    tags.track_no = std.mem.readInt(u16, payload[2..4], .big);
                }
            }
        }
        c.i = start + size;
    }
}

fn dataPayload(item: []const u8) ?[]const u8 {
    var c: Cursor = .{ .b = item };
    const size = c.u32be() orelse return null;
    const kind = c.take(4) orelse return null;
    if (!std.mem.eql(u8, kind, "data")) return null;
    if (size < 16 or size > item.len) return null;
    return item[16..size];
}

fn readMvhd(body: []const u8, tags: *Tags) void {
    var c: Cursor = .{ .b = body };
    const version = c.byte() orelse return;
    _ = c.take(3) orelse return;

    var timescale: u64 = 0;
    var duration: u64 = 0;
    if (version == 1) {
        _ = c.u64be() orelse return;
        _ = c.u64be() orelse return;
        timescale = c.u32be() orelse return;
        duration = c.u64be() orelse return;
    } else {
        _ = c.u32be() orelse return;
        _ = c.u32be() orelse return;
        timescale = c.u32be() orelse return;
        duration = c.u32be() orelse return;
    }
    if (timescale == 0 or duration == 0) return;
    tags.duration_s = @intCast(@min(duration / timescale, std.math.maxInt(u32)));
}

// ------------------------------------------------------------ path fallback

pub fn fromPath(arena: std.mem.Allocator, file_path: []const u8) Tags {
    var tags: Tags = .{};

    const base = std.fs.path.basename(file_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;

    var title = stem;
    var digits: usize = 0;
    while (digits < title.len and title[digits] >= '0' and title[digits] <= '9') digits += 1;
    if (digits > 0 and digits < title.len) {
        tags.track_no = leadingNumber(title[0..digits]);
        var rest = title[digits..];
        rest = std.mem.trimStart(u8, rest, " .-_");
        if (rest.len > 0) title = rest;
    }
    store(arena, &tags.title, title);

    if (std.fs.path.dirname(file_path)) |dir| {
        store(arena, &tags.album, std.fs.path.basename(dir));
        if (std.fs.path.dirname(dir)) |up| {
            store(arena, &tags.artist, std.fs.path.basename(up));
        }
    }
    return tags;
}

pub fn readOrPath(arena: std.mem.Allocator, file_path: []const u8, total_size: u64) Tags {
    const from_path = fromPath(arena, file_path);
    var tags = read(arena, file_path, total_size) orelse return from_path;
    if (tags.title.len == 0) tags.title = from_path.title;
    if (tags.artist.len == 0) tags.artist = from_path.artist;
    if (tags.album.len == 0) tags.album = from_path.album;
    if (tags.track_no == 0) tags.track_no = from_path.track_no;
    return tags;
}

const testing = std.testing;

fn syncsafeBytes(n: usize) [4]u8 {
    return .{
        @intCast((n >> 21) & 0x7f),
        @intCast((n >> 14) & 0x7f),
        @intCast((n >> 7) & 0x7f),
        @intCast(n & 0x7f),
    };
}

fn beBytes(n: u32) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, n, .big);
    return out;
}

fn id3Frame(a: std.mem.Allocator, id: []const u8, major: u8, body: []const u8, declared: ?u32) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, id) catch unreachable;
    const size: u32 = declared orelse @intCast(body.len);
    if (major == 4) {
        out.appendSlice(a, &syncsafeBytes(size)) catch unreachable;
    } else {
        out.appendSlice(a, &beBytes(size)) catch unreachable;
    }
    out.appendSlice(a, &.{ 0, 0 }) catch unreachable;
    out.appendSlice(a, body) catch unreachable;
    return out.items;
}

fn id3(a: std.mem.Allocator, major: u8, frames: []const []const u8) []u8 {
    var body: std.ArrayList(u8) = .empty;
    for (frames) |f| body.appendSlice(a, f) catch unreachable;

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "ID3") catch unreachable;
    out.appendSlice(a, &.{ major, 0, 0 }) catch unreachable;
    out.appendSlice(a, &syncsafeBytes(body.items.len)) catch unreachable;
    out.appendSlice(a, body.items) catch unreachable;
    out.appendSlice(a, &.{ 0xFF, 0xFB, 0x90, 0x00 }) catch unreachable;
    return out.items;
}

fn survivesEveryTruncation(a: std.mem.Allocator, bytes: []const u8) void {
    var n: usize = 0;
    while (n <= bytes.len) : (n += 1) {
        _ = parse(a, bytes[0..n], 0);
    }
}

test "id3v2.3 reads latin-1, utf-8 and utf-16 text frames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = id3(a, 3, &.{
        id3Frame(a, "TIT2", 3, "\x00mot\xf6rhead", null),
        id3Frame(a, "TPE1", 3, "\x03Bohren & der Club of Gore", null),
        id3Frame(a, "TALB", 3, "\x01\xff\xfeB\x00l\x00a\x00c\x00k\x00", null),
        id3Frame(a, "TRCK", 3, "\x004/12", null),
        id3Frame(a, "TLEN", 3, "\x00222000", null),
    });

    const t = parse(a, bytes, 0).?;
    try testing.expectEqualStrings("motörhead", t.title);
    try testing.expectEqualStrings("Bohren & der Club of Gore", t.artist);
    try testing.expectEqualStrings("Black", t.album);
    try testing.expectEqual(@as(u16, 4), t.track_no);
    try testing.expectEqual(@as(u32, 222), t.duration_s);
}

test "id3v2.4 sync-safe frame sizes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = id3(a, 4, &.{id3Frame(a, "TIT2", 4, "\x03Midnight", null)});
    try testing.expectEqualStrings("Midnight", parse(a, bytes, 0).?.title);
}

test "id3 frame declaring an absurd size is refused, not sliced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = id3(a, 3, &.{
        id3Frame(a, "TIT2", 3, "\x03Good", null),
        id3Frame(a, "TALB", 3, "\x03Evil", 0xFFFF_FFFF),
    });
    const t = parse(a, bytes, 0).?;
    try testing.expectEqualStrings("Good", t.title);
    try testing.expectEqualStrings("", t.album);
}

test "id3 skips frames whose text encoding byte is unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x09garbage", null)});
    try testing.expectEqualStrings("", parse(a, bytes, 0).?.title);
}

test "id3 utf-16 without a BOM, and an unpaired surrogate, decode to nothing bad" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const no_bom = id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x01B\x00l\x00a\x00", null)});
    try testing.expectEqualStrings("", parse(a, no_bom, 0).?.title);

    const lone = id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x01\xff\xfeA\x00\x00\xd8", null)});
    const got = parse(a, lone, 0).?.title;
    try testing.expectEqualStrings("A", got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "id3 tag text carrying escapes and tabs is neutralized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x03evil\x1b[2Jtitle\there", null)});
    const t = parse(a, bytes, 0).?;
    try testing.expectEqualStrings("evil [2Jtitle here", t.title);
}

test "id3 survives truncation at every byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = id3(a, 3, &.{
        id3Frame(a, "TIT2", 3, "\x03Midnight Black Earth", null),
        id3Frame(a, "TPE1", 3, "\x03Bohren", null),
    });
    survivesEveryTruncation(a, bytes);
}

fn flacFile(a: std.mem.Allocator, comments: []const []const u8, bad_count: ?u32) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "fLaC") catch unreachable;

    var info: [34]u8 = @splat(0);
    const packed_bits: u64 = (@as(u64, 44100) << 44) | 9_797_400;
    std.mem.writeInt(u64, info[10..18], packed_bits, .big);
    out.append(a, 0) catch unreachable;
    out.appendSlice(a, &.{ 0, 0, 34 }) catch unreachable;
    out.appendSlice(a, &info) catch unreachable;

    var vc: std.ArrayList(u8) = .empty;
    var vendor: [4]u8 = undefined;
    std.mem.writeInt(u32, &vendor, 3, .little);
    vc.appendSlice(a, &vendor) catch unreachable;
    vc.appendSlice(a, "abc") catch unreachable;
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, bad_count orelse @as(u32, @intCast(comments.len)), .little);
    vc.appendSlice(a, &count) catch unreachable;
    for (comments) |cm| {
        var l: [4]u8 = undefined;
        std.mem.writeInt(u32, &l, @intCast(cm.len), .little);
        vc.appendSlice(a, &l) catch unreachable;
        vc.appendSlice(a, cm) catch unreachable;
    }

    out.append(a, 0x84) catch unreachable;
    out.appendSlice(a, &.{
        @intCast((vc.items.len >> 16) & 0xff),
        @intCast((vc.items.len >> 8) & 0xff),
        @intCast(vc.items.len & 0xff),
    }) catch unreachable;
    out.appendSlice(a, vc.items) catch unreachable;
    return out.items;
}

test "flac reads vorbis comments and derives duration from STREAMINFO" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = flacFile(a, &.{
        "TITLE=Midnight Black Earth",
        "artist=Bohren & der Club of Gore",
        "ALBUM=Black Earth",
        "TRACKNUMBER=1",
        "REPLAYGAIN_TRACK_GAIN=-7.4 dB",
    }, null);

    const t = parse(a, bytes, 0).?;
    try testing.expectEqualStrings("Midnight Black Earth", t.title);
    try testing.expectEqualStrings("Bohren & der Club of Gore", t.artist);
    try testing.expectEqualStrings("Black Earth", t.album);
    try testing.expectEqual(@as(u16, 1), t.track_no);
    try testing.expectEqual(@as(u32, 222), t.duration_s);
}

test "flac comment count of 4 billion allocates nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = flacFile(a, &.{"TITLE=Real"}, 0xFFFF_FFFF);
    const t = parse(a, bytes, 0).?;
    try testing.expectEqualStrings("Real", t.title);
}

test "flac survives truncation at every byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    survivesEveryTruncation(a, flacFile(a, &.{ "TITLE=T", "ARTIST=A" }, null));
}

fn atom(a: std.mem.Allocator, kind: []const u8, body: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, &beBytes(@intCast(body.len + 8))) catch unreachable;
    out.appendSlice(a, kind) catch unreachable;
    out.appendSlice(a, body) catch unreachable;
    return out.items;
}

fn dataAtom(a: std.mem.Allocator, payload: []const u8) []u8 {
    var body: std.ArrayList(u8) = .empty;
    body.appendSlice(a, &.{ 0, 0, 0, 1, 0, 0, 0, 0 }) catch unreachable;
    body.appendSlice(a, payload) catch unreachable;
    return atom(a, "data", body.items);
}

fn mp4File(a: std.mem.Allocator) []u8 {
    var mvhd: std.ArrayList(u8) = .empty;
    mvhd.appendSlice(a, &.{ 0, 0, 0, 0 }) catch unreachable;
    mvhd.appendSlice(a, &beBytes(0)) catch unreachable;
    mvhd.appendSlice(a, &beBytes(0)) catch unreachable;
    mvhd.appendSlice(a, &beBytes(1000)) catch unreachable;
    mvhd.appendSlice(a, &beBytes(222_000)) catch unreachable;

    var trkn_body: std.ArrayList(u8) = .empty;
    trkn_body.appendSlice(a, &.{ 0, 0, 0, 7, 0, 12 }) catch unreachable;

    var ilst: std.ArrayList(u8) = .empty;
    ilst.appendSlice(a, atom(a, "\xA9nam", dataAtom(a, "Midnight"))) catch unreachable;
    ilst.appendSlice(a, atom(a, "\xA9ART", dataAtom(a, "Bohren"))) catch unreachable;
    ilst.appendSlice(a, atom(a, "\xA9alb", dataAtom(a, "Black Earth"))) catch unreachable;
    ilst.appendSlice(a, atom(a, "trkn", dataAtom(a, trkn_body.items))) catch unreachable;

    var meta_body: std.ArrayList(u8) = .empty;
    meta_body.appendSlice(a, &.{ 0, 0, 0, 0 }) catch unreachable;
    meta_body.appendSlice(a, atom(a, "ilst", ilst.items)) catch unreachable;

    var udta: std.ArrayList(u8) = .empty;
    udta.appendSlice(a, atom(a, "meta", meta_body.items)) catch unreachable;

    var moov: std.ArrayList(u8) = .empty;
    moov.appendSlice(a, atom(a, "mvhd", mvhd.items)) catch unreachable;
    moov.appendSlice(a, atom(a, "udta", udta.items)) catch unreachable;

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, atom(a, "ftyp", "M4A isom")) catch unreachable;
    out.appendSlice(a, atom(a, "moov", moov.items)) catch unreachable;
    return out.items;
}

test "mp4 reads ilst metadata and mvhd duration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = parse(a, mp4File(a), 0).?;
    try testing.expectEqualStrings("Midnight", t.title);
    try testing.expectEqualStrings("Bohren", t.artist);
    try testing.expectEqualStrings("Black Earth", t.album);
    try testing.expectEqual(@as(u16, 7), t.track_no);
    try testing.expectEqual(@as(u32, 222), t.duration_s);
}

test "mp4 atom smaller than its own header terminates the walk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bytes: std.ArrayList(u8) = .empty;
    bytes.appendSlice(a, atom(a, "ftyp", "M4A isom")) catch unreachable;
    bytes.appendSlice(a, &beBytes(4)) catch unreachable;
    bytes.appendSlice(a, "moov") catch unreachable;
    bytes.appendSlice(a, &.{ 0, 0, 0, 0 }) catch unreachable;

    const t = parse(a, bytes.items, 0).?;
    try testing.expectEqualStrings("", t.title);
}

test "mp4 atom claiming more than the file holds is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bytes: std.ArrayList(u8) = .empty;
    bytes.appendSlice(a, atom(a, "ftyp", "M4A isom")) catch unreachable;
    bytes.appendSlice(a, &beBytes(0xFFFF_FFF0)) catch unreachable;
    bytes.appendSlice(a, "moov") catch unreachable;
    bytes.appendSlice(a, &.{ 0, 0, 0, 0 }) catch unreachable;

    try testing.expectEqualStrings("", parse(a, bytes.items, 0).?.title);
}

test "mp4 nesting past the depth cap stops instead of exhausting the stack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inner = atom(a, "moov", "");
    var i: usize = 0;
    while (i < 200) : (i += 1) inner = atom(a, "moov", inner);

    var bytes: std.ArrayList(u8) = .empty;
    bytes.appendSlice(a, atom(a, "ftyp", "M4A isom")) catch unreachable;
    bytes.appendSlice(a, inner) catch unreachable;

    _ = parse(a, bytes.items, 0);
}

test "mp4 survives truncation at every byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    survivesEveryTruncation(a, mp4File(a));
}

test "ogg/opus comment header is found and parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var vc: std.ArrayList(u8) = .empty;
    var vendor: [4]u8 = undefined;
    std.mem.writeInt(u32, &vendor, 4, .little);
    vc.appendSlice(a, &vendor) catch unreachable;
    vc.appendSlice(a, "libo") catch unreachable;
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, 2, .little);
    vc.appendSlice(a, &count) catch unreachable;
    for ([_][]const u8{ "TITLE=Opus Song", "ARTIST=Someone" }) |cm| {
        var l: [4]u8 = undefined;
        std.mem.writeInt(u32, &l, @intCast(cm.len), .little);
        vc.appendSlice(a, &l) catch unreachable;
        vc.appendSlice(a, cm) catch unreachable;
    }

    var bytes: std.ArrayList(u8) = .empty;
    bytes.appendSlice(a, "OggS") catch unreachable;
    bytes.appendSlice(a, &@as([24]u8, @splat(0))) catch unreachable;
    bytes.appendSlice(a, "OpusTags") catch unreachable;
    bytes.appendSlice(a, vc.items) catch unreachable;

    const t = parse(a, bytes.items, 0).?;
    try testing.expectEqualStrings("Opus Song", t.title);
    try testing.expectEqualStrings("Someone", t.artist);
    survivesEveryTruncation(a, bytes.items);
}

test "files that are not audio yield nothing rather than garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(parse(a, "", 0) == null);
    try testing.expect(parse(a, "not an audio file at all", 0) == null);
    try testing.expect(parse(a, &@as([64]u8, @splat(0xFF)), 0) == null);
    try testing.expect(parse(a, "ID3", 0) == null);
    try testing.expect(parse(a, "ID3\x02\x00\x00\x00\x00\x00\x00", 0) == null);
}

test "fromPath derives artist, album, track and title from the layout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = fromPath(a, "/music/Bohren & der Club of Gore/Black Earth/01 Midnight.flac");
    try testing.expectEqualStrings("Midnight", t.title);
    try testing.expectEqualStrings("Black Earth", t.album);
    try testing.expectEqualStrings("Bohren & der Club of Gore", t.artist);
    try testing.expectEqual(@as(u16, 1), t.track_no);

    const bare = fromPath(a, "tone.wav");
    try testing.expectEqualStrings("tone", bare.title);
    try testing.expectEqualStrings("", bare.artist);

    const numeric = fromPath(a, "/music/A/B/1979.mp3");
    try testing.expectEqualStrings("1979", numeric.title);
}

test "random mutations of valid files never panic, hang or leak past bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const seeds = [_][]const u8{
        id3(a, 3, &.{ id3Frame(a, "TIT2", 3, "\x03Title", null), id3Frame(a, "TPE1", 3, "\x00Artist", null) }),
        id3(a, 4, &.{id3Frame(a, "TALB", 4, "\x01\xff\xfeA\x00", null)}),
        flacFile(a, &.{ "TITLE=T", "ARTIST=A", "TRACKNUMBER=3" }, null),
        mp4File(a),
    };

    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rand = prng.random();

    for (seeds) |seed| {
        var round: usize = 0;
        while (round < 300) : (round += 1) {
            const copy = a.dupe(u8, seed) catch unreachable;
            const flips = 1 + rand.uintLessThan(usize, 8);
            var f: usize = 0;
            while (f < flips) : (f += 1) {
                const at = if (rand.boolean())
                    rand.uintLessThan(usize, @min(copy.len, 64))
                else
                    rand.uintLessThan(usize, copy.len);
                copy[at] = rand.int(u8);
            }
            _ = parse(a, copy, 0);
        }
    }
}

test "mp3 duration from a CBR stream when TLEN is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x03No TLEN here", null)}));
    try bytes.appendSlice(a, &cbrFrame);
    try bytes.appendSlice(a, &cbrFrame);

    const t = parse(a, bytes.items, 1_600_000).?;
    try testing.expectEqualStrings("No TLEN here", t.title);
    try testing.expectApproxEqAbs(@as(f64, 100), @as(f64, @floatFromInt(t.duration_s)), 2);
}

test "mp3 duration prefers an exact Xing frame count over the CBR estimate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var frame: std.ArrayList(u8) = .empty;
    try frame.appendSlice(a, &xingFrame(3830));
    try frame.appendSlice(a, &cbrFrame);

    const t = parse(a, frame.items, 99_999_999).?;
    try testing.expectApproxEqAbs(@as(f64, 100), @as(f64, @floatFromInt(t.duration_s)), 1);
}

test "mp3 duration skips a lone sync pattern that no frame follows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x03Sock", null)}));
    try bytes.appendSlice(a, &.{ 0xFF, 0xFB, 0x90, 0x00 });
    try bytes.appendSlice(a, &@as([600]u8, @splat(0x55)));
    try bytes.appendSlice(a, &xingFrame(3830));
    try bytes.appendSlice(a, &cbrFrame);

    const t = parse(a, bytes.items, 99_999_999).?;
    try testing.expectApproxEqAbs(@as(f64, 100), @as(f64, @floatFromInt(t.duration_s)), 1);
}

const cbrFrame = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 } ++ @as([413]u8, @splat(0));

fn xingFrame(frames: u32) [417]u8 {
    var f = cbrFrame;
    @memcpy(f[36..40], "Xing");
    std.mem.writeInt(u32, f[40..44], 1, .big);
    std.mem.writeInt(u32, f[44..48], frames, .big);
    return f;
}

test "mp3 duration declines rather than guessing on junk headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bad: std.ArrayList(u8) = .empty;
    try bad.appendSlice(a, &.{ 0xFF, 0xFB, 0xF0, 0x00 });
    try bad.appendSlice(a, &@as([64]u8, @splat(0)));
    try testing.expect(parse(a, bad.items, 1_000_000) == null);

    var layer2: std.ArrayList(u8) = .empty;
    try layer2.appendSlice(a, &.{ 0xFF, 0xFD, 0x90, 0x00 });
    try layer2.appendSlice(a, &@as([64]u8, @splat(0)));
    try testing.expect(parse(a, layer2.items, 1_000_000) == null);

    var cbr: std.ArrayList(u8) = .empty;
    try cbr.appendSlice(a, &.{ 0xFF, 0xFB, 0x90, 0x00 });
    try cbr.appendSlice(a, &@as([64]u8, @splat(0)));
    try testing.expect(parse(a, cbr.items, 0) == null);

    const tagged = id3(a, 3, &.{id3Frame(a, "TIT2", 3, "\x03Still Titled", null)});
    const t = parse(a, tagged, 0).?;
    try testing.expectEqualStrings("Still Titled", t.title);
    try testing.expectEqual(@as(u32, 0), t.duration_s);
}
