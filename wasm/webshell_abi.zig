//! Compatibility ABI used by WebShell and the native terminal clients.
//! The terminal parser and snapshot format come from Ghostty's lib-vt C API.
const std = @import("std");
const terminal = @import("terminal/main.zig");
const c = terminal.c_api;
const wasm_alloc = @import("lib/allocator/wasm.zig");
const Allocator = std.mem.Allocator;
const alloc = @import("terminal/lib.zig").alloc.default(null);
const RenderState = terminal.RenderState;
const Style = terminal.Style;
const color = terminal.color;
const modespkg = terminal.modes;
const continuation_limit: usize = 1024 * 1024;

const TerminalWrapper = struct {
    alloc: Allocator = alloc,
    core: c.terminal.Terminal,
    terminal: *terminal.Terminal,
    render_state: RenderState = .empty,
    response_buffer: std.ArrayList(u8) = .empty,
    response_failed: bool = false,
    last_screen_is_alternate: bool = false,
};

const GhosttyCell = extern struct {
    codepoint: u32,
    fg_r: u8, fg_g: u8, fg_b: u8,
    bg_r: u8, bg_g: u8, bg_b: u8,
    flags: u8, width: u8, hyperlink_id: u16,
    grapheme_len: u8 = 0, _pad: u8 = 0,
};
const GhosttyDirty = enum(u8) { none = 0, partial = 1, full = 2 };
const GhosttyTerminalConfig = extern struct {
    scrollback_limit: u32,
    fg_color: u32,
    bg_color: u32,
    cursor_color: u32,
    palette: [16]u32,
};

fn response(_: c.terminal.Terminal, userdata: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(userdata orelse return));
    wrapper.response_buffer.appendSlice(wrapper.alloc, bytes[0..len]) catch {
        wrapper.response_failed = true;
    };
}

// Keep the identity reported by the previous WebShell core: VT220 with ANSI
// color for DA1 and firmware 10 for DA2.
fn deviceAttributes(_: c.terminal.Terminal, _: ?*anyopaque, out: *c.terminal.DeviceAttributes) callconv(.c) bool {
    out.* = std.mem.zeroes(c.terminal.DeviceAttributes);
    out.primary.conformance_level = 62;
    out.primary.features[0] = 22;
    out.primary.num_features = 1;
    out.secondary = .{ .device_type = 1, .firmware_version = 10, .rom_cartridge = 0 };
    return true;
}

fn configureCore(wrapper: *TerminalWrapper, core: c.terminal.Terminal) bool {
    return c.terminal.set(core, .userdata, wrapper) == .success and
        c.terminal.set(core, .write_pty, @ptrCast(&response)) == .success and
        c.terminal.set(core, .device_attributes, @ptrCast(&deviceAttributes)) == .success and
        c.terminal.set(core, .continuation_max_bytes, &continuation_limit) == .success;
}

fn rgbFromU32(value: u32) color.RGB {
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}

pub fn checkpointTheme(ptr: ?*anyopaque, config: *const GhosttyTerminalConfig) callconv(.c) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return));
    const colors = &wrapper.terminal.colors;
    colors.foreground.default = if (config.fg_color == 0) null else rgbFromU32(config.fg_color);
    colors.background.default = if (config.bg_color == 0) null else rgbFromU32(config.bg_color);
    colors.cursor.default = if (config.cursor_color == 0) null else rgbFromU32(config.cursor_color);
    var palette = color.default;
    for (config.palette, 0..) |value, index| if (value != 0) { palette[index] = rgbFromU32(value); };
    colors.palette.changeDefault(wrapper.alloc, palette) catch return;
    wrapper.terminal.flags.dirty.palette = true;
    wrapper.render_state.deinit(wrapper.alloc);
    wrapper.render_state = .empty;
}

