const std = @import("std");
const builtin = @import("builtin");
const _global = @import("../../../global.zig");
const strings = _global.strings;
const string = _global.string;
const AsyncIO = @import("io");
const JSC = @import("../../../jsc.zig");
const PathString = JSC.PathString;
const Environment = _global.Environment;
const C = _global.C;
const Syscall = @import("./syscall.zig");
const os = std.os;
const Buffer = JSC.MarkedArrayBuffer;
const IdentityContext = @import("../../../identity_context.zig").IdentityContext;
const logger = @import("../../../logger.zig");
const Shimmer = @import("../bindings/shimmer.zig").Shimmer;
const is_bindgen: bool = std.meta.globalOption("bindgen", bool) orelse false;
const meta = _global.meta;

/// Time in seconds. Not nanos!
pub const TimeLike = c_int;
pub const Mode = if (Environment.isLinux) u32 else std.os.mode_t;
const heap_allocator = _global.default_allocator;
pub fn DeclEnum(comptime T: type) type {
    const fieldInfos = std.meta.declarations(T);
    var enumFields: [fieldInfos.len]std.builtin.TypeInfo.EnumField = undefined;
    var decls = [_]std.builtin.TypeInfo.Declaration{};
    inline for (fieldInfos) |field, i| {
        enumFields[i] = .{
            .name = field.name,
            .value = i,
        };
    }
    return @Type(.{
        .Enum = .{
            .layout = .Auto,
            .tag_type = std.math.IntFittingRange(0, fieldInfos.len - 1),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}

pub const FileDescriptor = os.fd_t;
pub const Flavor = enum {
    sync,
    promise,
    callback,

    pub fn Wrap(comptime this: Flavor, comptime Type: type) type {
        return comptime brk: {
            switch (this) {
                .sync => break :brk Type,
                // .callback => {
                //     const Callback = CallbackTask(Type);
                // },
                else => @compileError("Not implemented yet"),
            }
        };
    }
};

/// Node.js expects the error to include contextual information
/// - "syscall"
/// - "path"
/// - "errno"
pub fn Maybe(comptime ResultType: type) type {
    return union(Tag) {
        pub const ReturnType = ResultType;

        err: Syscall.Error,
        result: ReturnType,

        pub const Tag = enum { err, result };

        pub const success: @This() = @This(){
            .result = std.mem.zeroes(ReturnType),
        };

        pub const todo: @This() = @This(){ .err = Syscall.Error.todo };

        pub inline fn getErrno(this: @This()) os.E {
            return switch (this) {
                .result => os.E.SUCCESS,
                .err => |err| @intToEnum(os.E, err.errno),
            };
        }

        pub inline fn errno(rc: anytype) ?@This() {
            return switch (Syscall.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| @This(){
                    // always truncate
                    .err = .{ .errno = @truncate(Syscall.Error.Int, @enumToInt(err)) },
                },
            };
        }

        pub inline fn errnoSys(rc: anytype, syscall: Syscall.Tag) ?@This() {
            return switch (Syscall.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| @This(){
                    // always truncate
                    .err = .{ .errno = @truncate(Syscall.Error.Int, @enumToInt(err)), .syscall = syscall },
                },
            };
        }

        pub inline fn errnoSysP(rc: anytype, syscall: Syscall.Tag, path: anytype) ?@This() {
            return switch (Syscall.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| @This(){
                    // always truncate
                    .err = .{ .errno = @truncate(Syscall.Error.Int, @enumToInt(err)), .syscall = syscall, .path = std.mem.span(path) },
                },
            };
        }
    };
}

pub const StringOrBuffer = union(Tag) {
    string: string,
    buffer: Buffer,

    pub const Tag = enum { string, buffer };

    pub fn slice(this: StringOrBuffer) []const u8 {
        return switch (this) {
            .string => this.string,
            .buffer => this.buffer.slice(),
        };
    }

    pub export fn external_string_finalizer(_: ?*anyopaque, _: JSC.C.JSStringRef, buffer: *anyopaque, byteLength: usize) void {
        _global.default_allocator.free(@ptrCast([*]const u8, buffer)[0..byteLength]);
    }

    pub fn toJS(this: StringOrBuffer, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.C.JSValueRef {
        return switch (this) {
            .string => {
                var external = JSC.C.JSStringCreateExternal(this.string.ptr, this.string.len, null, external_string_finalizer);
                return JSC.C.JSValueMakeString(ctx, external);
            },
            .buffer => this.buffer.toJSObjectRef(ctx, exception),
        };
    }

    pub fn fromJS(global: *JSC.JSGlobalObject, value: JSC.JSValue, exception: JSC.C.ExceptionRef) ?StringOrBuffer {
        return switch (value.jsType()) {
            JSC.JSValue.JSType.String, JSC.JSValue.JSType.StringObject, JSC.JSValue.JSType.DerivedStringObject, JSC.JSValue.JSType.Object => {
                var zig_str = JSC.ZigString.init("");
                value.toZigString(&zig_str, global);
                if (zig_str.len == 0) {
                    JSC.throwInvalidArguments("Expected string to have length > 0", .{}, global.ref(), exception);
                    return null;
                }

                return StringOrBuffer{
                    .string = zig_str.slice(),
                };
            },
            JSC.JSValue.JSType.ArrayBuffer => StringOrBuffer{
                .buffer = Buffer.fromArrayBuffer(global.ref(), value, exception),
            },
            JSC.JSValue.JSType.Uint8Array, JSC.JSValue.JSType.DataView => StringOrBuffer{
                .buffer = Buffer.fromArrayBuffer(global.ref(), value, exception),
            },
            else => null,
        };
    }
};
pub const ErrorCode = @import("./nodejs_error_code.zig").Code;

// We can't really use Zig's error handling for syscalls because Node.js expects the "real" errno to be returned
// and various issues with std.os that make it too unstable for arbitrary user input (e.g. how .BADF is marked as unreachable)

/// https://github.com/nodejs/node/blob/master/lib/buffer.js#L587
pub const Encoding = enum(u8) {
    utf8,
    ucs2,
    utf16le,
    latin1,
    ascii,
    base64,
    base64url,
    hex,

    /// Refer to the buffer's encoding
    buffer,

    const Eight = strings.ExactSizeMatcher(8);
    /// Caller must verify the value is a string
    pub fn fromStringValue(value: JSC.JSValue, global: *JSC.JSGlobalObject) ?Encoding {
        var str = JSC.ZigString.Empty;
        value.toZigString(&str, global);
        const slice = str.slice();
        return switch (slice.len) {
            0...2 => null,
            else => switch (Eight.matchLower(slice)) {
                Eight.case("utf-8"), Eight.case("utf8") => Encoding.utf8,
                Eight.case("ucs-2"), Eight.case("ucs2") => Encoding.ucs2,
                Eight.case("utf16-le"), Eight.case("utf16le") => Encoding.utf16le,
                Eight.case("latin1") => Encoding.latin1,
                Eight.case("ascii") => Encoding.ascii,
                Eight.case("base64") => Encoding.base64,
                Eight.case("hex") => Encoding.hex,
                Eight.case("buffer") => Encoding.buffer,
                else => null,
            },
            "base64url".len => brk: {
                if (strings.eqlCaseInsensitiveASCII(slice, "base64url", false)) {
                    break :brk Encoding.base64url;
                }
                break :brk null;
            },
        };
    }
};

const PathOrBuffer = union(Tag) {
    path: PathString,
    buffer: Buffer,

    pub const Tag = enum { path, buffer };

    pub inline fn slice(this: PathOrBuffer) []const u8 {
        return this.path.slice();
    }
};

pub fn CallbackTask(comptime Result: type) type {
    return struct {
        callback: JSC.C.JSObjectRef,
        option: Option,
        success: bool = false,
        completion: AsyncIO.Completion,

        pub const Option = union {
            err: JSC.SystemError,
            result: Result,
        };
    };
}

pub const PathLike = union(Tag) {
    string: PathString,
    buffer: Buffer,
    url: void,

    pub const Tag = enum { string, buffer, url };

    pub inline fn slice(this: PathLike) string {
        return switch (this) {
            .string => this.string.slice(),
            .buffer => this.buffer.slice(),
            else => unreachable, // TODO:
        };
    }

    pub fn sliceZWithForceCopy(this: PathLike, buf: *[std.fs.MAX_PATH_BYTES]u8, comptime force: bool) [:0]const u8 {
        var sliced = this.slice();

        if (sliced.len == 0) return "";

        if (comptime !force) {
            if (sliced[sliced.len - 1] == 0) {
                var sliced_ptr = sliced.ptr;
                return sliced_ptr[0 .. sliced.len - 1 :0];
            }
        }

        @memcpy(buf, sliced.ptr, sliced.len);
        buf[sliced.len] = 0;
        return buf[0..sliced.len :0];
    }

    pub inline fn sliceZ(this: PathLike, buf: *[std.fs.MAX_PATH_BYTES]u8) [:0]const u8 {
        return sliceZWithForceCopy(this, buf, false);
    }

    pub fn toJS(this: PathLike, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.C.JSValueRef {
        return switch (this) {
            .string => this.string.toJS(ctx, exception),
            .buffer => this.buffer.toJSObjectRef(ctx, exception),
            else => unreachable,
        };
    }

    pub fn fromJS(ctx: JSC.C.JSContextRef, arguments: *ArgumentsSlice, exception: JSC.C.ExceptionRef) ?PathLike {
        const arg = arguments.next() orelse return null;
        switch (arg.jsType()) {
            JSC.JSValue.JSType.Uint8Array,
            JSC.JSValue.JSType.DataView,
            => {
                const buffer = Buffer.fromTypedArray(ctx, arg, exception);
                if (exception.* != null) return null;
                if (!Valid.pathBuffer(buffer, ctx, exception)) return null;

                JSC.C.JSValueProtect(ctx, arg.asObjectRef());
                arguments.eat();
                return PathLike{ .buffer = buffer };
            },

            JSC.JSValue.JSType.ArrayBuffer => {
                const buffer = Buffer.fromArrayBuffer(ctx, arg, exception);
                if (exception.* != null) return null;
                if (!Valid.pathBuffer(buffer, ctx, exception)) return null;

                JSC.C.JSValueProtect(ctx, arg.asObjectRef());
                arguments.eat();

                return PathLike{ .buffer = buffer };
            },

            JSC.JSValue.JSType.String,
            JSC.JSValue.JSType.StringObject,
            JSC.JSValue.JSType.DerivedStringObject,
            => {
                var zig_str = JSC.ZigString.init("");
                arg.toZigString(&zig_str, ctx.ptr());

                if (!Valid.pathString(zig_str, ctx, exception)) return null;

                JSC.C.JSValueProtect(ctx, arg.asObjectRef());
                arguments.eat();

                if (zig_str.is16Bit()) {
                    var printed = std.mem.span(std.fmt.allocPrintZ(arguments.arena.allocator(), "{}", .{zig_str}) catch unreachable);
                    return PathLike{ .string = PathString.init(printed.ptr[0 .. printed.len + 1]) };
                }

                return PathLike{ .string = PathString.init(zig_str.slice()) };
            },
            else => return null,
        }
    }
};

pub const Valid = struct {
    pub fn fileDescriptor(fd: FileDescriptor, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        if (fd < 0) {
            JSC.throwInvalidArguments("Invalid file descriptor, must not be negative number", .{}, ctx, exception);
            return false;
        }

        return true;
    }

    pub fn pathString(zig_str: JSC.ZigString, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        switch (zig_str.len) {
            0 => {
                JSC.throwInvalidArguments("Invalid path string: can't be empty", .{}, ctx, exception);
                return false;
            },
            1...std.fs.MAX_PATH_BYTES => return true,
            else => {
                // TODO: should this be an EINVAL?
                JSC.throwInvalidArguments(
                    comptime std.fmt.comptimePrint("Invalid path string: path is too long (max: {d})", .{std.fs.MAX_PATH_BYTES}),
                    .{},
                    ctx,
                    exception,
                );
                return false;
            },
        }

        unreachable;
    }

    pub fn pathBuffer(buffer: Buffer, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) bool {
        const slice = buffer.slice();
        switch (slice.len) {
            0 => {
                JSC.throwInvalidArguments("Invalid path buffer: can't be empty", .{}, ctx, exception);
                return false;
            },

            else => {

                // TODO: should this be an EINVAL?
                JSC.throwInvalidArguments(
                    comptime std.fmt.comptimePrint("Invalid path buffer: path is too long (max: {d})", .{std.fs.MAX_PATH_BYTES}),
                    .{},
                    ctx,
                    exception,
                );
                return false;
            },
            1...std.fs.MAX_PATH_BYTES => return true,
        }

        unreachable;
    }
};

pub const ArgumentsSlice = struct {
    remaining: []const JSC.JSValue,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(_global.default_allocator),
    all: []const JSC.JSValue,

    pub fn init(arguments: []const JSC.JSValue) ArgumentsSlice {
        return ArgumentsSlice{
            .remaining = arguments,
            .all = arguments,
        };
    }

    pub inline fn len(this: *const ArgumentsSlice) u16 {
        return @truncate(u16, this.remaining.len);
    }
    pub fn eat(this: *ArgumentsSlice) void {
        if (this.remaining.len == 0) {
            return;
        }

        this.remaining = this.remaining[1..];
    }

    pub fn next(this: *ArgumentsSlice) ?JSC.JSValue {
        if (this.remaining.len == 0) {
            return null;
        }

        return this.remaining[0];
    }
};

pub fn fileDescriptorFromJS(ctx: JSC.C.JSContextRef, value: JSC.JSValue, exception: JSC.C.ExceptionRef) ?FileDescriptor {
    if (!value.isNumber() or value.isBigInt()) return null;
    const fd = value.toInt32();
    if (!Valid.fileDescriptor(fd, ctx, exception)) {
        return null;
    }

    return @truncate(FileDescriptor, fd);
}

var _get_time_prop_string: ?JSC.C.JSStringRef = null;
pub fn timeLikeFromJS(ctx: JSC.C.JSContextRef, value_: JSC.JSValue, exception: JSC.C.ExceptionRef) ?TimeLike {
    var value = value_;
    if (JSC.C.JSValueIsDate(ctx, value.asObjectRef())) {
        // TODO: make this faster
        var get_time_prop = _get_time_prop_string orelse brk: {
            var str = JSC.C.JSStringCreateStatic("getTime", "getTime".len);
            _get_time_prop_string = str;
            break :brk str;
        };

        var getTimeFunction = JSC.C.JSObjectGetProperty(ctx, value.asObjectRef(), get_time_prop, exception);
        if (exception.* != null) return null;
        value = JSC.JSValue.fromRef(JSC.C.JSObjectCallAsFunction(ctx, getTimeFunction, value.asObjectRef(), 0, null, exception) orelse return null);
        if (exception.* != null) return null;
    }

    const seconds = value.asNumber();
    if (!std.math.isFinite(seconds)) {
        return null;
    }

    return @floatToInt(TimeLike, @maximum(@floor(seconds), std.math.minInt(TimeLike)));
}

pub fn modeFromJS(ctx: JSC.C.JSContextRef, value: JSC.JSValue, exception: JSC.C.ExceptionRef) ?Mode {
    const mode_int = if (value.isNumber())
        @truncate(Mode, value.to(Mode))
    else brk: {
        if (value.isUndefinedOrNull()) return null;

        //        An easier method of constructing the mode is to use a sequence of
        //        three octal digits (e.g. 765). The left-most digit (7 in the example),
        //        specifies the permissions for the file owner. The middle digit (6 in
        //        the example), specifies permissions for the group. The right-most
        //        digit (5 in the example), specifies the permissions for others.

        var zig_str = JSC.ZigString.init("");
        value.toZigString(&zig_str, ctx.ptr());
        var slice = zig_str.slice();
        if (strings.hasPrefix(slice, "0o")) {
            slice = slice[2..];
        }

        break :brk std.fmt.parseInt(Mode, slice, 8) catch {
            JSC.throwInvalidArguments("Invalid mode string: must be an octal number", .{}, ctx, exception);
            return null;
        };
    };

    if (mode_int < 0 or mode_int > 0o777) {
        JSC.throwInvalidArguments("Invalid mode: must be an octal number", .{}, ctx, exception);
        return null;
    }

    return mode_int;
}

pub const PathOrFileDescriptor = union(Tag) {
    path: PathLike,
    fd: FileDescriptor,

    pub const Tag = enum { fd, path };

    pub fn copyToStream(this: PathOrFileDescriptor, flags: FileSystemFlags, auto_close: bool, mode: Mode, allocator: std.mem.Allocator, stream: *Stream) !void {
        switch (this) {
            .fd => |fd| {
                stream.content = Stream.Content{
                    .file = .{
                        .fd = fd,
                        .flags = flags,
                        .mode = mode,
                    },
                };
                stream.content_type = .file;
            },
            .path => |path| {
                stream.content = Stream.Content{
                    .file_path = .{
                        .path = PathString.init(std.mem.span(try allocator.dupeZ(u8, path.slice()))),
                        .auto_close = auto_close,
                        .file = .{
                            .fd = std.math.maxInt(FileDescriptor),
                            .flags = flags,
                            .mode = mode,
                        },
                        .opened = false,
                    },
                };
                stream.content_type = .file_path;
            },
        }
    }

    pub fn fromJS(ctx: JSC.C.JSContextRef, arguments: *ArgumentsSlice, exception: JSC.C.ExceptionRef) ?PathOrFileDescriptor {
        const first = arguments.next() orelse return null;

        if (fileDescriptorFromJS(ctx, first, exception)) |fd| {
            arguments.eat();
            return PathOrFileDescriptor{ .fd = fd };
        }

        if (exception.* != null) return null;

        return PathOrFileDescriptor{ .path = PathLike.fromJS(ctx, arguments, exception) orelse return null };
    }

    pub fn toJS(this: PathOrFileDescriptor, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.C.JSValueRef {
        return switch (this) {
            .path => this.path.toJS(ctx, exception),
            .fd => JSC.JSValue.jsNumberFromInt32(@intCast(i32, this.fd)).asRef(),
        };
    }
};

pub const FileSystemFlags = enum(Mode) {
    /// Open file for appending. The file is created if it does not exist.
    @"a" = std.os.O.APPEND,
    /// Like 'a' but fails if the path exists.
    // @"ax" = std.os.O.APPEND | std.os.O.EXCL,
    /// Open file for reading and appending. The file is created if it does not exist.
    // @"a+" = std.os.O.APPEND | std.os.O.RDWR,
    /// Like 'a+' but fails if the path exists.
    // @"ax+" = std.os.O.APPEND | std.os.O.RDWR | std.os.O.EXCL,
    /// Open file for appending in synchronous mode. The file is created if it does not exist.
    // @"as" = std.os.O.APPEND,
    /// Open file for reading and appending in synchronous mode. The file is created if it does not exist.
    // @"as+" = std.os.O.APPEND | std.os.O.RDWR,
    /// Open file for reading. An exception occurs if the file does not exist.
    @"r" = std.os.O.RDONLY,
    /// Open file for reading and writing. An exception occurs if the file does not exist.
    // @"r+" = std.os.O.RDWR,
    /// Open file for reading and writing in synchronous mode. Instructs the operating system to bypass the local file system cache.
    /// This is primarily useful for opening files on NFS mounts as it allows skipping the potentially stale local cache. It has a very real impact on I/O performance so using this flag is not recommended unless it is needed.
    /// This doesn't turn fs.open() or fsPromises.open() into a synchronous blocking call. If synchronous operation is desired, something like fs.openSync() should be used.
    // @"rs+" = std.os.O.RDWR,
    /// Open file for writing. The file is created (if it does not exist) or truncated (if it exists).
    @"w" = std.os.O.WRONLY | std.os.O.CREAT,
    /// Like 'w' but fails if the path exists.
    // @"wx" = std.os.O.WRONLY | std.os.O.TRUNC,
    // ///  Open file for reading and writing. The file is created (if it does not exist) or truncated (if it exists).
    // @"w+" = std.os.O.RDWR | std.os.O.CREAT,
    // ///  Like 'w+' but fails if the path exists.
    // @"wx+" = std.os.O.RDWR | std.os.O.EXCL,

    _,

    const O_RDONLY: Mode = std.os.O.RDONLY;
    const O_RDWR: Mode = std.os.O.RDWR;
    const O_APPEND: Mode = std.os.O.APPEND;
    const O_CREAT: Mode = std.os.O.CREAT;
    const O_WRONLY: Mode = std.os.O.WRONLY;
    const O_EXCL: Mode = std.os.O.EXCL;
    const O_SYNC: Mode = 0;
    const O_TRUNC: Mode = std.os.O.TRUNC;

    pub fn fromJS(ctx: JSC.C.JSContextRef, val: JSC.JSValue, exception: JSC.C.ExceptionRef) ?FileSystemFlags {
        if (val.isUndefinedOrNull()) {
            return @intToEnum(FileSystemFlags, O_RDONLY);
        }

        if (val.isNumber()) {
            const number = val.toInt32();
            if (!(number > 0o000 and number < 0o777)) {
                JSC.throwInvalidArguments(
                    "Invalid integer mode: must be a number between 0o000 and 0o777",
                    .{},
                    ctx,
                    exception,
                );
                return null;
            }
            return @intToEnum(FileSystemFlags, number);
        }

        const jsType = val.jsType();
        if (jsType.isStringLike()) {
            var zig_str = JSC.ZigString.init("");
            val.toZigString(&zig_str, ctx.ptr());

            var buf: [4]u8 = .{ 0, 0, 0, 0 };
            @memcpy(&buf, zig_str.ptr, @minimum(buf.len, zig_str.len));
            const Matcher = strings.ExactSizeMatcher(4);

            // https://github.com/nodejs/node/blob/8c3637cd35cca352794e2c128f3bc5e6b6c41380/lib/internal/fs/utils.js#L565
            const flags = switch (Matcher.match(buf[0..4])) {
                Matcher.case("r") => O_RDONLY,
                Matcher.case("rs"), Matcher.case("sr") => O_RDONLY | O_SYNC,
                Matcher.case("r+") => O_RDWR,
                Matcher.case("rs+"), Matcher.case("sr+") => O_RDWR | O_SYNC,

                Matcher.case("w") => O_TRUNC | O_CREAT | O_WRONLY,
                Matcher.case("wx"), Matcher.case("xw") => O_TRUNC | O_CREAT | O_WRONLY | O_EXCL,

                Matcher.case("w+") => O_TRUNC | O_CREAT | O_RDWR,
                Matcher.case("wx+"), Matcher.case("xw+") => O_TRUNC | O_CREAT | O_RDWR | O_EXCL,

                Matcher.case("a") => O_APPEND | O_CREAT | O_WRONLY,
                Matcher.case("ax"), Matcher.case("xa") => O_APPEND | O_CREAT | O_WRONLY | O_EXCL,
                Matcher.case("as"), Matcher.case("sa") => O_APPEND | O_CREAT | O_WRONLY | O_SYNC,

                Matcher.case("a+") => O_APPEND | O_CREAT | O_RDWR,
                Matcher.case("ax+"), Matcher.case("xa+") => O_APPEND | O_CREAT | O_RDWR | O_EXCL,
                Matcher.case("as+"), Matcher.case("sa+") => O_APPEND | O_CREAT | O_RDWR | O_SYNC,

                Matcher.case("") => {
                    JSC.throwInvalidArguments(
                        "Invalid flag: string can't be empty",
                        .{},
                        ctx,
                        exception,
                    );
                    return null;
                },
                else => {
                    JSC.throwInvalidArguments(
                        "Invalid flag. Learn more at https://nodejs.org/api/fs.html#fs_file_system_flags",
                        .{},
                        ctx,
                        exception,
                    );
                    return null;
                },
            };

            return @intToEnum(FileSystemFlags, flags);
        }

        return null;
    }
};

/// Milliseconds precision 
pub const Date = enum(u64) {
    _,

    pub fn toJS(this: Date, ctx: JSC.C.JSContextRef, exception: JSC.C.ExceptionRef) JSC.C.JSValueRef {
        const seconds = @floatCast(f64, @intToFloat(f128, @enumToInt(this)) * 1000.0);
        const unix_timestamp = JSC.C.JSValueMakeNumber(ctx, seconds);
        const array: [1]JSC.C.JSValueRef = .{unix_timestamp};
        const obj = JSC.C.JSObjectMakeDate(ctx, 1, &array, exception);
        return obj;
    }
};

fn StatsLike(comptime name: string, comptime T: type) type {
    return struct {
        const This = @This();

        pub const Class = JSC.NewClass(
            This,
            .{ .name = name },
            .{},
            .{
                .dev = .{
                    .get = JSC.To.JS.Getter(This, .dev),
                    .name = "dev",
                },
                .ino = .{
                    .get = JSC.To.JS.Getter(This, .ino),
                    .name = "ino",
                },
                .mode = .{
                    .get = JSC.To.JS.Getter(This, .mode),
                    .name = "mode",
                },
                .nlink = .{
                    .get = JSC.To.JS.Getter(This, .nlink),
                    .name = "nlink",
                },
                .uid = .{
                    .get = JSC.To.JS.Getter(This, .uid),
                    .name = "uid",
                },
                .gid = .{
                    .get = JSC.To.JS.Getter(This, .gid),
                    .name = "gid",
                },
                .rdev = .{
                    .get = JSC.To.JS.Getter(This, .rdev),
                    .name = "rdev",
                },
                .size = .{
                    .get = JSC.To.JS.Getter(This, .size),
                    .name = "size",
                },
                .blksize = .{
                    .get = JSC.To.JS.Getter(This, .blksize),
                    .name = "blksize",
                },
                .blocks = .{
                    .get = JSC.To.JS.Getter(This, .blocks),
                    .name = "blocks",
                },
                .atime = .{
                    .get = JSC.To.JS.Getter(This, .atime),
                    .name = "atime",
                },
                .mtime = .{
                    .get = JSC.To.JS.Getter(This, .mtime),
                    .name = "mtime",
                },
                .ctime = .{
                    .get = JSC.To.JS.Getter(This, .ctime),
                    .name = "ctime",
                },
                .birthtime = .{
                    .get = JSC.To.JS.Getter(This, .birthtime),
                    .name = "birthtime",
                },
                .atime_ms = .{
                    .get = JSC.To.JS.Getter(This, .atime_ms),
                    .name = "atimeMs",
                },
                .mtime_ms = .{
                    .get = JSC.To.JS.Getter(This, .mtime_ms),
                    .name = "mtimeMs",
                },
                .ctime_ms = .{
                    .get = JSC.To.JS.Getter(This, .ctime_ms),
                    .name = "ctimeMs",
                },
                .birthtime_ms = .{
                    .get = JSC.To.JS.Getter(This, .birthtime_ms),
                    .name = "birthtimeMs",
                },
            },
        );

        dev: T,
        ino: T,
        mode: T,
        nlink: T,
        uid: T,
        gid: T,
        rdev: T,
        size: T,
        blksize: T,
        blocks: T,
        atime_ms: T,
        mtime_ms: T,
        ctime_ms: T,
        birthtime_ms: T,
        atime: Date,
        mtime: Date,
        ctime: Date,
        birthtime: Date,

        pub fn init(stat_: os.Stat) @This() {
            const atime = stat_.atime();
            const mtime = stat_.mtime();
            const ctime = stat_.ctime();
            return @This(){
                .dev = @truncate(T, @intCast(i64, stat_.dev)),
                .ino = @truncate(T, @intCast(i64, stat_.ino)),
                .mode = @truncate(T, @intCast(i64, stat_.mode)),
                .nlink = @truncate(T, @intCast(i64, stat_.nlink)),
                .uid = @truncate(T, @intCast(i64, stat_.uid)),
                .gid = @truncate(T, @intCast(i64, stat_.gid)),
                .rdev = @truncate(T, @intCast(i64, stat_.rdev)),
                .size = @truncate(T, @intCast(i64, stat_.size)),
                .blksize = @truncate(T, @intCast(i64, stat_.blksize)),
                .blocks = @truncate(T, @intCast(i64, stat_.blocks)),
                .atime_ms = @truncate(T, @intCast(i64, if (atime.tv_nsec > 0) (@intCast(usize, atime.tv_nsec) / std.time.ns_per_ms) else 0)),
                .mtime_ms = @truncate(T, @intCast(i64, if (mtime.tv_nsec > 0) (@intCast(usize, mtime.tv_nsec) / std.time.ns_per_ms) else 0)),
                .ctime_ms = @truncate(T, @intCast(i64, if (ctime.tv_nsec > 0) (@intCast(usize, ctime.tv_nsec) / std.time.ns_per_ms) else 0)),
                .atime = @intToEnum(Date, @intCast(u64, @maximum(atime.tv_sec, 0))),
                .mtime = @intToEnum(Date, @intCast(u64, @maximum(mtime.tv_sec, 0))),
                .ctime = @intToEnum(Date, @intCast(u64, @maximum(ctime.tv_sec, 0))),

                // Linux doesn't include this info in stat
                // maybe it does in statx, but do you really need birthtime? If you do please file an issue.
                .birthtime_ms = if (Environment.isLinux)
                    0
                else
                    @truncate(T, @intCast(i64, if (stat_.birthtimensec > 0) (@intCast(usize, stat_.birthtimensec) / std.time.ns_per_ms) else 0)),

                .birthtime = if (Environment.isLinux)
                    @intToEnum(Date, 0)
                else
                    @intToEnum(Date, @intCast(u64, @maximum(stat_.birthtimesec, 0))),
            };
        }

        pub fn toJS(this: Stats, ctx: JSC.C.JSContextRef, _: JSC.C.ExceptionRef) JSC.C.JSValueRef {
            var _this = _global.default_allocator.create(Stats) catch unreachable;
            _this.* = this;
            return Class.make(ctx, _this);
        }

        pub fn finalize(this: *Stats) void {
            _global.default_allocator.destroy(this);
        }
    };
}

pub const Stats = StatsLike("Stats", i32);
pub const BigIntStats = StatsLike("BigIntStats", i64);

/// A class representing a directory stream.
///
/// Created by {@link opendir}, {@link opendirSync}, or `fsPromises.opendir()`.
///
/// ```js
/// import { opendir } from 'fs/promises';
///
/// try {
///   const dir = await opendir('./');
///   for await (const dirent of dir)
///     console.log(dirent.name);
/// } catch (err) {
///   console.error(err);
/// }
/// ```
///
/// When using the async iterator, the `fs.Dir` object will be automatically
/// closed after the iterator exits.
/// @since v12.12.0
pub const DirEnt = struct {
    name: PathString,
    // not publicly exposed
    kind: Kind,

    pub const Kind = std.fs.File.Kind;

    pub fn isBlockDevice(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.BlockDevice);
    }
    pub fn isCharacterDevice(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.CharacterDevice);
    }
    pub fn isDirectory(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.Directory);
    }
    pub fn isFIFO(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.NamedPipe or this.kind == std.fs.File.Kind.EventPort);
    }
    pub fn isFile(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.File);
    }
    pub fn isSocket(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.UnixDomainSocket);
    }
    pub fn isSymbolicLink(
        this: *DirEnt,
        ctx: JSC.C.JSContextRef,
        _: JSC.C.JSObjectRef,
        _: JSC.C.JSObjectRef,
        _: []const JSC.C.JSValueRef,
        _: JSC.C.ExceptionRef,
    ) JSC.C.JSValueRef {
        return JSC.C.JSValueMakeBoolean(ctx, this.kind == std.fs.File.Kind.SymLink);
    }

    pub const Class = JSC.NewClass(DirEnt, .{ .name = "DirEnt" }, .{
        .isBlockDevice = .{
            .name = "isBlockDevice",
            .rfn = isBlockDevice,
        },
        .isCharacterDevice = .{
            .name = "isCharacterDevice",
            .rfn = isCharacterDevice,
        },
        .isDirectory = .{
            .name = "isDirectory",
            .rfn = isDirectory,
        },
        .isFIFO = .{
            .name = "isFIFO",
            .rfn = isFIFO,
        },
        .isFile = .{
            .name = "isFile",
            .rfn = isFile,
        },
        .isSocket = .{
            .name = "isSocket",
            .rfn = isSocket,
        },
        .isSymbolicLink = .{
            .name = "isSymbolicLink",
            .rfn = isSymbolicLink,
        },
    }, .{
        .name = .{
            .get = JSC.To.JS.Getter(DirEnt, .name),
            .name = "name",
        },
    });

    pub fn finalize(this: *DirEnt) void {
        _global.default_allocator.free(this.name.slice());
        _global.default_allocator.destroy(this);
    }
};

