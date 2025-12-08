// Copyright (c) 2025 Igor Spichkin
// SPDX-License-Identifier: MIT

const std = @import("std");
const Crc32 = std.hash.crc.Crc32IsoHdlc;

const Rand31PM = struct {
    seed: i32,

    pub fn init(seed: i32) Rand31PM {
        return .{ .seed = seed };
    }

    pub fn next(this: *Rand31PM) i32 {
        const hi: i32 = @divFloor(this.seed, 0x1F31D);
        const low: i32 = @mod(this.seed, 0x1F31D);

        this.seed = low * 0x41A7 - hi * 0xB14;

        if (this.seed < 1) {
            this.seed += 0x7FFFFFFF;
        }

        return this.seed - 1;
    }
};

pub const Dat = struct {
    pub const Node = struct {
        pub const Error = error{UnknownType};

        const RawType = enum(u8) {
            par = 1,
            block = 2,
        };

        pub const Par = struct {
            value: []u8,

            pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Par {
                return .{
                    .value = try readWString(allocator, reader),
                };
            }

            pub fn jsonStringify(this: *const Par, sw: *std.json.Stringify) !void {
                try sw.write(this.value);
            }

            pub fn deinit(this: *Par, allocator: std.mem.Allocator) void {
                allocator.free(this.value);
            }
        };

        pub const Block = struct {
            children: std.ArrayList(Node),

            pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, format: Format) anyerror!Block {
                var block: Block = .{
                    .children = .empty,
                };
                errdefer block.children.deinit(allocator);

                const sorted: bool = switch (format) {
                    .sr1, .hd_main, .reload_main => try reader.takeByte() != 0,
                    else => false,
                };

                const children_count: u32 = try reader.takeInt(u32, .little);

                for (0..children_count) |_| {
                    if (sorted) {
                        _ = try reader.takeInt(u32, .little);
                        _ = try reader.takeInt(u32, .little);
                    }

                    const child = try Node.read(allocator, reader, format);
                    try block.children.append(allocator, child);
                }

                return block;
            }

            pub fn jsonStringify(this: *const Block, sw: *std.json.Stringify) !void {
                try sw.write(this.children.items);
            }

            pub fn deinit(this: *Block, allocator: std.mem.Allocator) void {
                for (this.children.items) |*child| {
                    child.deinit(allocator);
                }

                this.children.deinit(allocator);
            }
        };

        pub const Value = union(enum) {
            par: Par,
            block: Block,

            pub fn jsonStringify(this: *const Value, sw: *std.json.Stringify) !void {
                switch (this.*) {
                    .par => |*par| try sw.write(par),
                    .block => |*block| try sw.write(block),
                }
            }

            pub fn deinit(this: *Value, allocator: std.mem.Allocator) void {
                switch (this.*) {
                    .par => |*par| {
                        par.deinit(allocator);
                    },
                    .block => |*block| {
                        block.deinit(allocator);
                    },
                }
            }
        };

        name: []u8,
        value: Value,

        fn readWString(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
            var str: std.ArrayList(u16) = .empty;
            try str.ensureTotalCapacity(allocator, 256);

            defer str.deinit(allocator);

            while (true) {
                const wchar: [2]u8 = (try reader.takeArray(2)).*;

                if (std.mem.eql(u8, &wchar, "\x00\x00")) {
                    break;
                }

                try str.append(allocator, std.mem.bytesToValue(u16, &wchar));
            }

            return try std.unicode.utf16LeToUtf8Alloc(allocator, str.items);
        }

        pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, format: Format) !Node {
            const ty = try reader.takeEnum(RawType, .little);
            const name: []u8 = try readWString(allocator, reader);
            errdefer allocator.free(name);

            return switch (ty) {
                .par => .{
                    .name = name,
                    .value = .{
                        .par = try .read(allocator, reader),
                    },
                },
                .block => .{
                    .name = name,
                    .value = .{
                        .block = try .read(allocator, reader, format),
                    },
                },
            };
        }

        pub fn readRoot(allocator: std.mem.Allocator, reader: *std.Io.Reader, format: Format) !Node {
            return .{
                .name = "",
                .value = .{
                    .block = try .read(allocator, reader, format),
                },
            };
        }

        pub fn deinit(this: *Node, allocator: std.mem.Allocator) void {
            allocator.free(this.name);
            this.value.deinit(allocator);
        }
    };

    pub const Error = error{ UnknownFormat, BadContent };

    // keys from https://github.com/denballakh/ranger-tools/blob/b3c0ce20d1cf61b030f3c33482d09b91500b75c6/rangers/dat.py#L17
    pub const SIGN_KEY_1: u32 = 0xC83FCBF3;
    pub const SIGN_KEY_2: u32 = 0x7DB6C99D;

    pub const Format = enum {
        sr1,
        reload_main,
        reload_cache,
        hd_main,
        hd_cache,
    };

    pub const Key = struct { i32, Format };

    pub const KEYS: [5]Key = [_]Key{
        .{ 0, .sr1 },
        .{ 1050086386, .reload_main },
        .{ 1929242201, .reload_cache },
        .{ -1310144887, .hd_main },
        .{ -359710921, .hd_cache },
    };

    fn crc32Stream(crc32: *Crc32, freader: *std.fs.File.Reader) !u32 {
        var buffer: [1024]u8 = undefined;

        while (true) {
            const readed = try freader.interface.readSliceShort(&buffer);

            crc32.update(buffer[0..readed]);

            if (readed != buffer.len) {
                return crc32.final();
            }
        }
    }

    fn getSign(freader: *std.fs.File.Reader) ![8]u8 {
        const size: u32 = @intCast(try freader.getSize() - freader.logicalPos());
        const size_part: u32 = size ^ SIGN_KEY_1 ^ SIGN_KEY_2;

        const original_pos = freader.logicalPos();

        var checksum_part: u32 = 0;

        {
            defer freader.seekTo(original_pos) catch {};

            var crc32: Crc32 = .init();
            checksum_part = try crc32Stream(&crc32, freader) ^ SIGN_KEY_2;
        }

        {
            defer freader.seekTo(original_pos) catch {};

            var crc32: Crc32 = .init();

            crc32.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, checksum_part)));
            checksum_part = try crc32Stream(&crc32, freader) ^ SIGN_KEY_1;
        }

        checksum_part =
            return std.mem.toBytes(std.mem.nativeToLittle(u32, size_part)) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, checksum_part));
    }

    fn isSigned(freader: *std.fs.File.Reader) !bool {
        const expected_sign = try freader.interface.takeArray(8);
        const actual_sign: [8]u8 = try getSign(freader);

        return std.mem.eql(u8, expected_sign, &actual_sign);
    }

    const Header = struct {
        hash: u32,
        seed: i32,
        key: i32,
        format: Format,
    };

    fn tryDecryptHeader(freader: *std.fs.File.Reader) !?Header {
        const hash = try freader.interface.takeInt(u32, .little);
        const seed_encrypted = try freader.interface.takeInt(i32, .little);

        const original_pos = freader.logicalPos();
        defer freader.seekTo(original_pos) catch {};

        const magic_encrypted: [4]u8 = (try freader.interface.takeArray(4)).*;

        for (KEYS) |kvp| {
            const key, const format = kvp;

            const seed_decrypted = seed_encrypted ^ key;
            var rand: Rand31PM = .init(seed_decrypted);
            var magic_decrypted: [4]u8 = undefined;

            for (magic_encrypted, 0..) |byte, i| {
                const xored: u32 = @intCast(byte ^ (rand.next() & 0xFF));
                magic_decrypted[i] = @as(u8, @truncate(xored));
            }

            if (!std.mem.eql(u8, &magic_decrypted, "ZL01")) {
                continue;
            }

            return .{
                .hash = hash,
                .seed = seed_decrypted,
                .key = key,
                .format = format,
            };
        }

        return null;
    }

    fn decrypt(allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !struct { []u8, Header } {
        if (!try isSigned(freader)) {
            try freader.seekTo(0);
        }

        const header = try tryDecryptHeader(freader) orelse {
            return Error.UnknownFormat;
        };
        var rand: Rand31PM = .init(header.seed);

        const decrypted_data = try allocator.alloc(u8, try freader.getSize() - freader.logicalPos());
        errdefer allocator.free(decrypted_data);

        try freader.interface.readSliceAll(decrypted_data);

        for (decrypted_data, 0..) |byte, i| {
            const xored: u32 = @intCast(byte ^ (rand.next() & 0xFF));
            decrypted_data[i] = @as(u8, @truncate(xored));
        }

        const actual_hash = Crc32.hash(decrypted_data);

        if (header.hash != actual_hash) {
            return Error.BadContent;
        }

        return .{ decrypted_data, header };
    }

    fn uncompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
        var reader: std.Io.Reader = .fixed(compressed);

        const magic = try reader.takeArray(4);
        _ = magic;

        const size = try reader.takeInt(u32, .little);
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);

        var buffer: [std.compress.flate.max_window_len]u8 = undefined;

        var deflate: std.compress.flate.Decompress = .init(&reader, .zlib, &buffer);
        try deflate.reader.readSliceAll(data);

        return data;
    }

    pub fn read(allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !Node {
        const decrypted_data, const header = try decrypt(allocator, freader);
        defer allocator.free(decrypted_data);

        const data = try uncompress(allocator, decrypted_data);
        defer allocator.free(data);

        var reader: std.Io.Reader = .fixed(data);

        return try Node.readRoot(allocator, &reader, header.format);
    }
};
