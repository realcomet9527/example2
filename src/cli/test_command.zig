const _global = @import("../global.zig");
const string = _global.string;
const Output = _global.Output;
const Global = _global.Global;
const Environment = _global.Environment;
const strings = _global.strings;
const MutableString = _global.MutableString;
const stringZ = _global.stringZ;
const default_allocator = _global.default_allocator;
const C = _global.C;
const std = @import("std");

const lex = @import("../js_lexer.zig");
const logger = @import("../logger.zig");

const FileSystem = @import("../fs.zig").FileSystem;
const options = @import("../options.zig");
const js_parser = @import("../js_parser.zig");
const json_parser = @import("../json_parser.zig");
const js_printer = @import("../js_printer.zig");
const js_ast = @import("../js_ast.zig");
const linker = @import("../linker.zig");
const panicky = @import("../panic_handler.zig");
const sync = @import("../sync.zig");
const Api = @import("../api/schema.zig").Api;
const resolve_path = @import("../resolver/resolve_path.zig");
const configureTransformOptionsForBun = @import("../javascript/jsc/config.zig").configureTransformOptionsForBun;
const Command = @import("../cli.zig").Command;
const bundler = @import("../bundler.zig");
const NodeModuleBundle = @import("../node_module_bundle.zig").NodeModuleBundle;
const DotEnv = @import("../env_loader.zig");
const which = @import("../which.zig").which;
const Run = @import("../bun_js.zig").Run;
var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
var path_buf2: [std.fs.MAX_PATH_BYTES]u8 = undefined;
const PathString = _global.PathString;

const JSC = @import("javascript_core");
const Jest = JSC.Jest;
const TestRunner = JSC.Jest.TestRunner;
const Test = TestRunner.Test;
pub const CommandLineReporter = struct {
    jest: TestRunner,
    callback: TestRunner.Callback,
    last_dot: u32 = 0,
    summary: Summary = Summary{},

    pub const Summary = struct {
        pass: u32 = 0,
        expectations: u32 = 0,
        fail: u32 = 0,
    };

    const DotColorMap = std.EnumMap(TestRunner.Test.Status, string);
    const dots: DotColorMap = brk: {
        var map: DotColorMap = DotColorMap.init(.{});
        map.put(TestRunner.Test.Status.pending, Output.RESET ++ Output.ED ++ Output.color_map.get("yellow").? ++ "." ++ Output.RESET);
        map.put(TestRunner.Test.Status.pass, Output.RESET ++ Output.ED ++ Output.color_map.get("green").? ++ "." ++ Output.RESET);
        map.put(TestRunner.Test.Status.fail, Output.RESET ++ Output.ED ++ Output.color_map.get("red").? ++ "." ++ Output.RESET);
        break :brk map;
    };

    fn updateDots(this: *CommandLineReporter) void {
        const statuses = this.jest.tests.items(.status);
        var writer = Output.errorWriter();
        writer.writeAll("\r") catch unreachable;
        if (Output.enable_ansi_colors_stderr) {
            for (statuses) |status| {
                writer.writeAll(dots.get(status).?) catch unreachable;
            }
        } else {
            for (statuses) |_| {
                writer.writeAll(".") catch unreachable;
            }
        }
    }

    pub fn handleUpdateCount(cb: *TestRunner.Callback, _: u32, _: u32) void {
        _ = cb;
    }

    pub fn handleTestStart(_: *TestRunner.Callback, _: Test.ID) void {
        // var this: *CommandLineReporter = @fieldParentPtr(CommandLineReporter, "callback", cb);
    }
    pub fn handleTestPass(cb: *TestRunner.Callback, _: Test.ID, expectations: u32) void {
        var this: *CommandLineReporter = @fieldParentPtr(CommandLineReporter, "callback", cb);
        // this.updateDots();
        this.summary.pass += 1;
        this.summary.expectations += expectations;
    }
    pub fn handleTestFail(cb: *TestRunner.Callback, test_id: Test.ID, _: string, _: string, _: u32) void {
        // var this: *CommandLineReporter = @fieldParentPtr(CommandLineReporter, "callback", cb);
        var this: *CommandLineReporter = @fieldParentPtr(CommandLineReporter, "callback", cb);
        // this.updateDots();
        this.summary.fail += 1;
        _ = test_id;
    }
};