pub const Emitter = struct {
    pub const Listener = struct {
        once: bool = false,
        callback: JSC.JSValue,

        pub const List = struct {
            pub const ArrayList = std.MultiArrayList(Listener);
            list: ArrayList = ArrayList{},
            once_count: u32 = 0,

            pub fn append(this: *List, allocator: std.mem.Allocator, ctx: JSC.C.JSContextRef, listener: Listener) !void {
                JSC.C.JSValueProtect(ctx, listener.callback.asObjectRef());
                try this.list.append(allocator, listener);
                this.once_count +|= @as(u32, @boolToInt(listener.once));
            }

            pub fn prepend(this: *List, allocator: std.mem.Allocator, ctx: JSC.C.JSContextRef, listener: Listener) !void {
                JSC.C.JSValueProtect(ctx, listener.callback.asObjectRef());
                try this.list.ensureUnusedCapacity(allocator, 1);
                this.list.insertAssumeCapacity(0, listener);
                this.once_count +|= @as(u32, @boolToInt(listener.once));
            }

            // removeListener() will remove, at most, one instance of a listener from the
            // listener array. If any single listener has been added multiple times to the
            // listener array for the specified eventName, then removeListener() must be
            // called multiple times to remove each instance.
            pub fn remove(this: *List, ctx: JSC.C.JSContextRef, callback: JSC.JSValue) bool {
                const callbacks = this.list.items(.callback);

                for (callbacks) |item, i| {
                    if (callback.eqlValue(item)) {
                        JSC.C.JSValueUnprotect(ctx, callback.asObjectRef());
                        this.once_count -|= @as(u32, @boolToInt(this.list.items(.once)[i]));
                        this.list.orderedRemove(i);
                        return true;
                    }
                }

                return false;
            }

            pub fn emit(this: *List, globalThis: *JSC.JSGlobalObject, value: JSC.JSValue) void {
                var i: usize = 0;
                outer: while (true) {
                    var slice = this.list.slice();
                    var callbacks = slice.items(.callback);
                    var once = slice.items(.once);
                    while (i < callbacks.len) : (i += 1) {
                        const callback = callbacks[i];

                        globalThis.enqueueMicrotask1(
                            callback,
                            value,
                        );

                        if (once[i]) {
                            this.once_count -= 1;
                            JSC.C.JSValueUnprotect(globalThis.ref(), callback.asObjectRef());
                            this.list.orderedRemove(i);
                            slice = this.list.slice();
                            callbacks = slice.items(.callback);
                            once = slice.items(.once);
                            continue :outer;
                        }
                    }

                    return;
                }
            }
        };
    };

    pub fn New(comptime EventType: type) type {
        return struct {
            const EventEmitter = @This();
            pub const Map = std.enums.EnumArray(EventType, Listener.List);
            listeners: Map = Map.initFill(Listener.List{}),

            pub fn addListener(this: *EventEmitter, ctx: JSC.C.JSContextRef, event: EventType, listener: Emitter.Listener) !void {
                try this.listeners.getPtr(event).append(_global.default_allocator, ctx, listener);
            }

            pub fn prependListener(this: *EventEmitter, ctx: JSC.C.JSContextRef, event: EventType, listener: Emitter.Listener) !void {
                try this.listeners.getPtr(event).prepend(_global.default_allocator, ctx, listener);
            }

            pub fn emit(this: *EventEmitter, event: EventType, globalThis: *JSC.JSGlobalObject, value: JSC.JSValue) void {
                this.listeners.getPtr(event).emit(globalThis, value);
            }

            pub fn removeListener(this: *EventEmitter, ctx: JSC.C.JSContextRef, event: EventType, callback: JSC.JSValue) bool {
                return this.listeners.getPtr(event).remove(ctx, callback);
            }
        };
    }
};

