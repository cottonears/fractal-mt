const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});
const std = @import("std");
const utils = @import("utils.zig");

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

pub const TextInfo = struct {
    colour: Colour,
    string: [:0]const u8,
    x: f32,
    y: f32,
};

pub const TextureInfo = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
};

pub const DrawCommand = union(enum) {
    clear: Colour,
    rectangle: RectInfo,
    text: TextInfo,
    texture: TextureInfo,
};

pub const Request = union(enum) {
    c_left: void,
    c_right: void,
    c_up: void,
    c_down: void,
    pan_left: void,
    pan_right: void,
    pan_up: void,
    pan_down: void,
    zoom_in: void,
    zoom_out: void,
    pause: void,
    quit: void,
};

var window: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;
var texture: *c.SDL_Texture = undefined;
var prev_space_down: bool = false;

pub fn init(
    // allocator: std.mem.Allocator,
    name: []const u8,
    win_width: u16,
    win_height: u16,
    fullscreen: bool,
) !void {
    const base_flags = c.SDL_INIT_AUDIO | c.SDL_INIT_VIDEO;
    if (!c.SDL_Init(base_flags)) {
        c.SDL_Log("Could not initialise SDL video subsytem: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    }
    const w_flag = if (fullscreen) c.SDL_WINDOW_FULLSCREEN else 0;
    window = c.SDL_CreateWindow(name.ptr, @intCast(win_width), @intCast(win_height), w_flag) orelse {
        c.SDL_Log("Could not create SDL window: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    };
    renderer = c.SDL_CreateRenderer(window, null) orelse {
        c.SDL_Log("Could not create SDL renderer: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    };
    texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(win_width),
        @intCast(win_height),
    ) orelse {
        c.SDL_Log("failed to create streaming texture: %s\n", c.SDL_GetError());
        return error.SDLFailedToCreateStreamingTexture;
    };
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)) {
        c.SDL_Log("Could not set SDL renderer blend mode: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    }
}

pub fn deinit() void {
    c.SDL_DestroyRenderer(renderer);
    c.SDL_DestroyTexture(texture);
    c.SDL_DestroyWindow(window);
    c.SDL_Quit();
}

pub fn draw(render_queue: []DrawCommand) !void {
    for (render_queue) |cmd| {
        switch (cmd) {
            .clear => renderClear(cmd.clear),
            .rectangle => renderRectangle(cmd.rectangle),
            .text => renderText(cmd.text),
            .texture => try renderTexture(cmd.texture),
        }
    }
    _ = c.SDL_RenderPresent(renderer);
}

pub fn getRequests(req_buffer: []Request) ![]Request {
    var req_list = utils.BoundedList(Request).init(req_buffer);
    var e: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&e)) {
        if (e.type == c.SDL_EVENT_QUIT) {
            try req_list.add(Request{ .quit = {} });
            return req_list.getItems();
        }
    }
    // check keyboard input
    const key_states = c.SDL_GetKeyboardState(null);
    if (key_states[c.SDL_SCANCODE_ESCAPE]) {
        try req_list.add(.{ .quit = {} });
        return req_list.getItems();
    }
    if (key_states[c.SDL_SCANCODE_UP]) try req_list.add(.{ .c_up = {} });
    if (key_states[c.SDL_SCANCODE_DOWN]) try req_list.add(.{ .c_down = {} });
    if (key_states[c.SDL_SCANCODE_LEFT]) try req_list.add(.{ .c_left = {} });
    if (key_states[c.SDL_SCANCODE_RIGHT]) try req_list.add(.{ .c_right = {} });
    if (key_states[c.SDL_SCANCODE_W]) try req_list.add(.{ .pan_up = {} });
    if (key_states[c.SDL_SCANCODE_S]) try req_list.add(.{ .pan_down = {} });
    if (key_states[c.SDL_SCANCODE_A]) try req_list.add(.{ .pan_left = {} });
    if (key_states[c.SDL_SCANCODE_D]) try req_list.add(.{ .pan_right = {} });
    if (key_states[c.SDL_SCANCODE_SPACE]) try req_list.add(.{ .zoom_in = {} });
    if (key_states[c.SDL_SCANCODE_LSHIFT]) try req_list.add(.{ .zoom_out = {} });
    return req_list.getItems();
}

fn getSdlFRect(rect: RectInfo) c.SDL_FRect {
    var sdl_rect: c.SDL_FRect = undefined;
    const diff = rect.max - rect.min;
    sdl_rect.x = rect.min[0];
    sdl_rect.y = rect.min[1];
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

fn renderText(text: TextInfo) void {
    const col = text.colour;
    _ = c.SDL_SetRenderScale(renderer, 2.0, 2.0);
    _ = c.SDL_SetRenderDrawColor(renderer, col.r, col.g, col.b, col.a);
    _ = c.SDL_RenderDebugText(renderer, text.x, text.y, text.string);
}
fn renderTexture(info: TextureInfo) !void {
    var texture_pixels: ?*anyopaque = null;
    var pitch: c_int = 0;
    if (!c.SDL_LockTexture(texture, null, &texture_pixels, &pitch)) {
        c.SDL_Log("Failed to lock texture: %s", c.SDL_GetError());
        return error.SDLFailedToCreateLockTexture;
    }
    defer c.SDL_UnlockTexture(texture);
    const s_pitch = info.width * @sizeOf(u32);
    const d_pitch: usize = @intCast(pitch);
    const dst: [*]u8 = @ptrCast(texture_pixels.?);
    const src = std.mem.sliceAsBytes(info.pixels);

    if (d_pitch == s_pitch) {
        @memcpy(
            dst[0 .. s_pitch * info.height],
            src[0 .. s_pitch * info.height],
        );
    } else {
        for (0..info.height) |y| {
            const s_start = y * s_pitch;
            const d_start = y * d_pitch;
            @memcpy(dst[d_start .. d_start + s_pitch], src[s_start .. s_start + s_pitch]);
        }
    }
    c.SDL_UnlockTexture(texture);
    if (!c.SDL_RenderTexture(renderer, texture, null, null)) {
        return error.SDLTextureRenderFailed;
    }
}
