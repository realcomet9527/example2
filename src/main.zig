const std = @import("std");
const lex = @import("js_lexer.zig");
const logger = @import("logger.zig");
const options = @import("options.zig");
const js_parser = @import("js_parser.zig");
const json_parser = @import("json_parser.zig");
const js_printer = @import("js_printer.zig");
const js_ast = @import("js_ast.zig");
const linker = @import("linker.zig");
usingnamespace @import("ast/base.zig");
usingnamespace @import("defines.zig");
usingnamespace @import("global.zig");
const panicky = @import("panic_handler.zig");
const cli = @import("cli.zig");
pub const MainPanicHandler = panicky.NewPanicHandler(std.builtin.default_panic);
const js = @import("javascript/jsc/bindings/bindings.zig");
usingnamespace @import("javascript/jsc/javascript.zig");

pub const io_mode = .blocking;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    MainPanicHandler.handle_panic(msg, error_return_trace);
}
pub var start_time: i128 = 0;
pub fn main() anyerror!void {
    start_time = std.time.nanoTimestamp();

    // The memory allocator makes a massive difference.
    // std.heap.raw_c_allocator and default_allocator perform similarly.
    // std.heap.GeneralPurposeAllocator makes this about 3x _slower_ than esbuild.
    // var root_alloc = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    // var root_alloc_ = &root_alloc.allocator;

    var stdout = std.io.getStdOut();
    // var stdout = std.io.bufferedWriter(stdout_file.writer());
    var stderr = std.io.getStdErr();
    var output_source = Output.Source.init(stdout, stderr);

    Output.Source.set(&output_source);
    defer Output.flush();
    
    cli.Cli.start(default_allocator, stdout, stderr, MainPanicHandler) catch |err| {
        switch (err) {
            error.CurrentWorkingDirectoryUnlinked => {
                Output.prettyError(
                    "\n<r><red>error: <r>The current working directory was deleted, so that command didn't work. Please cd into a different directory and try again.",
                    .{},
                );
                Output.flush();
                std.os.exit(1);
            },
            else => return err,
        }
    };

    std.mem.doNotOptimizeAway(JavaScriptVirtualMachine.fetch);
    std.mem.doNotOptimizeAway(JavaScriptVirtualMachine.init);
    std.mem.doNotOptimizeAway(JavaScriptVirtualMachine.resolve);
}

pub const JavaScriptVirtualMachine = VirtualMachine;

test "" {
    @import("std").testing.refAllDecls(@This());

    std.mem.doNotOptimizeAway(JavaScriptVirtualMachine.fetch);
    std.mem.doNotOptimizeAway(JavaScriptVirtualMachine.init);
    std.mem.doNotOptimizeAway(JavaScriptVirtualMachine.resolve);
}