pub fn new(cols: c_int, rows: c_int) callconv(.c) ?*anyopaque {
    return newWithConfig(cols, rows, null);
}
pub fn newWithConfig(cols: c_int, rows: c_int, config: ?*const GhosttyTerminalConfig) callconv(.c) ?*anyopaque {
    if (cols < 1 or rows < 1 or cols > 65535 or rows > 65535) return null;
    var core: c.terminal.Terminal = null;
    if (c.terminal.new(null, &core, @intCast(cols), @intCast(rows)) != .success) return null;
    const wrapper = alloc.create(TerminalWrapper) catch { c.terminal.free(core); return null; };
    wrapper.* = .{ .core = core, .terminal = c.terminal.zigTerminal(core).? };
    if (!configureCore(wrapper, core)) {
        c.terminal.free(core);
        alloc.destroy(wrapper);
        return null;
    }
    wrapper.terminal.modes.set(.linefeed, false);
    wrapper.terminal.modes.set(.grapheme_cluster, true);
    if (config) |cfg| {
        const limit: usize = cfg.scrollback_limit;
        wrapper.terminal.setScrollbackMaxBytes(if (limit == 0) null else limit);
        checkpointTheme(wrapper, cfg);
    }
    return wrapper;
}
pub fn free(ptr: ?*anyopaque) callconv(.c) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return));
    wrapper.render_state.deinit(wrapper.alloc);
    wrapper.response_buffer.deinit(wrapper.alloc);
    c.terminal.free(wrapper.core);
    alloc.destroy(wrapper);
}
pub fn resize(ptr: ?*anyopaque, cols: c_int, rows: c_int) callconv(.c) c_int {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    if (cols < 1 or rows < 1 or cols > 65535 or rows > 65535) return 0;
    return if (c.terminal.resize(wrapper.core, @intCast(cols), @intCast(rows), 0, 0) == .success) 1 else 0;
}
pub fn setScrollbackLimit(ptr: ?*anyopaque, max_bytes: u32) callconv(.c) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return));
    const limit: usize = if (max_bytes == 0) std.math.maxInt(usize) else max_bytes;
    const primary = wrapper.terminal.screens.get(.primary) orelse return;
    if (limit > primary.pages.limits.bytes.explicit) wrapper.terminal.setScrollbackMaxBytes(if (max_bytes == 0) null else limit);
}
pub fn write(ptr: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) c_int {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    c.terminal.vt_write(wrapper.core, data, len);
    return if (wrapper.response_failed) 0 else 1;
}

/// Encode to an allocator-owned GHOSTSNP buffer. Release with snapshotFree.
pub fn snapshotEncode(ptr: ?*anyopaque, out: *?[*]u8, len: *usize) callconv(.c) c_int {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    return if (c.snapshot.encode_alloc(wrapper.core, null, out, len) == .success) 1 else 0;
}
pub fn snapshotFree(ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr) |p| alloc.free(p[0..len]);
}
/// Fully validate and decode before replacing the current terminal.
pub fn snapshotRestore(ptr: ?*anyopaque, data: [*]const u8, len: usize, cols: u16, rows: u16) callconv(.c) c_int {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    var decoder: c.snapshot.Decoder = null;
    if (c.snapshot.decoder_new_buf(null, &decoder, data, len) != .success) return 0;
    defer c.snapshot.decoder_free(decoder);
    const retain = true;
    if (c.snapshot.decoder_set(decoder, .max_continuation_bytes, &continuation_limit) != .success or
        c.snapshot.decoder_set(decoder, .retain_continuation, &retain) != .success) return 0;
    var core: c.terminal.Terminal = null;
    if (c.snapshot.decoder_decode(decoder, &core) != .success) return 0;
    const restored = c.terminal.zigTerminal(core).?;
    if (restored.cols != cols or restored.rows != rows or !configureCore(wrapper, core)) {
        c.terminal.free(core);
        return 0;
    }
    wrapper.render_state.deinit(wrapper.alloc);
    wrapper.render_state = .empty;
    c.terminal.free(wrapper.core);
    wrapper.core = core;
    wrapper.terminal = restored;
    wrapper.response_buffer.clearRetainingCapacity();
    wrapper.response_failed = false;
    wrapper.last_screen_is_alternate = restored.screens.active_key == .alternate;
    return 1;
}

fn allocU8() callconv(.c) ?[*]u8 { return wasm_alloc.allocBytes(1); }
fn freeU8(p: ?[*]u8) callconv(.c) void { wasm_alloc.freeBytes(p, 1); }
fn allocUsize() callconv(.c) ?[*]u8 { return wasm_alloc.allocBytes(@sizeOf(usize)); }
fn freeUsize(p: ?[*]u8) callconv(.c) void { wasm_alloc.freeBytes(p, @sizeOf(usize)); }
fn allocU16Array(n: usize) callconv(.c) ?[*]u8 { return wasm_alloc.allocBytes(std.math.mul(usize, n, 2) catch return null); }
fn freeU16Array(p: ?[*]u8, n: usize) callconv(.c) void { wasm_alloc.freeBytes(p, std.math.mul(usize, n, 2) catch return); }
fn allocSgr() callconv(.c) ?[*]u8 { return wasm_alloc.allocBytes(@sizeOf(terminal.sgr.Attribute.C)); }
fn freeSgr(p: ?[*]u8) callconv(.c) void { wasm_alloc.freeBytes(p, @sizeOf(terminal.sgr.Attribute.C)); }
fn diagnosticCells(_: ?*anyopaque, _: [*]u32, _: usize) callconv(.c) c_int { return -1; }
fn diagnosticEmpty() callconv(.c) usize { return 0; }

