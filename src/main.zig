// Copyright (c) 2025 Igor Spichkin
// SPDX-License-Identifier: MIT

const std = @import("std");

const sr2tools = @import("sr2tools");

fn printHelp(status: u8) noreturn {
    std.debug.print("Usage: sr2tools <unpack|dump> <what> <where>\n", .{});
    std.process.exit(status);
}

const Command = enum { unpack, dump };

fn unpackFolder(dir: *std.fs.Dir, folder: *const sr2tools.Pkg.Folder) !void {
    for (folder.file_recs, 0..) |*rec, i| {
        if (rec.ty == .folder) {
            continue;
        }

        const name: []const u8 = std.mem.sliceTo(&rec.real_name, 0);

        var file = try dir.createFile(name, .{});
        defer file.close();

        const data = folder.data[i].?;
        try file.writeAll(data);
    }

    for (folder.folders, 0..) |*inner_folder, i| {
        if (inner_folder.*) |*f| {
            const rec = &folder.file_recs[i];
            const name: []const u8 = std.mem.sliceTo(&rec.real_name, 0);

            var inner_dir = try dir.makeOpenPath(name, .{});
            defer inner_dir.close();

            try unpackFolder(&inner_dir, f);
        }
    }
}

fn doCmd(allocator: std.mem.Allocator, cmd: Command, what: []const u8, where: []const u8) !void {
    var file = try std.fs.cwd().openFile(what, .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(&buffer);

    const extension = std.fs.path.extension(what);

    if (std.mem.eql(u8, extension, ".pkg")) {
        var pkg = try sr2tools.Pkg.read(allocator, &reader);
        defer pkg.deinit(allocator);

        switch (cmd) {
            .unpack => {
                var dst_dir = try std.fs.cwd().makeOpenPath(where, .{});
                defer dst_dir.close();

                try unpackFolder(&dst_dir, &pkg.root_folder);
            },
            .dump => {
                const dst = try std.fs.cwd().createFile(where, .{});
                defer dst.close();

                var writer_buffer: [1024]u8 = undefined;
                var writer = dst.writer(&writer_buffer);

                try std.json.Stringify.value(pkg, .{ .whitespace = .minified }, &writer.interface);

                try writer.interface.flush();
            },
        }
    } else {
        std.debug.print("Unknown format: {s}\n", .{extension});
        printHelp(1);
    }
}

pub fn main() !void {
    var alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = alloc.deinit();

    const args = try std.process.argsAlloc(alloc.allocator());
    defer std.process.argsFree(alloc.allocator(), args);

    if (args.len < 4) {
        printHelp(1);
    }

    const cmd = args[1];
    const what = args[2];
    const where = args[3];

    var command: Command = undefined;

    if (std.mem.eql(u8, cmd, "unpack")) {
        command = .unpack;
    } else if (std.mem.eql(u8, cmd, "dump")) {
        command = .dump;
    } else {
        std.debug.print("Unknown command '{s}'\n", .{cmd});
        printHelp(1);
    }

    try doCmd(alloc.allocator(), command, what, where);
}
