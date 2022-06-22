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

const JSC = @import("../../../jsc.zig");

const Classes = JSC.GlobalClasses;

pub fn main() anyerror!void {
    var allocator = std.heap.c_allocator;
    const src: std.builtin.SourceLocation = @src();
    {
        const paths = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, "headers.h" };
        const paths2 = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, "headers-cpp.h" };
        const paths3 = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, "ZigLazyStaticFunctions.h" };
        const paths4 = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, "ZigLazyStaticFunctions-inlines.h" };

        const cpp = try std.fs.createFileAbsolute(try std.fs.path.join(allocator, &paths2), .{});
        const file = try std.fs.createFileAbsolute(try std.fs.path.join(allocator, &paths), .{});
        const static = try std.fs.createFileAbsolute(try std.fs.path.join(allocator, &paths3), .{});
        const staticInlines = try std.fs.createFileAbsolute(try std.fs.path.join(allocator, &paths4), .{});

        const HeaderGenerator = HeaderGen(
            Bindings,
            Exports,
            "src/javascript/jsc/bindings/bindings.zig",
        );
        HeaderGenerator.exec(HeaderGenerator{}, file, cpp, static, staticInlines);
    }
    // TODO: finish this
    const use_cpp_generator = false;
    if (use_cpp_generator) {
        comptime var i: usize = 0;
        inline while (i < Classes.len) : (i += 1) {
            const Class = Classes[i];
            const paths = [_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, Class.name ++ ".generated.h" };
            var headerFilePath = try std.fs.path.join(
                allocator,
                &paths,
            );
            var implFilePath = try std.fs.path.join(
                allocator,
                &[_][]const u8{ std.fs.path.dirname(src.file) orelse return error.BadPath, Class.name ++ ".generated.cpp" },
            );
            var headerFile = try std.fs.createFileAbsolute(headerFilePath, .{});
            var header_writer = headerFile.writer();
            var implFile = try std.fs.createFileAbsolute(implFilePath, .{});
            try Class.@"generateC++Header"(header_writer);
            try Class.@"generateC++Class"(implFile.writer());
            headerFile.close();
            implFile.close();
        }
    }
}
