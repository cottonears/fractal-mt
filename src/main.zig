const std = @import("std");
const render = @import("sdl_render.zig");
const utils = @import("utils.zig");
const AtomicRangeIter = utils.AtomicRangeIter;
const Colour = render.Colour;
const Thread = std.Thread;
const clock = std.Io.Clock.awake;
const z32 = std.math.complex.Complex(f32);

const partitions = 128;
const mod_square_max = 8.0;
const sequence_len = 100;
const target_frame_time_us = 16_667; // ~60 fps

// configurable settings (TODO: support loading these from JSON!)
const h_frame_inc: f32 = 0.01; // TODO:
const c_inc: f32 = 0.001;
const z_inc: f32 = 0.006;
const zoom_inc: f32 = 0.012;

// updateable state
var c = z32{ .re = -0.5125, .im = 0.5213 };
var z_centre: z32 = .{ .im = 0, .re = 0 };
var z_min: z32 = .{ .im = -1.35, .re = -2.4 };
var z_max: z32 = .{ .im = 1.35, .re = 2.4 };

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip the program name

    var disp_width: u32 = 1920;
    var disp_height: u32 = 1080;
    while (args_iter.next()) |arg| {
        const x_pos = std.ascii.findIgnoreCasePos(arg, 0, "x") orelse return error.InvalidArgs;
        disp_width = try std.fmt.parseInt(u32, arg[0..x_pos], 10);
        disp_height = try std.fmt.parseInt(u32, arg[x_pos + 1 .. arg.len], 10);
    }
    try render.init("julia", @truncate(disp_width), @truncate(disp_height), true);
    defer render.deinit();

    const num_hw_threads = try std.Thread.getCpuCount();
    const num_threads: u16 = @truncate(std.math.clamp(num_hw_threads - 2, 1, 16));
    std.debug.print(
        "Using {d} of {d} available hardware threads.\n",
        .{ num_threads, num_hw_threads },
    );
    try runDisplayLoop(arena, io, num_threads, disp_width, disp_height, true);
}

fn runDisplayLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    num_threads: u16,
    disp_width: u32,
    disp_height: u32,
    use_group: bool,
) !void {
    const pixels = try allocator.alloc(u32, disp_width * disp_height);
    defer allocator.free(pixels);
    var group: std.Io.Group = .init;
    errdefer group.cancel(io);
    const text_col = Colour.fromRgba(0xFFFFFFFF);
    var text_buf: [128]u8 = undefined;
    var text_c: [:0]u8 = undefined;
    var text_z: [:0]u8 = undefined;
    var draw_buffer = [_]render.DrawCommand{
        .{ .clear = Colour.fromRgba(0x000000FF) },
        .{ .texture = .{ .pixels = pixels, .width = disp_width, .height = disp_height } },
        .{ .rectangle = .{ .colour = Colour.fromRgba(0x88888888), .min = .{ 6, 6 }, .max = .{ 182, 46 } } },
        .{ .text = .{ .string = try getTextC(text_buf[0..]), .x = 12, .y = 12, .colour = text_col } },
        .{ .text = .{ .string = try getTextZ(text_buf[64..]), .x = 12, .y = 32, .colour = text_col } },
    };

    var frame_times_ms: [60]f32 = undefined;
    var frame_counter: usize = 0;
    var request_buffer: [8]render.Request = undefined;
    var h: f32 = 0;
    var quit = false;
    var last_frame_end = clock.now(io);
    while (!quit) {
        // 1. process input
        const input_reqs = try render.getRequests(&request_buffer);
        for (input_reqs) |r| {
            switch (r) {
                .quit => quit = true,
                .c_up => changeC(0, c_inc),
                .c_left => changeC(-c_inc, 0),
                .c_right => changeC(c_inc, 0),
                .c_down => changeC(0, -c_inc),
                .pan_left => pan(-z_inc, 0),
                .pan_right => pan(z_inc, 0),
                .pan_down => pan(0, -z_inc),
                .pan_up => pan(0, z_inc),
                .zoom_in => zoom(1.0 - zoom_inc),
                .zoom_out => zoom(1.0 + zoom_inc),
                else => {},
            }
        }
        // 2. compute
        var range_iter = try AtomicRangeIter.init(0, disp_height, partitions);
        const col_table = getColourTable(sequence_len + 1, h, 1.0, 0.4, 0.001, 0, 0.01);
        if (use_group) {
            for (0..num_threads) |_| {
                const args = .{ pixels, disp_width, disp_height, col_table[0..], &range_iter };
                group.async(io, fillPixelValues, args);
            }
            try group.await(io);
        } else {
            const threads = try allocator.alloc(Thread, num_threads);
            for (0..num_threads) |i| {
                const args = .{ pixels, disp_width, disp_height, col_table[0..], &range_iter };
                threads[i] = try Thread.spawn(.{}, fillPixelValues, args);
            }
            for (0..num_threads) |i| threads[i].join();
        }
        h = @mod(h + h_frame_inc, 360);
        // 3. draw
        text_c = try getTextC(text_buf[0..]);
        text_z = try getTextZ(text_buf[64..]);
        try render.draw(&draw_buffer);
        // 4. frame pacing
        const t_end = clock.now(io);
        const frame_us = std.Io.Timestamp.durationTo(last_frame_end, t_end).toMicroseconds();
        if (frame_us < target_frame_time_us) {
            try io.sleep(.fromMicroseconds(target_frame_time_us - frame_us), clock);
        }
        last_frame_end = clock.now(io);
        frame_times_ms[frame_counter] = 0.001 * @as(f32, @floatFromInt(frame_us));
        if (frame_counter == frame_times_ms.len - 1) {
            var total_ms: f32 = 0;
            for (frame_times_ms) |t| total_ms += t;
            const avg_frame_ms: f32 = total_ms / @as(f32, @floatFromInt(frame_times_ms.len));
            std.debug.print("Group average frame time = {d:.1} ms\n", .{avg_frame_ms});
        }
        frame_counter = (frame_counter + 1) % frame_times_ms.len;
    }
}

