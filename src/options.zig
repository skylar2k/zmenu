// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 zmenu contributors
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License, version 3, as published
// by the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details. You should have received a copy of it along with this
// program (the file LICENSE); if not, see <https://www.gnu.org/licenses/>.

//! Command-line options for zmenu, parsed without touching any UI.
const std = @import("std");

pub const Color = struct { r: f64, g: f64, b: f64 };

fn hex(comptime v: u24) Color {
    return .{
        .r = @as(f64, (v >> 16) & 0xff) / 255.0,
        .g = @as(f64, (v >> 8) & 0xff) / 255.0,
        .b = @as(f64, v & 0xff) / 255.0,
    };
}

pub const Options = struct {
    /// Text shown before the input field (`-p`).
    prompt: []const u8 = "",
    /// Number of list lines under the input (`-l`). 0 = items go on one line.
    /// With -c, defaults to 10.
    lines: usize = 0,
    /// Centered box instead of a bar across the top of the screen (`-c`).
    centered: bool = false,
    /// Bar at the bottom of the screen instead of the top (`-b`).
    bottom: bool = false,
    /// Ignore case when matching. The default, unlike plain dmenu (which is
    /// case-sensitive unless given -i): typing "calc" finds "Calculator".
    /// `-s` turns it off (dmenu's own behaviour); `-i` is accepted for scripts
    /// written for dmenu.
    insensitive: bool = true,
    /// Monitor number, left to right, from 0 (`-m`, or $ZWM_MONITOR).
    /// Default: the monitor the mouse pointer is on.
    monitor: ?usize = null,
    /// Width of the centered box in points (`-W`).
    width: ?f64 = null,
    /// Height of the input bar / list rows in points (`-H`). Default: just
    /// enough for the font.
    height: ?f64 = null,
    /// Corner radius in points (`-R`), like the rounded corners of the macOS menu
    /// bar: the top corners of a top bar, the bottom corners of a `-b` bar, all
    /// four of the centered box. 0 = square.
    radius: f64 = 10,
    /// Colours of items you marked with Ctrl+Return (`-ob`, `-of`). dmenu's defaults.
    ob: Color = hex(0x00ffff),
    of: Color = hex(0x000000),
    /// Password mode (`-P`): the field shows dots, there is no item list, and
    /// what you typed is printed. (Not a dmenu feature: a common community patch.)
    password: bool = false,
    /// `-H menubar`: make a bar at the top as tall as the macOS menu bar, so
    /// that it hides it completely (44 points on some displays).
    cover_menubar: bool = false,
    /// List applications and open the one you pick (`-a`). Also what zmenu does
    /// when nothing is piped into it.
    apps: bool = false,
    /// Font as "Name size", e.g. "Menlo 14" (`-fn`).
    font: ?[]const u8 = null,
    /// Colors, "#rrggbb": normal background/foreground, selected background/foreground.
    nb: Color = hex(0x222222),
    nf: Color = hex(0xbbbbbb),
    sb: Color = hex(0x005577),
    sf: Color = hex(0xeeeeee),
    /// -h / --help and -v / --version
    help: bool = false,
    version: bool = false,
};

pub const ParseError = error{ UnknownOption, MissingValue, BadValue };