pub fn renderStateUpdate(ptr: ?*anyopaque) callconv(.c) GhosttyDirty {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return .full));
    
    // Detect screen buffer switch (normal <-> alternate)
    const current_is_alternate = wrapper.terminal.screens.active_key == .alternate;
    const screen_switched = current_is_alternate != wrapper.last_screen_is_alternate;
    wrapper.last_screen_is_alternate = current_is_alternate;
    
    // When screen switches, we must fully reset the render state to avoid
    // stale cached cell data from the previous screen buffer.
    if (screen_switched) {
        wrapper.render_state.deinit(wrapper.alloc);
        wrapper.render_state = RenderState.empty;
    }
    
    wrapper.render_state.update(wrapper.alloc, wrapper.terminal) catch return .full;
    
    // If screen switched, always return full dirty to force complete redraw
    if (screen_switched) {
        return .full;
    }
    
    return switch (wrapper.render_state.dirty) {
        .false => .none,
        .partial => .partial,
        .full => .full,
    };
}

/// Get dimensions from render state
pub fn renderStateGetCols(ptr: ?*anyopaque) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    return @intCast(wrapper.render_state.cols);
}

pub fn renderStateGetRows(ptr: ?*anyopaque) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    return @intCast(wrapper.render_state.rows);
}

/// Get cursor X position
pub fn renderStateGetCursorX(ptr: ?*anyopaque) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    return @intCast(wrapper.render_state.cursor.active.x);
}

/// Get cursor Y position  
pub fn renderStateGetCursorY(ptr: ?*anyopaque) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    return @intCast(wrapper.render_state.cursor.active.y);
}

/// Check if cursor is visible
pub fn renderStateGetCursorVisible(ptr: ?*anyopaque) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return false));
    return wrapper.render_state.cursor.visible;
}

/// Get default background color as 0xRRGGBB
pub fn renderStateGetBgColor(ptr: ?*anyopaque) callconv(.c) u32 {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    const bg = wrapper.render_state.colors.background;
    return (@as(u32, bg.r) << 16) | (@as(u32, bg.g) << 8) | bg.b;
}

/// Get default foreground color as 0xRRGGBB
pub fn renderStateGetFgColor(ptr: ?*anyopaque) callconv(.c) u32 {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0xCCCCCC));
    const fg = wrapper.render_state.colors.foreground;
    return (@as(u32, fg.r) << 16) | (@as(u32, fg.g) << 8) | fg.b;
}

/// Check if row is dirty
pub fn renderStateIsRowDirty(ptr: ?*anyopaque, y: c_int) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return true));
    if (wrapper.render_state.dirty == .full) return true;
    if (wrapper.render_state.dirty == .false) return false;
    const y_usize: usize = @intCast(y);
    if (y_usize >= wrapper.render_state.row_data.len) return false;
    return wrapper.render_state.row_data.items(.dirty)[y_usize];
}

/// Mark render state as clean after rendering
pub fn renderStateMarkClean(ptr: ?*anyopaque) callconv(.c) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return));
    wrapper.render_state.dirty = .false;
    @memset(wrapper.render_state.row_data.items(.dirty), false);
}