const Scanner = struct {
    const Fifo = std.fifo.LinearFifo(ScanEntry, .Dynamic);
    exclusion_names: []const []const u8 = &.{},
    filter_names: []const []const u8 = &.{},
    dirs_to_scan: Fifo,
    results: std.ArrayList(_global.PathString),
    fs: *FileSystem,
    open_dir_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined,
    scan_dir_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined,
    options: *options.BundleOptions,
    has_iterated: bool = false,

    const ScanEntry = struct {
        relative_dir: _global.StoredFileDescriptorType,
        dir_path: string,
        name: strings.StringOrTinyString,
    };

    fn readDirWithName(this: *Scanner, name: string, handle: ?std.fs.Dir) !*FileSystem.RealFS.EntriesOption {
        return try this.fs.fs.readDirectoryWithIterator(name, handle, *Scanner, this);
    }

    pub fn scan(this: *Scanner, path_literal: string) void {
        var parts = &[_]string{ this.fs.top_level_dir, path_literal };
        const path = this.fs.absBuf(parts, &this.scan_dir_buf);
        var root = this.readDirWithName(path, null) catch |err| {
            if (err == error.NotDir) {
                if (this.isTestFile(path)) {
                    this.results.append(_global.PathString.init(this.fs.filename_store.append(@TypeOf(path), path) catch unreachable)) catch unreachable;
                }
            }

            return;
        };

        // you typed "." and we already scanned it
        if (!this.has_iterated) {
            if (@as(FileSystem.RealFS.EntriesOption.Tag, root.*) == .entries) {
                var iter = root.entries.data.iterator();
                const fd = root.entries.fd;
                while (iter.next()) |entry| {
                    this.next(entry.value, fd);
                }
            }
        }

        while (this.dirs_to_scan.readItem()) |entry| {
            var dir = std.fs.Dir{ .fd = entry.relative_dir };
            var parts2 = &[_]string{ entry.dir_path, entry.name.slice() };
            var path2 = this.fs.absBuf(parts2, &this.open_dir_buf);
            this.open_dir_buf[path2.len] = 0;
            var pathZ = this.open_dir_buf[path2.len - entry.name.slice().len .. path2.len :0];
            var child_dir = dir.openDirZ(pathZ, .{ .iterate = true }) catch continue;
            path2 = this.fs.dirname_store.append(string, path2) catch unreachable;
            FileSystem.setMaxFd(child_dir.fd);
            _ = this.readDirWithName(path2, child_dir) catch continue;
        }
    }

    const test_name_suffixes = [_]string{
        ".test",
        "_test",
        ".spec",
        "_spec",
    };

    pub fn couldBeTestFile(this: *Scanner, name: string) bool {
        const extname = std.fs.path.extension(name);
        if (!this.options.loader(extname).isJavaScriptLike()) return false;
        const name_without_extension = name[0 .. name.len - extname.len];
        inline for (test_name_suffixes) |suffix| {
            if (strings.endsWithComptime(name_without_extension, suffix)) return true;
        }

        return false;
    }

    pub fn doesAbsolutePathMatchFilter(this: *Scanner, name: string) bool {
        if (this.filter_names.len == 0) return true;

        for (this.filter_names) |filter_name| {
            if (strings.contains(name, filter_name)) return true;
        }

        return false;
    }

    pub fn isTestFile(this: *Scanner, name: string) bool {
        return this.couldBeTestFile(name) and this.doesAbsolutePathMatchFilter(name);
    }

    pub fn next(this: *Scanner, entry: *FileSystem.Entry, fd: _global.StoredFileDescriptorType) void {
        const name = entry.base_lowercase();
        this.has_iterated = true;
        switch (entry.kind(&this.fs.fs)) {
            .dir => {
                if (strings.eqlComptime(name, "node_modules") or strings.eqlComptime(name, ".git")) {
                    return;
                }

                for (this.exclusion_names) |exclude_name| {
                    if (strings.eql(exclude_name, name)) return;
                }

                this.dirs_to_scan.writeItem(.{
                    .relative_dir = fd,
                    .name = entry.base_,
                    .dir_path = entry.dir,
                }) catch unreachable;
            },
            .file => {
                // already seen it!
                if (!entry.abs_path.isEmpty()) return;

                if (!this.couldBeTestFile(name)) return;

                var parts = &[_]string{ entry.dir, entry.base() };
                const path = this.fs.absBuf(parts, &this.open_dir_buf);

                if (!this.doesAbsolutePathMatchFilter(path)) return;

                entry.abs_path = _global.PathString.init(this.fs.filename_store.append(@TypeOf(path), path) catch unreachable);
                this.results.append(entry.abs_path) catch unreachable;
            },
        }
    }
};

