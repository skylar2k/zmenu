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
//
// This file contains code derived from dmenu (MIT/X Consortium License);
// see THIRD_PARTY_NOTICES.

//! Which items match what you typed, and in what order. Pure functions with
//! no UI, so they are easy to test.
//!
//! The rules are dmenu's (see dmenu(1)):
//!  * The text is split into words at spaces. An item matches if it contains
//!    EVERY word (anywhere in the item).
//!  * Results come in three groups, each keeping the input order:
//!    exact matches first, then items that START with the first word, then
//!    everything else that matches.
//!  * With no text, every item matches.
const std = @import("std");

fn contains(hay: []const u8, needle: []const u8, insensitive: bool) bool {
    if (insensitive) return std.ascii.findIgnoreCase(hay, needle) != null;
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn startsWith(hay: []const u8, prefix: []const u8, insensitive: bool) bool {
    if (insensitive) return std.ascii.startsWithIgnoreCase(hay, prefix);
    return std.mem.startsWith(u8, hay, prefix);
}

fn equals(a: []const u8, b: []const u8, insensitive: bool) bool {
    if (insensitive) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

/// Fill `out` with the indices of the matching items, best first.
/// (Case folding is ASCII-only: "é" and "É" are different letters here.)
pub fn filter(
    gpa: std.mem.Allocator,
    items: []const []const u8,
    text: []const u8,
    insensitive: bool,
    out: *std.ArrayList(u32),
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();

    // Split into words at spaces. dmenu's strtok() skips empty words, as
    // tokenize does; there is no limit on how many.
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    const first = words.next() orelse {
        for (items, 0..) |_, i| try out.append(gpa, @intCast(i));
        return;
    };

    var prefix: std.ArrayList(u32) = .empty;
    defer prefix.deinit(gpa);
    var substring: std.ArrayList(u32) = .empty;
    defer substring.deinit(gpa);

    for (items, 0..) |item, i| {
        var all = true;
        words.reset();
        while (words.next()) |w| {
            if (!contains(item, w, insensitive)) {
                all = false;
                break;
            }
        }
        if (!all) continue;
        const idx: u32 = @intCast(i);
        if (equals(item, text, insensitive)) {
            try out.append(gpa, idx); // exact matches go straight into `out`
        } else if (startsWith(item, first, insensitive)) {
            try prefix.append(gpa, idx);
        } else {
            try substring.append(gpa, idx);
        }
    }
    try out.appendSlice(gpa, prefix.items);
    try out.appendSlice(gpa, substring.items);
}

const testing = std.testing;

fn run(items: []const []const u8, text: []const u8, insensitive: bool, want: []const u32) !void {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try filter(testing.allocator, items, text, insensitive, &out);
    try testing.expectEqualSlices(u32, want, out.items);
}

test "no text matches everything in order" {
    try run(&.{ "b", "a", "c" }, "", false, &.{ 0, 1, 2 });
    try run(&.{ "b", "a" }, "   ", false, &.{ 0, 1 });
}

test "exact, then prefix, then substring" {
    // typed "ab": "xab" is a substring match, "abc" a prefix match, "ab" exact
    try run(&.{ "xab", "abc", "ab", "zzz" }, "ab", false, &.{ 2, 1, 0 });
}

test "each group keeps the input order" {
    try run(&.{ "xa", "ya", "ab", "ac" }, "a", false, &.{ 2, 3, 0, 1 });
}

test "every word has to match, in any order" {
    // Typed "bar foo": "bar" and "foo" alone don't match (each lacks a word).
    // "bar foo baz" starts with the first word, so it is a prefix match and comes
    // before "foo bar", which only contains both words.
    try run(&.{ "foo bar", "bar", "bar foo baz", "foo" }, "bar foo", false, &.{ 2, 0 });
    // An exact match ("bar foo") beats everything.
    try run(&.{ "foo bar", "bar foo" }, "bar foo", false, &.{ 1, 0 });
}

test "case sensitivity" {
    try run(&.{ "Firefox", "firefox" }, "fire", false, &.{1});
    try run(&.{ "Firefox", "firefox" }, "fire", true, &.{ 0, 1 });
}

test "dmenu's own results for \"cal\" (checked against its real match())" {
    // Items: 0 Calculator, 1 calendar, 2 Calendar, 3 Camera, 4 cal, 5 CAL
    const items = [_][]const u8{ "Calculator", "calendar", "Calendar", "Camera", "cal", "CAL" };
    try run(&items, "cal", false, &.{ 4, 1 }); // plain dmenu: case-sensitive
    try run(&items, "cal", true, &.{ 4, 5, 0, 1, 2 }); // -i: exact (both spellings), then prefixes
}

test "a typed word that is nowhere matches nothing" {
    try run(&.{ "a", "b" }, "zzz", false, &.{});
}