/// Get ALL viewport cells from the official RenderState snapshot in one call.
/// RenderState owns the viewport row mapping and copies managed cell data so
/// page movement cannot invalidate the exported frame while it is being read.
/// Returns total cells written (rows * cols), or -1 on error.
pub fn renderStateGetViewport(
    ptr: ?*anyopaque,
    out: [*]GhosttyCell,
    buf_size: usize,
) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));
    const rs = &wrapper.render_state;
    const rows = rs.rows;
    const cols = rs.cols;
    const total: usize = @as(usize, rows) * cols;

    if (buf_size < total) return -1;
    if (rs.row_data.len != rows) return -1;

    var idx: usize = 0;
    for (0..rows) |y| {
        const cells = rs.row_data.items(.cells)[y].slice();
        const raw_cells = cells.items(.raw);
        const graphemes = cells.items(.grapheme);
        const styles = cells.items(.style);
        if (raw_cells.len != cols) return -1;

        for (0..cols) |x| {
            const cell = &raw_cells[x];
            const sty: Style = switch (cell.content_tag) {
                .bg_color_rgb, .bg_color_palette => styles[x],
                else => if (cell.style_id > 0) styles[x] else .{},
            };

            // Resolve colors
            const fg: color.RGB = switch (sty.fg_color) {
                .none => rs.colors.foreground,
                .palette => |i| rs.colors.palette[i],
                .rgb => |value| value,
            };
            const bg: color.RGB = if (sty.bg(cell, &rs.colors.palette)) |rgb| rgb else rs.colors.background;

            // Build flags
            var flags: u8 = 0;
            if (sty.flags.bold) flags |= 1 << 0;
            if (sty.flags.italic) flags |= 1 << 1;
            if (sty.flags.underline != .none) flags |= 1 << 2;
            if (sty.flags.strikethrough) flags |= 1 << 3;
            if (sty.flags.inverse) flags |= 1 << 4;
            if (sty.flags.invisible) flags |= 1 << 5;
            if (sty.flags.blink) flags |= 1 << 6;
            if (sty.flags.faint) flags |= 1 << 7;

            const grapheme_len: u8 = if (cell.hasGrapheme())
                @intCast(@min(graphemes[x].len, std.math.maxInt(u8)))
            else 0;

            out[idx] = .{
                .codepoint = cell.codepoint(),
                .fg_r = fg.r,
                .fg_g = fg.g,
                .fg_b = fg.b,
                .bg_r = bg.r,
                .bg_g = bg.g,
                .bg_b = bg.b,
                .flags = flags,
                .width = switch (cell.wide) {
                    .narrow => 1,
                    .wide => 2,
                    .spacer_tail, .spacer_head => 0,
                },
                .hyperlink_id = if (cell.hyperlink) 1 else 0,
                .grapheme_len = grapheme_len,
            };
            idx += 1;
        }
    }

    return @intCast(total);
}

/// Get grapheme codepoints for a cell at (row, col).
/// Returns all codepoints (including the first one) as u32 values.
/// Returns the number of codepoints written, or -1 on error.
pub fn renderStateGetGrapheme(
    ptr: ?*anyopaque,
    row: c_int,
    col: c_int,
    out: [*]u32,
    buf_size: usize,
) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));
    const rs = &wrapper.render_state;
    const cols: usize = @intCast(rs.cols);

    if (row < 0 or col < 0) return -1;
    const y: usize = @intCast(row);
    const x: usize = @intCast(col);
    if (y >= rs.rows or y >= rs.row_data.len) return -1;
    if (x >= cols) return -1;
    if (buf_size < 1) return -1;

    const cells = rs.row_data.items(.cells)[y].slice();
    const raw_cells = cells.items(.raw);
    if (x >= raw_cells.len) return -1;
    const cell = &raw_cells[x];

    // First codepoint is always from the cell
    out[0] = cell.codepoint();
    var count: usize = 1;

    // Managed grapheme data was copied into RenderState during update().
    if (cell.hasGrapheme()) {
        for (cells.items(.grapheme)[x]) |cp| {
            if (count >= buf_size) break;
            out[count] = cp;
            count += 1;
        }
    }

    return @intCast(count);
}

// ============================================================================
// Terminal Modes (minimal set for compatibility)
// ============================================================================

pub fn isAlternateScreen(ptr: ?*anyopaque) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return false));
    return wrapper.terminal.screens.active_key == .alternate;
}

pub fn hasMouseTracking(ptr: ?*anyopaque) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return false));
    return wrapper.terminal.modes.get(.mouse_event_normal) or
           wrapper.terminal.modes.get(.mouse_event_button) or
           wrapper.terminal.modes.get(.mouse_event_any);
}

/// Query arbitrary terminal mode by number
/// Returns true if mode is set, false otherwise
pub fn getMode(ptr: ?*anyopaque, mode_num: c_int, is_ansi: bool) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return false));
    const mode = modespkg.modeFromInt(@intCast(mode_num), is_ansi) orelse return false;
    return wrapper.terminal.modes.get(mode);
}

// ============================================================================
// Scrollback API
// ============================================================================

