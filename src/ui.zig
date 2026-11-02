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

//! zmenu's window: a prompt, a text field, and the matching items either in a
//! row after the field (like dmenu) or in a list under it (`-l`, `-c`).
//!
//! The text field is a real NSTextField, so typing (dead keys, å/ø/æ, pasting,
//! emacs keys like ctrl-a) behaves like everywhere else on macOS. We only
//! intercept the special keys, through the field's delegate
//! (`control:textView:doCommandBySelector:`).
const std = @import("std");
const c = @import("c");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");
const match = @import("match.zig");
const options = @import("options.zig");
const geometry = @import("geometry.zig");
const marks_mod = @import("marks.zig");

const Object = objc.Object;
const id = cocoa.id; // the raw type, for the methods Cocoa calls on us
const NSRect = cocoa.NSRect;
const NSSize = cocoa.NSSize;
const NSPoint = cocoa.NSPoint;
const NSRange = cocoa.NSRange;
const nil: Object = .{ .value = null };

extern "c" const NSFontAttributeName: id;
extern "c" const NSWindowDidResignKeyNotification: id;

const gpa = std.heap.c_allocator;

// ---- state (one menu per process) -------------------------------------------
var opts: options.Options = .{};
var items: []const []const u8 = &.{};
var matches: std.ArrayList(u32) = .empty; // indices into `items`, best first
var selected: usize = 0; // index into `matches`
var page_start: usize = 0; // first visible entry of `matches`

var window: Object = nil;
var content: Object = nil;
var input: Object = nil;
var marks: marks_mod.Marks = .{ .flags = &.{} }; // items marked with Ctrl+Return
var rows: std.ArrayList(Object) = .empty; // one text field per visible item
var more_left: Object = nil; // the "<" and ">" markers (one-line mode)
var more_right: Object = nil;

var font: Object = nil;
var col_nb: Object = nil;
var col_nf: Object = nil;
var col_sb: Object = nil;
var col_sf: Object = nil;
var col_ob: Object = nil; // marked items
var col_of: Object = nil;

var line_h: f64 = 0; // height of a list row
var first_h: f64 = 0; // height of the first line (taller to cover the menu bar)
var pad: f64 = 0; // horizontal padding around text
var win_w: f64 = 0;
var win_h: f64 = 0;
var prompt_w: f64 = 0;
var input_w: f64 = 0;

/// What happens with the chosen text. Default: print it. The launcher mode
/// replaces this with "open the application".
pub var on_accept: *const fn ([]const u8) void = printLine;

pub fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn printLine(s: []const u8) void {
    writeAll(1, s);
    writeAll(1, "\n");
}

// ---- small Cocoa helpers --------------------------------------------------------

fn rect(x: f64, y: f64, w: f64, h: f64) NSRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

/// An NSString from bytes (cut at a character boundary if very long).
fn nsStr(bytes: []const u8) Object {
    var buf: [2048:0]u8 = undefined;
    var n = @min(bytes.len, buf.len - 1);
    while (n > 0 and n < bytes.len and (bytes[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], bytes[0..n]);
    buf[n] = 0;
    const s = cocoa.nsString(&buf);
    return if (!cocoa.isNil(s)) s else cocoa.nsString("?");
}

fn color(col: options.Color) Object {
    return cocoa.class("NSColor").msgSend(Object, "colorWithSRGBRed:green:blue:alpha:", .{ col.r, col.g, col.b, @as(f64, 1) });
}

fn makeFont(spec: ?[]const u8) Object {
    var name: ?[]const u8 = null;
    var size: f64 = options.default_font_size;
    if (spec) |s| {
        const f = options.parseFont(s);
        name = f.name;
        size = f.size;
    }
    if (name) |n| {
        if (!std.mem.eql(u8, n, "monospace")) {
            const f = cocoa.class("NSFont").msgSend(Object, "fontWithName:size:", .{ nsStr(n), size });
            if (!cocoa.isNil(f)) return f;
        }
    }
    return cocoa.class("NSFont").msgSend(Object, "monospacedSystemFontOfSize:weight:", .{ size, @as(f64, 0) });
}

fn textWidth(s: []const u8) f64 {
    const dict = cocoa.class("NSDictionary").msgSend(Object, "dictionaryWithObject:forKey:", .{ font, NSFontAttributeName });
    return nsStr(s).msgSend(NSSize, "sizeWithAttributes:", .{dict}).width;
}

/// `secure` = a password field: it shows dots, and while you type in it macOS
/// stops other programs from reading your keystrokes ("secure event input").
fn makeField(frame: NSRect, editable: bool, secure: bool) Object {
    const klass = if (secure) cocoa.class("NSSecureTextField") else cocoa.class("NSTextField");
    const f = klass.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{frame});
    f.msgSend(void, "setBordered:", .{false});
    f.msgSend(void, "setBezeled:", .{false});
    f.msgSend(void, "setDrawsBackground:", .{true});
    f.msgSend(void, "setBackgroundColor:", .{col_nb});
    f.msgSend(void, "setTextColor:", .{col_nf});
    f.msgSend(void, "setFont:", .{font});
    f.msgSend(void, "setFocusRingType:", .{@as(isize, 1)}); // none
    f.msgSend(void, "setEditable:", .{editable});
    f.msgSend(void, "setSelectable:", .{editable});
    const cell = f.msgSend(Object, "cell", .{});
    cell.msgSend(void, "setLineBreakMode:", .{@as(isize, 4)}); // truncate the end with "..."
    cell.msgSend(void, "setUsesSingleLineMode:", .{true});
    cell.msgSend(void, "setScrollable:", .{editable});
    return f;
}

