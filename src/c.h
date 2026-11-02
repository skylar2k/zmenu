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

// Everything we use from C: the C library. build.zig runs `translate-c` on this
// file and exposes the result to Zig as `@import("c")`. (The Objective-C side
// comes from the zig-objc package; see cocoa.zig.)
#include <spawn.h>
#include <dirent.h>
#include <stdlib.h>
#include <unistd.h>