/// Get the number of scrollback lines (history, not including active screen)
pub fn getScrollbackLength(ptr: ?*anyopaque) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    const pages = &wrapper.terminal.screens.active.pages;
    // total_rows includes both scrollback and active area
    // We subtract rows (active area) to get just scrollback
    if (pages.total_rows <= pages.rows) return 0;
    return @intCast(pages.total_rows - pages.rows);
}

/// Get a wrapping generation that increments whenever a row enters history.
pub fn getScrollbackGeneration(ptr: ?*anyopaque) callconv(.c) u32 {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return 0));
    const primary = wrapper.terminal.screens.get(.primary) orelse return 0;
    return primary.scrollback_generation;
}

/// Get a line from the scrollback buffer
/// offset 0 = oldest line in scrollback, offset (length-1) = most recent scrollback line
/// Returns number of cells written, or -1 on error
pub fn getScrollbackLine(
    ptr: ?*anyopaque,
    offset: c_int,
    out: [*]GhosttyCell,
    buf_size: usize,
) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));
    const rs = &wrapper.render_state;
    const cols = rs.cols;
    
    if (buf_size < cols) return -1;
    if (offset < 0) return -1;
    
    const scrollback_len = getScrollbackLength(ptr);
    if (offset >= scrollback_len) return -1;
    
    // Get the pin for this scrollback row
    // history point: y=0 is oldest, y=scrollback_len-1 is newest
    const pages = &wrapper.terminal.screens.active.pages;
    const pin = pages.pin(.{ .history = .{ .y = @intCast(offset) } }) orelse return -1;
    
    // Get cells for this row
    const cells = pin.cells(.all);
    const page = pin.node.page();
    
    // Fill output buffer
    for (0..cols) |x| {
        if (x >= cells.len) {
            // Fill with default
            out[x] = .{
                .codepoint = 0,
                .fg_r = rs.colors.foreground.r,
                .fg_g = rs.colors.foreground.g,
                .fg_b = rs.colors.foreground.b,
                .bg_r = rs.colors.background.r,
                .bg_g = rs.colors.background.g,
                .bg_b = rs.colors.background.b,
                .flags = 0,
                .width = 1,
                .hyperlink_id = 0,
            };
            continue;
        }
        
        const cell = &cells[x];
        
        // Get style from page styles (cell has style_id)
        const sty: Style = if (cell.style_id > 0)
            page.styles.get(page.memory, cell.style_id).*
        else
            .{};
        
        // Resolve colors
        const fg: color.RGB = switch (sty.fg_color) {
            .none => rs.colors.foreground,
            .palette => |i| rs.colors.palette[i],
            .rgb => |value| value,
        };
        const bg: color.RGB = if (sty.bg(cell, &rs.colors.palette)) |rgb| rgb else rs.colors.background;
        
        // Build flags
        var flags: u8 = 0;
        if (sty.flags.bold) flags |= 1 << 0;
        if (sty.flags.italic) flags |= 1 << 1;
        if (sty.flags.underline != .none) flags |= 1 << 2;
        if (sty.flags.strikethrough) flags |= 1 << 3;
        if (sty.flags.inverse) flags |= 1 << 4;
        if (sty.flags.invisible) flags |= 1 << 5;
        if (sty.flags.blink) flags |= 1 << 6;
        if (sty.flags.faint) flags |= 1 << 7;

        // Get grapheme length if cell has grapheme data
        const grapheme_len: u8 = if (cell.hasGrapheme())
            if (page.lookupGrapheme(cell)) |cps| @min(@as(u8, @intCast(cps.len)), 255) else 0
        else
            0;

        out[x] = .{
            .codepoint = cell.codepoint(),
            .fg_r = fg.r,
            .fg_g = fg.g,
            .fg_b = fg.b,
            .bg_r = bg.r,
            .bg_g = bg.g,
            .bg_b = bg.b,
            .flags = flags,
            .width = switch (cell.wide) {
                .narrow => 1,
                .wide => 2,
                .spacer_tail, .spacer_head => 0,
            },
            .hyperlink_id = if (cell.hyperlink) 1 else 0,
            .grapheme_len = grapheme_len,
        };
    }
    return @intCast(cols);
}

