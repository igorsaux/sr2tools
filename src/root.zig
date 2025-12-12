// Copyright (c) 2025 Igor Spichkin
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Dat = @import("dat.zig").Dat;
pub const Pkg = @import("pkg.zig").Pkg;
pub const Gi = @import("gi.zig").Gi;
pub const Tga = @import("tga.zig").Tga;

pub const Rgba = extern struct {
    r: u8 align(1) = 0,
    g: u8 align(1) = 0,
    b: u8 align(1) = 0,
    a: u8 align(1) = 0,
};