// pub fn Untag(comptime Union: type) type {
//     const info: std.builtin.TypeInfo.Union = @typeInfo(Union);
//     const tag = info.tag_type orelse @compileError("Must be tagged");
//     return struct {
//         pub const Tag = tag;
//         pub const Union =
//     };
// }

pub const Stream = struct {
    sink_type: Sink.Type,
    sink: Sink,
    content: Content,
    content_type: Content.Type,
    allocator: std.mem.Allocator,

    pub fn open(this: *Stream) ?JSC.Node.Syscall.Error {
        switch (Syscall.open(this.content.file_path.path.sliceAssumeZ(), @enumToInt(this.content.file_path.file.flags))) {
            .err => |err| {
                return err.withPath(this.content.file_path.path.slice());
            },
            .result => |fd| {
                this.content.file_path.file.fd = fd;
                this.content.file_path.opened = true;
                this.emit(.open);
                return null;
            },
        }
    }

    pub fn getFd(this: *Stream) FileDescriptor {
        return switch (this.content_type) {
            .file => this.content.file.fd,
            .file_path => if (comptime Environment.allow_assert) brk: {
                std.debug.assert(this.content.file_path.opened);
                break :brk this.content.file_path.file.fd;
            } else this.content.file_path.file.fd,
            else => unreachable,
        };
    }

    pub fn close(this: *Stream) ?JSC.Node.Syscall.Error {
        const fd = this.getFd();

        // Don't ever close stdin, stdout, or stderr
        // we are assuming that these are always 0 1 2, which is not strictly true in some cases
        if (fd <= 2) {
            return null;
        }

        if (Syscall.close(fd)) |err| {
            return err;
        }

        switch (this.content_type) {
            .file_path => {
                this.content.file_path.opened = false;
                this.content.file_path.file.fd = std.math.maxInt(FileDescriptor);
            },
            .file => {
                this.content.file.fd = std.math.maxInt(FileDescriptor);
            },
            else => {},
        }

        this.emit(.Close);
    }

    const CommonEvent = enum { Error, Open, Close };
    pub fn emit(this: *Stream, comptime event: CommonEvent) void {
        switch (this.sink_type) {
            .readable => {
                switch (comptime event) {
                    .Open => this.sink.readable.emit(.Open),
                    .Close => this.sink.readable.emit(.Close),
                    else => unreachable,
                }
            },
            .writable => {
                switch (comptime event) {
                    .Open => this.sink.writable.emit(.Open),
                    .Close => this.sink.writable.emit(.Close),
                    else => unreachable,
                }
            },
        }
    }

    // This allocates a new stream object
    pub fn toJS(this: *Stream, ctx: JSC.C.JSContextRef, _: JSC.C.ExceptionRef) JSC.C.JSValueRef {
        switch (this.sink_type) {
            .readable => {
                var readable = &this.sink.readable.state;
                return readable.create(
                    ctx.ptr(),
                ).asObjectRef();
            },
            .writable => {
                var writable = &this.sink.writable.state;
                return writable.create(
                    ctx.ptr(),
                ).asObjectRef();
            },
        }
    }

    pub fn deinit(this: *Stream) void {
        this.allocator.destroy(this);
    }

    pub const Sink = union {
        readable: Readable,
        writable: Writable,

        pub const Type = enum(u8) {
            readable,
            writable,
        };
    };

    pub const Consumed = u52;

    const Response = struct {
        bytes: [8]u8 = std.mem.zeroes([8]u8),
    };

    const Error = union(Type) {
        Syscall: Syscall.Error,
        JavaScript: JSC.JSValue,
        Internal: anyerror,

        pub const Type = enum {
            Syscall,
            JavaScript,
            Internal,
        };
    };

    pub const Content = union {
        file: File,
        file_path: FilePath,
        socket: Socket,
        buffer: *Buffer,
        stream: *Stream,
        javascript: JSC.JSValue,

        pub fn getFile(this: *Content, content_type: Content.Type) *File {
            return switch (content_type) {
                .file => &this.file,
                .file_path => &this.file_path.file,
                else => unreachable,
            };
        }

        pub const File = struct {
            fd: FileDescriptor,
            flags: FileSystemFlags,
            mode: Mode,
            size: Consumed = std.math.maxInt(Consumed),

            // pub fn read(this: *File, comptime chunk_type: Content.Type, chunk: Source.Type.of(chunk_type)) Response {}

            pub inline fn setPermissions(this: File) meta.ReturnOf(Syscall.fchmod) {
                return Syscall.fchmod(this.fd, this.mode);
            }
        };

        pub const FilePath = struct {
            path: PathString,
            auto_close: bool = false,
            file: File = File{ .fd = std.math.maxInt(FileDescriptor), .mode = 0o666, .flags = FileSystemFlags.@"r" },
            opened: bool = false,

            // pub fn read(this: *File, comptime chunk_type: Content.Type, chunk: Source.Type.of(chunk_type)) Response {}
        };

        pub const Socket = struct {
            fd: FileDescriptor,
            flags: FileSystemFlags,

            // pub fn write(this: *File, comptime chunk_type: Source.Type, chunk: Source.Type.of(chunk_type)) Response {}
            // pub fn read(this: *File, comptime chunk_type: Source.Type, chunk: Source.Type.of(chunk_type)) Response {}
        };

        pub const Type = enum(u8) {
            file,
            file_path,
            socket,
            buffer,
            stream,
            javascript,
        };
    };
};