pub const TestCommand = struct {
    pub const name = "wiptest";
    pub fn exec(ctx: Command.Context) !void {
        var env_loader = brk: {
            var map = try ctx.allocator.create(DotEnv.Map);
            map.* = DotEnv.Map.init(ctx.allocator);

            var loader = try ctx.allocator.create(DotEnv.Loader);
            loader.* = DotEnv.Loader.init(map, ctx.allocator);
            break :brk loader;
        };
        JSC.C.JSCInitialize();
        var reporter = try ctx.allocator.create(CommandLineReporter);
        reporter.* = CommandLineReporter{
            .jest = TestRunner{
                .allocator = ctx.allocator,
                .log = ctx.log,
                .callback = undefined,
            },
            .callback = undefined,
        };
        reporter.callback = TestRunner.Callback{
            .onUpdateCount = CommandLineReporter.handleUpdateCount,
            .onTestStart = CommandLineReporter.handleTestStart,
            .onTestPass = CommandLineReporter.handleTestPass,
            .onTestFail = CommandLineReporter.handleTestFail,
        };
        reporter.jest.callback = &reporter.callback;
        Jest.Jest.runner = &reporter.jest;

        js_ast.Expr.Data.Store.create(default_allocator);
        js_ast.Stmt.Data.Store.create(default_allocator);
        var vm = try JSC.VirtualMachine.init(ctx.allocator, ctx.args, null, ctx.log, env_loader);
        vm.argv = ctx.positionals;

        try vm.bundler.configureDefines();

        var scanner = Scanner{
            .dirs_to_scan = Scanner.Fifo.init(ctx.allocator),
            .options = &vm.bundler.options,
            .fs = vm.bundler.fs,
            .filter_names = ctx.positionals[1..],
            .results = std.ArrayList(PathString).init(ctx.allocator),
        };

        scanner.scan(scanner.fs.top_level_dir);
        scanner.dirs_to_scan.deinit();

        const test_files = scanner.results.toOwnedSlice();

        // vm.bundler.fs.fs.readDirectory(_dir: string, _handle: ?std.fs.Dir)
        runAllTests(reporter, vm, test_files, ctx.allocator);

        Output.pretty("\n", .{});
        Output.flush();

        Output.prettyError("\n", .{});

        if (reporter.summary.pass > 0) {
            Output.prettyError("<r><green>", .{});
        }

        Output.prettyError(" {d:5>} pass<r>\n", .{reporter.summary.pass});

        if (reporter.summary.fail > 0) {
            Output.prettyError("<r><red>", .{});
        } else {
            Output.prettyError("<r><d>", .{});
        }

        Output.prettyError(" {d:5>} fail<r>\n", .{reporter.summary.fail});

        if (reporter.summary.fail == 0 and reporter.summary.expectations > 0) {
            Output.prettyError("<r><green>", .{});
        } else {
            Output.prettyError("<r>", .{});
        }
        Output.prettyError(" {d:5>} expectations\n", .{reporter.summary.expectations});

        Output.prettyError(
            \\ Ran {d} tests across {d} files 
        , .{
            reporter.summary.fail + reporter.summary.pass,
            test_files.len,
        });
        Output.printStartEnd(ctx.start_time, std.time.nanoTimestamp());
        Output.prettyError("\n", .{});

        Output.flush();

        if (reporter.summary.fail > 0) {
            std.os.exit(1);
        }
    }

    pub fn runAllTests(
        reporter_: *CommandLineReporter,
        vm_: *JSC.VirtualMachine,
        files_: []const PathString,
        allocator_: std.mem.Allocator,
    ) void {
        const Context = struct {
            reporter: *CommandLineReporter,
            vm: *JSC.VirtualMachine,
            files: []const PathString,
            allocator: std.mem.Allocator,
            pub fn begin(this: *@This()) void {
                var reporter = this.reporter;
                var vm = this.vm;
                var files = this.files;
                var allocator = this.allocator;
                for (files) |file_name| {
                    TestCommand.run(reporter, vm, file_name.slice(), allocator) catch {};
                }
            }
        };
        var ctx = Context{ .reporter = reporter_, .vm = vm_, .files = files_, .allocator = allocator_ };
        vm_.runWithAPILock(Context, &ctx, Context.begin);
    }

    pub fn run(
        reporter: *CommandLineReporter,
        vm: *JSC.VirtualMachine,
        file_name: string,
        _: std.mem.Allocator,
    ) !void {
        defer {
            js_ast.Expr.Data.Store.reset();
            js_ast.Stmt.Data.Store.reset();

            if (vm.log.errors > 0) {
                if (Output.enable_ansi_colors) {
                    vm.log.printForLogLevelWithEnableAnsiColors(Output.errorWriter(), true) catch {};
                } else {
                    vm.log.printForLogLevelWithEnableAnsiColors(Output.errorWriter(), false) catch {};
                }
                vm.log.msgs.clearRetainingCapacity();
                vm.log.errors = 0;
            }

            Output.flush();
        }

        var file_start = reporter.jest.files.len;
        var resolution = try vm.bundler.resolveEntryPoint(file_name);

        var promise = try vm.loadEntryPoint(resolution.path_pair.primary.text);

        while (promise.status(vm.global.vm()) == .Pending) {
            vm.tick();
        }

        var result = promise.result(vm.global.vm());
        if (result.isError() or
            result.isAggregateError(vm.global) or
            result.isException(vm.global.vm()))
        {
            vm.defaultErrorHandler(result, null);
        }

        reporter.updateDots();

        var modules: []*Jest.DescribeScope = reporter.jest.files.items(.module_scope)[file_start..];
        for (modules) |module| {
            module.runTests(vm.global.ref());
        }

        reporter.updateDots();
    }
};
