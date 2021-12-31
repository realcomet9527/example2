const Bindings = @import("bindings.zig");
const Exports = @import("exports.zig");
const HeaderGen = @import("./header-gen.zig").HeaderGen;
const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const fs = std.fs;
const process = std.process;
const ChildProcess = std.ChildProcess;
const Progress = std.Progress;
const print = std.debug.print;
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const bindgen = true;

pub fn main() anyerror!void {
    var allocator = std.heap.c_allocator;
    var stdout = std.io.getStdOut();
    var writer = stdout.writer();
    const src: std.builtin.SourceLocation = @src();
    const paths = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, "headers.h" };
    const paths2 = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, "headers-cpp.h" };

    const cpp = try std.fs.createFileAbsolute(try std.fs.path.join(allocator, &paths2), .{});
    const file = try std.fs.createFileAbsolute(try std.fs.path.join(allocator, &paths), .{});

    const HeaderGenerator = HeaderGen(
        Bindings,
        Exports,
        "src/javascript/jsc/bindings/bindings.zig",
    );
    HeaderGenerator.exec(HeaderGenerator{}, file, cpp);
}
