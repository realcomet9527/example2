const fs = @import("fs.zig");
const logger = @import("logger.zig");
const std = @import("std");
const Ref = @import("ast/base.zig").Ref;

pub const ImportKind = enum(u8) {

    // An entry point provided by the user
    entry_point,

    // An ES6 import or re-export statement
    stmt,

    // A call to "require()"
    require,

    // An "import()" expression with a string argument
    dynamic,

    /// A call to "require.resolve()"
    require_resolve,

    /// A CSS "@import" rule
    at,

    /// A CSS "@import" rule with import conditions
    at_conditional,

    /// A CSS "url(...)" token
    url,

    internal,

    pub inline fn isCommonJS(this: ImportKind) bool {
        return switch (this) {
            .require, .require_resolve => true,
            else => false,
        };
    }

    pub fn jsonStringify(self: @This(), options: anytype, writer: anytype) !void {
        return try std.json.stringify(@tagName(self), options, writer);
    }

    pub fn isFromCSS(k: ImportKind) bool {
        return k == .at_conditional or k == .at or k == .url;
    }
};

pub const ImportRecord = struct {
    range: logger.Range,
    path: fs.Path,

    /// 0 is invalid
    module_id: u32 = 0,

    source_index: Ref.Int = std.math.maxInt(Ref.Int),

    print_mode: PrintMode = .normal,

    /// True for the following cases:
    ///
    ///   try { require('x') } catch { handle }
    ///   try { await import('x') } catch { handle }
    ///   try { require.resolve('x') } catch { handle }
    ///   import('x').catch(handle)
    ///   import('x').then(_, handle)
    ///
    /// In these cases we shouldn't generate an error if the path could not be
    /// resolved.
    handles_import_errors: bool = false,

    is_internal: bool = false,

    /// This tells the printer that we should print as export var $moduleID = ...
    /// Instead of using the path.
    is_bundled: bool = false,

    /// Sometimes the parser creates an import record and decides it isn't needed.
    /// For example, TypeScript code may have import statements that later turn
    /// out to be type-only imports after analyzing the whole file.
    is_unused: bool = false,

    /// If this is true, the import contains syntax like "* as ns". This is used
    /// to determine whether modules that have no exports need to be wrapped in a
    /// CommonJS wrapper or not.
    contains_import_star: bool = false,

    /// If this is true, the import contains an import for the alias "default",
    /// either via the "import x from" or "import {default as x} from" syntax.
    contains_default_alias: bool = false,

    /// If true, this "export * from 'path'" statement is evaluated at run-time by
    /// calling the "__reExport()" helper function
    calls_run_time_re_export_fn: bool = false,

    /// Tell the printer to wrap this call to "require()" in "__toModule(...)"
    wrap_with_to_module: bool = false,

    /// True for require calls like this: "try { require() } catch {}". In this
    /// case we shouldn't generate an error if the path could not be resolved.
    is_inside_try_body: bool = false,

    /// If true, this was originally written as a bare "import 'file'" statement
    was_originally_bare_import: bool = false,

    was_originally_require: bool = false,

    /// If a macro used <import>, it will be tracked here.
    was_injected_by_macro: bool = false,

    kind: ImportKind,

    pub const PrintMode = enum {
        normal,
        import_path,
        css,
    };
};