fn setText(field: Object, text: []const u8) void {
    field.msgSend(void, "setStringValue:", .{nsStr(text)});
}

fn style(field: Object, kind: marks_mod.RowKind) void {
    const bg = switch (kind) {
        .normal => col_nb,
        .selected => col_sb,
        .marked => col_ob,
    };
    const fg = switch (kind) {
        .normal => col_nf,
        .selected => col_sf,
        .marked => col_of,
    };
    field.msgSend(void, "setBackgroundColor:", .{bg});
    field.msgSend(void, "setTextColor:", .{fg});
}

/// How to draw entry `idx` of the filtered list.
fn kindOf(idx: usize) marks_mod.RowKind {
    return marks_mod.rowKind(idx == selected, marks.isMarked(matches.items[idx]));
}

fn setHidden(field: Object, hidden: bool) void {
    field.msgSend(void, "setHidden:", .{hidden});
}

// ---- screens ------------------------------------------------------------------------

/// A screen: the whole thing (`x`..`h`), and its usable part (`vis`) without
/// the menu bar and a visible Dock. `top_inset` = the menu bar's height.
/// `notch_left_w` = how much of the top edge, from the left, is usable before a
/// notch (0 on screens without one).
const Screen = struct { x: f64, y: f64, w: f64, h: f64, top_inset: f64, notch_left_w: f64, vis: geometry.Rect };

/// Screens in Cocoa coordinates (y up), ordered left to right: the same
/// order zwm numbers its monitors in.
fn listScreens(out: []Screen) usize {
    const arr = cocoa.class("NSScreen").msgSend(Object, "screens", .{});
    const count = @min(arr.msgSend(usize, "count", .{}), out.len);
    for (0..count) |i| {
        const s = arr.msgSend(Object, "objectAtIndex:", .{i});
        const f = s.msgSend(NSRect, "frame", .{});
        const vis = s.msgSend(NSRect, "visibleFrame", .{}); // minus menu bar and Dock
        // Notched displays: the menu bar has a usable area left of the notch.
        var notch_left_w: f64 = 0;
        if (s.msgSend(bool, "respondsToSelector:", .{objc.sel("auxiliaryTopLeftArea")})) {
            const aux = s.msgSend(NSRect, "auxiliaryTopLeftArea", .{});
            if (aux.size.width > 0 and aux.size.width < f.size.width) notch_left_w = aux.size.width;
        }
        out[i] = .{
            .notch_left_w = notch_left_w,
            .x = f.origin.x,
            .y = f.origin.y,
            .w = f.size.width,
            .h = f.size.height,
            .top_inset = std.math.clamp((f.origin.y + f.size.height) - (vis.origin.y + vis.size.height), 0, 60),
            .vis = .{ .x = vis.origin.x, .y = vis.origin.y, .w = vis.size.width, .h = vis.size.height },
        };
    }
    std.mem.sort(Screen, out[0..count], {}, struct {
        fn lt(_: void, a: Screen, b: Screen) bool {
            if (a.x != b.x) return a.x < b.x;
            return a.y > b.y; // higher on the desk first
        }
    }.lt);
    return count;
}

