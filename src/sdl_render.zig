const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const std = @import("std");

pub const Colour = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn fromRgba(rgba: u32) Colour {
        return @bitCast(@byteSwap(rgba));
    }

    pub fn fromHsl(h: f32, s: f32, l: f32) Colour {
        const hue = @mod(h, 360.0);
        const chroma = (1 - @abs(2 * l - 1)) * s;
        const x = chroma * (1 - @abs(@mod(hue / 60.0, 2) - 1));
        const m = l - chroma / 2;
        const rgb1: @Vector(3, f32) = switch (@as(u32, @intFromFloat(hue / 60.0))) {
            0 => .{ chroma, x, 0 },
            1 => .{ x, chroma, 0 },
            2 => .{ 0, chroma, x },
            3 => .{ 0, x, chroma },
            4 => .{ x, 0, chroma },
            else => .{ chroma, 0, x },
        };
        const rgb = (rgb1 + @as(@Vector(3, f32), @splat(m))) * @as(@Vector(3, f32), @splat(255.0));
        return .{
            .r = @intFromFloat(rgb[0]),
            .g = @intFromFloat(rgb[1]),
            .b = @intFromFloat(rgb[2]),
        };
    }
};

pub const RectInfo = struct {
    min: @Vector(2, f32),
    max: @Vector(2, f32),
    colour: Colour,
};

pub const StreamTextureInfo = struct {
    texture: *c.SDL_Texture,
    pixels: []const u32,
    width: u32,
    height: u32,
};

pub const DrawCommand = union(enum) {
    clear: Colour,
    rectangle: RectInfo,
    stream_texture: StreamTextureInfo,
};

pub const Request = union(enum) {
    click: @Vector(2, f32),
    pause: void,
    quit: void,
};

var window: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;
var prev_space_down: bool = false;

pub fn init(
    //allocator: std.mem.Allocator,
    name: []const u8,
    win_width: u16,
    win_height: u16,
) !void {
    const sdl_base_flags = c.SDL_INIT_AUDIO | c.SDL_INIT_VIDEO;
    if (!c.SDL_Init(sdl_base_flags)) {
        c.SDL_Log("Could not initialise SDL video subsytem: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    }
    window = c.SDL_CreateWindow(name.ptr, @intCast(win_width), @intCast(win_height), 0) orelse {
        c.SDL_Log("Could not create SDL window: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    };
    renderer = c.SDL_CreateRenderer(window, null) orelse {
        c.SDL_Log("Could not create SDL renderer: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    };
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)) {
        c.SDL_Log("Could not set SDL renderer blend mode: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    }
}

pub fn deinit() void {
    c.SDL_DestroyRenderer(renderer);
    c.SDL_DestroyWindow(window);
    c.SDL_Quit();
}

pub fn draw(render_queue: []DrawCommand) !void {
    for (render_queue) |cmd| {
        switch (cmd) {
            .clear => renderClear(cmd.clear),
            .rectangle => renderRectangle(cmd.rectangle),
            .stream_texture => try renderStreamTexture(cmd.stream_texture),
        }
    }
    _ = c.SDL_RenderPresent(renderer);
}

pub fn createStreamingTexture(width: u16, height: u16) !*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(width),
        @intCast(height),
    ) orelse {
        c.SDL_Log("failed to create streaming texture: %s\n", c.SDL_GetError());
        return error.SDLFailedToCreateStreamingTexture;
    };
    return texture;
}

pub fn destroyStreamingTexture(texture: *c.SDL_Texture) void {
    c.SDL_DestroyTexture(texture);
}

pub fn getRequests(req_buffer: []Request) []Request {
    var e: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&e)) {
        if (e.type == c.SDL_EVENT_QUIT) {
            req_buffer[0] = .{ .quit = {} };
            return req_buffer[0..1];
        }
    }
    var buff_index: usize = 0;
    // check keyboard input
    const key_states = c.SDL_GetKeyboardState(null);
    if (key_states[c.SDL_SCANCODE_ESCAPE]) {
        req_buffer[0] = .{ .quit = {} };
        return req_buffer[0..1];
    }
    const space_down = key_states[c.SDL_SCANCODE_SPACE];
    if (space_down and !prev_space_down) {
        req_buffer[buff_index] = .{ .pause = {} };
        buff_index += 1;
    }
    prev_space_down = space_down;
    // check mouse input
    var mouse_x: f32 = undefined;
    var mouse_y: f32 = undefined;
    const mb_flags = c.SDL_GetMouseState(&mouse_x, &mouse_y);
    if (mb_flags & 0b1 == 0b1) { // LMB down
        req_buffer[buff_index] = .{ .click = .{ mouse_x, mouse_y } };
        buff_index += 1;
    }
    return req_buffer[0..buff_index];
}

fn getSdlFRect(rect: RectInfo) c.SDL_FRect {
    var sdl_rect: c.SDL_FRect = undefined;
    const diff = rect.max - rect.min;
    sdl_rect.x = rect.min[0];
    sdl_rect.y = rect.max[1];
    sdl_rect.w = diff[0];
    sdl_rect.h = diff[1];
    return sdl_rect;
}

fn getSdlFColour(col: Colour) c.SDL_FColor {
    // NOTE: SDL_FColor channels are normalised floats in [0, 1].
    var sdl_col: c.SDL_FColor = undefined;
    sdl_col.r = @as(f32, @floatFromInt(col.r)) / 255.0;
    sdl_col.g = @as(f32, @floatFromInt(col.g)) / 255.0;
    sdl_col.b = @as(f32, @floatFromInt(col.b)) / 255.0;
    sdl_col.a = @as(f32, @floatFromInt(col.a)) / 255.0;
    return sdl_col;
}

fn renderClear(col: Colour) void {
    _ = c.SDL_SetRenderDrawColor(renderer, col.r, col.g, col.b, col.a);
    _ = c.SDL_RenderClear(renderer);
}

fn renderRectangle(rect: RectInfo) void {
    const col = rect.colour;
    const sdl_rect = getSdlFRect(rect);
    _ = c.SDL_SetRenderDrawColor(renderer, col.r, col.g, col.b, col.a);
    _ = c.SDL_RenderFillRect(renderer, &sdl_rect);
}

fn renderStreamTexture(info: StreamTextureInfo) !void {
    var texture_pixels: ?*anyopaque = null;
    var pitch: c_int = 0;
    if (!c.SDL_LockTexture(info.texture, null, &texture_pixels, &pitch)) {
        c.SDL_Log("Failed to lock texture: %s", c.SDL_GetError());
        return error.SDLFailedToCreateLockTexture;
    }
    defer c.SDL_UnlockTexture(info.texture);
    const src_pitch = info.width * @sizeOf(u32);
    const dst_pitch: usize = @intCast(pitch);
    const dst: [*]u8 = @ptrCast(texture_pixels.?);
    const src = std.mem.sliceAsBytes(info.pixels);

    if (dst_pitch == src_pitch) {
        @memcpy(
            dst[0 .. src_pitch * info.height],
            src[0 .. src_pitch * info.height],
        );
    } else {
        for (0..info.height) |y| {
            const src_start = y * src_pitch;
            const dst_start = y * dst_pitch;
            @memcpy(dst[dst_start .. dst_start + src_pitch], src[src_start .. src_start + src_pitch]);
        }
    }
    c.SDL_UnlockTexture(info.texture);
    if (!c.SDL_RenderTexture(renderer, info.texture, null, null)) {
        return error.SDLTextureRenderFailed;
    }
}