pub const Writable = struct {
    state: State = State{},
    emitter: EventEmitter = EventEmitter{},

    connection: ?*Stream = null,
    globalObject: ?*JSC.JSGlobalObject = null,

    // workaround https://github.com/ziglang/zig/issues/6611
    stream: *Stream = undefined,
    pipeline: Pipeline = Pipeline{},
    started: bool = false,

    pub const Chunk = struct {
        data: StringOrBuffer,
        encoding: Encoding = Encoding.utf8,
    };

    pub const Pipe = struct {
        source: *Stream,
        destination: *Stream,
        chunk: ?*Chunk = null,
        // Might be the end of the stream
        // or it might just be another stream
        next: ?*Pipe = null,

        pub fn start(this: *Pipe, pipeline: *Pipeline, chunk: ?*Chunk) void {
            this.run(pipeline, chunk, null);
        }

        var disable_clonefile = false;

        fn runCloneFileWithFallback(pipeline: *Pipeline, source: *Stream.Content, destination: *Stream.Content) void {
            switch (Syscall.clonefile(source.path.sliceAssumeZ(), destination.path.sliceAssumeZ())) {
                .result => return,
                .err => |err| {
                    switch (err.getErrno()) {
                        // these are retryable
                        .ENOTSUP, .EXDEV, .EXIST, .EIO, .ENOTDIR => |call| {
                            if (call == .ENOTSUP) {
                                disable_clonefile = true;
                            }

                            return runCopyfile(
                                false,
                                pipeline,
                                source,
                                .file_path,
                                destination,
                                .file_path,
                            );
                        },
                        else => {
                            pipeline.err = err;
                            return;
                        },
                    }
                },
            }
        }

        fn runCopyfile(
            must_open_files: bool,
            pipeline: *Pipeline,
            source: *Stream.Content,
            source_type: Stream.Content.Type,
            destination: *Stream.Content,
            destination_type: Stream.Content.Type,
            is_end: bool,
        ) void {
            do_the_work: {
                // fallback-only
                if (destination_type == .file_path and source_type == .file_path and !destination.file_path.opened and !must_open_files) {
                    switch (Syscall.copyfile(source.path.sliceAssumeZ(), destination.path.sliceAssumeZ(), 0)) {
                        .err => |err| {
                            pipeline.err = err;

                            return;
                        },
                        .result => break :do_the_work,
                    }
                }

                defer {
                    if (source_type == .file_path and source.file_path.auto_close and source.file_path.opened) {
                        if (source.stream.close()) |err| {
                            if (pipeline.err == null) {
                                pipeline.err = err;
                            }
                        }
                    }

                    if (is_end and destination_type == .file_path and destination.file_path.auto_close and destination.file_path.opened) {
                        if (destination.stream.close()) |err| {
                            if (pipeline.err == null) {
                                pipeline.err = err;
                            }
                        }
                    }
                }

                if (source_type == .file_path and !source.file_path.opened) {
                    if (source.stream.open()) |err| {
                        pipeline.err = err;
                        return;
                    }
                }

                const source_fd = if (source_type == .file_path)
                    source.file_path.file.fd
                else
                    source.file.fd;

                if (destination == .file_path and !destination.file_path.opened) {
                    if (destination.stream.open()) |err| {
                        pipeline.err = err;
                        return;
                    }
                }

                const dest_fd = if (destination_type == .file_path)
                    destination.file_path.file.fd
                else
                    destination.file.fd;

                switch (Syscall.fcopyfile(source_fd, dest_fd, 0)) {
                    .err => |err| {
                        pipeline.err = err;
                        return;
                    },
                    .result => break :do_the_work,
                }
            }

            switch (destination.getFile(destination_type).setPermissions()) {
                .err => |err| {
                    destination.stream.emitError(err);
                    pipeline.err = err;
                    return;
                },
                .result => return,
            }
        }

        pub fn run(this: *Pipe, pipeline: *Pipeline) void {
            var source = this.source;
            var destination = this.destination;
            const source_content_type = source.content_type;
            const destination_content_type = destination.content_type;

            if (pipeline.err != null) return;

            switch (FastPath.get(
                source_content_type,
                destination_content_type,
                pipeline.head == this,
                pipeline.tail == this,
            )) {
                .clonefile => {
                    if (comptime !Environment.isMac) unreachable;
                    if (destination.content.file_path.opened) {
                        runCopyfile(
                            // Can we skip sending a .open event?
                            (!source.content.file_path.auto_close and !source.content.file_path.opened) or (!destination.content.file_path.auto_close and !destination.content.file_path.opened),
                            pipeline,
                            &source.content,
                            .file_path,
                            &destination.content,
                            .file_path,
                            this.next == null,
                        );
                    } else {
                        runCloneFileWithFallback(pipeline, source.content.file_path, destination.content.file_path);
                    }
                },
                .copyfile => {
                    if (comptime !Environment.isMac) unreachable;
                    runCopyfile(
                        // Can we skip sending a .open event?
                        (!source.content.file_path.auto_close and !source.content.file_path.opened) or (!destination.content.file_path.auto_close and !destination.content.file_path.opened),
                        pipeline,
                        &source.content,
                        source_content_type,
                        &destination.content,
                        destination_content_type,
                        this.next == null,
                    );
                },
                else => {},
            }
        }

        pub const FastPath = enum {
            none,
            clonefile,
            sendfile,
            copyfile,
            copy_file_range,

            pub fn get(source: Stream.Content.Type, destination: Stream.Content.Type, is_head: bool, is_tail: bool) FastPath {
                _ = is_tail;
                if (comptime Environment.isMac) {
                    if (is_head) {
                        if (source == .file_path and destination == .file_path and !disable_clonefile)
                            return .clonefile;

                        if ((source == .file or source == .file_path) and (destination == .file or destination == .file_path)) {
                            return .copyfile;
                        }
                    }
                }

                return FastPath.none;
            }
        };
    };

    pub const Pipeline = struct {
        head: ?*Pipe = null,
        tail: ?*Pipe = null,

        // Preallocate a single pipe so that
        preallocated_tail_pipe: Pipe = undefined,

        /// Does the data exit at any point to JavaScript?
        closed_loop: bool = true,

        // If there is a pending error, this is the error
        err: ?Syscall.Error = null,

        pub const StartTask = struct {
            writable: *Writable,
            pub fn run(this: *StartTask) void {
                var writable = this.writable;
                var head = writable.pipeline.head orelse return;
                if (writable.started) {
                    return;
                }
                writable.started = true;

                head.start(&writable.pipeline, null);
            }
        };
    };

    pub fn appendReadable(this: *Writable, readable: *Stream) void {
        if (comptime Environment.allow_assert) {
            std.debug.assert(readable.sink_type == .readable);
        }

        if (this.pipeline.tail == null) {
            this.pipeline.head = &this.pipeline.preallocated_tail_pipe;
            this.pipeline.head.?.* = Pipe{
                .destination = this.stream,
                .source = readable,
            };
            this.pipeline.tail = this.pipeline.head;
            return;
        }

        var pipe = readable.allocator.create(Pipe) catch unreachable;
        pipe.* = Pipe{
            .source = readable,
            .destination = this.stream,
        };
        this.pipeline.tail.?.next = pipe;
        this.pipeline.tail = pipe;
    }

    pub const EventEmitter = Emitter.New(Events);

    pub fn emit(this: *Writable, event: Events, value: JSC.JSValue) void {
        if (this.shouldSkipEvent(event)) return;

        this.emitter.emit(event, this.globalObject.?, value);
    }

    pub inline fn shouldEmitEvent(this: *const Writable, event: Events) bool {
        return switch (event) {
            .Close => this.state.emit_close and this.emitter.listeners.get(.Close).list.len > 0,
            .Drain => this.emitter.listeners.get(.Drain).list.len > 0,
            .Error => this.emitter.listeners.get(.Error).list.len > 0,
            .Finish => this.emitter.listeners.get(.Finish).list.len > 0,
            .Pipe => this.emitter.listeners.get(.Pipe).list.len > 0,
            .Unpipe => this.emitter.listeners.get(.Unpipe).list.len > 0,
            .Open => this.emitter.listeners.get(.Open).list.len > 0,
        };
    }

    pub const State = extern struct {
        highwater_mark: u32 = 256_000,
        encoding: Encoding = Encoding.utf8,
        start: i32 = 0,
        destroyed: bool = false,
        ended: bool = false,
        corked: bool = false,
        finished: bool = false,
        emit_close: bool = true,

        pub fn deinit(state: *State) callconv(.C) void {
            if (comptime is_bindgen) return;

            var stream = state.getStream();
            stream.deinit();
        }

        pub fn create(state: *State, globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
            return shim.cppFn("create", .{ state, globalObject });
        }

        // i know.
        pub inline fn getStream(state: *State) *Stream {
            return getWritable(state).stream;
        }

        pub inline fn getWritable(state: *State) *Writable {
            return @fieldParentPtr(Writable, "state", state);
        }

        pub fn addEventListener(state: *State, global: *JSC.JSGlobalObject, event: Events, callback: JSC.JSValue, is_once: bool) callconv(.C) void {
            if (comptime is_bindgen) return;
            var writable = state.getWritable();
            writable.emitter.addListener(global.ref(), event, .{
                .once = is_once,
                .callback = callback,
            }) catch unreachable;
        }

        pub fn removeEventListener(state: *State, global: *JSC.JSGlobalObject, event: Events, callback: JSC.JSValue) callconv(.C) bool {
            if (comptime is_bindgen) return true;
            var writable = state.getWritable();
            return writable.emitter.removeListener(global.ref(), event, callback);
        }

        pub fn prependEventListener(state: *State, global: *JSC.JSGlobalObject, event: Events, callback: JSC.JSValue, is_once: bool) callconv(.C) void {
            if (comptime is_bindgen) return;
            var writable = state.getWritable();
            writable.emitter.prependListener(global.ref(), event, .{
                .once = is_once,
                .callback = callback,
            }) catch unreachable;
        }

        pub fn write(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }
        pub fn end(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }
        pub fn close(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }
        pub fn destroy(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }
        pub fn cork(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }
        pub fn uncork(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }

        pub const Flowing = enum(u8) {
            pending,
            yes,
            paused,
        };

        pub const shim = Shimmer("Bun", "Writable", @This());
        pub const name = "Bun__Writable";
        pub const include = "BunStream.h";
        pub const namespace = shim.namespace;

        pub const Export = shim.exportFunctions(.{
            .@"deinit" = deinit,
            .@"addEventListener" = addEventListener,
            .@"removeEventListener" = removeEventListener,
            .@"prependEventListener" = prependEventListener,
            .@"write" = write,
            .@"end" = end,
            .@"close" = close,
            .@"destroy" = destroy,
            .@"cork" = cork,
            .@"uncork" = uncork,
        });

        pub const Extern = [_][]const u8{"create"};

        comptime {
            if (!is_bindgen) {
                @export(deinit, .{ .name = Export[0].symbol_name });
                @export(addEventListener, .{ .name = Export[1].symbol_name });
                @export(removeEventListener, .{ .name = Export[2].symbol_name });
                @export(prependEventListener, .{ .name = Export[3].symbol_name });
                @export(write, .{ .name = Export[4].symbol_name });
                @export(end, .{ .name = Export[5].symbol_name });
                @export(close, .{ .name = Export[6].symbol_name });
                @export(destroy, .{ .name = Export[7].symbol_name });
                @export(cork, .{ .name = Export[8].symbol_name });
                @export(uncork, .{ .name = Export[9].symbol_name });
            }
        }
    };

    pub const Events = enum(u8) {
        Close,
        Drain,
        Error,
        Finish,
        Pipe,
        Unpipe,
        Open,

        pub const name = "WritableEvent";
    };
};

