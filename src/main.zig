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

//! zmenu: a dmenu-style menu for macOS.
//!
//!     printf 'one\ntwo\nthree\n' | zmenu -p pick:     # prints your choice
//!     zmenu                                            # app launcher
//!
//! Exit status: 0 = you chose something (it is printed), 1 = you cancelled
//! (Esc, or clicking elsewhere), 2 = bad command line.
const std = @import("std");
const c = @import("c");
const options = @import("options.zig");
const ui = @import("ui.zig");
const apps = @import("apps.zig");

const gpa = std.heap.c_allocator;

const usage =
    \\usage: zmenu [-cbiasP] [-l lines] [-m monitor] [-p prompt] [-fn font]
    \\             [-nb color] [-nf color] [-sb color] [-sf color] [-ob color] [-of color] [-W width] [-H height] [-R radius]
    \\
    \\Reads items (one per line) from standard input, lets you pick one, and
    \\prints it. With nothing piped in, or with -a, it lists applications and
    \\opens the one you pick.
    \\
    \\  -c           centered box (10 lines unless -l is given), instead of a bar
    \\  -b           bar at the bottom of the screen
    \\  -i           ignore case when matching (the default; accepted for dmenu scripts)
    \\  -s           match case-sensitively, like plain dmenu
    \\  -a           application launcher
    \\  -l lines     show the items in a list of this many lines
    \\  -m monitor   monitor number, left to right from 0
    \\               (default: $ZWM_MONITOR, else where the mouse pointer is)
    \\  -p prompt    text shown before the input field
    \\  -fn font     font as "Name size", e.g. "Menlo 14"
    \\  -P           password mode: the field shows dots, no list, and what you type is
    \\               printed (macOS also hides your keystrokes from other programs)
    \\  -nb/-nf      normal background / foreground, "#rrggbb"
    \\  -sb/-sf      selected background / foreground
    \\  -ob/-of      background / foreground of items marked with Ctrl/Cmd+Return
    \\  -W width     width of the centered box, in points
    \\  -R radius    corner radius in points (default 10; 0 = square corners)
    \\  -H height    height of the bar and of each list row, in points
    \\               (default: the font height). -H menubar makes a bar at the
    \\               top as tall as the menu bar, hiding it completely
    \\  -v, -h       version, this help
    \\
    \\Keys: Return picks the highlighted item (or your text if nothing matches),
    \\Shift+Return picks your text as typed, Ctrl+Return (or Cmd+Return) picks the item
    \\and keeps the menu open (several picks, each printed as you make it; Return ends), Tab copies the highlighted item into
    \\the field, Up/Down (ctrl-p/n) move, Left/Right move through the items when
    \\the text cursor is at an end, PageUp/PageDown, Esc cancels.
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zmenu: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// Everything on stdin, one item per non-empty line.
fn readItems() []const []const u8 {
    var data: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) break;
        data.appendSlice(gpa, buf[0..@intCast(n)]) catch break;
    }
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data.items, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len > 0) list.append(gpa, trimmed) catch break;
    }
    return list.items;
}

extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

/// Launcher mode: open the application with `open -a`.
fn launch(name: []const u8) void {
    if (name.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = [_][]const u8{ "open", "-a", name };
    var argv: [4]?[*:0]u8 = undefined;
    for (parts, 0..) |p, i| {
        const z = a.allocSentinel(u8, p.len, 0) catch return;
        @memcpy(z, p);
        argv[i] = z.ptr;
    }
    argv[3] = null;
    var pid: c.pid_t = 0;
    _ = c.posix_spawnp(&pid, "open", null, null, @ptrCast(&argv), @ptrCast(_NSGetEnviron().*));
}

pub fn main(init: std.process.Init) !void {
    const raw = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try gpa.alloc([]const u8, raw.len -| 1);
    for (raw[1..], 0..) |a, i| args[i] = a;

    const env_monitor: ?[]const u8 = if (c.getenv("ZWM_MONITOR")) |p| std.mem.span(p) else null;
    const opts = options.parse(args, env_monitor) catch |err| switch (err) {
        error.UnknownOption => fail("unknown option (try -h)", .{}),
        error.MissingValue => fail("an option is missing its value (try -h)", .{}),
        error.BadValue => fail("an option has an invalid value (try -h)", .{}),
    };
    if (opts.help) {
        ui.writeAll(1, usage);
        return;
    }
    if (opts.version) {
        ui.writeAll(1, "zmenu 0.1\n");
        return;
    }

    // Launcher mode: asked for with -a, or nothing is piped in (stdin is a terminal).
    // A password prompt (-P) never is, and never reads stdin.
    const launcher = !opts.password and (opts.apps or c.isatty(0) != 0);
    const list: []const []const u8 = if (opts.password) &.{} else if (launcher) apps.list(gpa) else readItems();
    if (launcher) ui.on_accept = launch;
    ui.run(opts, list);
}

test {
    _ = @import("match.zig");
    _ = @import("options.zig");
    _ = @import("geometry.zig");
    _ = @import("marks.zig");
}