/// Get grapheme codepoints for a cell in the scrollback buffer.
/// Returns all codepoints (including the first one) as u32 values.
/// Returns the number of codepoints written, or -1 on error.
pub fn getScrollbackGrapheme(
    ptr: ?*anyopaque,
    offset: c_int,
    col: c_int,
    out: [*]u32,
    buf_size: usize,
) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));
    const rs = &wrapper.render_state;
    const cols: usize = @intCast(rs.cols);

    if (offset < 0 or col < 0) return -1;
    if (@as(usize, @intCast(col)) >= cols) return -1;
    if (buf_size < 1) return -1;

    const scrollback_len = getScrollbackLength(ptr);
    if (offset >= scrollback_len) return -1;

    // Get the pin for this scrollback row
    const pages = &wrapper.terminal.screens.active.pages;
    const pin = pages.pin(.{ .history = .{ .y = @intCast(offset) } }) orelse return -1;

    const cells = pin.cells(.all);
    const page = pin.node.page();
    const x: usize = @intCast(col);

    if (x >= cells.len) return -1;

    const cell = &cells[x];

    // First codepoint is always from the cell
    out[0] = cell.codepoint();
    var count: usize = 1;

    // Add extra codepoints from grapheme map if present
    if (cell.hasGrapheme()) {
        if (page.lookupGrapheme(cell)) |cps| {
            for (cps) |cp| {
                if (count >= buf_size) break;
                out[count] = cp;
                count += 1;
            }
        }
    }

    return @intCast(count);
}

/// Check if a row is a continuation from the previous row (soft-wrapped)
/// This matches xterm.js semantics where isWrapped indicates the row continues
/// from the previous row, not that it wraps to the next row.
pub fn isRowWrapped(ptr: ?*anyopaque, y: c_int) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return false));
    const pages = &wrapper.terminal.screens.active.pages;
    
    // Get pin for this row in active area
    const pin = pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse return false;
    const rac = pin.rowAndCell();
    
    // wrap_continuation means this row continues from the previous row
    return rac.row.wrap_continuation;
}

// ============================================================================
// Hyperlink API
// ============================================================================

/// Get the hyperlink URI for a cell in the active viewport.
/// Returns number of bytes written, 0 if no hyperlink, -1 on error.
pub fn getHyperlinkUri(
    ptr: ?*anyopaque,
    row: c_int,
    col: c_int,
    out: [*]u8,
    buf_size: usize,
) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));
    const t = wrapper.terminal;

    if (row < 0 or col < 0) return -1;

    // Get the pin for this row from the terminal's active screen
    const pages = &t.screens.active.pages;
    const pin = pages.pin(.{ .active = .{ .y = @intCast(row) } }) orelse return -1;

    const cells = pin.cells(.all);
    const page = pin.node.page();
    const x: usize = @intCast(col);

    if (x >= cells.len) return -1;

    const cell = &cells[x];

    // Check if cell has a hyperlink
    if (!cell.hyperlink) return 0;

    // Look up the hyperlink ID from the page
    const hyperlink_id = page.lookupHyperlink(cell) orelse return 0;

    // Get the hyperlink entry from the set
    const hyperlink_entry = page.hyperlink_set.get(page.memory, hyperlink_id);

    // Get the URI bytes from the page memory
    const uri = hyperlink_entry.uri.slice(page.memory);

    if (uri.len == 0) return 0;
    if (buf_size < uri.len) return -1;

    @memcpy(out[0..uri.len], uri);
    return @intCast(uri.len);
}

/// Get the hyperlink URI for a cell in the scrollback buffer.
/// @param offset Scrollback line offset (0 = oldest, scrollback_len-1 = newest)
/// @param col Column index (0-based)
/// Returns number of bytes written, 0 if no hyperlink, -1 on error.
pub fn getScrollbackHyperlinkUri(
    ptr: ?*anyopaque,
    offset: c_int,
    col: c_int,
    out: [*]u8,
    buf_size: usize,
) callconv(.c) c_int {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));

    if (offset < 0 or col < 0) return -1;

    const scrollback_len = getScrollbackLength(ptr);
    if (offset >= scrollback_len) return -1;

    // Get the pin for this scrollback row
    const pages = &wrapper.terminal.screens.active.pages;
    const pin = pages.pin(.{ .history = .{ .y = @intCast(offset) } }) orelse return -1;

    const cells = pin.cells(.all);
    const page = pin.node.page();
    const x: usize = @intCast(col);

    if (x >= cells.len) return -1;

    const cell = &cells[x];

    // Check if cell has a hyperlink
    if (!cell.hyperlink) return 0;

    // Look up the hyperlink ID from the page
    const hyperlink_id = page.lookupHyperlink(cell) orelse return 0;

    // Get the hyperlink entry from the set
    const hyperlink_entry = page.hyperlink_set.get(page.memory, hyperlink_id);

    // Get the URI bytes from the page memory
    const uri = hyperlink_entry.uri.slice(page.memory);

    if (uri.len == 0) return 0;
    if (buf_size < uri.len) return -1;

    @memcpy(out[0..uri.len], uri);
    return @intCast(uri.len);
}