pub const Readable = struct {
    state: State = State{},
    emitter: EventEmitter = EventEmitter{},
    stream: *Stream = undefined,
    destination: ?*Writable = null,
    globalObject: ?*JSC.JSGlobalObject = null,

    pub const EventEmitter = Emitter.New(Events);

    pub fn emit(this: *Readable, event: Events, comptime ValueType: type, value: JSC.JSValue) void {
        _ = ValueType;
        if (this.shouldEmitEvent(event)) return;

        this.emitter.emit(event, this.globalObject.?, value);
    }

    pub fn shouldEmitEvent(this: *Readable, event: Events) bool {
        return switch (event) {
            .Close => this.state.emit_close and this.emitter.listeners.get(.Close).list.len > 0,
            .Data => this.emitter.listeners.get(.Data).list.len > 0,
            .End => this.state.emit_end and this.emitter.listeners.get(.End).list.len > 0,
            .Error => this.emitter.listeners.get(.Error).list.len > 0,
            .Pause => this.emitter.listeners.get(.Pause).list.len > 0,
            .Readable => this.emitter.listeners.get(.Readable).list.len > 0,
            .Resume => this.emitter.listeners.get(.Resume).list.len > 0,
            .Open => this.emitter.listeners.get(.Open).list.len > 0,
        };
    }

    pub const Events = enum(u8) {
        Close,
        Data,
        End,
        Error,
        Pause,
        Readable,
        Resume,
        Open,

        pub const name = "ReadableEvent";
    };

    // This struct is exposed to JavaScript
    pub const State = extern struct {
        highwater_mark: u32 = 256_000,
        encoding: Encoding = Encoding.utf8,

        start: i32 = 0,
        end: i32 = std.math.maxInt(i32),

        readable: bool = false,
        aborted: bool = false,
        did_read: bool = false,
        ended: bool = false,
        flowing: Flowing = Flowing.pending,

        emit_close: bool = true,
        emit_end: bool = true,

        // i know.
        pub inline fn getStream(state: *State) *Stream {
            return getReadable(state).stream;
        }

        pub inline fn getReadable(state: *State) *Readable {
            return @fieldParentPtr(Readable, "state", state);
        }

        pub const Flowing = enum(u8) {
            pending,
            yes,
            paused,
        };

        pub const shim = Shimmer("Bun", "Readable", @This());
        pub const name = "Bun__Readable";
        pub const include = "BunStream.h";
        pub const namespace = shim.namespace;

        pub fn create(
            state: *State,
            globalObject: *JSC.JSGlobalObject,
        ) callconv(.C) JSC.JSValue {
            return shim.cppFn("create", .{ state, globalObject });
        }

        pub fn deinit(state: *State) callconv(.C) void {
            if (comptime is_bindgen) return;
            var stream = state.getStream();
            stream.deinit();
        }

        pub fn addEventListener(state: *State, global: *JSC.JSGlobalObject, event: Events, callback: JSC.JSValue, is_once: bool) callconv(.C) void {
            if (comptime is_bindgen) return;
            var readable = state.getReadable();

            readable.emitter.addListener(global.ref(), event, .{
                .once = is_once,
                .callback = callback,
            }) catch unreachable;
        }

        pub fn removeEventListener(state: *State, global: *JSC.JSGlobalObject, event: Events, callback: JSC.JSValue) callconv(.C) bool {
            if (comptime is_bindgen) return true;
            var readable = state.getReadable();
            return readable.emitter.removeListener(global.ref(), event, callback);
        }

        pub fn prependEventListener(state: *State, global: *JSC.JSGlobalObject, event: Events, callback: JSC.JSValue, is_once: bool) callconv(.C) void {
            if (comptime is_bindgen) return;
            var readable = state.getReadable();
            readable.emitter.prependListener(global.ref(), event, .{
                .once = is_once,
                .callback = callback,
            }) catch unreachable;
        }

        pub fn pipe(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            if (len < 1) {
                return JSC.toInvalidArguments("Writable is required", .{}, global.ref());
            }
            const args: []const JSC.JSValue = args_ptr[0..len];
            var writable_state: *Writable.State = args[0].getWritableStreamState(global.vm()) orelse {
                return JSC.toInvalidArguments("Expected Writable but didn't receive it", .{}, global.ref());
            };
            writable_state.getWritable().appendReadable(state.getStream());
            return JSC.JSValue.jsUndefined();
        }

        pub fn unpipe(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }

        pub fn unshift(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }

        pub fn read(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }

        pub fn pause(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }

        pub fn @"resume"(state: *State, global: *JSC.JSGlobalObject, args_ptr: [*]const JSC.JSValue, len: u16) callconv(.C) JSC.JSValue {
            if (comptime is_bindgen) return JSC.JSValue.jsUndefined();
            _ = state;
            _ = global;
            _ = args_ptr;
            _ = len;

            return JSC.JSValue.jsUndefined();
        }

        pub const Export = shim.exportFunctions(.{
            .@"deinit" = deinit,
            .@"addEventListener" = addEventListener,
            .@"removeEventListener" = removeEventListener,
            .@"prependEventListener" = prependEventListener,
            .@"pipe" = pipe,
            .@"unpipe" = unpipe,
            .@"unshift" = unshift,
            .@"read" = read,
            .@"pause" = pause,
            .@"resume" = State.@"resume",
        });

        pub const Extern = [_][]const u8{"create"};

        comptime {
            if (!is_bindgen) {
                @export(deinit, .{
                    .name = Export[0].symbol_name,
                });
                @export(addEventListener, .{
                    .name = Export[1].symbol_name,
                });
                @export(removeEventListener, .{
                    .name = Export[2].symbol_name,
                });
                @export(prependEventListener, .{
                    .name = Export[3].symbol_name,
                });
                @export(
                    pipe,
                    .{ .name = Export[4].symbol_name },
                );
                @export(
                    unpipe,
                    .{ .name = Export[5].symbol_name },
                );
                @export(
                    unshift,
                    .{ .name = Export[6].symbol_name },
                );
                @export(
                    read,
                    .{ .name = Export[7].symbol_name },
                );
                @export(
                    pause,
                    .{ .name = Export[8].symbol_name },
                );
                @export(
                    State.@"resume",
                    .{ .name = Export[9].symbol_name },
                );
            }
        }
    };
};

