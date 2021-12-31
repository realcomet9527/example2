const _global = @import("global.zig");
const string = _global.string;
const Output = _global.Output;
const StoredFileDescriptorType = _global.StoredFileDescriptorType;
const Global = _global.Global;
const Environment = _global.Environment;
const strings = _global.strings;
const MutableString = _global.MutableString;
const stringZ = _global.stringZ;
const FeatureFlags = _global.FeatureFlags;
const default_allocator = _global.default_allocator;
const C = _global.C;

const js_ast = @import("./js_ast.zig");
const logger = @import("./logger.zig");
const js_parser = @import("./js_parser/js_parser.zig");
const json_parser = @import("./json_parser.zig");
const options = @import("./options.zig");
const Define = @import("./defines.zig").Define;
const std = @import("std");
const fs = @import("./fs.zig");
const sync = @import("sync.zig");
const Mutex = @import("./lock.zig").Lock;

const import_record = @import("./import_record.zig");

const ImportRecord = import_record.ImportRecord;

pub const FsCacheEntry = struct {
    contents: string,
    fd: StoredFileDescriptorType = 0,

    pub fn deinit(entry: *FsCacheEntry, allocator: std.mem.Allocator) void {
        if (entry.contents.len > 0) {
            allocator.free(entry.contents);
            entry.contents = "";
        }
    }
};

pub const Set = struct {
    js: JavaScript,
    fs: Fs,
    json: Json,

    pub fn init(allocator: std.mem.Allocator) Set {
        return Set{
            .js = JavaScript.init(allocator),
            .fs = Fs{
                .shared_buffer = MutableString.init(allocator, 0) catch unreachable,
            },
            .json = Json{},
        };
    }
};
pub const Fs = struct {
    const Entry = FsCacheEntry;

    shared_buffer: MutableString,

    pub fn deinit(c: *Fs) void {
        var iter = c.entries.iterator();
        while (iter.next()) |entry| {
            entry.value.deinit(c.entries.allocator);
        }
        c.entries.deinit();
    }

    pub fn readFileShared(
        _: *Fs,
        _fs: *fs.FileSystem,
        path: [:0]const u8,
        _: StoredFileDescriptorType,
        _file_handle: ?StoredFileDescriptorType,
        shared: *MutableString,
    ) !Entry {
        var rfs = _fs.fs;

        const file_handle: std.fs.File = if (_file_handle) |__file|
            std.fs.File{ .handle = __file }
        else
            try std.fs.openFileAbsoluteZ(path, .{ .read = true });

        defer {
            if (rfs.needToCloseFiles() and _file_handle == null) {
                file_handle.close();
            }
        }

        const file = rfs.readFileWithHandle(path, null, file_handle, true, shared) catch |err| {
            if (comptime Environment.isDebug) {
                Output.printError("{s}: readFile error -- {s}", .{ path, @errorName(err) });
            }
            return err;
        };

        return Entry{
            .contents = file.contents,
            .fd = if (FeatureFlags.store_file_descriptors) file_handle.handle else 0,
        };
    }

    pub fn readFile(
        c: *Fs,
        _fs: *fs.FileSystem,
        path: string,
        dirname_fd: StoredFileDescriptorType,
        comptime use_shared_buffer: bool,
        _file_handle: ?StoredFileDescriptorType,
    ) !Entry {
        var rfs = _fs.fs;

        var file_handle: std.fs.File = if (_file_handle) |__file| std.fs.File{ .handle = __file } else undefined;

        if (_file_handle == null) {
            if (FeatureFlags.store_file_descriptors and dirname_fd > 0) {
                file_handle = std.fs.Dir.openFile(std.fs.Dir{ .fd = dirname_fd }, std.fs.path.basename(path), .{ .read = true }) catch |err| brk: {
                    switch (err) {
                        error.FileNotFound => {
                            const handle = try std.fs.openFileAbsolute(path, .{ .read = true });
                            Output.prettyErrorln(
                                "<r><d>Internal error: directory mismatch for directory \"{s}\", fd {d}<r>. You don't need to do anything, but this indicates a bug.",
                                .{ path, dirname_fd },
                            );
                            break :brk handle;
                        },
                        else => return err,
                    }
                };
            } else {
                file_handle = try std.fs.openFileAbsolute(path, .{ .read = true });
            }
        }

        defer {
            if (rfs.needToCloseFiles() and _file_handle == null) {
                file_handle.close();
            }
        }

        const file = rfs.readFileWithHandle(path, null, file_handle, use_shared_buffer, &c.shared_buffer) catch |err| {
            if (Environment.isDebug) {
                Output.printError("{s}: readFile error -- {s}", .{ path, @errorName(err) });
            }
            return err;
        };

        return Entry{
            .contents = file.contents,
            .fd = if (FeatureFlags.store_file_descriptors) file_handle.handle else 0,
        };
    }
};

