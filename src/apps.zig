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

//! The standalone launcher mode: find the applications on this Mac.
const std = @import("std");
const c = @import("c");

const dirs = [_][]const u8{
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    "/System/Cryptexes/App/System/Applications",
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

fn scan(gpa: std.mem.Allocator, dir: [:0]const u8, out: *std.ArrayList([]const u8)) void {
    const d = c.opendir(dir) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(&ent.*.d_name, 0);
        if (!std.mem.endsWith(u8, name, ".app")) continue;
        const copy = gpa.dupe(u8, name[0 .. name.len - 4]) catch continue;
        out.append(gpa, copy) catch gpa.free(copy);
    }
}

/// Names of installed applications, sorted, without ".app" and without duplicates.
pub fn list(gpa: std.mem.Allocator) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (dirs) |d| {
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{d}, 0) catch continue;
        scan(gpa, z, &names);
    }
    if (c.getenv("HOME")) |home| {
        var buf: [1024:0]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&buf, "{s}/Applications", .{std.mem.span(home)}, 0)) |z| scan(gpa, z, &names) else |_| {}
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    // Drop duplicates (the same app can appear in two folders).
    var n: usize = 0;
    for (names.items) |name| {
        if (n > 0 and std.ascii.eqlIgnoreCase(names.items[n - 1], name)) continue;
        names.items[n] = name;
        n += 1;
    }
    names.shrinkRetainingCapacity(n);
    return names.items;
}