fn pickScreen() Screen {
    var list: [16]Screen = undefined;
    const n = listScreens(&list);
    if (n == 0) return .{ .x = 0, .y = 0, .w = 1440, .h = 900, .top_inset = 0, .notch_left_w = 0, .vis = .{ .x = 0, .y = 0, .w = 1440, .h = 900 } };
    if (opts.monitor) |m| return list[@min(m, n - 1)];
    const p = cocoa.class("NSEvent").msgSend(NSPoint, "mouseLocation", .{});
    for (list[0..n]) |s| {
        if (p.x >= s.x and p.x < s.x + s.w and p.y >= s.y and p.y < s.y + s.h) return s;
    }
    return list[0];
}

// ---- what the user does -------------------------------------------------------------

fn currentText(buf: []u8) []const u8 {
    return cocoa.utf8(input.msgSend(Object, "stringValue", .{}), buf) orelse "";
}

fn refilter() void {
    var buf: [2048]u8 = undefined;
    match.filter(gpa, items, currentText(&buf), opts.insensitive, &matches) catch return;
    selected = 0;
    page_start = 0;
    render();
}

fn accept(text_only: bool) void {
    var buf: [2048]u8 = undefined;
    const text = currentText(&buf);
    const out = if (text_only or matches.items.len == 0) text else items[matches.items[selected]];
    on_accept(out);
    std.process.exit(0);
}

fn move(delta: i64) void {
    if (matches.items.len == 0) return;
    const last: i64 = @intCast(matches.items.len - 1);
    const next = std.math.clamp(@as(i64, @intCast(selected)) + delta, 0, last);
    selected = @intCast(next);
    render();
}

fn complete() void {
    if (matches.items.len == 0) return;
    const text = items[matches.items[selected]];
    setText(input, text);
    const editor = input.msgSend(Object, "currentEditor", .{});
    if (!cocoa.isNil(editor)) {
        const len = editor.msgSend(Object, "string", .{}).msgSend(usize, "length", .{});
        editor.msgSend(void, "setSelectedRange:", .{NSRange{ .location = len, .length = 0 }});
    }
    refilter();
}

/// Was shift held for the key being handled? Asked of the key event itself
/// (not of the keyboard hardware), so it is right for any source of key events.
fn modifierHeld(mask: usize) bool {
    const event = cocoa.sharedApplication().msgSend(Object, "currentEvent", .{});
    const flags = if (!cocoa.isNil(event))
        event.msgSend(usize, "modifierFlags", .{})
    else
        cocoa.class("NSEvent").msgSend(usize, "modifierFlags", .{});
    return flags & mask != 0;
}

fn shiftHeld() bool {
    return modifierHeld(1 << 17);
}

/// Ctrl+Return / Cmd+Return (multi-select): hand over the highlighted item now, mark it, and
/// keep the menu open. With Shift as well, hand over the typed text instead.
/// Like dmenu, which prints the item and sets its "out" flag.
fn markCurrent(text_only: bool) void {
    var buf: [2048]u8 = undefined;
    const text = currentText(&buf);
    const have_item = matches.items.len > 0 and !text_only;
    on_accept(if (have_item) items[matches.items[selected]] else text);
    if (have_item) {
        marks.mark(matches.items[selected]);
        render();
    }
}

fn pageSize() i64 {
    if (opts.lines > 0) return @intCast(opts.lines);
    return 8;
}

/// Returns true if we handled the key (so the text field must not).
fn handleCommand(textview: Object, name: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, name, "insertNewline:") or eq(u8, name, "insertNewlineIgnoringFieldEditor:") or eq(u8, name, "insertLineBreak:")) {
        accept(shiftHeld()); // shift+return: the text as typed
        return true;
    }
    if (eq(u8, name, "cancelOperation:")) std.process.exit(1);
    if (eq(u8, name, "insertTab:")) {
        complete();
        return true;
    }
    if (eq(u8, name, "moveDown:")) {
        move(1);
        return true;
    }
    if (eq(u8, name, "moveUp:")) {
        move(-1);
        return true;
    }
    if (eq(u8, name, "pageDown:") or eq(u8, name, "scrollPageDown:")) {
        move(pageSize());
        return true;
    }
    if (eq(u8, name, "pageUp:") or eq(u8, name, "scrollPageUp:")) {
        move(-pageSize());
        return true;
    }
    if (eq(u8, name, "scrollToBeginningOfDocument:")) { // Home
        selected = 0;
        render();
        return true;
    }
    if (eq(u8, name, "scrollToEndOfDocument:")) { // End
        if (matches.items.len > 0) selected = matches.items.len - 1;
        render();
        return true;
    }
    // In one-line mode left/right walk through the items once the text cursor
    // is at the end / start of what you typed, like dmenu.
    if (opts.lines == 0 and (eq(u8, name, "moveRight:") or eq(u8, name, "moveLeft:"))) {
        const range = textview.msgSend(NSRange, "selectedRange", .{});
        if (eq(u8, name, "moveRight:")) {
            const len = textview.msgSend(Object, "string", .{}).msgSend(usize, "length", .{});
            if (range.location + range.length >= len) {
                move(1);
                return true;
            }
        } else if (range.location == 0 and range.length == 0) {
            move(-1);
            return true;
        }
    }
    return false;
}