// ============================================================================
// Response API - for DSR and other terminal queries
// ============================================================================

/// Check if there are pending responses from the terminal
pub fn hasResponse(ptr: ?*anyopaque) callconv(.c) bool {
    const wrapper: *const TerminalWrapper = @ptrCast(@alignCast(ptr orelse return false));
    return wrapper.response_buffer.items.len > 0;
}

/// Read pending responses from the terminal.
/// Returns number of bytes written to buffer, or 0 if no responses pending.
/// Returns -1 on error (null pointer or buffer too small).
pub fn readResponse(ptr: ?*anyopaque, out: [*]u8, buf_size: usize) callconv(.c) c_int {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(ptr orelse return -1));
    const len = @min(wrapper.response_buffer.items.len, buf_size);
    if (len == 0) return 0;
    
    @memcpy(out[0..len], wrapper.response_buffer.items[0..len]);
    
    // Remove consumed bytes from buffer
    if (len == wrapper.response_buffer.items.len) {
        wrapper.response_buffer.clearRetainingCapacity();
    } else {
        // Shift remaining bytes to front
        std.mem.copyForwards(
            u8,
            wrapper.response_buffer.items[0..],
            wrapper.response_buffer.items[len..],
        );
        wrapper.response_buffer.shrinkRetainingCapacity(wrapper.response_buffer.items.len - len);
    }
    
    return @intCast(len);
}


