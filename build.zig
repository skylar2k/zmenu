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

//! Build script for zmenu.
//!
//!     zig build                         -> zig-out/bin/zmenu
//!     zig build -Doptimize=ReleaseSafe  -> the same, optimised
//!     zig build test                    -> unit tests
//!
//! Two pieces come from outside the Zig code: the C library headers (turned
//! into a Zig module by translate-c) and the Objective-C runtime, which the
//! `zig-objc` package wraps (see build.zig.zon).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const zig_objc = b.dependency("zig_objc", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
            .{ .name = "objc", .module = zig_objc.module("objc") },
        },
    });
    mod.linkFramework("AppKit", .{});

    const exe = b.addExecutable(.{ .name = "zmenu", .root_module = mod });
    b.installArtifact(exe);

    // The unit tests: matching, option parsing, window placement, marks.
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
