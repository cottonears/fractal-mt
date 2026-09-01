const std = @import("std");
const zigimg = @import("zigimg");
const threading = @import("threading.zig");
const AtomicRangeIter = threading.AtomicRangeIter;
const Thread = std.Thread;
const clock = std.Io.Clock.awake;
const z32 = std.math.complex.Complex(f32);

const min_re: f32 = -2.0;
const max_re: f32 = 2.0;
const min_im: f32 = -1.5;
const max_im: f32 = 1.5;
const min_threads = 1;
const max_threads = 20;
const mod_square_max = 8.0;
const sequence_len = 255;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip the program name

    var disp_width: u32 = 800;
    var disp_height: u32 = 600;

    while (args_iter.next()) |arg| {
        std.debug.print("arg: {s}\n", .{arg});
        const x_pos = std.ascii.findIgnoreCasePos(arg, 0, "x") orelse return error.InvalidArgs;
        std.debug.print("x_pos = {d}\n", .{x_pos});
        disp_width = try std.fmt.parseInt(u32, arg[0..x_pos], 10);
        disp_height = try std.fmt.parseInt(u32, arg[x_pos + 1 .. arg.len], 10);
    }
    const num_hw_threads = try std.Thread.getCpuCount();
    std.debug.print("Hardware threads available: {}\n", .{num_hw_threads});
    const num_threads = std.math.clamp(num_hw_threads - 2, min_threads, max_threads);
    const partitions = 128;

    var pixels = try arena.alloc([]u24, disp_height);
    defer arena.free(pixels);
    for (0..pixels.len) |i| pixels[i] = try arena.alloc(u24, disp_width);
    errdefer for (0..pixels.len) |i| arena.free(pixels[i]);
    const c = z32{ .re = -0.5125, .im = 0.5213 };
    std.debug.print("Computing julia set for c = {any} using {d} threads.\n", .{ c, num_threads });

    const threads = try arena.alloc(Thread, num_threads);

    // create a range iterator and start worker threads
    const t_start = clock.now(io);
    var range_iter = try AtomicRangeIter.init(0, disp_height, partitions);
    for (0..num_threads) |i| {
        const args = .{ io, c, pixels, disp_width, disp_height, &range_iter };
        threads[i] = try Thread.spawn(.{}, fillPixelValues, args);
    }
    for (0..num_threads) |i| threads[i].join();
    const t_end = clock.now(io);

    var img = try zigimg.Image.create(arena, disp_width, disp_height, .bgr24);
    defer img.deinit(arena);
    for (0..disp_height) |i| {
        for (0..disp_width) |j| {
            img.pixels.bgr24[i * disp_width + j] = @bitCast(pixels[i][j]);
        }
    }
    var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try img.writeToFilePath(arena, io, "julia.bmp", &write_buffer, .{ .bmp = .{} });

    const elapsed_us = std.Io.Timestamp.durationTo(t_start, t_end).toMicroseconds();
    std.debug.print("Fractal generated in {} us\n", .{elapsed_us});
}

fn fillPixelValues(
    io: std.Io,
    c: z32,
    pixel_vals: [][]u24,
    disp_width: u32,
    disp_height: u32,
    y_iter: *AtomicRangeIter,
) !void {
    const width_scale_factor: f32 = 1 / @as(f32, @floatFromInt(disp_width));
    const height_scale_factor: f32 = 1 / @as(f32, @floatFromInt(disp_height));
    const t_start = clock.now(io);
    var total_iters: usize = 0;
    while (y_iter.next()) |y_range| {
        const start_y = y_range.start;
        const end_y = y_range.end;
        for (start_y..end_y) |i| {
            const im_pos = height_scale_factor * @as(f32, @floatFromInt(i));
            for (0..disp_width) |j| {
                const re_pos = width_scale_factor * @as(f32, @floatFromInt(j));
                var z = z32{
                    .re = min_re + re_pos * (max_re - min_re),
                    .im = min_im + im_pos * (max_im - min_im),
                };
                var mod_squared = z.squaredMagnitude();
                var iter: u24 = 0;
                while (iter < sequence_len and mod_squared < mod_square_max) : (iter += 1) {
                    z = z.mul(z).add(c);
                    mod_squared = z.squaredMagnitude();
                }
                pixel_vals[i][j] = (iter <<| 16) + (iter <<| 8) + iter; // B + W
                total_iters += iter;
            }
        }
    }
    const t_end = clock.now(io);
    const elapsed_us = std.Io.Timestamp.durationTo(t_start, t_end).toMicroseconds();
    std.debug.print("worker thread finished {} iters in {} us\n", .{ total_iters, elapsed_us });
}