pub const Process = struct {
    pub fn getArgv(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        if (JSC.VirtualMachine.vm.argv.len == 0)
            return JSC.JSValue.createStringArray(globalObject, null, 0, false);

        // Allocate up to 32 strings in stack
        var stack_fallback_allocator = std.heap.stackFallback(
            32 * @sizeOf(JSC.ZigString),
            heap_allocator,
        );
        var allocator = stack_fallback_allocator.get();

        // If it was launched with bun run or bun test, skip it
        var skip: usize = 0;
        if (JSC.VirtualMachine.vm.argv.len > 1 and (strings.eqlComptime(JSC.VirtualMachine.vm.argv[0], "run") or strings.eqlComptime(JSC.VirtualMachine.vm.argv[0], "test"))) {
            skip += 1;
        }
        const count = JSC.VirtualMachine.vm.argv.len + 1;
        var args = allocator.alloc(
            JSC.ZigString,
            count - skip,
        ) catch unreachable;
        defer allocator.free(args);

        // https://github.com/yargs/yargs/blob/adb0d11e02c613af3d9427b3028cc192703a3869/lib/utils/process-argv.ts#L1
        args[0] = JSC.ZigString.init(std.mem.span(std.os.argv[0]));

        if (JSC.VirtualMachine.vm.argv.len > skip) {
            for (JSC.VirtualMachine.vm.argv[skip..]) |arg, i| {
                args[i + 1] = JSC.ZigString.init(arg);
                args[i + 1].detectEncoding();
            }
        }

        return JSC.JSValue.createStringArray(globalObject, args.ptr, args.len, true);
    }

    pub fn getCwd(globalObject: *JSC.JSGlobalObject) callconv(.C) JSC.JSValue {
        var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        switch (Syscall.getcwd(&buffer)) {
            .err => |err| {
                return err.toJSC(globalObject);
            },
            .result => |result| {
                var zig_str = JSC.ZigString.init(result);
                zig_str.detectEncoding();

                const value = zig_str.toValueGC(globalObject);

                return value;
            },
        }
    }
    pub fn setCwd(globalObject: *JSC.JSGlobalObject, to: *JSC.ZigString) callconv(.C) JSC.JSValue {
        if (to.len == 0) {
            return JSC.toInvalidArguments("path is required", .{}, globalObject.ref());
        }

        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const slice = to.sliceZBuf(&buf) catch {
            return JSC.toInvalidArguments("Invalid path", .{}, globalObject.ref());
        };
        const result = Syscall.chdir(slice);

        switch (result) {
            .err => |err| {
                return err.toJSC(globalObject);
            },
            .result => {
                // When we update the cwd from JS, we have to update the bundler's version as well
                // However, this might be called many times in a row, so we use a pre-allocated buffer
                // that way we don't have to worry about garbage collector
                var trimmed = std.mem.trimRight(u8, buf[0..slice.len], std.fs.path.sep_str);
                buf[trimmed.len] = std.fs.path.sep;
                const with_trailing_slash = buf[0 .. trimmed.len + 1];
                std.mem.copy(u8, &JSC.VirtualMachine.vm.bundler.fs.top_level_dir_buf, with_trailing_slash);
                JSC.VirtualMachine.vm.bundler.fs.top_level_dir = JSC.VirtualMachine.vm.bundler.fs.top_level_dir_buf[0..with_trailing_slash.len];
                return JSC.JSValue.jsUndefined();
            },
        }
    }

    pub export const Bun__version: [:0]const u8 = "v" ++ _global.Global.package_json_version;
    pub export const Bun__versions_mimalloc: [:0]const u8 = _global.Global.versions.mimalloc;
    pub export const Bun__versions_webkit: [:0]const u8 = _global.Global.versions.webkit;
    pub export const Bun__versions_libarchive: [:0]const u8 = _global.Global.versions.libarchive;
    pub export const Bun__versions_picohttpparser: [:0]const u8 = _global.Global.versions.picohttpparser;
    pub export const Bun__versions_boringssl: [:0]const u8 = _global.Global.versions.boringssl;
    pub export const Bun__versions_zlib: [:0]const u8 = _global.Global.versions.zlib;
    pub export const Bun__versions_zig: [:0]const u8 = _global.Global.versions.zig;
};

comptime {
    std.testing.refAllDecls(Process);
    std.testing.refAllDecls(Stream);
    std.testing.refAllDecls(Readable);
    std.testing.refAllDecls(Writable);
    std.testing.refAllDecls(Writable.State);
    std.testing.refAllDecls(Readable.State);
}