// ---- drawing ----------------------------------------------------------------------------

fn itemWidth(idx: usize) f64 {
    const w = textWidth(items[matches.items[idx]]) + 2 * pad;
    return @min(w, win_w - prompt_w - input_w - 4 * pad);
}

fn fitFrom(start: usize, avail: f64) usize {
    var sum: f64 = 0;
    var k: usize = 0;
    while (start + k < matches.items.len and k < 200) : (k += 1) {
        const w = itemWidth(start + k);
        if (k > 0 and sum + w > avail) break;
        sum += w;
    }
    return k;
}

fn rowAt(i: usize) Object {
    while (rows.items.len <= i) {
        const f = makeField(rect(0, 0, 10, line_h), false, false);
        f.msgSend(void, "setAlignment:", .{@as(usize, 2)}); // centred
        content.msgSend(void, "addSubview:", .{f});
        rows.append(gpa, f) catch return f;
    }
    return rows.items[i];
}

fn renderList() void {
    const lines = opts.lines;
    if (matches.items.len > 0) {
        if (selected < page_start) page_start = selected;
        if (selected >= page_start + lines) page_start = selected + 1 - lines;
    }
    for (0..lines) |r| {
        const row = rows.items[r];
        const idx = page_start + r;
        if (idx < matches.items.len) {
            var buf: [2050]u8 = undefined;
            const shown = std.fmt.bufPrint(&buf, " {s}", .{items[matches.items[idx]]}) catch items[matches.items[idx]];
            setText(row, shown);
            style(row, kindOf(idx));
            setHidden(row, false);
        } else {
            setHidden(row, true);
        }
    }
}

fn renderRow() void {
    const ind_w = pad * 1.5;
    const avail = win_w - prompt_w - input_w - 2 * ind_w;
    var fit = fitFrom(page_start, avail);
    if (matches.items.len > 0) {
        if (selected < page_start or selected >= page_start + fit) {
            page_start = selected;
            fit = fitFrom(page_start, avail);
        }
    }
    var x = prompt_w + input_w + ind_w;
    const y = win_h - first_h;
    for (0..fit) |k| {
        const idx = page_start + k;
        const w = itemWidth(idx);
        const row = rowAt(k);
        row.msgSend(void, "setFrame:", .{rect(x, y, w, first_h)});
        setText(row, items[matches.items[idx]]);
        style(row, kindOf(idx));
        setHidden(row, false);
        x += w;
    }
    for (fit..rows.items.len) |k| setHidden(rows.items[k], true);
    setHidden(more_left, page_start == 0);
    setHidden(more_right, page_start + fit >= matches.items.len);
}

fn render() void {
    if (opts.lines > 0) renderList() else renderRow();
}

// ---- Objective-C glue ----------------------------------------------------------------------

// Cocoa calls these as fn(self, _cmd, arguments...). zig-objc derives each
// method's type encoding from the Zig signature.

fn yes(_: id, _: cocoa.SEL) callconv(.c) bool {
    return true;
}

/// Every event for the window passes through here first. We use it for the keys
/// the text field's own key bindings would otherwise swallow: Ctrl+Return and
/// Cmd+Return (multi-select), see marks.markKey. Everything else goes on to what
/// NSPanel itself does with it.
fn panelSendEvent(self: id, _: cocoa.SEL, event: id) callconv(.c) void {
    const ev = Object.fromId(event);
    const key_down = 10; // NSEventTypeKeyDown
    if (ev.msgSend(usize, "type", .{}) == key_down) {
        const code = ev.msgSend(u16, "keyCode", .{});
        const flags = ev.msgSend(usize, "modifierFlags", .{});
        if (marks_mod.markKey(code, flags)) |kind| {
            markCurrent(kind == .text);
            return;
        }
    }
    Object.fromId(self).msgSendSuper(cocoa.class("NSPanel"), void, "sendEvent:", .{event});
}