comptime {
    @export(&new, .{ .name = "ghostty_terminal_new" });
    @export(&newWithConfig, .{ .name = "ghostty_terminal_new_with_config" });
    @export(&free, .{ .name = "ghostty_terminal_free" });
    @export(&resize, .{ .name = "ghostty_terminal_resize" });
    @export(&setScrollbackLimit, .{ .name = "ghostty_terminal_set_scrollback_limit" });
    @export(&write, .{ .name = "ghostty_terminal_write" });
    @export(&renderStateUpdate, .{ .name = "ghostty_render_state_update" });
    @export(&renderStateGetCols, .{ .name = "ghostty_render_state_get_cols" });
    @export(&renderStateGetRows, .{ .name = "ghostty_render_state_get_rows" });
    @export(&renderStateGetCursorX, .{ .name = "ghostty_render_state_get_cursor_x" });
    @export(&renderStateGetCursorY, .{ .name = "ghostty_render_state_get_cursor_y" });
    @export(&renderStateGetCursorVisible, .{ .name = "ghostty_render_state_get_cursor_visible" });
    @export(&renderStateGetBgColor, .{ .name = "ghostty_render_state_get_bg_color" });
    @export(&renderStateGetFgColor, .{ .name = "ghostty_render_state_get_fg_color" });
    @export(&renderStateIsRowDirty, .{ .name = "ghostty_render_state_is_row_dirty" });
    @export(&renderStateMarkClean, .{ .name = "ghostty_render_state_mark_clean" });
    @export(&renderStateGetViewport, .{ .name = "ghostty_render_state_get_viewport" });
    @export(&renderStateGetGrapheme, .{ .name = "ghostty_render_state_get_grapheme" });
    @export(&isAlternateScreen, .{ .name = "ghostty_terminal_is_alternate_screen" });
    @export(&hasMouseTracking, .{ .name = "ghostty_terminal_has_mouse_tracking" });
    @export(&getMode, .{ .name = "ghostty_terminal_get_mode" });
    @export(&getScrollbackLength, .{ .name = "ghostty_terminal_get_scrollback_length" });
    @export(&getScrollbackGeneration, .{ .name = "ghostty_terminal_get_scrollback_generation" });
    @export(&getScrollbackLine, .{ .name = "ghostty_terminal_get_scrollback_line" });
    @export(&getScrollbackGrapheme, .{ .name = "ghostty_terminal_get_scrollback_grapheme" });
    @export(&isRowWrapped, .{ .name = "ghostty_terminal_is_row_wrapped" });
    @export(&getHyperlinkUri, .{ .name = "ghostty_terminal_get_hyperlink_uri" });
    @export(&getScrollbackHyperlinkUri, .{ .name = "ghostty_terminal_get_scrollback_hyperlink_uri" });
    @export(&hasResponse, .{ .name = "ghostty_terminal_has_response" });
    @export(&readResponse, .{ .name = "ghostty_terminal_read_response" });
    @export(&checkpointTheme, .{ .name = "ghostty_terminal_checkpoint_theme" });
    @export(&snapshotEncode, .{ .name = "ghostty_terminal_snapshot_encode" });
    @export(&snapshotFree, .{ .name = "ghostty_terminal_snapshot_free" });
    @export(&snapshotRestore, .{ .name = "ghostty_terminal_snapshot_restore" });
    @export(&diagnosticCells, .{ .name = "ghostty_terminal_diagnostic_cells" });
    @export(&diagnosticEmpty, .{ .name = "ghostty_terminal_write_error_ptr" });
    @export(&diagnosticEmpty, .{ .name = "ghostty_terminal_write_error_len" });
    @export(&diagnosticEmpty, .{ .name = "ghostty_terminal_resize_error_ptr" });
    @export(&diagnosticEmpty, .{ .name = "ghostty_terminal_resize_error_len" });
    @export(&diagnosticEmpty, .{ .name = "ghostty_terminal_allocation_diagnostics_ptr" });
    @export(&diagnosticEmpty, .{ .name = "ghostty_terminal_allocation_diagnostics_len" });
    @export(&allocU8, .{ .name = "ghostty_wasm_alloc_u8" });
    @export(&freeU8, .{ .name = "ghostty_wasm_free_u8" });
    @export(&allocUsize, .{ .name = "ghostty_wasm_alloc_usize" });
    @export(&freeUsize, .{ .name = "ghostty_wasm_free_usize" });
    @export(&allocU16Array, .{ .name = "ghostty_wasm_alloc_u16_array" });
    @export(&freeU16Array, .{ .name = "ghostty_wasm_free_u16_array" });
    @export(&allocSgr, .{ .name = "ghostty_wasm_alloc_sgr_attribute" });
    @export(&freeSgr, .{ .name = "ghostty_wasm_free_sgr_attribute" });
    @export(&wasm_alloc.allocBytes, .{ .name = "ghostty_wasm_alloc_u8_array" });
    @export(&wasm_alloc.freeBytes, .{ .name = "ghostty_wasm_free_u8_array" });
    @export(&wasm_alloc.allocOpaque, .{ .name = "ghostty_wasm_alloc_opaque" });
    @export(&wasm_alloc.freeOpaque, .{ .name = "ghostty_wasm_free_opaque" });
    @export(&c.key_event_new, .{ .name = "ghostty_key_event_new" });
    @export(&c.key_event_free, .{ .name = "ghostty_key_event_free" });
    @export(&c.key_event_set_action, .{ .name = "ghostty_key_event_set_action" });
    @export(&c.key_event_set_key, .{ .name = "ghostty_key_event_set_key" });
    @export(&c.key_event_set_mods, .{ .name = "ghostty_key_event_set_mods" });
    @export(&c.key_event_set_utf8, .{ .name = "ghostty_key_event_set_utf8" });
    @export(&c.key_encoder_new, .{ .name = "ghostty_key_encoder_new" });
    @export(&c.key_encoder_free, .{ .name = "ghostty_key_encoder_free" });
    @export(&c.key_encoder_setopt, .{ .name = "ghostty_key_encoder_setopt" });
    @export(&c.key_encoder_encode, .{ .name = "ghostty_key_encoder_encode" });
    @export(&c.sgr_new, .{ .name = "ghostty_sgr_new" });
    @export(&c.sgr_free, .{ .name = "ghostty_sgr_free" });
    @export(&c.sgr_reset, .{ .name = "ghostty_sgr_reset" });
    @export(&c.sgr_set_params, .{ .name = "ghostty_sgr_set_params" });
    @export(&c.sgr_next, .{ .name = "ghostty_sgr_next" });
    @export(&c.sgr_unknown_full, .{ .name = "ghostty_sgr_unknown_full" });
    @export(&c.sgr_unknown_partial, .{ .name = "ghostty_sgr_unknown_partial" });
    @export(&c.sgr_attribute_tag, .{ .name = "ghostty_sgr_attribute_tag" });
    @export(&c.sgr_attribute_value, .{ .name = "ghostty_sgr_attribute_value" });
}
