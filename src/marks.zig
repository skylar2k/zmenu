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

//! Multi-select: which items you marked with Ctrl+Return, and how a row is
//! styled. Pure, so it is tested without a screen.
//!
//! As in dmenu, Ctrl+Return prints the highlighted item and keeps the menu
//! open, remembering that you picked it ("marked"). Marked items are drawn in
//! their own colours (-ob / -of); the highlighted item always wins over a mark.
const std = @import("std");

pub const RowKind = enum { normal, selected, marked };

/// dmenu draws the selected item in the selected colours, else a marked item
/// in the marked colours, else normally.
pub fn rowKind(is_selected: bool, is_marked: bool) RowKind {
    if (is_selected) return .selected;
    if (is_marked) return .marked;
    return .normal;
}

/// NSEvent modifier flag bits.
pub const shift_flag: usize = 1 << 17;
pub const control_flag: usize = 1 << 18;
pub const command_flag: usize = 1 << 20;

pub const MarkKey = enum { item, text };

/// Is this key press a "pick and keep the menu open"? In dmenu that is
/// Ctrl+Return. zmenu also takes Cmd+Return, because on macOS Ctrl+Return is
/// sometimes claimed by the system or by other software before an app sees it.
/// With Shift as well, it is the typed text that is picked, not the item.
pub fn markKey(key_code: u16, flags: usize) ?MarkKey {
    const is_return = key_code == 36 or key_code == 76; // Return, keypad Enter
    if (!is_return) return null;
    if (flags & (control_flag | command_flag) == 0) return null;
    return if (flags & shift_flag != 0) .text else .item;
}

/// One flag per item (by its index in the input, not in the filtered list).
pub const Marks = struct {
    flags: []bool,

    pub fn init(gpa: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Marks {
        const flags = try gpa.alloc(bool, count);
        @memset(flags, false);
        return .{ .flags = flags };
    }

    pub fn deinit(self: *Marks, gpa: std.mem.Allocator) void {
        gpa.free(self.flags);
    }

    pub fn mark(self: *Marks, index: usize) void {
        if (index < self.flags.len) self.flags[index] = true;
    }

    pub fn isMarked(self: Marks, index: usize) bool {
        return index < self.flags.len and self.flags[index];
    }
};

test "the highlighted row wins over a mark; a mark wins over normal" {
    try std.testing.expectEqual(RowKind.selected, rowKind(true, true));
    try std.testing.expectEqual(RowKind.selected, rowKind(true, false));
    try std.testing.expectEqual(RowKind.marked, rowKind(false, true));
    try std.testing.expectEqual(RowKind.normal, rowKind(false, false));
}

test "which key presses mark: Ctrl+Return and Cmd+Return, not plain Return or Option+Return" {
    try std.testing.expectEqual(@as(?MarkKey, .item), markKey(36, control_flag));
    try std.testing.expectEqual(@as(?MarkKey, .item), markKey(36, command_flag));
    try std.testing.expectEqual(@as(?MarkKey, .item), markKey(76, control_flag)); // keypad Enter
    try std.testing.expectEqual(@as(?MarkKey, .text), markKey(36, control_flag | shift_flag));
    try std.testing.expectEqual(@as(?MarkKey, .text), markKey(36, command_flag | shift_flag));
    try std.testing.expectEqual(@as(?MarkKey, null), markKey(36, 0)); // plain Return picks and ends
    try std.testing.expectEqual(@as(?MarkKey, null), markKey(36, shift_flag)); // so does Shift+Return
    try std.testing.expectEqual(@as(?MarkKey, null), markKey(36, 1 << 19)); // Option+Return
    try std.testing.expectEqual(@as(?MarkKey, null), markKey(11, control_flag)); // another key
}

test "marks are remembered per item, and out-of-range is harmless" {
    var m = try Marks.init(std.testing.allocator, 3);
    defer m.deinit(std.testing.allocator);
    try std.testing.expect(!m.isMarked(1));
    m.mark(1);
    try std.testing.expect(m.isMarked(1));
    try std.testing.expect(!m.isMarked(0) and !m.isMarked(2));
    m.mark(99); // ignored
    try std.testing.expect(!m.isMarked(99));
    m.mark(1); // marking twice is fine
    try std.testing.expect(m.isMarked(1));
}
