// Copyright (c) 2025 Igor Spichkin
// SPDX-License-Identifier: MIT

const std = @import("std");

const sr2tools = @import("sr2tools");

inline fn rgb565leToRgb888(in: [2]u8) [3]u8 {
    const r = in[1] & 0b11111000;
    var g = ((in[0] & 0b11100000) >> 5) | ((in[1] & 0b00000111) << 3);
    var b = (in[0] & 0b00011111);

    g <<= 2;
    b <<= 3;

    return [3]u8{ r, g, b };
}

pub const Gi = struct {
    pub const Error = Header.Error;

    const Header = struct {
        pub const Bitmask = struct {
            r: u32,
            g: u32,
            b: u32,
            a: u32,

            pub fn read(reader: *std.Io.Reader) !Bitmask {
                return .{
                    .r = try reader.takeInt(u32, .little),
                    .g = try reader.takeInt(u32, .little),
                    .b = try reader.takeInt(u32, .little),
                    .a = try reader.takeInt(u32, .little),
                };
            }
        };

        pub const Error = error{
            InvalidMagic,
            InvalidVersion,
            InvalidFrameType,
        };

        version: u32,
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
        bitmask: Bitmask,
        frame_type: u32,
        layers_count: u32,

        pub fn read(reader: *std.Io.Reader) !Header {
            const signature = try reader.takeArray(4);

            if (!std.mem.eql(u8, signature, "gi\x00\x00")) {
                return Header.Error.InvalidMagic;
            }

            const version = try reader.takeInt(u32, .little);

            if (version != 1) {
                return Header.Error.InvalidVersion;
            }

            const left = try reader.takeInt(i32, .little);
            const top = try reader.takeInt(i32, .little);
            const right = try reader.takeInt(i32, .little);
            const bottom = try reader.takeInt(i32, .little);
            const bitmask = try Bitmask.read(reader);
            const frame_type = try reader.takeInt(u32, .little);

            if (frame_type > 5) {
                return Header.Error.InvalidFrameType;
            }

            const layers_count = try reader.takeInt(u32, .little);

            for (0..4) |_| {
                _ = try reader.takeInt(u32, .little);
            }

            return .{
                .version = version,
                .left = left,
                .top = top,
                .right = right,
                .bottom = bottom,
                .bitmask = bitmask,
                .frame_type = frame_type,
                .layers_count = layers_count,
            };
        }
    };

    pub const Layer = struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
        data: []u8,

        pub fn read(allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !Layer {
            const offset = try freader.interface.takeInt(u32, .little);
            const size = try freader.interface.takeInt(u32, .little);
            const left = try freader.interface.takeInt(i32, .little);
            const top = try freader.interface.takeInt(i32, .little);
            const right = try freader.interface.takeInt(i32, .little);
            const bottom = try freader.interface.takeInt(i32, .little);

            for (0..2) |_| {
                _ = try freader.interface.takeInt(u32, .little);
            }

            const original_pos = freader.logicalPos();
            defer freader.seekTo(original_pos) catch {};

            try freader.seekTo(offset);
            const data = try freader.interface.readAlloc(allocator, size);

            return .{
                .left = left,
                .top = top,
                .right = right,
                .bottom = bottom,
                .data = data,
            };
        }

        pub fn deinit(this: *Layer, allocator: std.mem.Allocator) void {
            allocator.free(this.data);
        }
    };

    header: Header,
    layers: std.ArrayList(Layer),
    pixels: []sr2tools.Rgba,

    fn makePixels2(this: *Gi, allocator: std.mem.Allocator) !void {
        const width: usize = @intCast(this.header.right - this.header.left);
        const height: usize = @intCast(this.header.bottom - this.header.top);

        this.pixels = try allocator.alloc(sr2tools.Rgba, @intCast(width * height));
        @memset(this.pixels, .{});

        for (this.layers.items, 0..) |*layer, i| {
            var reader: std.Io.Reader = .fixed(layer.data);

            const size = try reader.takeInt(u32, .little);
            _ = size;

            const layer_width = try reader.takeInt(u32, .little);
            _ = layer_width;
            const layer_height = try reader.takeInt(u32, .little);
            _ = layer_height;

            _ = try reader.takeInt(u32, .little);

            var x: usize = 0;
            var y: usize = 0;

            const left: usize = @intCast(layer.left - this.header.left);
            const top: usize = @intCast(layer.top - this.header.top);

            while (reader.seek != reader.end) {
                const byte = try reader.takeByte();

                if (byte == 0 or byte == 0x80) {
                    x = 0;
                    y += 1;
                } else if (byte > 0x80) {
                    var count: usize = byte & 0x7F;
                    const offset: usize = (y + top) * width + left;

                    while (count > 0) {
                        const idx = (x + offset);
                        var pixel: sr2tools.Rgba = .{};

                        if (i == 0 or i == 1) {
                            pixel.r, pixel.g, pixel.b = rgb565leToRgb888(
                                (try reader.takeArray(2)).*,
                            );
                            pixel.a = 0xFF;
                        } else {
                            pixel.a = (63 - try reader.takeByte()) << 2;
                            pixel.r = this.pixels[idx].r;
                            pixel.g = this.pixels[idx].g;
                            pixel.b = this.pixels[idx].b;

                            if (pixel.a != 0 and pixel.a != 255) {
                                const r: f32 = @floatFromInt(pixel.r);
                                const g: f32 = @floatFromInt(pixel.g);
                                const b: f32 = @floatFromInt(pixel.b);
                                const a: f32 = @floatFromInt(pixel.a);

                                pixel.r = @as(u8, @intFromFloat(std.math.round((r / a) * 63.0))) << 2;
                                pixel.g = @as(u8, @intFromFloat(std.math.round((g / a) * 63.0))) << 2;
                                pixel.b = @as(u8, @intFromFloat(std.math.round((b / a) * 63.0))) << 2;
                            }
                        }

                        this.pixels[idx] = pixel;

                        x += 1;
                        count -= 1;
                    }
                } else if (byte < 0x80) {
                    x += byte;
                }
            }
        }
    }

    inline fn makePixels(this: *Gi, allocator: std.mem.Allocator) !void {
        return switch (this.header.frame_type) {
            0 => unreachable, // TODO
            1 => unreachable, // TODO
            2 => makePixels2(this, allocator), // TODO
            3 => unreachable, // TODO
            4 => unreachable, // TODO
            5 => unreachable, // TODO
            else => unreachable,
        };
    }

    pub fn read(allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !Gi {
        const header = try Header.read(&freader.interface);

        var gi: Gi = .{
            .header = header,
            .layers = .empty,
            .pixels = &.{},
        };
        errdefer gi.deinit(allocator);

        try gi.layers.ensureTotalCapacity(allocator, header.layers_count);

        for (0..header.layers_count) |_| {
            const layer: Layer = try .read(allocator, freader);
            try gi.layers.append(allocator, layer);
        }

        try gi.makePixels(allocator);

        return gi;
    }

    pub fn jsonStringify(this: *const Gi, sw: *std.json.Stringify) !void {
        try sw.beginObject();

        try sw.objectField("header");
        try sw.write(this.header);

        try sw.objectField("layers");
        try sw.write(this.layers.items);

        try sw.endObject();
    }

    pub fn deinit(this: *Gi, allocator: std.mem.Allocator) void {
        for (this.layers.items) |*layer| {
            layer.deinit(allocator);
        }

        this.layers.clearAndFree(allocator);
        allocator.free(this.pixels);
    }
};