pub const Css = struct {
    pub const Entry = struct {};
    pub const Result = struct {
        ok: bool,
        value: void,
    };
    pub fn parse(_: *@This(), _: *logger.Log, _: logger.Source) !Result {
        Global.notimpl();
    }
};

pub const JavaScript = struct {
    pub const Result = js_ast.Result;

    pub fn init(_: std.mem.Allocator) JavaScript {
        return JavaScript{};
    }
    // For now, we're not going to cache JavaScript ASTs.
    // It's probably only relevant when bundling for production.
    pub fn parse(
        _: *const @This(),
        allocator: std.mem.Allocator,
        opts: js_parser.Parser.Options,
        defines: *Define,
        log: *logger.Log,
        source: *const logger.Source,
    ) anyerror!?js_ast.Ast {
        var temp_log = logger.Log.init(allocator);
        var parser = js_parser.Parser.init(opts, &temp_log, source, defines, allocator) catch {
            temp_log.appendToMaybeRecycled(log, source) catch {};
            return null;
        };

        const result = parser.parse() catch |err| {
            if (temp_log.errors == 0) {
                log.addRangeError(source, parser.lexer.range(), @errorName(err)) catch unreachable;
            }

            temp_log.appendToMaybeRecycled(log, source) catch {};
            return null;
        };

        temp_log.appendToMaybeRecycled(log, source) catch {};
        return if (result.ok) result.ast else null;
    }

    pub fn scan(
        _: *@This(),
        allocator: std.mem.Allocator,
        scan_pass_result: *js_parser.ScanPassResult,
        opts: js_parser.Parser.Options,
        defines: *Define,
        log: *logger.Log,
        source: *const logger.Source,
    ) anyerror!void {
        var temp_log = logger.Log.init(allocator);
        defer temp_log.appendToMaybeRecycled(log, source) catch {};

        var parser = js_parser.Parser.init(opts, &temp_log, source, defines, allocator) catch return;

        return try parser.scanImports(scan_pass_result);
    }
};

pub const Json = struct {
    pub fn init(_: std.mem.Allocator) Json {
        return Json{};
    }
    fn parse(_: *@This(), log: *logger.Log, source: logger.Source, allocator: std.mem.Allocator, comptime func: anytype) anyerror!?js_ast.Expr {
        var temp_log = logger.Log.init(allocator);
        defer {
            temp_log.appendToMaybeRecycled(log, &source) catch {};
        }
        return func(&source, &temp_log, allocator) catch handler: {
            break :handler null;
        };
    }
    pub fn parseJSON(cache: *@This(), log: *logger.Log, source: logger.Source, allocator: std.mem.Allocator) anyerror!?js_ast.Expr {
        return try parse(cache, log, source, allocator, json_parser.ParseJSON);
    }

    pub fn parseTSConfig(cache: *@This(), log: *logger.Log, source: logger.Source, allocator: std.mem.Allocator) anyerror!?js_ast.Expr {
        return try parse(cache, log, source, allocator, json_parser.ParseTSConfig);
    }
};
