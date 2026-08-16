const std = @import("std");

pub const Theme = struct {
    accent: []const u8,
    accent_strong: []const u8,
    dim: []const u8,
    ghost: []const u8,
    highlight: []const u8,
    title_bg: []const u8 = "",
    reset: []const u8 = "\x1b[0m",
    bold: []const u8 = "\x1b[1m",
};

pub const Named = struct { name: []const u8, theme: Theme };

pub const red: Theme = .{
    .accent = "\x1b[38;5;196m",
    .accent_strong = "\x1b[1;38;5;196m",
    .dim = "\x1b[38;5;243m",
    .ghost = "\x1b[38;5;238m",
    .highlight = "\x1b[48;5;196m\x1b[38;5;231m",
};

pub const cyan: Theme = .{
    .accent = "\x1b[36m",
    .accent_strong = "\x1b[1;36m",
    .dim = "\x1b[2m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[7m",
};

pub const mono: Theme = .{
    .accent = "\x1b[37m",
    .accent_strong = "\x1b[1;37m",
    .dim = "\x1b[2m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[7m",
};

pub const dracula: Theme = .{
    .accent = "\x1b[38;5;141m",
    .accent_strong = "\x1b[1;38;5;141m",
    .dim = "\x1b[2m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[48;5;141m\x1b[38;5;232m",
};

pub const nord: Theme = .{
    .accent = "\x1b[38;5;110m",
    .accent_strong = "\x1b[1;38;5;110m",
    .dim = "\x1b[2m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[48;5;110m\x1b[38;5;232m",
};

pub const gruvbox: Theme = .{
    .accent = "\x1b[38;5;214m",
    .accent_strong = "\x1b[1;38;5;214m",
    .dim = "\x1b[38;5;243m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[48;5;214m\x1b[38;5;232m",
};

pub const tokyonight: Theme = .{
    .accent = "\x1b[38;5;111m",
    .accent_strong = "\x1b[1;38;5;111m",
    .dim = "\x1b[38;5;60m",
    .ghost = "\x1b[38;5;238m",
    .highlight = "\x1b[48;5;111m\x1b[38;5;235m",
};

pub const catppuccin: Theme = .{
    .accent = "\x1b[38;5;183m",
    .accent_strong = "\x1b[1;38;5;183m",
    .dim = "\x1b[38;5;103m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[48;5;183m\x1b[38;5;235m",
};

pub const matrix: Theme = .{
    .accent = "\x1b[38;5;46m",
    .accent_strong = "\x1b[1;38;5;46m",
    .dim = "\x1b[38;5;65m",
    .ghost = "\x1b[38;5;22m",
    .highlight = "\x1b[48;5;46m\x1b[38;5;232m",
};

pub const rosepine: Theme = .{
    .accent = "\x1b[38;5;168m",
    .accent_strong = "\x1b[1;38;5;168m",
    .dim = "\x1b[38;5;245m",
    .ghost = "\x1b[38;5;240m",
    .highlight = "\x1b[48;5;168m\x1b[38;5;235m",
};

pub const solarized: Theme = .{
    .accent = "\x1b[38;5;37m",
    .accent_strong = "\x1b[1;38;5;136m",
    .dim = "\x1b[38;5;66m",
    .ghost = "\x1b[38;5;239m",
    .highlight = "\x1b[48;5;37m\x1b[38;5;235m",
};

pub const default: Theme = red;

pub const all = [_]Named{
    .{ .name = "red", .theme = red },
    .{ .name = "cyan", .theme = cyan },
    .{ .name = "mono", .theme = mono },
    .{ .name = "dracula", .theme = dracula },
    .{ .name = "nord", .theme = nord },
    .{ .name = "gruvbox", .theme = gruvbox },
    .{ .name = "tokyonight", .theme = tokyonight },
    .{ .name = "catppuccin", .theme = catppuccin },
    .{ .name = "matrix", .theme = matrix },
    .{ .name = "rosepine", .theme = rosepine },
    .{ .name = "solarized", .theme = solarized },
};

pub fn byName(name: []const u8) ?Theme {
    if (indexOf(name)) |i| return all[i].theme;
    if (std.mem.eql(u8, name, "yt") or std.mem.eql(u8, name, "youtube")) return red;
    if (std.mem.eql(u8, name, "default")) return default;
    return null;
}

pub fn indexOf(name: []const u8) ?usize {
    for (all, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return i;
    }
    return null;
}

pub const names = blk: {
    var s: []const u8 = "";
    for (all, 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ n.name;
    break :blk s;
};

const testing = std.testing;

test "byName resolves known names, aliases, and default" {
    try testing.expectEqualStrings(red.accent, byName("red").?.accent);
    try testing.expectEqualStrings(nord.accent, byName("nord").?.accent);
    try testing.expectEqualStrings(red.accent, byName("yt").?.accent);
    try testing.expectEqualStrings(red.accent, byName("youtube").?.accent);
    try testing.expectEqualStrings(default.accent, byName("default").?.accent);
    try testing.expect(byName("nonexistent") == null);
}

test "indexOf matches all and only declared themes" {
    try testing.expectEqual(@as(?usize, 0), indexOf("red"));
    try testing.expectEqual(@as(?usize, 1), indexOf("cyan"));
    try testing.expectEqual(@as(?usize, all.len - 1), indexOf("solarized"));
    try testing.expect(indexOf("yt") == null); // alias is not a declared name
}

test "names is generated from the all table" {
    try testing.expectEqualStrings("red, cyan, mono, dracula, nord, gruvbox, tokyonight, catppuccin, matrix, rosepine, solarized", names);
}