fn onTextChanged(_: id, _: cocoa.SEL, _: id) callconv(.c) void {
    refilter();
}

fn onCommand(_: id, _: cocoa.SEL, _: id, textview: id, command: cocoa.SEL) callconv(.c) bool {
    return handleCommand(Object.fromId(textview), (objc.Sel{ .value = command }).getName());
}

/// Clicking somewhere else closes the menu, like dmenu giving up the keyboard.
fn onResign(_: id, _: cocoa.SEL, _: id) callconv(.c) void {
    std.process.exit(1);
}

// ---- setup -------------------------------------------------------------------------------------

pub fn run(o: options.Options, all_items: []const []const u8) noreturn {
    opts = o;
    items = if (o.password) &.{} else all_items; // a password prompt has no choices
    marks = marks_mod.Marks.init(gpa, items.len) catch .{ .flags = &.{} };

    const app = cocoa.sharedApplication();
    // Accessory: no Dock icon, no menu bar of its own.
    _ = app.msgSend(bool, "setActivationPolicy:", .{@as(isize, 1)});

    font = makeFont(opts.font);
    col_nb = color(opts.nb);
    col_nf = color(opts.nf);
    col_sb = color(opts.sb);
    col_sf = color(opts.sf);
    col_ob = color(opts.ob);
    col_of = color(opts.of);

    const asc = font.msgSend(f64, "ascender", .{});
    const desc = font.msgSend(f64, "descender", .{});
    const lead = font.msgSend(f64, "leading", .{});
    line_h = opts.height orelse (@ceil(asc - desc + lead) + 8);
    pad = @floor(line_h / 2);

    // Where the window goes.
    const scr = pickScreen();
    // The first line. A top bar is, by default, just tall enough to hide the
    // menu bar's text (but never taller than the menu bar); `-H menubar` hides
    // the menu bar completely; `-H n` sets it exactly.
    first_h = line_h;
    if (!opts.centered and !opts.bottom and opts.height == null and scr.top_inset > 0) {
        first_h = if (opts.cover_menubar)
            @max(line_h, scr.top_inset)
        else
            @min(@max(line_h, 30), @max(line_h, scr.top_inset));
    }
    win_h = first_h + line_h * @as(f64, @floatFromInt(opts.lines));
    // Bars span the whole screen (the top one covers the menu bar, the bottom
    // one the Dock); the centered box sits in the middle of the USABLE area,
    // so a visible Dock or the menu bar doesn't push it off-centre.
    // A top bar stops at the notch, if the screen has one: nothing is drawn
    // under it, and the status icons on the right stay visible.
    const bar_width: ?f64 = if (!opts.bottom and scr.notch_left_w > 0) scr.notch_left_w else null;
    win_w = if (opts.centered) (opts.width orelse geometry.defaultCenteredWidth(scr.vis.w)) else (bar_width orelse scr.w);
    const frame = if (opts.centered)
        geometry.centered(scr.vis, win_w, win_h)
    else
        geometry.bar(.{ .x = scr.x, .y = scr.y, .w = scr.w, .h = scr.h }, win_h, opts.bottom, bar_width);
    const win_x = frame.x;
    const win_y = frame.y;

    // Column widths of the first line.
    prompt_w = if (opts.prompt.len > 0) textWidth(opts.prompt) + 2 * pad else 0;
    if (opts.lines > 0) {
        input_w = win_w - prompt_w;
    } else {
        var widest: []const u8 = "";
        for (items) |it| {
            if (it.len > widest.len) widest = it;
        }
        input_w = std.math.clamp(textWidth(widest) + 2 * pad, 120, @floor(win_w / 3));
    }
    if (opts.password and opts.lines == 0) input_w = @max(input_w, @floor(win_w / 3));

    // The window: a panel that takes keyboard focus without a title bar, above
    // everything including the menu bar (window level 101 = pop-up menus).
    const panel_class = objc.allocateClassPair(cocoa.class("NSPanel"), "ZmenuPanel").?;
    if (!panel_class.addMethod("canBecomeKeyWindow", yes) or
        !panel_class.addMethod("canBecomeMainWindow", yes) or
        !panel_class.addMethod("sendEvent:", panelSendEvent)) @panic("could not add the panel's methods");
    objc.registerClassPair(panel_class);
    window = panel_class.msgSend(Object, "alloc", .{}).msgSend(
        Object,
        "initWithContentRect:styleMask:backing:defer:",
        .{
            rect(win_x, win_y, win_w, win_h),
            @as(usize, 128), // borderless + non-activating panel
            @as(usize, 2), // buffered
            false,
        },
    );
    window.msgSend(void, "setLevel:", .{@as(isize, 101)});
    // Not opaque, so the rounded corners show what is behind the window.
    window.msgSend(void, "setOpaque:", .{opts.radius <= 0});
    window.msgSend(void, "setBackgroundColor:", .{if (opts.radius > 0) cocoa.class("NSColor").msgSend(Object, "clearColor", .{}) else col_nb});
    window.msgSend(void, "setHasShadow:", .{opts.centered});
    window.msgSend(void, "setCollectionBehavior:", .{@as(usize, 1 | 256)}); // all Spaces, over full-screen apps
    window.msgSend(void, "setReleasedWhenClosed:", .{false});
    window.msgSend(void, "setHidesOnDeactivate:", .{false});

    content = window.msgSend(Object, "contentView", .{});
    content.msgSend(void, "setWantsLayer:", .{true});
    const layer = content.msgSend(Object, "layer", .{});
    layer.msgSend(void, "setBackgroundColor:", .{col_nb.msgSend(?*anyopaque, "CGColor", .{})});
    if (opts.radius > 0) {
        layer.msgSend(void, "setCornerRadius:", .{opts.radius});
        layer.msgSend(void, "setMasksToBounds:", .{true});
        // CACornerMask bits (y points up here): 1 bottom-left, 2 bottom-right,
        // 4 top-left, 8 top-right.
        const corners: usize = if (opts.centered) 15 else if (opts.bottom) 3 else 12;
        layer.msgSend(void, "setMaskedCorners:", .{corners});
    }

    // First line: [prompt] [input] [items...]
    const top = win_h - first_h;
    if (opts.prompt.len > 0) {
        const p = makeField(rect(0, top, prompt_w, first_h), false, false);
        p.msgSend(void, "setAlignment:", .{@as(usize, 2)});
        style(p, .selected);
        setText(p, opts.prompt);
        content.msgSend(void, "addSubview:", .{p});
    }
    input = makeField(rect(prompt_w + pad, top, input_w - pad, first_h), true, opts.password);
    content.msgSend(void, "addSubview:", .{input});

    if (opts.lines > 0) {
        for (0..opts.lines) |r| {
            const f = makeField(rect(0, top - line_h * @as(f64, @floatFromInt(r + 1)), win_w, line_h), false, false);
            content.msgSend(void, "addSubview:", .{f});
            rows.append(gpa, f) catch {};
        }
    } else {
        const ind_w = pad * 1.5;
        more_left = makeField(rect(prompt_w + input_w, top, ind_w, first_h), false, false);
        more_left.msgSend(void, "setAlignment:", .{@as(usize, 2)});
        setText(more_left, "<");
        more_right = makeField(rect(win_w - ind_w, top, ind_w, first_h), false, false);
        more_right.msgSend(void, "setAlignment:", .{@as(usize, 2)});
        setText(more_right, ">");
        content.msgSend(void, "addSubview:", .{more_left});
        content.msgSend(void, "addSubview:", .{more_right});
    }

    // Events: typing and special keys go to the delegate.
    const delegate_class = objc.allocateClassPair(cocoa.class("NSObject"), "ZmenuDelegate").?;
    if (!delegate_class.addMethod("controlTextDidChange:", onTextChanged) or
        !delegate_class.addMethod("control:textView:doCommandBySelector:", onCommand) or
        !delegate_class.addMethod("windowDidResignKey:", onResign)) @panic("could not add the delegate's methods");
    objc.registerClassPair(delegate_class);
    const delegate = delegate_class.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
    input.msgSend(void, "setDelegate:", .{delegate});
    const center = cocoa.class("NSNotificationCenter").msgSend(Object, "defaultCenter", .{});
    center.msgSend(void, "addObserver:selector:name:object:", .{ delegate, objc.sel("windowDidResignKey:"), NSWindowDidResignKeyNotification, window });

    refilter();

    app.msgSend(void, "activateIgnoringOtherApps:", .{true});
    window.msgSend(void, "makeKeyAndOrderFront:", .{@as(id, null)});
    _ = window.msgSend(bool, "makeFirstResponder:", .{input});
    // The text cursor is drawn in the field's text colour only if we say so.
    const editor = input.msgSend(Object, "currentEditor", .{});
    if (!cocoa.isNil(editor)) editor.msgSend(void, "setInsertionPointColor:", .{col_nf});

    app.msgSend(void, "run", .{});
    std.process.exit(1); // not reached
}
