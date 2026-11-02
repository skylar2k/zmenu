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

//! Where zmenu's window goes. Pure arithmetic, so it can be tested.
//! Coordinates are Cocoa's: y grows UPWARDS from the bottom of the screen.
const std = @import("std");

pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

/// A box of size `w` x `h` in the middle of `area`.
pub fn centered(area: Rect, w: f64, h: f64) Rect {
    return .{
        .x = area.x + @floor((area.w - w) / 2),
        .y = area.y + @floor((area.h - h) / 2),
        .w = w,
        .h = h,
    };
}

/// Width of the centered box when `-W` isn't given: 45% of the usable width,
/// but never narrower than 520 or wider than 900 points.
pub fn defaultCenteredWidth(usable_width: f64) f64 {
    return std.math.clamp(usable_width * 0.45, 520, 900);
}

/// A bar across the top or the bottom of the screen. The top bar is at the very
/// top, so it covers the menu bar; the bottom bar covers the Dock. `width`
/// limits it to that much from the left edge (used to stop a top bar at the
/// notch of a notched display); null = the whole screen width.
pub fn bar(screen: Rect, h: f64, at_bottom: bool, width: ?f64) Rect {
    return .{
        .x = screen.x,
        .y = if (at_bottom) screen.y else screen.y + screen.h - h,
        .w = width orelse screen.w,
        .h = h,
    };
}

test "centered box is centered in the usable area, not the whole screen" {
    // A 1000x800 screen with a 100-high Dock at the bottom: usable area y=100..800.
    const usable = Rect{ .x = 0, .y = 100, .w = 1000, .h = 700 };
    const r = centered(usable, 400, 200);
    try std.testing.expectEqual(@as(f64, 300), r.x);
    try std.testing.expectEqual(@as(f64, 350), r.y); // 100 + (700-200)/2
}

test "a Dock on the left moves the centered box to the right" {
    const usable = Rect{ .x = 80, .y = 0, .w = 920, .h = 800 };
    try std.testing.expectEqual(@as(f64, 80 + 260), centered(usable, 400, 100).x);
}

test "default width is clamped" {
    try std.testing.expectEqual(@as(f64, 520), defaultCenteredWidth(800));
    try std.testing.expectEqual(@as(f64, 900), defaultCenteredWidth(3440));
    try std.testing.expectEqual(@as(f64, 0.45 * 1440), defaultCenteredWidth(1440));
}

test "bars hug the top or the bottom edge of the whole screen" {
    const screen = Rect{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try std.testing.expectEqual(@as(f64, 776), bar(screen, 24, false, null).y);
    try std.testing.expectEqual(@as(f64, 0), bar(screen, 24, true, null).y);
    try std.testing.expectEqual(@as(f64, 1000), bar(screen, 24, true, null).w);
}

test "a top bar can stop short of a notch" {
    const screen = Rect{ .x = 0, .y = 0, .w = 2048, .h = 1330 };
    const r = bar(screen, 30, false, 898); // 898 points are usable left of the notch
    try std.testing.expectEqual(@as(f64, 0), r.x);
    try std.testing.expectEqual(@as(f64, 898), r.w);
    try std.testing.expectEqual(@as(f64, 1300), r.y);
}
