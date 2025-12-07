// Copyright (c) 2025 Igor Spichkin
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Pkg = struct {
    pub const MAX_FILE_NAME: usize = 63;

    pub const FileType = enum(u32) {
        text = 0,
        binary = 1,
        compressed = 2,
        folder = 3,
    };

    pub const FileRec = extern struct {
        size: u32 align(1),
        real_size: u32 align(1),
        name: [MAX_FILE_NAME]u8 align(1),
        real_name: [MAX_FILE_NAME]u8 align(1),
        ty: FileType align(1),
        nty: FileType align(1),
        free: u32 align(1),
        date: u32 align(1),
        // TODO: is it always 32-bit?
        offset: u32 align(1),
        extra: u32 align(1),

        pub fn read(reader: *std.Io.Reader) !FileRec {
            const size = try reader.takeInt(u32, .little);
            const real_size = try reader.takeInt(u32, .little);

            var name: [MAX_FILE_NAME]u8 = undefined;
            try reader.readSliceAll(&name);

            var real_name: [MAX_FILE_NAME]u8 = undefined;
            try reader.readSliceAll(&real_name);

            const ty = try reader.takeEnum(FileType, .little);
            const nty = try reader.takeEnum(FileType, .little);
            const free = try reader.takeInt(u32, .little);
            const date = try reader.takeInt(u32, .little);
            const offset = try reader.takeInt(u32, .little);
            const extra = try reader.takeInt(u32, .little);

            return .{
                .size = size,
                .real_size = real_size,
                .name = name,
                .real_name = real_name,
                .ty = ty,
                .nty = nty,
                .free = free,
                .date = date,
                .offset = offset,
                .extra = extra,
            };
        }
    };

    pub const Folder = struct {
        size: u32,
        recnum: u32,
        recsize: u32,
        file_recs: []FileRec,
        folders: []?Folder,
        data: []?[]u8,

        pub const Error = error{ InvalidRecSize, InvalidChunkSignature };

        pub fn read(allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !Folder {
            const size = try freader.interface.takeInt(u32, .little);
            const recnum = try freader.interface.takeInt(u32, .little);
            const recsize = try freader.interface.takeInt(u32, .little);

            if (recsize != @sizeOf(FileRec)) {
                return Error.InvalidRecSize;
            }

            const file_recs = try allocator.alloc(FileRec, recnum);
            errdefer allocator.free(file_recs);

            for (file_recs) |*rec| {
                rec.* = try FileRec.read(&freader.interface);
                rec.extra = 0;
                rec.nty = rec.ty;
            }

            const folders = try allocator.alloc(?Folder, recnum);
            for (folders) |*folder| {
                folder.* = null;
            }

            errdefer allocator.free(folders);

            for (file_recs, 0..) |*rec, i| {
                if (rec.ty == .folder and rec.free == 0) {
                    try freader.seekTo(rec.offset);
                    folders[i] = try Folder.read(allocator, freader);
                }
            }

            const data = try allocator.alloc(?[]u8, recnum);
            for (data) |*d| {
                d.* = null;
            }

            return .{
                .size = size,
                .recnum = recnum,
                .recsize = recsize,
                .file_recs = file_recs,
                .folders = folders,
                .data = data,
            };
        }

        pub fn readData(this: *Folder, allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !void {
            for (this.file_recs, 0..) |*rec, i| {
                if (rec.size == 0 or rec.real_size == 0 or rec.ty == .folder or rec.free != 0) {
                    continue;
                }

                if (rec.ty == .compressed) {
                    var deflated: usize = 0;
                    this.data[i] = try allocator.alloc(u8, rec.real_size);

                    try freader.seekTo(rec.offset);

                    _ = try freader.interface.takeInt(u32, .little);

                    while (deflated != rec.real_size) {
                        const chunk_size = try freader.interface.takeInt(u32, .little);
                        const signature = try freader.interface.takeInt(u32, .little);

                        if (signature != 0x32304c5a) {
                            return error.InvalidChunkSignature;
                        }

                        const uncompressed_size = try freader.interface.takeInt(u32, .little);

                        const chunk = try freader.interface.readAlloc(allocator, chunk_size - 8);
                        defer allocator.free(chunk);
                        var chunk_reader = std.Io.Reader.fixed(chunk);

                        var buffer: [std.compress.flate.max_window_len]u8 = undefined;
                        var deflate: std.compress.flate.Decompress = .init(&chunk_reader, .zlib, &buffer);
                        try deflate.reader.readSliceAll(this.data[i].?[deflated .. uncompressed_size + deflated]);

                        deflated += uncompressed_size;
                    }
                } else {
                    this.data[i] = try allocator.alloc(u8, rec.size);
                    try freader.seekTo(rec.offset);
                    try freader.interface.readSliceAll(this.data[i].?);
                }
            }

            for (this.folders) |*folder| {
                if (folder.*) |*f| {
                    try f.readData(allocator, freader);
                }
            }
        }

        pub fn deinit(this: *Folder, allocator: std.mem.Allocator) void {
            allocator.free(this.file_recs);

            for (this.folders) |*folder| {
                if (folder.*) |*f| {
                    f.deinit(allocator);
                }
            }

            allocator.free(this.folders);

            for (this.data) |data| {
                if (data == null) {
                    continue;
                }

                allocator.free(data.?);
            }

            allocator.free(this.data);
        }
    };

    root_offset: u32,
    root_folder: Folder,

    pub fn read(allocator: std.mem.Allocator, freader: *std.fs.File.Reader) !Pkg {
        const root_offset: u32 = try freader.interface.takeInt(u32, .little);

        try freader.seekTo(root_offset);
        var root_folder = try Folder.read(allocator, freader);
        errdefer root_folder.deinit(allocator);

        try root_folder.readData(allocator, freader);

        return .{
            .root_offset = root_offset,
            .root_folder = root_folder,
        };
    }

    pub fn deinit(this: *Pkg, allocator: std.mem.Allocator) void {
        this.root_folder.deinit(allocator);
    }
};