fn fillPixelValues(
    pixel_vals: []u32,
    disp_width: u32,
    disp_height: u32,
    colour_lookup: []const u32,
    y_iter: *AtomicRangeIter,
) !void {
    const re_inc: f32 = (z_max.re - z_min.re) / @as(f32, @floatFromInt(disp_width));
    const im_inc: f32 = (z_max.im - z_min.im) / @as(f32, @floatFromInt(disp_height));
    var total_iters: usize = 0;
    while (y_iter.next()) |y_range| {
        const start_y = y_range.start;
        const end_y = y_range.end;
        for (start_y..end_y) |i| {
            for (0..disp_width) |j| {
                var z_re = z_min.re + re_inc * @as(f32, @floatFromInt(j));
                var z_im = z_min.im + im_inc * @as(f32, @floatFromInt(i));
                var iter: u32 = 0;
                while (iter < sequence_len) : (iter += 1) {
                    const z_re_squared = z_re * z_re;
                    const z_im_squared = z_im * z_im;
                    if (z_re_squared + z_im_squared > mod_square_max) break;
                    z_im = 2 * z_re * z_im + c.im;
                    z_re = z_re_squared - z_im_squared + c.re;
                }
                pixel_vals[i * @as(usize, disp_width) + j] = colour_lookup[iter];
                total_iters += iter;
            }
        }
    }
    std.debug.print("total_num_iters = {d}\n", .{total_iters});
}

fn getColourTable(
    comptime n: u16,
    h_start: f32,
    h_inc: f32,
    s_start: f32,
    s_inc: f32,
    l_start: f32,
    l_inc: f32,
) [n]u32 {
    var rgb: [n]u32 = undefined;
    for (0..rgb.len) |index| {
        const i: f32 = @floatFromInt(index);
        const h = @mod(h_start + i * h_inc, 360.0);
        const s = @min(1.0, s_start + i * s_inc);
        const l = @min(1.0, l_start + i * l_inc);
        rgb[index] = @bitCast(Colour.fromHsl(h, s, l));
    }
    return rgb;
}

fn changeC(re_inc: f32, im_inc: f32) void {
    c = c.add(.{ .re = re_inc, .im = im_inc });
}

fn pan(re_inc: f32, im_inc: f32) void {
    const current_extent = z_max.sub(z_min);

    const offset = z32{
        .re = current_extent.re * re_inc,
        .im = current_extent.im * im_inc,
    };
    z_min = z_min.add(offset);
    z_max = z_max.add(offset);
    z_centre = .{
        .re = z_min.re + 0.5 * (z_max.re - z_min.re),
        .im = z_min.im + 0.5 * (z_max.im - z_min.im),
    };
}

fn getTextC(buf: []u8) ![:0]u8 {
    return try std.fmt.bufPrintSentinel(buf, "c = ({d:.4}, {d:.4})", .{ c.re, c.im }, 0);
}

fn getTextZ(buf: []u8) ![:0]u8 {
    return try std.fmt.bufPrintSentinel(buf, "z = ({d:.4}, {d:.4})", .{ z_centre.re, z_centre.im }, 0);
}

fn zoom(scale_factor: f32) void {
    const current_extent = z_max.sub(z_min);
    const half_extent: z32 = .{ .re = 0.5 * current_extent.re, .im = 0.5 * current_extent.im };
    const current_centre = z_min.add(half_extent);
    z_min = .{
        .re = current_centre.re - scale_factor * half_extent.re,
        .im = current_centre.im - scale_factor * half_extent.im,
    };
    z_max = .{
        .re = current_centre.re + scale_factor * half_extent.re,
        .im = current_centre.im + scale_factor * half_extent.im,
    };
}
