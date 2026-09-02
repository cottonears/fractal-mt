const std = @import("std");
const zigimg = @import("zigimg");
const render = @import("sdl_render.zig");
const threading = @import("threading.zig");
const AtomicRangeIter = threading.AtomicRangeIter;
const Colour = render.Colour;
const Thread = std.Thread;
const clock = std.Io.Clock.awake;
const z32 = std.math.complex.Complex(f32);

const min_threads = 1;
const max_threads = 20;
const partitions = 128;
const mod_square_max = 8.0;
const sequence_len = 100;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip the program name

    var disp_width: u32 = 3200;
    var disp_height: u32 = 1800;
    while (args_iter.next()) |arg| {
        const x_pos = std.ascii.findIgnoreCasePos(arg, 0, "x") orelse return error.InvalidArgs;
        disp_width = try std.fmt.parseInt(u32, arg[0..x_pos], 10);
        disp_height = try std.fmt.parseInt(u32, arg[x_pos + 1 .. arg.len], 10);
    }
    try render.init("julia", @truncate(disp_width), @truncate(disp_height));
    defer render.deinit();

    const num_hw_threads = try std.Thread.getCpuCount();
    const num_threads: u16 = @truncate(std.math.clamp(num_hw_threads - 2, min_threads, max_threads));
    std.debug.print(
        "Using {d} of {d} available hardware threads.\n",
        .{ num_threads, num_hw_threads },
    );
    try runDisplayLoop(arena, io, num_threads, disp_width, disp_height);
}

const target_frame_time_us = 16_667; // ~60 fps

fn runDisplayLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    num_threads: u16,
    disp_width: u32,
    disp_height: u32,
) !void {
    const texture = try render.createStreamingTexture(@truncate(disp_width), @truncate(disp_height));
    defer render.destroyStreamingTexture(texture);
    const threads = try allocator.alloc(Thread, num_threads);

    const pixels = try allocator.alloc(u32, disp_width * disp_height);
    defer allocator.free(pixels);
    const c = z32{ .re = -0.5125, .im = 0.5213 };

    const z_min: z32 = .{ .im = -1.35, .re = -2.4 };
    const z_max: z32 = .{ .im = 1.35, .re = 2.4 };

    var draw_buffer = [_]render.DrawCommand{
        .{ .clear = Colour.fromRgba(0x000000FF) },
        .{ .stream_texture = .{ .texture = texture, .pixels = pixels, .width = disp_width, .height = disp_height } },
    };

    var request_buffer: [8]render.Request = undefined;
    var h: f32 = 0;
    var s: f32 = 0.5;
    var quit = false;
    var last_frame_end = clock.now(io);
    while (!quit) {
        // 1. process input
        const input_reqs = render.getRequests(&request_buffer);
        for (input_reqs) |r| {
            // TODO: add support for moving location, zoom, c, etc.
            switch (r) {
                .quit => quit = true,
                .click, .pause => {}, // no interaction hooked up yet
            }
        }

        // 2. compute
        var range_iter = try AtomicRangeIter.init(0, disp_height, partitions);
        for (0..num_threads) |i| {
            const col_table = generateColourPalette(sequence_len + 1, h, 2.0, s, 0, 0, 0.01);
            const args = .{ io, c, z_min, z_max, pixels, disp_width, disp_height, col_table[0..], &range_iter };
            threads[i] = try Thread.spawn(.{}, fillPixelValues, args);
            h = @mod(h + 3, 360);
            s = std.math.clamp(@mod(s + 0.01, 1.0), 0.5, 0.8);
        }

        for (0..num_threads) |i| threads[i].join();
        // 3. draw
        try render.draw(&draw_buffer);
        // 4. frame pacing
        const t_end = clock.now(io);
        const frame_us = std.Io.Timestamp.durationTo(last_frame_end, t_end).toMicroseconds();
        if (frame_us < target_frame_time_us) {
            try io.sleep(.fromMicroseconds(target_frame_time_us - frame_us), clock);
        }
        last_frame_end = clock.now(io);
    }
}

fn writImg(allocator: std.mem.Allocator, io: std.Io, disp_width: u32, disp_height: u32, pixels: [][]u32) !void {
    var img = try zigimg.Image.create(allocator, disp_width, disp_height, .bgra32);
    defer img.deinit(allocator);
    for (pixels, 0..) |p, idx| img.pixels.bgra32[idx] = @bitCast(p);
    var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try img.writeToFilePath(allocator, io, "julia.bmp", &write_buffer, .{ .bmp = .{} });
}
/// h_start/h_inc are hue degrees; s_start/s_inc/l_start/l_inc are normalised to [0, 1],
/// matching the units Colour.fromHsl expects.
fn generateColourPalette(
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

fn fillPixelValues(
    io: std.Io,
    c: z32,
    min_z: z32,
    max_z: z32,
    pixel_vals: []u32,
    disp_width: u32,
    disp_height: u32,
    colour_lookup: []const u32,
    y_iter: *AtomicRangeIter,
) !void {
    const re_inc: f32 = (max_z.re - min_z.re) / @as(f32, @floatFromInt(disp_width));
    const im_inc: f32 = (max_z.im - min_z.im) / @as(f32, @floatFromInt(disp_height));
    var total_iters: usize = 0;
    while (y_iter.next()) |y_range| {
        const start_y = y_range.start;
        const end_y = y_range.end;
        for (start_y..end_y) |i| {
            for (0..disp_width) |j| {
                var z_re = min_z.re + re_inc * @as(f32, @floatFromInt(j));
                var z_im = min_z.im + im_inc * @as(f32, @floatFromInt(i));
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
}