pub fn parseColor(s: []const u8) ?Color {
    const digits = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (digits.len != 6) return null;
    const v = std.fmt.parseInt(u24, digits, 16) catch return null;
    return .{
        .r = @as(f64, @floatFromInt((v >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((v >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(v & 0xff)) / 255.0,
    };
}

pub const default_font_size: f64 = 13;

/// "Menlo 14" -> name "Menlo", size 14. Without a trailing number: the default size.
pub const FontSpec = struct { name: []const u8, size: f64 };

pub fn parseFont(s: []const u8) FontSpec {
    if (std.mem.lastIndexOfScalar(u8, s, ' ')) |i| {
        if (std.fmt.parseFloat(f64, s[i + 1 ..])) |size| {
            return .{ .name = std.mem.trim(u8, s[0..i], " "), .size = size };
        } else |_| {}
    }
    return .{ .name = s, .size = default_font_size };
}

/// `args` excludes the program name. `env_monitor` is $ZWM_MONITOR, used when
/// no -m was given (zwm sets it to the monitor you are working on).
pub fn parse(args: []const []const u8, env_monitor: ?[]const u8) ParseError!Options {
    var o = Options{};
    var lines_given = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-c")) {
            o.centered = true;
        } else if (std.mem.eql(u8, a, "-b")) {
            o.bottom = true;
        } else if (std.mem.eql(u8, a, "-i")) {
            o.insensitive = true;
        } else if (std.mem.eql(u8, a, "-s")) {
            o.insensitive = false;
        } else if (std.mem.eql(u8, a, "-P")) {
            o.password = true;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--apps")) {
            o.apps = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            o.help = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            o.version = true;
        } else {
            // Everything else takes a value.
            const known = [_][]const u8{ "-l", "-m", "-p", "-fn", "-nb", "-nf", "-sb", "-sf", "-ob", "-of", "-W", "-H", "-R" };
            var is_known = false;
            for (known) |k| {
                if (std.mem.eql(u8, a, k)) is_known = true;
            }
            if (!is_known) return error.UnknownOption;
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = args[i];
            if (std.mem.eql(u8, a, "-l")) {
                o.lines = std.fmt.parseInt(usize, v, 10) catch return error.BadValue;
                lines_given = true;
            } else if (std.mem.eql(u8, a, "-m")) {
                o.monitor = std.fmt.parseInt(usize, v, 10) catch return error.BadValue;
            } else if (std.mem.eql(u8, a, "-p")) {
                o.prompt = v;
            } else if (std.mem.eql(u8, a, "-fn")) {
                o.font = v;
            } else if (std.mem.eql(u8, a, "-W")) {
                o.width = std.fmt.parseFloat(f64, v) catch return error.BadValue;
            } else if (std.mem.eql(u8, a, "-R")) {
                o.radius = std.fmt.parseFloat(f64, v) catch return error.BadValue;
            } else if (std.mem.eql(u8, a, "-H")) {
                if (std.mem.eql(u8, v, "menubar")) {
                    o.cover_menubar = true;
                } else {
                    o.height = std.fmt.parseFloat(f64, v) catch return error.BadValue;
                }
            } else {
                const col = parseColor(v) orelse return error.BadValue;
                if (std.mem.eql(u8, a, "-nb")) o.nb = col;
                if (std.mem.eql(u8, a, "-nf")) o.nf = col;
                if (std.mem.eql(u8, a, "-sb")) o.sb = col;
                if (std.mem.eql(u8, a, "-sf")) o.sf = col;
                if (std.mem.eql(u8, a, "-ob")) o.ob = col;
                if (std.mem.eql(u8, a, "-of")) o.of = col;
            }
        }
    }
    if (o.monitor == null) {
        if (env_monitor) |m| o.monitor = std.fmt.parseInt(usize, m, 10) catch null;
    }
    if (o.centered and !lines_given) o.lines = 10;
    if (o.password) { // a password prompt shows no choices
        o.lines = 0;
        o.apps = false;
    }
    return o;
}

const testing = std.testing;

test "defaults" {
    const o = try parse(&.{}, null);
    try testing.expectEqual(@as(usize, 0), o.lines);
    try testing.expect(!o.centered and !o.apps);
    try testing.expect(o.insensitive); // typing lowercase finds uppercase

}

test "flags and values" {
    const o = try parse(&.{ "-c", "-i", "-p", "run:", "-l", "5", "-m", "1", "-nb", "#ff0000" }, null);
    try testing.expect(o.centered and o.insensitive);
    try testing.expectEqualStrings("run:", o.prompt);
    try testing.expectEqual(@as(usize, 5), o.lines);
    try testing.expectEqual(@as(?usize, 1), o.monitor);
    try testing.expectEqual(@as(f64, 1.0), o.nb.r);
    try testing.expectEqual(@as(?f64, 30), (try parse(&.{ "-H", "30" }, null)).height);
    try testing.expect((try parse(&.{ "-H", "menubar" }, null)).cover_menubar);
    try testing.expectEqual(@as(f64, 0), (try parse(&.{ "-R", "0" }, null)).radius);
    try testing.expectEqual(@as(f64, 10), (try parse(&.{}, null)).radius);
}

test "case: insensitive by default, -s is dmenu's strict mode, -i still accepted" {
    try testing.expect((try parse(&.{}, null)).insensitive);
    try testing.expect(!(try parse(&.{"-s"}, null)).insensitive);
    try testing.expect((try parse(&.{"-i"}, null)).insensitive);
    try testing.expect(!(try parse(&.{ "-i", "-s" }, null)).insensitive); // the last one wins
}

test "centered mode lists 10 lines unless told otherwise" {
    try testing.expectEqual(@as(usize, 10), (try parse(&.{"-c"}, null)).lines);
    try testing.expectEqual(@as(usize, 3), (try parse(&.{ "-c", "-l", "3" }, null)).lines);
}

test "the monitor comes from the environment only if -m is absent" {
    try testing.expectEqual(@as(?usize, 2), (try parse(&.{}, "2")).monitor);
    try testing.expectEqual(@as(?usize, 0), (try parse(&.{ "-m", "0" }, "2")).monitor);
    try testing.expectEqual(@as(?usize, null), (try parse(&.{}, "nonsense")).monitor);
}

test "marked-item colours and password mode" {
    const o = try parse(&.{ "-ob", "#102030", "-of", "ffffff" }, null);
    try testing.expectEqual(@as(f64, 0x10) / 255.0, o.ob.r);
    try testing.expectEqual(@as(f64, 1.0), o.of.r);
    // dmenu's defaults: black on cyan
    const d = try parse(&.{}, null);
    try testing.expectEqual(@as(f64, 1.0), d.ob.b);
    try testing.expectEqual(@as(f64, 0.0), d.of.r);
    try testing.expect(!d.password);
}

test "password mode has no list and is never the launcher" {
    const p = try parse(&.{ "-P", "-c", "-a" }, null);
    try testing.expect(p.password);
    try testing.expectEqual(@as(usize, 0), p.lines); // even with -c, which would show 10
    try testing.expect(!p.apps);
}

test "errors" {
    try testing.expectError(error.UnknownOption, parse(&.{"-x"}, null));
    try testing.expectError(error.MissingValue, parse(&.{"-p"}, null));
    try testing.expectError(error.BadValue, parse(&.{ "-l", "many" }, null));
    try testing.expectError(error.BadValue, parse(&.{ "-nb", "red" }, null));
    try testing.expectError(error.BadValue, parse(&.{ "-ob", "red" }, null));
}

test "colors and fonts" {
    try testing.expectEqual(@as(f64, 0), parseColor("000000").?.r);
    try testing.expect(parseColor("#12345") == null);
    const f = parseFont("Menlo 16");
    try testing.expectEqualStrings("Menlo", f.name);
    try testing.expectEqual(@as(f64, 16), f.size);
    try testing.expectEqualStrings("SF Mono", parseFont("SF Mono 12").name);
    try testing.expectEqual(default_font_size, parseFont("Menlo").size);
}
