const _global = @import("../../global.zig");
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

const Fs = @import("../../fs.zig");
const resolver = @import("../../resolver/resolver.zig");
const ast = @import("../../import_record.zig");
const NodeModuleBundle = @import("../../node_module_bundle.zig").NodeModuleBundle;
const logger = @import("../../logger.zig");
const Api = @import("../../api/schema.zig").Api;
const options = @import("../../options.zig");
const Bundler = @import("../../bundler.zig").ServeBundler;
const js_printer = @import("../../js_printer.zig");
const hash_map = @import("../../hash_map.zig");
const http = @import("../../http.zig");

pub const DefaultBunDefines = struct {
    pub const Keys = struct {
        const window = "window";
    };
    pub const Values = struct {
        const window = "undefined";
    };
};

pub fn configureTransformOptionsForBunVM(allocator: std.mem.Allocator, _args: Api.TransformOptions) !Api.TransformOptions {
    var args = _args;

    // args.serve = false;
    args.write = false;
    args.resolve = Api.ResolveMode.lazy;
    args.generate_node_module_bundle = false;
    return try configureTransformOptionsForBun(allocator, args);
}

pub fn configureTransformOptionsForBun(_: std.mem.Allocator, _args: Api.TransformOptions) !Api.TransformOptions {
    var args = _args;
    args.platform = Api.Platform.bun;
    return args;
}
