// Copyright (c) 2025 Igor Spichkin
// SPDX-License-Identifier: MIT

const std = @import("std");

const sr2tools = @import("sr2tools");

pub const Tga = struct {
    const Header = extern struct {
        const ColMapDesc = extern struct {
            first_idx: u16 align(1) = 0,
            len: u16 align(1) = 0,
            bpp: u8 align(1) = 0,
        };

        id_len: u8 align(1),
        colmap: u8 align(1),
        ty: u8 align(1),
        colmap_desc: ColMapDesc align(1) = .{},
        x: u16 align(1),
        y: u16 align(1),
        w: u16 align(1),
        h: u16 align(1),
        bpp: u8 align(1),
        desc: u8 align(1),
    };

    pub fn fromRgba(allocator: std.mem.Allocator, pixels: []sr2tools.Rgba, width: u16, height: u16) ![]u8 {
        const out = try allocator.alloc(
            u8,
            @sizeOf(Header) + (@sizeOf(sr2tools.Rgba) * width * height),
        );
        errdefer allocator.free(out);

        @memset(out, 0);

        const header: Header = .{
            .id_len = 0,
            .colmap = 0,
            .ty = 2, // true color
            .colmap_desc = .{},
            .x = 0,
            .y = 0,
            .w = width,
            .h = height,
            .bpp = 32,
            .desc = (0b1 << 5) // top-to-bottom
            | 0b1000, // 8-bit alpha
        };

        var writer: std.Io.Writer = .fixed(out);
        try writer.writeAll(@ptrCast(@alignCast(&header)));

        for (pixels) |pixel| {
            try writer.writeAll(&[4]u8{ pixel.b, pixel.g, pixel.r, pixel.a });
        }

        return out;
    }
};
