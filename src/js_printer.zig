const std = @import("std");
const logger = @import("logger.zig");
const js_lexer = @import("js_lexer.zig");
const importRecord = @import("import_record.zig");
const js_ast = @import("js_ast.zig");
const options = @import("options.zig");
const rename = @import("renamer.zig");
const runtime = @import("runtime.zig");
const Lock = @import("./lock.zig").Lock;
const Api = @import("./api/schema.zig").Api;
const fs = @import("fs.zig");
const _global = @import("global.zig");
const string = _global.string;
const Output = _global.Output;
const Global = _global.Global;
const Environment = _global.Environment;
const strings = _global.strings;
const MutableString = _global.MutableString;
const stringZ = _global.stringZ;
const default_allocator = _global.default_allocator;
const C = _global.C;
const Ref = @import("ast/base.zig").Ref;
const StoredFileDescriptorType = _global.StoredFileDescriptorType;
const FeatureFlags = _global.FeatureFlags;
const FileDescriptorType = _global.FileDescriptorType;

const expect = std.testing.expect;
const ImportKind = importRecord.ImportKind;
const BindingNodeIndex = js_ast.BindingNodeIndex;

const LocRef = js_ast.LocRef;
const S = js_ast.S;
const B = js_ast.B;
const G = js_ast.G;
const T = js_lexer.T;
const E = js_ast.E;
const Stmt = js_ast.Stmt;
const Expr = js_ast.Expr;
const Binding = js_ast.Binding;
const Symbol = js_ast.Symbol;
const Level = js_ast.Op.Level;
const Op = js_ast.Op;
const Scope = js_ast.Scope;
const locModuleScope = logger.Loc.Empty;
const Ast = js_ast.Ast;

const hex_chars = "0123456789ABCDEF";
const first_ascii = 0x20;
const last_ascii = 0x7E;
const first_high_surrogate = 0xD800;
const last_high_surrogate = 0xDBFF;
const first_low_surrogate = 0xDC00;
const last_low_surrogate = 0xDFFF;
const CodepointIterator = @import("./string_immutable.zig").UnsignedCodepointIterator;
const assert = std.debug.assert;

threadlocal var imported_module_ids_list: std.ArrayList(u32) = undefined;
threadlocal var imported_module_ids_list_unset: bool = true;
const ImportRecord = importRecord.ImportRecord;

fn notimpl() void {
    Global.panic("Not implemented yet!", .{});
}

fn formatUnsignedIntegerBetween(comptime len: u16, buf: *[len]u8, val: u64) void {
    comptime var i: u16 = len;
    var remainder = val;
    // Write out the number from the end to the front

    inline while (i > 0) {
        comptime i -= 1;
        buf[comptime i] = @intCast(u8, (remainder % 10)) + '0';
        remainder /= 10;
    }
}

pub fn writeModuleId(comptime Writer: type, writer: Writer, module_id: u32) void {
    std.debug.assert(module_id != 0); // either module_id is forgotten or it should be disabled
    _ = writer.writeAll("$") catch unreachable;
    std.fmt.formatInt(module_id, 16, .lower, .{}, writer) catch unreachable;
}

pub const SourceMapChunk = struct {
    buffer: MutableString,
    end_state: State = State{},
    final_generated_column: usize = 0,
    should_ignore: bool = false,

    // Coordinates in source maps are stored using relative offsets for size
    // reasons. When joining together chunks of a source map that were emitted
    // in parallel for different parts of a file, we need to fix up the first
    // segment of each chunk to be relative to the end of the previous chunk.
    pub const State = struct {
        // This isn't stored in the source map. It's only used by the bundler to join
        // source map chunks together correctly.
        generated_line: i32 = 0,

        // These are stored in the source map in VLQ format.
        generated_column: i32 = 0,
        source_index: i32 = 0,
        original_line: i32 = 0,
        original_column: i32 = 0,
    };
};

pub const Options = struct {
    transform_imports: bool = true,
    to_module_ref: Ref = Ref.None,
    require_ref: ?Ref = null,
    indent: usize = 0,
    externals: []u32 = &[_]u32{},
    runtime_imports: runtime.Runtime.Imports = runtime.Runtime.Imports{},
    module_hash: u32 = 0,
    source_path: ?fs.Path = null,
    bundle_export_ref: ?Ref = null,
    rewrite_require_resolve: bool = true,

    css_import_behavior: Api.CssInJsBehavior = Api.CssInJsBehavior.facade,

    // TODO: remove this
    // The reason for this is:
    // 1. You're bundling a React component
    // 2. jsx auto imports are prepended to the list of parts
    // 3. The AST modification for bundling only applies to the final part
    // 4. This means that it will try to add a toplevel part which is not wrapped in the arrow function, which is an error
    //     TypeError: $30851277 is not a function. (In '$30851277()', '$30851277' is undefined)
    //        at (anonymous) (0/node_modules.server.e1b5ffcd183e9551.jsb:1463:21)
    //        at #init_react/jsx-dev-runtime.js (0/node_modules.server.e1b5ffcd183e9551.jsb:1309:8)
    //        at (esm) (0/node_modules.server.e1b5ffcd183e9551.jsb:1480:30)

    // The temporary fix here is to tag a stmts ptr as the one we want to prepend to
    // Then, when we're JUST about to print it, we print the body of prepend_part_value first
    prepend_part_key: ?*anyopaque = null,
    prepend_part_value: ?*js_ast.Part = null,

    // If we're writing out a source map, this table of line start indices lets
    // us do binary search on to figure out what line a given AST node came from
    // line_offset_tables: []LineOffsetTable

    pub fn unindent(self: *Options) void {
        self.indent = std.math.max(self.indent, 1) - 1;
    }
};

pub const PrintResult = struct { js: string, source_map: ?SourceMapChunk = null };

// Zig represents booleans in packed structs as 1 bit, with no padding
// This is effectively a bit field
const ExprFlag = packed struct {
    forbid_call: bool = false,
    forbid_in: bool = false,
    has_non_optional_chain_parent: bool = false,
    expr_result_is_unused: bool = false,

    pub fn None() ExprFlag {
        return ExprFlag{};
    }

    pub fn ForbidCall() ExprFlag {
        return ExprFlag{ .forbid_call = true };
    }

    pub fn ForbidAnd() ExprFlag {
        return ExprFlag{ .forbid_and = true };
    }

    pub fn HasNonOptionalChainParent() ExprFlag {
        return ExprFlag{ .has_non_optional_chain_parent = true };
    }

    pub fn ExprResultIsUnused() ExprFlag {
        return ExprFlag{ .expr_result_is_unused = true };
    }
};

const ImportVariant = enum {
    path_only,
    import_star,
    import_default,
    import_star_and_import_default,
    import_items,
    import_items_and_default,
    import_items_and_star,
    import_items_and_default_and_star,

    pub inline fn hasItems(import_variant: @This()) @This() {
        return switch (import_variant) {
            .import_default => .import_items_and_default,
            .import_star => .import_items_and_star,
            .import_star_and_import_default => .import_items_and_default_and_star,
            else => .import_items,
        };
    }

    // We always check star first so don't need to be exhaustive here
    pub inline fn hasStar(import_variant: @This()) @This() {
        return switch (import_variant) {
            .path_only => .import_star,
            else => import_variant,
        };
    }

    // We check default after star
    pub inline fn hasDefault(import_variant: @This()) @This() {
        return switch (import_variant) {
            .path_only => .import_default,
            .import_star => .import_star_and_import_default,
            else => import_variant,
        };
    }

    pub fn determine(record: *const importRecord.ImportRecord, _: *const Symbol, s_import: *const S.Import) ImportVariant {
        var variant = ImportVariant.path_only;

        if (record.contains_import_star) {
            variant = variant.hasStar();
        }

        if (!record.was_originally_bare_import) {
            if (!record.contains_default_alias) {
                if (s_import.default_name) |default_name| {
                    if (default_name.ref != null) {
                        variant = variant.hasDefault();
                    }
                }
            } else {
                variant = variant.hasDefault();
            }
        }

        if (s_import.items.len > 0) {
            variant = variant.hasItems();
        }

        return variant;
    }
};

pub fn NewPrinter(
    comptime ascii_only: bool,
    comptime Writer: type,
    comptime Linker: type,
    comptime rewrite_esm_to_cjs: bool,
    comptime bun: bool,
    comptime is_inside_bundle: bool,
    comptime is_json: bool,
) type {
    return struct {
        symbols: Symbol.Map,
        import_records: []importRecord.ImportRecord,
        linker: ?*Linker,

        needs_semicolon: bool = false,
        stmt_start: i32 = -1,
        options: Options,
        export_default_start: i32 = -1,
        arrow_expr_start: i32 = -1,
        for_of_init_start: i32 = -1,
        prev_op: Op.Code = Op.Code.bin_add,
        prev_op_end: i32 = -1,
        prev_num_end: i32 = -1,
        prev_reg_exp_end: i32 = -1,
        call_target: ?Expr.Data = null,
        writer: Writer,

        has_printed_bundled_import_statement: bool = false,
        imported_module_ids: std.ArrayList(u32),

        renamer: rename.Renamer,
        prev_stmt_tag: Stmt.Tag = .s_empty,

        const Printer = @This();

        pub fn writeAll(p: *Printer, bytes: anytype) anyerror!void {
            p.print(bytes);
            return;
        }

        pub fn writeByteNTimes(self: *Printer, byte: u8, n: usize) !void {
            var bytes: [256]u8 = undefined;
            std.mem.set(u8, bytes[0..], byte);

            var remaining: usize = n;
            while (remaining > 0) {
                const to_write = std.math.min(remaining, bytes.len);
                try self.writeAll(bytes[0..to_write]);
                remaining -= to_write;
            }
        }

        fn fmt(p: *Printer, comptime str: string, args: anytype) !void {
            const len = @call(
                .{
                    .modifier = .always_inline,
                },
                std.fmt.count,
                .{ str, args },
            );
            var ptr = try p.writer.reserveNext(
                len,
            );

            const written = @call(
                .{
                    .modifier = .always_inline,
                },
                std.fmt.bufPrint,
                .{ ptr[0..len], str, args },
            ) catch unreachable;

            p.writer.advance(written.len);
        }

        pub fn print(p: *Printer, str: anytype) void {
            switch (@TypeOf(str)) {
                comptime_int, u16, u8 => {
                    p.writer.print(@TypeOf(str), str);
                },
                [6]u8 => {
                    const span = std.mem.span(&str);
                    p.writer.print(@TypeOf(span), span);
                },
                else => {
                    p.writer.print(@TypeOf(str), str);
                },
            }
        }

        pub inline fn unsafePrint(p: *Printer, str: string) void {
            p.print(str);
        }

        pub fn printIndent(p: *Printer) void {
            if (p.options.indent == 0) {
                return;
            }

            // p.js.growBy(p.options.indent * "  ".len) catch unreachable;
            var i: usize = 0;

            while (i < p.options.indent) : (i += 1) {
                p.unsafePrint("  ");
            }
        }

        pub inline fn printSpace(p: *Printer) void {
            p.print(" ");
        }
        pub inline fn printNewline(p: *Printer) void {
            p.print("\n");
        }
        pub inline fn printSemicolonAfterStatement(p: *Printer) void {
            p.print(";\n");
        }
        pub fn printSemicolonIfNeeded(p: *Printer) void {
            if (p.needs_semicolon) {
                p.print(";");
                p.needs_semicolon = false;
            }
        }

        //
        fn printBunJestImportStatement(p: *Printer, import: S.Import) void {
            p.print("const ");

            if (import.star_name_loc != null) {
                p.printSymbol(import.namespace_ref);
                p.printSpace();
                p.print("=");
                p.printSpaceBeforeIdentifier();
                p.print("Bun.jest(import.meta.path)");
                p.printSemicolonAfterStatement();
                p.printIndent();
                p.print("const ");
            }

            if (import.items.len > 0) {
                p.print("{ ");
                if (!import.is_single_line) {
                    p.print("\n");
                    p.options.indent += 1;
                    p.printIndent();
                }

                for (import.items) |item, i| {
                    if (i > 0) {
                        p.print(",");
                        p.printSpace();

                        if (!import.is_single_line) {
                            p.print("\n");
                            p.printIndent();
                        }
                    }

                    const name = p.renamer.nameForSymbol(item.name.ref.?);
                    p.printIdentifier(name);

                    if (!strings.eql(name, item.alias)) {
                        p.print(" : ");
                        p.printSpace();
                        p.printClauseAlias(item.alias);
                    }
                }

                if (!import.is_single_line) {
                    p.print("\n");
                    p.options.indent -= 1;
                } else {
                    p.printSpace();
                }

                if (import.star_name_loc == null) {
                    p.print("} = Bun.jest(import.meta.path)");
                } else {
                    p.print("} =");
                    p.printSpaceBeforeIdentifier();
                    p.printSymbol(import.namespace_ref);
                }

                p.printSemicolonAfterStatement();
            }
        }

        pub inline fn printSpaceBeforeIdentifier(
            p: *Printer,
        ) void {
            if (p.writer.written > 0 and (js_lexer.isIdentifierContinue(@as(i32, p.writer.prevChar())) or p.writer.written == p.prev_reg_exp_end)) {
                p.print(" ");
            }
        }

        pub inline fn maybePrintSpace(
            p: *Printer,
        ) void {
            switch (p.writer.prevChar()) {
                0, ' ', '\n' => {},
                else => {
                    p.print(" ");
                },
            }
        }
        pub fn printDotThenPrefix(p: *Printer) Level {
            p.print(".then(() => ");
            return .comma;
        }

        pub inline fn printUndefined(p: *Printer, _: Level) void {
            // void 0 is more efficient in output size
            // however, "void 0" is the same as "undefined" is a point of confusion for many
            // since we are optimizing for development, undefined is more clear.
            // an ideal development bundler would output very readable code, even without source maps.
            p.print("undefined");
        }

        pub fn printBody(p: *Printer, stmt: Stmt) void {
            switch (stmt.data) {
                .s_block => |block| {
                    p.printSpace();
                    p.printBlock(stmt.loc, block.stmts);
                    p.printNewline();
                },
                else => {
                    p.printNewline();
                    p.options.indent += 1;
                    p.printStmt(stmt) catch unreachable;
                    p.options.unindent();
                },
            }
        }

        pub fn printBlockBody(p: *Printer, stmts: []Stmt) void {
            for (stmts) |stmt| {
                p.printSemicolonIfNeeded();
                p.printStmt(stmt) catch unreachable;
            }
        }

        pub fn printBlock(p: *Printer, loc: logger.Loc, stmts: []Stmt) void {
            p.addSourceMapping(loc);
            p.print("{");
            p.printNewline();

            p.options.indent += 1;
            p.printBlockBody(stmts);
            p.options.unindent();
            p.needs_semicolon = false;

            p.printIndent();
            p.print("}");
        }

        pub fn printTwoBlocksInOne(p: *Printer, loc: logger.Loc, stmts: []Stmt, prepend: []Stmt) void {
            p.addSourceMapping(loc);
            p.print("{");
            p.printNewline();

            p.options.indent += 1;
            p.printBlockBody(prepend);
            p.printBlockBody(stmts);
            p.options.unindent();
            p.needs_semicolon = false;

            p.printIndent();
            p.print("}");
        }

        pub fn printDecls(p: *Printer, comptime keyword: string, decls: []G.Decl, _: ExprFlag) void {
            p.print(keyword);
            p.printSpace();

            for (decls) |*decl, i| {
                if (i != 0) {
                    p.print(",");
                    p.printSpace();
                }

                p.printBinding(decl.binding);

                if (decl.value) |value| {
                    p.printSpace();
                    p.print("=");
                    p.printSpace();
                    p.printExpr(value, .comma, ExprFlag.None());
                }
            }
        }

        // noop for now
        pub fn addSourceMapping(_: *Printer, _: logger.Loc) void {}

        pub fn printSymbol(p: *Printer, ref: Ref) void {
            const name = p.renamer.nameForSymbol(ref);

            p.printIdentifier(name);
        }
        pub fn printClauseAlias(p: *Printer, alias: string) void {
            if (p.canPrintIdentifier(alias)) {
                p.printSpaceBeforeIdentifier();
                p.printIdentifier(alias);
            } else {
                p.printQuotedUTF8(alias, false);
            }
        }

        pub fn printFnArgs(
            p: *Printer,
            args: []G.Arg,
            has_rest_arg: bool,
            // is_arrow can be used for minifying later
            _: bool,
        ) void {
            const wrap = true;

            if (wrap) {
                p.print("(");
            }

            for (args) |arg, i| {
                if (i != 0) {
                    p.print(",");
                    p.printSpace();
                }

                if (has_rest_arg and i + 1 == args.len) {
                    p.print("...");
                }

                p.printBinding(arg.binding);

                if (arg.default) |default| {
                    p.printSpace();
                    p.print("=");
                    p.printSpace();
                    p.printExpr(default, .comma, ExprFlag.None());
                }
            }

            if (wrap) {
                p.print(")");
            }
        }

        pub fn printFunc(p: *Printer, func: G.Fn) void {
            p.printFnArgs(func.args, func.flags.has_rest_arg, false);
            p.printSpace();
            p.printBlock(func.body.loc, func.body.stmts);
        }
        pub fn printClass(p: *Printer, class: G.Class) void {
            if (class.extends) |extends| {
                p.print(" extends");
                p.printSpace();
                p.printExpr(extends, Level.new.sub(1), ExprFlag.None());
            }

            p.printSpace();

            p.addSourceMapping(class.body_loc);
            p.print("{");
            p.printNewline();
            p.options.indent += 1;

            for (class.properties) |item| {
                p.printSemicolonIfNeeded();
                p.printIndent();
                p.printProperty(item);

                if (item.value == null) {
                    p.printSemicolonAfterStatement();
                } else {
                    p.printNewline();
                }
            }

            p.needs_semicolon = false;
            p.options.unindent();
            p.printIndent();
            p.print("}");
        }

        pub fn bestQuoteCharForEString(p: *Printer, str: *const E.String, allow_backtick: bool) u8 {
            if (str.isUTF8()) {
                return p.bestQuoteCharForString(str.utf8, allow_backtick);
            } else {
                return p.bestQuoteCharForString(str.value, allow_backtick);
            }
        }

        pub fn bestQuoteCharForString(_: *Printer, str: anytype, allow_backtick_: bool) u8 {
            if (comptime is_json) return '"';

            const allow_backtick = allow_backtick_;

            var single_cost: usize = 0;
            var double_cost: usize = 0;
            var backtick_cost: usize = 0;
            var char: u8 = 0;
            var i: usize = 0;
            while (i < str.len) {
                switch (str[i]) {
                    '\'' => {
                        single_cost += 1;
                    },
                    '"' => {
                        double_cost += 1;
                    },
                    '`' => {
                        backtick_cost += 1;
                    },
                    '\r', '\n' => {
                        if (allow_backtick) {
                            return '`';
                        }
                    },
                    '\\' => {
                        i += 1;
                    },
                    '$' => {
                        if (i + 1 < str.len and str[i + 1] == '{') {
                            backtick_cost += 1;
                        }
                    },
                    else => {},
                }
                i += 1;
            }

            char = '"';
            if (double_cost > single_cost) {
                char = '\'';

                if (single_cost > backtick_cost and allow_backtick) {
                    char = '`';
                }
            } else if (double_cost > backtick_cost and allow_backtick) {
                char = '`';
            }

            return char;
        }

        pub fn printNonNegativeFloat(p: *Printer, float: f64) void {
            // Is this actually an integer?
            @setRuntimeSafety(false);
            const floored: f64 = @floor(float);
            const remainder: f64 = (float - floored);
            const is_integer = remainder == 0;
            if (float < std.math.maxInt(u52) and is_integer) {
                @setFloatMode(.Optimized);
                // In JavaScript, numbers are represented as 64 bit floats
                // However, they could also be signed or unsigned int 32 (when doing bit shifts)
                // In this case, it's always going to unsigned since that conversion has already happened.
                const val = @floatToInt(u64, float);
                switch (val) {
                    0 => {
                        p.print("0");
                    },
                    1...9 => {
                        var bytes = [1]u8{'0' + @intCast(u8, val)};
                        p.print(&bytes);
                    },
                    10 => {
                        p.print("10");
                    },
                    11...99 => {
                        var buf: *[2]u8 = (p.writer.reserve(2) catch unreachable)[0..2];
                        formatUnsignedIntegerBetween(2, buf, val);
                        p.writer.advance(2);
                    },
                    100 => {
                        p.print("100");
                    },
                    101...999 => {
                        var buf: *[3]u8 = (p.writer.reserve(3) catch unreachable)[0..3];
                        formatUnsignedIntegerBetween(3, buf, val);
                        p.writer.advance(3);
                    },

                    1000 => {
                        p.print("1000");
                    },
                    1001...9999 => {
                        var buf: *[4]u8 = (p.writer.reserve(4) catch unreachable)[0..4];
                        formatUnsignedIntegerBetween(4, buf, val);
                        p.writer.advance(4);
                    },
                    10000 => {
                        p.print("1e4");
                    },
                    100000 => {
                        p.print("1e5");
                    },
                    1000000 => {
                        p.print("1e6");
                    },
                    10000000 => {
                        p.print("1e7");
                    },
                    100000000 => {
                        p.print("1e8");
                    },
                    1000000000 => {
                        p.print("1e9");
                    },

                    10001...99999 => {
                        var buf: *[5]u8 = (p.writer.reserve(5) catch unreachable)[0..5];
                        formatUnsignedIntegerBetween(5, buf, val);
                        p.writer.advance(5);
                    },
                    100001...999999 => {
                        var buf: *[6]u8 = (p.writer.reserve(6) catch unreachable)[0..6];
                        formatUnsignedIntegerBetween(6, buf, val);
                        p.writer.advance(6);
                    },
                    1_000_001...9_999_999 => {
                        var buf: *[7]u8 = (p.writer.reserve(7) catch unreachable)[0..7];
                        formatUnsignedIntegerBetween(7, buf, val);
                        p.writer.advance(7);
                    },
                    10_000_001...99_999_999 => {
                        var buf: *[8]u8 = (p.writer.reserve(8) catch unreachable)[0..8];
                        formatUnsignedIntegerBetween(8, buf, val);
                        p.writer.advance(8);
                    },
                    100_000_001...999_999_999 => {
                        var buf: *[9]u8 = (p.writer.reserve(9) catch unreachable)[0..9];
                        formatUnsignedIntegerBetween(9, buf, val);
                        p.writer.advance(9);
                    },
                    1_000_000_001...9_999_999_999 => {
                        var buf: *[10]u8 = (p.writer.reserve(10) catch unreachable)[0..10];
                        formatUnsignedIntegerBetween(10, buf, val);
                        p.writer.advance(10);
                    },
                    else => std.fmt.formatInt(val, 10, .lower, .{}, p) catch unreachable,
                }

                return;
            }

            std.fmt.formatFloatDecimal(
                float,
                .{},
                p,
            ) catch unreachable;
        }

        pub fn printQuotedUTF16(e: *Printer, text: []const u16, quote: u8) void {
            var i: usize = 0;
            const n: usize = text.len;

            // e(text.len) catch unreachable;

            while (i < n) {
                const CodeUnitType = u32;

                const c: CodeUnitType = text[i];
                i += 1;

                // TODO: here
                switch (c) {

                    // Special-case the null character since it may mess with code written in C
                    // that treats null characters as the end of the string.
                    0x00 => {
                        // We don't want "\x001" to be written as "\01"
                        if (i < n and text[i] >= '0' and text[i] <= '9') {
                            e.print("\\x00");
                        } else {
                            e.print("\\0");
                        }
                    },

                    '/',
                    'a'...'z',
                    'A'...'Z',
                    '0'...'9',
                    '_',
                    '-',
                    '(',
                    '[',
                    '{',
                    '<',
                    '>',
                    ')',
                    ']',
                    '}',
                    ',',
                    ':',
                    ';',
                    '.',
                    '?',
                    '!',
                    '@',
                    '#',
                    '%',
                    '^',
                    '&',
                    '*',
                    '+',
                    '=',
                    ' ',
                    => {
                        e.print(@intCast(u8, c));
                    },

                    // Special-case the bell character since it may cause dumping this file to
                    // the terminal to make a sound, which is undesirable. Note that we can't
                    // use an octal literal to print this shorter since octal literals are not
                    // allowed in strict mode (or in template strings).
                    0x07 => {
                        e.print("\\x07");
                    },
                    0x08 => {
                        e.print("\\b");
                    },
                    0x0C => {
                        e.print("\\f");
                    },
                    '\n' => {
                        if (quote == '`') {
                            e.print('\n');
                        } else {
                            e.print("\\n");
                        }
                    },
                    std.ascii.control_code.CR => {
                        e.print("\\r");
                    },
                    // \v
                    std.ascii.control_code.VT => {
                        e.print("\\v");
                    },
                    // "\\"
                    '\\' => {
                        e.print("\\\\");
                    },

                    '\'' => {
                        if (quote == '\'') {
                            e.print('\\');
                        }
                        e.print("'");
                    },

                    '"' => {
                        if (quote == '"') {
                            e.print('\\');
                        }

                        e.print("\"");
                    },
                    '`' => {
                        if (quote == '`') {
                            e.print('\\');
                        }

                        e.print("`");
                    },
                    '$' => {
                        if (quote == '`' and i < n and text[i] == '{') {
                            e.print('\\');
                        }

                        e.print('$');
                    },
                    0x2028 => {
                        e.print("\\u2028");
                    },
                    0x2029 => {
                        e.print("\\u2029");
                    },
                    0xFEFF => {
                        e.print("\\uFEFF");
                    },

                    else => {
                        switch (c) {
                            first_high_surrogate...last_high_surrogate => {

                                // Is there a next character?

                                if (i < n) {
                                    const c2: CodeUnitType = text[i];

                                    if (c2 >= first_high_surrogate and c2 <= last_low_surrogate) {
                                        i += 1;
                                        const r: CodeUnitType = 0x10000 + (((c & 0x03ff) << 10) | (c2 & 0x03ff));

                                        // Escape this character if UTF-8 isn't allowed
                                        if (ascii_only) {
                                            var ptr = e.writer.reserve(12) catch unreachable;
                                            ptr[0..12].* = [_]u8{
                                                '\\', 'u', hex_chars[c >> 12],  hex_chars[(c >> 8) & 15],  hex_chars[(c >> 4) & 15],  hex_chars[c & 15],
                                                '\\', 'u', hex_chars[c2 >> 12], hex_chars[(c2 >> 8) & 15], hex_chars[(c2 >> 4) & 15], hex_chars[c2 & 15],
                                            };
                                            e.writer.advance(12);

                                            continue;
                                            // Otherwise, encode to UTF-8
                                        }

                                        var ptr = e.writer.reserve(4) catch unreachable;
                                        e.writer.advance(strings.encodeWTF8RuneT(ptr[0..4], CodeUnitType, r));
                                        continue;
                                    }
                                }

                                // Write an unpaired high surrogate
                                var ptr = e.writer.reserve(6) catch unreachable;
                                ptr[0..6].* = [_]u8{ '\\', 'u', hex_chars[c >> 12], hex_chars[(c >> 8) & 15], hex_chars[(c >> 4) & 15], hex_chars[c & 15] };
                                e.writer.advance(6);
                            },
                            // Is this an unpaired low surrogate or four-digit hex escape?
                            first_low_surrogate...last_low_surrogate => {
                                // Write an unpaired high surrogate
                                var ptr = e.writer.reserve(6) catch unreachable;
                                ptr[0..6].* = [_]u8{ '\\', 'u', hex_chars[c >> 12], hex_chars[(c >> 8) & 15], hex_chars[(c >> 4) & 15], hex_chars[c & 15] };
                                e.writer.advance(6);
                            },
                            else => {
                                // this extra branch should get compiled
                                if (ascii_only) {
                                    if (c > 0xFF) {
                                        var ptr = e.writer.reserve(6) catch unreachable;
                                        // Write an unpaired high surrogate
                                        ptr[0..6].* = [_]u8{ '\\', 'u', hex_chars[c >> 12], hex_chars[(c >> 8) & 15], hex_chars[(c >> 4) & 15], hex_chars[c & 15] };
                                        e.writer.advance(6);
                                    } else {
                                        // Can this be a two-digit hex escape?
                                        var ptr = e.writer.reserve(4) catch unreachable;
                                        ptr[0..4].* = [_]u8{ '\\', 'x', hex_chars[c >> 4], hex_chars[c & 15] };
                                        e.writer.advance(4);
                                    }
                                } else {
                                    // chars < 255 as two digit hex escape
                                    if (c < 0xFF) {
                                        var ptr = e.writer.reserve(4) catch unreachable;
                                        ptr[0..4].* = [_]u8{ '\\', 'x', hex_chars[c >> 4], hex_chars[c & 15] };
                                        e.writer.advance(4);
                                        continue;
                                    }

                                    var ptr = e.writer.reserve(4) catch return;
                                    e.writer.advance(strings.encodeWTF8RuneT(ptr[0..4], CodeUnitType, c));
                                }
                            },
                        }
                    },
                }
            }
        }

        pub fn isUnboundEvalIdentifier(p: *Printer, value: Expr) bool {
            switch (value.data) {
                .e_identifier => |ident| {
                    if (ident.ref.is_source_contents_slice) return false;

                    const symbol = p.symbols.get(p.symbols.follow(ident.ref)) orelse return false;
                    return symbol.kind == .unbound and strings.eqlComptime(symbol.original_name, "eval");
                },
                else => {
                    return false;
                },
            }
        }

        pub fn printRequireError(p: *Printer, text: string) void {
            p.print("(() => { throw (new Error(`Cannot require module '");
            p.printQuotedUTF8(text, false);
            p.print("'`)); } )()");
        }

        pub fn printRequireOrImportExpr(
            p: *Printer,
            import_record_index: u32,
            leading_interior_comments: []G.Comment,
            level: Level,
            flags: ExprFlag,
        ) void {
            const wrap = level.gte(.new) or flags.forbid_call;
            if (wrap) p.print("(");
            defer if (wrap) p.print(")");

            assert(p.import_records.len > import_record_index);
            const record = p.import_records[import_record_index];

            const is_external = std.mem.indexOfScalar(
                u32,
                p.options.externals,
                import_record_index,
            ) != null;

            // External "require()"
            if (record.kind != .dynamic) {
                p.printSpaceBeforeIdentifier();

                if (record.path.is_disabled and record.handles_import_errors and !is_external) {
                    p.printRequireError(record.path.text);
                    return;
                }

                p.printSymbol(p.options.require_ref.?);
                p.print("(");
                p.printQuotedUTF8(record.path.text, true);
                p.print(")");
                return;
            }

            // External import()
            if (leading_interior_comments.len > 0) {
                p.printNewline();
                p.options.indent += 1;
                for (leading_interior_comments) |comment| {
                    p.printIndentedComment(comment.text);
                }
                p.printIndent();
            }
            p.addSourceMapping(record.range.loc);

            // Allow it to fail at runtime, if it should
            p.print("import(");
            p.printQuotedUTF8(record.path.text, true);
            p.print(")");

            if (leading_interior_comments.len > 0) {
                p.printNewline();
                p.options.unindent();
                p.printIndent();
            }

            return;
        }

        // noop for now
        pub inline fn printPure(_: *Printer) void {}

        pub fn printQuotedUTF8(p: *Printer, str: string, allow_backtick: bool) void {
            const quote = p.bestQuoteCharForString(str, allow_backtick);
            p.print(quote);
            p.print(str);
            p.print(quote);
        }

        pub inline fn canPrintIdentifier(_: *Printer, name: string) bool {
            if (comptime is_json) return false;

            if (comptime ascii_only) {
                return js_lexer.isLatin1Identifier(string, name);
            } else {
                return js_lexer.isIdentifier(name);
            }
        }

        pub inline fn canPrintIdentifierUTF16(_: *Printer, name: []const u16) bool {
            if (comptime ascii_only) {
                return js_lexer.isLatin1Identifier([]const u16, name);
            } else {
                return js_lexer.isIdentifierUTF16(name);
            }
        }

        pub fn printExpr(p: *Printer, expr: Expr, level: Level, _flags: ExprFlag) void {
            p.addSourceMapping(expr.loc);
            var flags = _flags;

            switch (expr.data) {
                .e_missing => {},
                .e_undefined => {
                    p.printSpaceBeforeIdentifier();

                    p.printUndefined(level);
                },
                .e_super => {
                    p.printSpaceBeforeIdentifier();
                    p.print("super");
                },
                .e_null => {
                    p.printSpaceBeforeIdentifier();
                    p.print("null");
                },
                .e_this => {
                    p.printSpaceBeforeIdentifier();
                    p.print("this");
                },
                .e_spread => |e| {
                    p.print("...");
                    p.printExpr(e.value, .comma, ExprFlag.None());
                },
                .e_new_target => {
                    p.printSpaceBeforeIdentifier();
                    p.print("new.target");
                },
                .e_import_meta => {
                    p.printSpaceBeforeIdentifier();
                    p.print("import.meta");
                },
                .e_new => |e| {
                    const has_pure_comment = e.can_be_unwrapped_if_unused;
                    const wrap = level.gte(.call) or (has_pure_comment and level.gte(.postfix));

                    if (wrap) {
                        p.print("(");
                    }

                    if (has_pure_comment) {
                        p.printPure();
                    }

                    p.printSpaceBeforeIdentifier();
                    p.print("new");
                    p.printSpace();
                    p.printExpr(e.target, .new, ExprFlag.ForbidCall());

                    if (e.args.len > 0 or level.gte(.postfix)) {
                        p.print("(");

                        if (e.args.len > 0) {
                            p.printExpr(e.args[0], .comma, ExprFlag.None());

                            for (e.args[1..]) |arg| {
                                p.print(",");
                                p.printSpace();
                                p.printExpr(arg, .comma, ExprFlag.None());
                            }
                        }

                        p.print(")");
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_call => |e| {
                    var wrap = level.gte(.new) or flags.forbid_call;
                    var target_flags = ExprFlag.None();
                    if (e.optional_chain == null) {
                        target_flags = ExprFlag.HasNonOptionalChainParent();
                    } else if (flags.has_non_optional_chain_parent) {
                        wrap = true;
                    }

                    const has_pure_comment = e.can_be_unwrapped_if_unused;
                    if (has_pure_comment and level.gte(.postfix)) {
                        wrap = true;
                    }

                    if (wrap) {
                        p.print("(");
                    }

                    if (has_pure_comment) {
                        const was_stmt_start = p.stmt_start == p.writer.written;
                        p.printPure();
                        if (was_stmt_start) {
                            p.stmt_start = p.writer.written;
                        }
                    }
                    // We don't ever want to accidentally generate a direct eval expression here
                    p.call_target = e.target.data;
                    if (!e.is_direct_eval and p.isUnboundEvalIdentifier(e.target)) {
                        p.print("(0, ");
                        p.printExpr(e.target, .postfix, ExprFlag.None());
                        p.print(")");
                    } else {
                        p.printExpr(e.target, .postfix, target_flags);
                    }

                    if (e.optional_chain != null and (e.optional_chain orelse unreachable) == .start) {
                        p.print("?.");
                    }
                    p.print("(");

                    if (e.args.len > 0) {
                        p.printExpr(e.args[0], .comma, ExprFlag.None());
                        for (e.args[1..]) |arg| {
                            p.print(",");
                            p.printSpace();
                            p.printExpr(arg, .comma, ExprFlag.None());
                        }
                    }

                    p.print(")");
                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_require => |e| {
                    if (rewrite_esm_to_cjs and p.import_records[e.import_record_index].is_bundled) {
                        p.printIndent();
                        p.printBundledRequire(e);
                        p.printSemicolonIfNeeded();
                        return;
                    }

                    if (!rewrite_esm_to_cjs or !p.import_records[e.import_record_index].is_bundled) {
                        p.printRequireOrImportExpr(e.import_record_index, &([_]G.Comment{}), level, flags);
                    }
                },
                .e_require_or_require_resolve => |e| {
                    const wrap = level.gte(.new) or flags.forbid_call;
                    if (wrap) {
                        p.print("(");
                    }

                    if (p.options.rewrite_require_resolve) {
                        // require.resolve("../src.js") => new URL("/src.js", location.origin).href
                        // require.resolve is not available to the browser
                        // if we return the relative filepath, that could be inaccessible if they're viewing the development server
                        // on a different origin than where it's compiling
                        // instead of doing that, we make the following assumption: the assets are same-origin
                        p.printSpaceBeforeIdentifier();
                        p.print("new URL(");
                        p.printQuotedUTF8(p.import_records[e.import_record_index].path.text, true);
                        p.print(", location.origin).href");
                    } else {
                        p.printSpaceBeforeIdentifier();
                        p.printQuotedUTF8(p.import_records[e.import_record_index].path.text, true);
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_import => |e| {

                    // Handle non-string expressions
                    if (Ref.isSourceIndexNull(e.import_record_index)) {
                        const wrap = level.gte(.new) or flags.forbid_call;
                        if (wrap) {
                            p.print("(");
                        }

                        p.printSpaceBeforeIdentifier();
                        p.print("import(");
                        if (e.leading_interior_comments.len > 0) {
                            p.printNewline();
                            p.options.indent += 1;
                            for (e.leading_interior_comments) |comment| {
                                p.printIndentedComment(comment.text);
                            }
                            p.printIndent();
                        }
                        p.printExpr(e.expr, .comma, ExprFlag.None());

                        if (e.leading_interior_comments.len > 0) {
                            p.printNewline();
                            p.options.unindent();
                            p.printIndent();
                        }
                        p.print(")");
                        if (wrap) {
                            p.print(")");
                        }
                    } else {
                        p.printRequireOrImportExpr(e.import_record_index, e.leading_interior_comments, level, flags);
                    }
                },
                .e_dot => |e| {
                    var wrap = false;
                    if (e.optional_chain == null) {
                        flags.has_non_optional_chain_parent = true;
                    } else {
                        if (!flags.has_non_optional_chain_parent) {
                            wrap = true;
                            p.print("(");
                        }

                        flags.has_non_optional_chain_parent = true;
                    }
                    p.printExpr(e.target, .postfix, flags);
                    // Ironic Zig compiler bug: e.optional_chain == null or e.optional_chain == .start causes broken LLVM IR
                    // https://github.com/ziglang/zig/issues/6059
                    const isOptionalChain = (e.optional_chain orelse js_ast.OptionalChain.ccontinue) == js_ast.OptionalChain.start;

                    if (p.canPrintIdentifier(e.name)) {
                        if (!isOptionalChain and p.prev_num_end == p.writer.written) {
                            // "1.toString" is a syntax error, so print "1 .toString" instead
                            p.print(" ");
                        }
                        if (isOptionalChain) {
                            p.print("?.");
                        } else {
                            p.print(".");
                        }

                        p.addSourceMapping(e.name_loc);
                        p.printIdentifier(e.name);
                    } else {
                        if (isOptionalChain) {
                            p.print("?.");
                        }
                        p.print("[");
                        p.addSourceMapping(e.name_loc);
                        p.printQuotedUTF8(e.name, true);
                        p.print("]");
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_index => |e| {
                    var wrap = false;
                    if (e.optional_chain == null) {
                        flags.has_non_optional_chain_parent = false;
                    } else {
                        if (flags.has_non_optional_chain_parent) {
                            wrap = true;
                            p.print("(");
                        }
                        flags.has_non_optional_chain_parent = false;
                    }

                    p.printExpr(e.target, .postfix, flags);

                    // Zig compiler bug: e.optional_chain == null or e.optional_chain == .start causes broken LLVM IR
                    // https://github.com/ziglang/zig/issues/6059
                    const is_optional_chain_start = (e.optional_chain orelse js_ast.OptionalChain.ccontinue) == js_ast.OptionalChain.start;

                    if (is_optional_chain_start) {
                        p.print("?.");
                    }

                    switch (e.index.data) {
                        .e_private_identifier => {
                            const priv = e.index.data.e_private_identifier;
                            if (is_optional_chain_start) {
                                p.print(".");
                            }

                            p.printSymbol(priv.ref);
                        },
                        else => {
                            p.print("[");
                            p.printExpr(e.index, .lowest, ExprFlag.None());
                            p.print("]");
                        },
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_if => |e| {
                    const wrap = level.gte(.conditional);
                    if (wrap) {
                        p.print("(");
                        flags.forbid_in = false;
                    }
                    p.printExpr(e.test_, .conditional, flags);
                    p.printSpace();
                    p.print("? ");
                    p.printExpr(e.yes, .yield, ExprFlag.None());
                    p.printSpace();
                    p.print(": ");
                    flags.forbid_in = true;
                    p.printExpr(e.no, .yield, flags);
                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_arrow => |e| {
                    const wrap = level.gte(.assign);

                    if (wrap) {
                        p.print("(");
                    }

                    if (e.is_async) {
                        p.printSpaceBeforeIdentifier();
                        p.print("async");
                        p.printSpace();
                    }

                    p.printFnArgs(e.args, e.has_rest_arg, true);
                    p.printSpace();
                    p.print("=>");
                    p.printSpace();

                    var wasPrinted = false;

                    // This is more efficient than creating a new Part just for the JSX auto imports when bundling
                    if (comptime rewrite_esm_to_cjs) {
                        if (@ptrToInt(p.options.prepend_part_key) > 0 and @ptrToInt(e.body.stmts.ptr) == @ptrToInt(p.options.prepend_part_key)) {
                            p.printTwoBlocksInOne(e.body.loc, e.body.stmts, p.options.prepend_part_value.?.stmts);
                            wasPrinted = true;
                        }
                    }

                    if (e.body.stmts.len == 1 and e.prefer_expr) {
                        switch (e.body.stmts[0].data) {
                            .s_return => {
                                if (e.body.stmts[0].data.s_return.value) |val| {
                                    p.arrow_expr_start = p.writer.written;
                                    p.printExpr(val, .comma, ExprFlag{ .forbid_in = true });
                                    wasPrinted = true;
                                }
                            },
                            else => {},
                        }
                    }

                    if (!wasPrinted) {
                        p.printBlock(e.body.loc, e.body.stmts);
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_function => |e| {
                    const n = p.writer.written;
                    var wrap = p.stmt_start == n or p.export_default_start == n;

                    if (wrap) {
                        p.print("(");
                    }

                    p.printSpaceBeforeIdentifier();
                    if (e.func.flags.is_async) {
                        p.print("async ");
                    }
                    p.print("function");
                    if (e.func.flags.is_generator) {
                        p.print("*");
                        p.printSpace();
                    }

                    if (e.func.name) |sym| {
                        p.maybePrintSpace();
                        p.printSymbol(sym.ref orelse Global.panic("internal error: expected E.Function's name symbol to have a ref\n{s}", .{e.func}));
                    }

                    p.printFunc(e.func);
                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_class => |e| {
                    const n = p.writer.written;
                    var wrap = p.stmt_start == n or p.export_default_start == n;
                    if (wrap) {
                        p.print("(");
                    }

                    p.printSpaceBeforeIdentifier();
                    p.print("class");
                    if (e.class_name) |name| {
                        p.maybePrintSpace();
                        p.printSymbol(name.ref orelse Global.panic("internal error: expected E.Class's name symbol to have a ref\n{s}", .{e}));
                        p.maybePrintSpace();
                    }
                    p.printClass(e.*);
                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_array => |e| {
                    p.print("[");
                    if (e.items.len > 0) {
                        if (!e.is_single_line) {
                            p.options.indent += 1;
                        }

                        for (e.items) |item, i| {
                            if (i != 0) {
                                p.print(",");
                                if (e.is_single_line) {
                                    p.printSpace();
                                }
                            }
                            if (!e.is_single_line) {
                                p.printNewline();
                                p.printIndent();
                            }
                            p.printExpr(item, .comma, ExprFlag.None());

                            if (i == e.items.len - 1) {
                                // Make sure there's a comma after trailing missing items
                                switch (item.data) {
                                    .e_missing => {
                                        p.print(",");
                                    },
                                    else => {},
                                }
                            }
                        }

                        if (!e.is_single_line) {
                            p.options.unindent();
                            p.printNewline();
                            p.printIndent();
                        }
                    }

                    p.print("]");
                },
                .e_object => |e| {
                    const n = p.writer.written;
                    const wrap = if (comptime is_json)
                        false
                    else
                        p.stmt_start == n or p.arrow_expr_start == n;

                    if (wrap) {
                        p.print("(");
                    }
                    p.print("{");
                    if (e.properties.len > 0) {
                        if (!e.is_single_line) {
                            p.options.indent += 1;
                        }

                        for (e.properties) |property, i| {
                            if (i != 0) {
                                p.print(",");
                                if (e.is_single_line) {
                                    p.printSpace();
                                }
                            }

                            if (!e.is_single_line) {
                                p.printNewline();
                                p.printIndent();
                            }
                            p.printProperty(property);
                        }

                        if (!e.is_single_line) {
                            p.options.unindent();
                            p.printNewline();
                            p.printIndent();
                        } else if (e.properties.len > 0) {
                            p.printSpace();
                        }
                    }
                    p.print("}");
                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_boolean => |e| {
                    p.printSpaceBeforeIdentifier();
                    p.print(if (e.value) "true" else "false");
                },
                .e_string => |e| {

                    // If this was originally a template literal, print it as one as long as we're not minifying
                    if (e.prefer_template) {
                        p.print("`");
                        p.printStringContent(e, '`');
                        p.print("`");
                        return;
                    }

                    const c = p.bestQuoteCharForEString(e, true);
                    p.print(c);
                    p.printStringContent(e, c);
                    p.print(c);
                },
                .e_template => |e| {
                    if (e.tag) |tag| {
                        // Optional chains are forbidden in template tags
                        if (expr.isOptionalChain()) {
                            p.print("(");
                            p.printExpr(tag, .lowest, ExprFlag.None());
                            p.print(")");
                        } else {
                            p.printExpr(tag, .postfix, ExprFlag.None());
                        }
                    }

                    p.print("`");
                    if (e.head.isPresent()) {
                        p.printStringContent(&e.head, '`');
                    }

                    for (e.parts) |part| {
                        p.print("${");
                        p.printExpr(part.value, .lowest, ExprFlag.None());
                        p.print("}");
                        if (part.tail.isPresent()) {
                            p.printStringContent(&part.tail, '`');
                        }
                    }
                    p.print("`");
                },
                .e_reg_exp => |e| {
                    const n = p.writer.written;

                    // Avoid forming a single-line comment
                    if (n > 0 and p.writer.prevChar() == '/') {
                        p.print(" ");
                    }

                    p.print(e.value);

                    // Need a space before the next identifier to avoid it turning into flags
                    p.prev_reg_exp_end = p.writer.written;
                },
                .e_big_int => |e| {
                    p.printSpaceBeforeIdentifier();
                    p.print(e.value);
                    p.print('n');
                },
                .e_number => |e| {
                    const value = e.value;

                    const absValue = @fabs(value);

                    if (std.math.isNan(value)) {
                        p.printSpaceBeforeIdentifier();
                        p.print("NaN");
                    } else if (std.math.isPositiveInf(value)) {
                        p.printSpaceBeforeIdentifier();
                        p.print("Infinity");
                    } else if (std.math.isNegativeInf(value)) {
                        if (level.gte(.prefix)) {
                            p.print("(-Infinity)");
                        } else {
                            p.printSpaceBeforeIdentifier();
                            p.print("(-Infinity)");
                        }
                    } else if (!std.math.signbit(value)) {
                        p.printSpaceBeforeIdentifier();
                        p.printNonNegativeFloat(absValue);

                        // Remember the end of the latest number
                        p.prev_num_end = p.writer.written;
                    } else if (level.gte(.prefix)) {
                        // Expressions such as "(-1).toString" need to wrap negative numbers.
                        // Instead of testing for "value < 0" we test for "signbit(value)" and
                        // "!isNaN(value)" because we need this to be true for "-0" and "-0 < 0"
                        // is false.
                        p.print("(-");
                        p.printNonNegativeFloat(absValue);
                        p.print(")");
                    } else {
                        p.printSpaceBeforeOperator(Op.Code.un_neg);
                        p.print("-");
                        p.printNonNegativeFloat(absValue);

                        // Remember the end of the latest number
                        p.prev_num_end = p.writer.written;
                    }
                },
                .e_identifier => |e| {
                    const name = p.renamer.nameForSymbol(e.ref);
                    const wrap = p.writer.written == p.for_of_init_start and strings.eqlComptime(name, "let");

                    if (wrap) {
                        p.print("(");
                    }

                    p.printSpaceBeforeIdentifier();
                    p.printIdentifier(name);

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_import_identifier => |e| {
                    // Potentially use a property access instead of an identifier
                    var didPrint = false;

                    if (p.symbols.getWithLink(e.ref)) |symbol| {
                        if (symbol.import_item_status == .missing) {
                            p.printUndefined(level);
                            didPrint = true;
                        } else if (symbol.namespace_alias) |namespace| {
                            const import_record = p.import_records[namespace.import_record_index];
                            if ((comptime is_inside_bundle) or import_record.is_bundled or namespace.was_originally_property_access) {
                                var wrap = false;
                                didPrint = true;

                                if (p.call_target) |target| {
                                    wrap = e.was_originally_identifier and (target == .e_identifier and
                                        target.e_identifier.ref.eql(expr.data.e_import_identifier.ref));
                                }

                                if (wrap) {
                                    p.print("(0, ");
                                }

                                p.printNamespaceAlias(import_record, namespace);

                                if (wrap) {
                                    p.print(")");
                                }
                            } else if (import_record.was_originally_require and import_record.path.is_disabled) {
                                p.printRequireError(import_record.path.text);
                                didPrint = true;
                            }
                        }
                    }

                    if (!didPrint) {
                        p.printSymbol(e.ref);
                    }
                },
                .e_await => |e| {
                    const wrap = level.gte(.prefix);

                    if (wrap) {
                        p.print("(");
                    }

                    p.printSpaceBeforeIdentifier();
                    p.print("await");
                    p.printSpace();
                    p.printExpr(e.value, Level.sub(.prefix, 1), ExprFlag.None());

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_yield => |e| {
                    const wrap = level.gte(.assign);
                    if (wrap) {
                        p.print("(");
                    }

                    p.printSpaceBeforeIdentifier();
                    p.print("yield");

                    if (e.value) |val| {
                        if (e.is_star) {
                            p.print("*");
                        }
                        p.printSpace();
                        p.printExpr(val, .yield, ExprFlag.None());
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_unary => |e| {
                    const entry: Op = Op.Table.get(e.op);
                    const wrap = level.gte(entry.level);

                    if (wrap) {
                        p.print("(");
                    }

                    if (!e.op.isPrefix()) {
                        p.printExpr(e.value, Op.Level.sub(.postfix, 1), ExprFlag.None());
                    }

                    if (entry.is_keyword) {
                        p.printSpaceBeforeIdentifier();
                        p.print(entry.text);
                        p.printSpace();
                    } else {
                        p.printSpaceBeforeOperator(e.op);
                        p.print(entry.text);
                        p.prev_op = e.op;
                        p.prev_op_end = p.writer.written;
                    }

                    if (e.op.isPrefix()) {
                        p.printExpr(e.value, Op.Level.sub(.prefix, 1), ExprFlag.None());
                    }

                    if (wrap) {
                        p.print(")");
                    }
                },
                .e_binary => |e| {
                    const entry: Op = Op.Table.get(e.op);
                    var wrap = level.gte(entry.level) or (e.op == Op.Code.bin_in and flags.forbid_in);

                    // Destructuring assignments must be parenthesized
                    const n = p.writer.written;
                    if (n == p.stmt_start or n == p.arrow_expr_start) {
                        switch (e.left.data) {
                            .e_object => {
                                wrap = true;
                            },
                            else => {},
                        }
                    }

                    if (wrap) {
                        p.print("(");
                        flags.forbid_in = true;
                    }

                    var left_level = entry.level.sub(1);
                    var right_level = entry.level.sub(1);

                    if (e.op.isRightAssociative()) {
                        left_level = entry.level;
                    }

                    if (e.op.isLeftAssociative()) {
                        right_level = entry.level;
                    }

                    switch (e.op) {
                        // "??" can't directly contain "||" or "&&" without being wrapped in parentheses
                        .bin_nullish_coalescing => {
                            switch (e.left.data) {
                                .e_binary => {
                                    const left = e.left.data.e_binary;
                                    switch (left.op) {
                                        .bin_logical_and, .bin_logical_or => {
                                            left_level = .prefix;
                                        },
                                        else => {},
                                    }
                                },
                                else => {},
                            }

                            switch (e.right.data) {
                                .e_binary => {
                                    const right = e.right.data.e_binary;
                                    switch (right.op) {
                                        .bin_logical_and, .bin_logical_or => {
                                            right_level = .prefix;
                                        },
                                        else => {},
                                    }
                                },
                                else => {},
                            }
                        },
                        // "**" can't contain certain unary expressions
                        .bin_pow => {
                            switch (e.left.data) {
                                .e_unary => {
                                    const left = e.left.data.e_unary;
                                    if (left.op.unaryAssignTarget() == .none) {
                                        left_level = .call;
                                    }
                                },
                                .e_await, .e_undefined, .e_number => {
                                    left_level = .call;
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }

                    // Special-case "#foo in bar"
                    if (e.op == .bin_in and @as(Expr.Tag, e.left.data) == .e_private_identifier) {
                        p.printSymbol(e.left.data.e_private_identifier.ref);
                    } else {
                        flags.forbid_in = true;
                        p.printExpr(e.left, left_level, flags);
                    }

                    if (e.op != .bin_comma) {
                        p.printSpace();
                    }

                    if (entry.is_keyword) {
                        p.printSpaceBeforeIdentifier();
                        p.print(entry.text);
                    } else {
                        p.printSpaceBeforeIdentifier();
                        p.print(entry.text);
                        p.prev_op = e.op;
                        p.prev_op_end = p.writer.written;
                    }

                    p.printSpace();
                    flags.forbid_in = true;
                    p.printExpr(e.right, right_level, flags);

                    if (wrap) {
                        p.print(")");
                    }
                },
                else => {
                    // Global.panic("Unexpected expression of type {s}", .{std.meta.activeTag(expr.data});
                },
            }
        }

        pub fn printSpaceBeforeOperator(p: *Printer, next: Op.Code) void {
            if (p.prev_op_end == p.writer.written) {
                const prev = p.prev_op;
                // "+ + y" => "+ +y"
                // "+ ++ y" => "+ ++y"
                // "x + + y" => "x+ +y"
                // "x ++ + y" => "x+++y"
                // "x + ++ y" => "x+ ++y"
                // "-- >" => "-- >"
                // "< ! --" => "<! --"
                if (((prev == Op.Code.bin_add or prev == Op.Code.un_pos) and (next == Op.Code.bin_add or next == Op.Code.un_pos or next == Op.Code.un_pre_inc)) or
                    ((prev == Op.Code.bin_sub or prev == Op.Code.un_neg) and (next == Op.Code.bin_sub or next == Op.Code.un_neg or next == Op.Code.un_pre_dec)) or
                    (prev == Op.Code.un_post_dec and next == Op.Code.bin_gt) or
                    (prev == Op.Code.un_not and next == Op.Code.un_pre_dec and p.writer.written > 1 and p.writer.prevPrevChar() == '<'))
                {
                    p.print(" ");
                }
            }
        }

        pub inline fn printDotThenSuffix(
            p: *Printer,
        ) void {
            p.print(")");
        }

        // This assumes the string has already been quoted.
        pub fn printStringContent(p: *Printer, str: *const E.String, c: u8) void {
            if (!str.isUTF8()) {
                // its already quoted for us!
                p.printQuotedUTF16(str.value, c);
            } else {
                p.printUTF8StringEscapedQuotes(str.utf8, c);
            }
        }

        // Add one outer branch so the inner loop does fewer branches
        pub fn printUTF8StringEscapedQuotes(p: *Printer, str: string, c: u8) void {
            switch (c) {
                '`' => _printUTF8StringEscapedQuotes(p, str, '`'),
                '"' => _printUTF8StringEscapedQuotes(p, str, '"'),
                '\'' => _printUTF8StringEscapedQuotes(p, str, '\''),
                else => unreachable,
            }
        }

        pub fn _printUTF8StringEscapedQuotes(p: *Printer, str: string, comptime c: u8) void {
            var utf8 = str;
            var i: usize = 0;
            // Walk the string searching for quote characters
            // Escape any we find
            // Skip over already-escaped strings
            while (i < utf8.len) : (i += 1) {
                switch (utf8[i]) {
                    '\\' => {
                        i += 1;
                    },
                    // We must escape here for JSX string literals that contain unescaped newlines
                    // Those will get transformed into a template string
                    // which can potentially have unescaped $
                    '$' => {
                        if (comptime c == '`') {
                            p.print(utf8[0..i]);
                            p.print("\\$");

                            utf8 = utf8[i + 1 ..];
                            i = 0;
                        }
                    },
                    c => {
                        p.print(utf8[0..i]);
                        p.print("\\" ++ &[_]u8{c});
                        utf8 = utf8[i + 1 ..];
                        i = 0;
                    },

                    else => {},
                }
            }
            if (utf8.len > 0) {
                p.print(utf8);
            }
        }

        pub fn printNamespaceAlias(p: *Printer, import_record: ImportRecord, namespace: G.NamespaceAlias) void {
            if (import_record.module_id > 0 and !import_record.contains_import_star) {
                p.print("$");
                p.printModuleId(import_record.module_id);
            } else {
                p.printSymbol(namespace.namespace_ref);
            }

            if (p.canPrintIdentifier(namespace.alias)) {
                p.print(".");
                p.printIdentifier(namespace.alias);
            } else {
                p.print("[");
                p.printQuotedUTF8(namespace.alias, true);
                p.print("]");
            }
        }

        pub fn printProperty(p: *Printer, item: G.Property) void {
            if (item.kind == .spread) {
                p.print("...");
                p.printExpr(item.value.?, .comma, ExprFlag.None());
                return;
            }
            const _key = item.key orelse unreachable;

            if (item.flags.is_static) {
                p.print("static");
                p.printSpace();
            }

            switch (item.kind) {
                .get => {
                    p.printSpaceBeforeIdentifier();
                    p.print("get");
                    p.printSpace();
                },
                .set => {
                    p.printSpaceBeforeIdentifier();
                    p.print("set");
                    p.printSpace();
                },
                else => {},
            }

            if (item.value) |val| {
                switch (val.data) {
                    .e_function => |func| {
                        if (item.flags.is_method) {
                            if (func.func.flags.is_async) {
                                p.printSpaceBeforeIdentifier();
                                p.print("async");
                            }

                            if (func.func.flags.is_generator) {
                                p.print("*");
                            }

                            if (func.func.flags.is_generator and func.func.flags.is_async) {
                                p.printSpace();
                            }
                        }
                    },
                    else => {},
                }
            }

            if (item.flags.is_computed) {
                p.print("[");
                p.printExpr(_key, .comma, ExprFlag.None());
                p.print("]");

                if (item.value) |val| {
                    switch (val.data) {
                        .e_function => |func| {
                            if (item.flags.is_method) {
                                p.printFunc(func.func);
                                return;
                            }
                        },
                        else => {},
                    }

                    p.print(":");
                    p.printSpace();
                    p.printExpr(val, .comma, ExprFlag.None());
                }

                if (item.initializer) |initial| {
                    p.printInitializer(initial);
                }
                return;
            }

            switch (_key.data) {
                .e_private_identifier => |priv| {
                    p.printSymbol(priv.ref);
                },
                .e_string => |key| {
                    p.addSourceMapping(_key.loc);
                    if (key.isUTF8()) {
                        p.printSpaceBeforeIdentifier();
                        var allow_shorthand: bool = true;
                        // In react/cjs/react.development.js, there's part of a function like this:
                        // var escaperLookup = {
                        //     "=": "=0",
                        //     ":": "=2"
                        //   };
                        // While each of those property keys are ASCII, a subset of ASCII is valid as the start of an identifier
                        // "=" and ":" are not valid
                        // So we need to check
                        if ((comptime !is_json) and p.canPrintIdentifier(key.utf8)) {
                            p.print(key.utf8);
                        } else {
                            allow_shorthand = false;
                            const quote = p.bestQuoteCharForString(key.utf8, true);
                            if (quote == '`') {
                                p.print('[');
                            }
                            p.print(quote);
                            p.printUTF8StringEscapedQuotes(key.utf8, quote);
                            p.print(quote);
                            if (quote == '`') {
                                p.print(']');
                            }
                        }

                        // Use a shorthand property if the names are the same
                        if (item.value) |val| {
                            switch (val.data) {
                                .e_identifier => |e| {

                                    // TODO: is needing to check item.flags.was_shorthand a bug?
                                    // esbuild doesn't have to do that...
                                    // maybe it's a symptom of some other underlying issue
                                    // or maybe, it's because i'm not lowering the same way that esbuild does.
                                    if (strings.eql(key.utf8, p.renamer.nameForSymbol(e.ref))) {
                                        if (item.initializer) |initial| {
                                            p.printInitializer(initial);
                                        }
                                        if (allow_shorthand) {
                                            return;
                                        }
                                    }
                                    // if (strings) {}
                                },
                                .e_import_identifier => |e| {
                                    const ref = p.symbols.follow(e.ref);
                                    if (p.symbols.get(ref)) |symbol| {
                                        if (symbol.namespace_alias == null and strings.eql(key.utf8, p.renamer.nameForSymbol(e.ref))) {
                                            if (item.initializer) |initial| {
                                                p.printInitializer(initial);
                                            }
                                            if (allow_shorthand) {
                                                return;
                                            }
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    } else if (p.canPrintIdentifierUTF16(key.value)) {
                        p.printSpaceBeforeIdentifier();
                        p.printIdentifierUTF16(key.value) catch unreachable;

                        // Use a shorthand property if the names are the same
                        if (item.value) |val| {
                            switch (val.data) {
                                .e_identifier => |e| {

                                    // TODO: is needing to check item.flags.was_shorthand a bug?
                                    // esbuild doesn't have to do that...
                                    // maybe it's a symptom of some other underlying issue
                                    // or maybe, it's because i'm not lowering the same way that esbuild does.
                                    if (item.flags.was_shorthand or strings.utf16EqlString(key.value, p.renamer.nameForSymbol(e.ref))) {
                                        if (item.initializer) |initial| {
                                            p.printInitializer(initial);
                                        }
                                        return;
                                    }
                                    // if (strings) {}
                                },
                                .e_import_identifier => |e| {
                                    const ref = p.symbols.follow(e.ref);
                                    if (p.symbols.get(ref)) |symbol| {
                                        if (symbol.namespace_alias == null and strings.utf16EqlString(key.value, p.renamer.nameForSymbol(e.ref))) {
                                            if (item.initializer) |initial| {
                                                p.printInitializer(initial);
                                            }
                                            return;
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    } else {
                        const c = p.bestQuoteCharForString(key.value, false);
                        p.print(c);
                        p.printQuotedUTF16(key.value, c);
                        p.print(c);
                    }
                },
                else => {
                    p.printExpr(_key, .lowest, ExprFlag{});
                },
            }

            if (item.kind != .normal) {
                switch (item.value.?.data) {
                    .e_function => |func| {
                        p.printFunc(func.func);
                        return;
                    },
                    else => {},
                }
            }

            if (item.value) |val| {
                switch (val.data) {
                    .e_function => |f| {
                        if (item.flags.is_method) {
                            p.printFunc(f.func);

                            return;
                        }
                    },
                    else => {},
                }

                p.print(":");
                p.printSpace();
                p.printExpr(val, .comma, ExprFlag{});
            }

            if (item.initializer) |initial| {
                p.printInitializer(initial);
            }
        }

        pub fn printInitializer(p: *Printer, initial: Expr) void {
            p.printSpace();
            p.print("=");
            p.printSpace();
            p.printExpr(initial, .comma, ExprFlag.None());
        }

        pub fn printBinding(p: *Printer, binding: Binding) void {
            p.addSourceMapping(binding.loc);

            switch (binding.data) {
                .b_missing => {},
                .b_identifier => |b| {
                    p.printSymbol(b.ref);
                },
                .b_array => |b| {
                    p.print("[");
                    if (b.items.len > 0) {
                        if (!b.is_single_line) {
                            p.options.indent += 1;
                        }

                        for (b.items) |*item, i| {
                            if (i != 0) {
                                p.print(",");
                                if (b.is_single_line) {
                                    p.printSpace();
                                }
                            }

                            if (!b.is_single_line) {
                                p.printNewline();
                                p.printIndent();
                            }

                            const is_last = i + 1 == b.items.len;
                            if (b.has_spread and is_last) {
                                p.print("...");
                            }

                            p.printBinding(item.binding);

                            p.maybePrintDefaultBindingValue(item);

                            // Make sure there's a comma after trailing missing items
                            if (is_last) {
                                switch (item.binding.data) {
                                    .b_missing => {
                                        p.print(",");
                                    },
                                    else => {},
                                }
                            }
                        }

                        if (!b.is_single_line) {
                            p.options.unindent();
                            p.printNewline();
                            p.printIndent();
                        }
                    }

                    p.print("]");
                },
                .b_object => |b| {
                    p.print("{");
                    if (b.properties.len > 0) {
                        if (!b.is_single_line) {
                            p.options.indent += 1;
                        }

                        for (b.properties) |*property, i| {
                            if (i != 0) {
                                p.print(",");
                            }

                            if (b.is_single_line) {
                                p.printSpace();
                            } else {
                                p.printNewline();
                                p.printIndent();
                            }

                            if (property.flags.is_spread) {
                                p.print("...");
                            } else {
                                if (property.flags.is_computed) {
                                    p.print("[");
                                    p.printExpr(property.key, .comma, ExprFlag.None());
                                    p.print("]:");
                                    p.printSpace();

                                    p.printBinding(property.value);
                                    p.maybePrintDefaultBindingValue(property);
                                    continue;
                                }

                                switch (property.key.data) {
                                    .e_string => |str| {
                                        if (str.isUTF8()) {
                                            p.addSourceMapping(property.key.loc);
                                            p.printSpaceBeforeIdentifier();
                                            // Example case:
                                            //      const Menu = React.memo(function Menu({
                                            //          aria-label: ariaLabel,
                                            //              ^
                                            // That needs to be:
                                            //          "aria-label": ariaLabel,
                                            if (p.canPrintIdentifier(str.utf8)) {
                                                p.printIdentifier(str.utf8);

                                                // Use a shorthand property if the names are the same
                                                switch (property.value.data) {
                                                    .b_identifier => |id| {
                                                        if (str.eql(string, p.renamer.nameForSymbol(id.ref))) {
                                                            p.maybePrintDefaultBindingValue(property);
                                                            continue;
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            } else {
                                                p.printQuotedUTF8(str.utf8, false);
                                            }
                                        } else if (p.canPrintIdentifierUTF16(str.value)) {
                                            p.addSourceMapping(property.key.loc);
                                            p.printSpaceBeforeIdentifier();
                                            p.printIdentifierUTF16(str.value) catch unreachable;

                                            // Use a shorthand property if the names are the same
                                            switch (property.value.data) {
                                                .b_identifier => |id| {
                                                    if (strings.utf16EqlString(str.value, p.renamer.nameForSymbol(id.ref))) {
                                                        p.maybePrintDefaultBindingValue(property);
                                                        continue;
                                                    }
                                                },
                                                else => {},
                                            }
                                        } else {
                                            p.printExpr(property.key, .lowest, ExprFlag.None());
                                        }
                                    },
                                    else => {
                                        p.printExpr(property.key, .lowest, ExprFlag.None());
                                    },
                                }

                                p.print(":");
                                p.printSpace();
                            }

                            p.printBinding(property.value);
                            p.maybePrintDefaultBindingValue(property);
                        }

                        if (!b.is_single_line) {
                            p.options.unindent();
                            p.printNewline();
                            p.printIndent();
                        } else if (b.properties.len > 0) {
                            p.printSpace();
                        }
                    }
                    p.print("}");
                },
                else => {
                    Global.panic("Unexpected binding of type {s}", .{binding});
                },
            }
        }

        pub fn maybePrintDefaultBindingValue(p: *Printer, property: anytype) void {
            if (property.default_value) |default| {
                p.printSpace();
                p.print("=");
                p.printSpace();
                p.printExpr(default, .comma, ExprFlag.None());
            }
        }

        pub fn printStmt(p: *Printer, stmt: Stmt) !void {
            const prev_stmt_tag = p.prev_stmt_tag;

            // Give an extra newline for readaiblity
            defer {
                //
                if (std.meta.activeTag(stmt.data) != .s_import and prev_stmt_tag == .s_import) {
                    p.printNewline();
                }

                p.prev_stmt_tag = std.meta.activeTag(stmt.data);
            }

            p.addSourceMapping(stmt.loc);
            switch (stmt.data) {
                .s_comment => |s| {
                    p.printIndentedComment(s.text);
                },
                .s_function => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    const name = s.func.name orelse Global.panic("Internal error: expected func to have a name ref\n{s}", .{s});
                    const nameRef = name.ref orelse Global.panic("Internal error: expected func to have a name\n{s}", .{s});
                    if (s.func.flags.is_export) {
                        if (!rewrite_esm_to_cjs) {
                            p.print("export ");
                        }
                    }
                    if (s.func.flags.is_async) {
                        p.print("async ");
                    }
                    p.print("function");
                    if (s.func.flags.is_generator) {
                        p.print("*");
                        p.printSpace();
                    }

                    p.printSpace();
                    p.printSymbol(nameRef);
                    p.printFunc(s.func);

                    // if (rewrite_esm_to_cjs and s.func.flags.is_export) {
                    //     p.printSemicolonAfterStatement();
                    //     p.print("var ");
                    //     p.printSymbol(nameRef);
                    //     p.print(" = ");
                    //     p.printSymbol(nameRef);
                    //     p.printSemicolonAfterStatement();
                    // } else {
                    p.printNewline();
                    // }

                    if (rewrite_esm_to_cjs and s.func.flags.is_export) {
                        p.printIndent();
                        p.printBundledExport(p.renamer.nameForSymbol(nameRef), p.renamer.nameForSymbol(nameRef));
                        p.printSemicolonAfterStatement();
                    }
                },
                .s_class => |s| {
                    // Give an extra newline for readaiblity
                    if (prev_stmt_tag != .s_empty) {
                        p.printNewline();
                    }

                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    const nameRef = s.class.class_name.?.ref.?;
                    if (s.is_export) {
                        if (!rewrite_esm_to_cjs) {
                            p.print("export ");
                        }
                    }

                    p.print("class ");
                    p.printSymbol(nameRef);
                    p.printClass(s.class);

                    if (rewrite_esm_to_cjs and s.is_export) {
                        p.printSemicolonAfterStatement();
                    } else {
                        p.printNewline();
                    }

                    if (rewrite_esm_to_cjs) {
                        if (s.is_export) {
                            p.printIndent();
                            p.printBundledExport(p.renamer.nameForSymbol(nameRef), p.renamer.nameForSymbol(nameRef));
                            p.printSemicolonAfterStatement();
                        }
                    }
                },
                .s_empty => {
                    p.printIndent();
                    p.print(";");
                    p.printNewline();
                },
                .s_export_default => |s| {
                    // Give an extra newline for export default for readability
                    if (!prev_stmt_tag.isExportLike()) {
                        p.printNewline();
                    }

                    p.printIndent();
                    p.printSpaceBeforeIdentifier();

                    if (!is_inside_bundle) {
                        p.print("export default");
                    }

                    p.printSpace();

                    switch (s.value) {
                        .expr => |expr| {
                            // this is still necessary for JSON
                            if (is_inside_bundle) {
                                p.printModuleExportSymbol();
                                p.print(" = ");
                            }

                            // Functions and classes must be wrapped to avoid confusion with their statement forms
                            p.export_default_start = p.writer.written;
                            p.printExpr(expr, .comma, ExprFlag.None());
                            p.printSemicolonAfterStatement();
                            return;
                        },

                        .stmt => |s2| {
                            switch (s2.data) {
                                .s_function => |func| {
                                    p.printSpaceBeforeIdentifier();
                                    if (is_inside_bundle) {
                                        if (func.func.name == null) {
                                            p.printModuleExportSymbol();
                                            p.print(" = ");
                                        }
                                    }

                                    if (func.func.flags.is_async) {
                                        p.print("async ");
                                    }
                                    p.print("function");

                                    if (func.func.flags.is_generator) {
                                        p.print("*");
                                        p.printSpace();
                                    } else {
                                        p.maybePrintSpace();
                                    }

                                    if (func.func.name) |name| {
                                        p.printSymbol(name.ref.?);
                                    }

                                    p.printFunc(func.func);

                                    if (is_inside_bundle) {
                                        p.printSemicolonAfterStatement();

                                        if (func.func.name) |name| {
                                            p.printIndent();
                                            p.printBundledExport("default", p.renamer.nameForSymbol(name.ref.?));
                                            p.printSemicolonAfterStatement();
                                        }
                                    } else {
                                        p.printNewline();
                                    }
                                },
                                .s_class => |class| {
                                    p.printSpaceBeforeIdentifier();

                                    if (is_inside_bundle) {
                                        if (class.class.class_name == null) {
                                            p.printModuleExportSymbol();
                                            p.print(" = ");
                                        }
                                    }

                                    if (class.class.class_name) |name| {
                                        p.print("class ");
                                        p.printSymbol(name.ref orelse Global.panic("Internal error: Expected class to have a name ref\n{s}", .{class}));
                                    } else {
                                        p.print("class");
                                    }

                                    p.printClass(class.class);

                                    if (is_inside_bundle) {
                                        p.printSemicolonAfterStatement();

                                        if (class.class.class_name) |name| {
                                            p.printIndent();
                                            p.printBundledExport("default", p.renamer.nameForSymbol(name.ref.?));
                                            p.printSemicolonAfterStatement();
                                        }
                                    } else {
                                        p.printNewline();
                                    }
                                },
                                else => {
                                    Global.panic("Internal error: unexpected export default stmt data {s}", .{s});
                                },
                            }
                        },
                    }
                },
                .s_export_star => |s| {
                    if (is_inside_bundle) {
                        p.printIndent();
                        p.printSpaceBeforeIdentifier();

                        // module.exports.react = $react();
                        if (s.alias) |alias| {
                            p.printBundledRexport(alias.original_name, s.import_record_index);
                            p.printSemicolonAfterStatement();

                            return;
                            // module.exports = $react();
                        } else {
                            p.printSymbol(p.options.runtime_imports.__reExport.?.ref);
                            p.print("(");
                            p.printModuleExportSymbol();
                            p.print(",");

                            p.printLoadFromBundle(s.import_record_index);

                            p.print(")");
                            p.printSemicolonAfterStatement();
                            return;
                        }
                    }

                    // Give an extra newline for readaiblity
                    if (!prev_stmt_tag.isExportLike()) {
                        p.printNewline();
                    }
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("export");
                    p.printSpace();
                    p.print("*");
                    p.printSpace();
                    if (s.alias) |alias| {
                        p.print("as");
                        p.printSpace();
                        p.printClauseAlias(alias.original_name);
                        p.printSpace();
                        p.printSpaceBeforeIdentifier();
                    }
                    p.print("from");
                    p.printSpace();
                    p.printQuotedUTF8(p.import_records[s.import_record_index].path.text, false);
                    p.printSemicolonAfterStatement();
                },
                .s_export_clause => |s| {
                    if (rewrite_esm_to_cjs) {
                        p.printIndent();
                        p.printSpaceBeforeIdentifier();

                        switch (s.items.len) {
                            0 => {},
                            // It unfortunately cannot be so simple as exports.foo = foo;
                            // If we have a lazy re-export and it's read-only...
                            // we have to overwrite it via Object.defineProperty
                            1 => {
                                const item = s.items[0];
                                const identifier = p.renamer.nameForSymbol(item.name.ref.?);
                                const name = if (!strings.eql(identifier, item.alias))
                                    item.alias
                                else
                                    identifier;
                                p.printBundledExport(name, identifier);
                                p.printSemicolonAfterStatement();
                            },

                            // Object.assign(__export, {prop1, prop2, prop3});
                            else => {
                                if (comptime is_inside_bundle) {
                                    p.printSymbol(p.options.runtime_imports.__export.?.ref);
                                } else {
                                    p.print("Object.assign");
                                }

                                p.print("(");
                                p.printModuleExportSymbol();
                                p.print(", {");
                                const last = s.items.len - 1;
                                for (s.items) |item, i| {
                                    const symbol = p.symbols.getWithLink(item.name.ref.?).?;
                                    const name = symbol.original_name;
                                    var did_print = false;

                                    if (symbol.namespace_alias) |namespace| {
                                        const import_record = p.import_records[namespace.import_record_index];
                                        if (import_record.is_bundled or (comptime is_inside_bundle) or namespace.was_originally_property_access) {
                                            p.printIdentifier(name);
                                            p.print(": () => ");
                                            p.printNamespaceAlias(import_record, namespace);
                                            did_print = true;
                                        }
                                    }

                                    if (!did_print) {
                                        p.printClauseAlias(item.alias);
                                        if (comptime is_inside_bundle) {
                                            p.print(":");
                                            p.printSpace();
                                            p.print("() => ");

                                            p.printIdentifier(name);
                                        } else if (!strings.eql(name, item.alias)) {
                                            p.print(":");
                                            p.printSpace();
                                            p.printIdentifier(name);
                                        }
                                    }

                                    if (i < last) {
                                        p.print(",");
                                    }
                                }
                                p.print("})");
                                p.printSemicolonAfterStatement();
                            },
                        }
                        return;
                    }

                    // Give an extra newline for export default for readability
                    if (!prev_stmt_tag.isExportLike()) {
                        p.printNewline();
                    }

                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("export");
                    p.printSpace();

                    // This transforms code like this:
                    // import {Foo, Bar} from 'bundled-module';
                    // export {Foo, Bar};
                    // into
                    // export var Foo = $$bundledModule.Foo; (where $$bundledModule is created at import time)
                    // This is necessary unfortunately because export statements do not allow dot expressions
                    // The correct approach here is to invert the logic
                    // instead, make the entire module behave like a CommonJS module
                    // and export that one instead
                    // This particular code segment does the transform inline by adding an extra pass over export clauses
                    // and then swapRemove'ing them as we go
                    var array = std.ArrayListUnmanaged(js_ast.ClauseItem){ .items = s.items, .capacity = s.items.len };
                    {
                        var i: usize = 0;
                        while (i < array.items.len) {
                            const item: js_ast.ClauseItem = array.items[i];

                            if (item.original_name.len > 0) {
                                if (p.symbols.get(item.name.ref.?)) |symbol| {
                                    if (symbol.namespace_alias) |namespace| {
                                        const import_record = p.import_records[namespace.import_record_index];
                                        if (import_record.is_bundled or (comptime is_inside_bundle) or namespace.was_originally_property_access) {
                                            p.print("var ");
                                            p.printSymbol(item.name.ref.?);
                                            p.print(" = ");
                                            p.printNamespaceAlias(import_record, namespace);
                                            p.printSemicolonAfterStatement();
                                            _ = array.swapRemove(i);

                                            if (i < array.items.len) {
                                                p.printIndent();
                                                p.printSpaceBeforeIdentifier();
                                                p.print("export");
                                                p.printSpace();
                                            }

                                            continue;
                                        }
                                    }
                                }
                            }

                            i += 1;
                        }

                        if (array.items.len == 0) {
                            return;
                        }

                        s.items = array.items;
                    }

                    p.print("{");

                    if (!s.is_single_line) {
                        p.options.indent += 1;
                    }

                    for (s.items) |*item, i| {
                        if (i != 0) {
                            p.print(",");
                            if (s.is_single_line) {
                                p.printSpace();
                            }
                        }

                        if (!s.is_single_line) {
                            p.printNewline();
                            p.printIndent();
                        }

                        const name = p.renamer.nameForSymbol(item.name.ref.?);
                        p.printIdentifier(name);
                        if (!strings.eql(name, item.alias)) {
                            p.print(" as");
                            p.printSpace();
                            p.printClauseAlias(item.alias);
                        }
                    }

                    if (!s.is_single_line) {
                        p.options.unindent();
                        p.printNewline();
                        p.printIndent();
                    }

                    p.print("}");
                    p.printSemicolonAfterStatement();
                },
                .s_export_from => |s| {
                    if (is_inside_bundle) {

                        // $$lz(export, $React(), {default: "React"});
                        if (s.items.len == 1) {
                            const item = s.items[0];
                            p.printSymbol(p.options.runtime_imports.@"$$lzy".?.ref);
                            p.print("(");
                            p.printModuleExportSymbol();
                            p.print(",");
                            // Avoid initializing an entire component library because you imported one icon
                            p.printLoadFromBundleWithoutCall(s.import_record_index);
                            p.print(",{");
                            p.printClauseAlias(item.alias);
                            p.print(":");
                            const name = p.renamer.nameForSymbol(item.name.ref.?);
                            p.printQuotedUTF8(name, true);
                            p.print("})");

                            p.printSemicolonAfterStatement();
                            // $$lz(export, $React(), {createElement: "React"});
                        } else {
                            p.printSymbol(p.options.runtime_imports.@"$$lzy".?.ref);
                            p.print("(");
                            p.printModuleExportSymbol();
                            p.print(",");

                            // Avoid initializing an entire component library because you imported one icon
                            p.printLoadFromBundleWithoutCall(s.import_record_index);
                            p.print(",{");
                            for (s.items) |item, i| {
                                p.printClauseAlias(item.alias);
                                p.print(":");
                                p.printQuotedUTF8(p.renamer.nameForSymbol(item.name.ref.?), true);
                                if (i < s.items.len - 1) {
                                    p.print(",");
                                }
                            }
                            p.print("})");
                            p.printSemicolonAfterStatement();
                        }

                        return;
                    }
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("export");
                    p.printSpace();
                    p.print("{");

                    if (!s.is_single_line) {
                        p.options.indent += 1;
                    }

                    for (s.items) |*item, i| {
                        if (i != 0) {
                            p.print(",");
                            if (s.is_single_line) {
                                p.printSpace();
                            }
                        }

                        if (!s.is_single_line) {
                            p.printNewline();
                            p.printIndent();
                        }
                        const name = p.renamer.nameForSymbol(item.name.ref.?);
                        p.printIdentifier(name);
                        if (!strings.eql(name, item.alias)) {
                            p.print(" as");
                            p.printSpace();
                            p.printClauseAlias(item.alias);
                        }
                    }

                    if (!s.is_single_line) {
                        p.options.unindent();
                        p.printNewline();
                        p.printIndent();
                    }

                    p.print("}");
                    p.printSpace();
                    p.print("from");
                    p.printSpace();
                    p.printQuotedUTF8(p.import_records[s.import_record_index].path.text, false);
                    p.printSemicolonAfterStatement();
                },
                .s_local => |s| {
                    switch (s.kind) {
                        .k_const => {
                            p.printDeclStmt(s.is_export, "const", s.decls);
                        },
                        .k_let => {
                            p.printDeclStmt(s.is_export, "let", s.decls);
                        },
                        .k_var => {
                            p.printDeclStmt(s.is_export, "var", s.decls);
                        },
                    }
                },
                .s_if => |s| {
                    p.printIndent();
                    p.printIf(s);
                },
                .s_do_while => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("do");
                    switch (s.body.data) {
                        .s_block => {
                            p.printSpace();
                            p.printBlock(s.body.loc, s.body.data.s_block.stmts);
                            p.printSpace();
                        },
                        else => {
                            p.printNewline();
                            p.options.indent += 1;
                            p.printStmt(s.body) catch unreachable;
                            p.printSemicolonIfNeeded();
                            p.options.unindent();
                            p.printIndent();
                        },
                    }

                    p.print("while");
                    p.printSpace();
                    p.print("(");
                    p.printExpr(s.test_, .lowest, ExprFlag.None());
                    p.print(")");
                    p.printSemicolonAfterStatement();
                },
                .s_for_in => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("for");
                    p.printSpace();
                    p.print("(");
                    p.printForLoopInit(s.init);
                    p.printSpace();
                    p.printSpaceBeforeIdentifier();
                    p.print("in");
                    p.printSpace();
                    p.printExpr(s.value, .lowest, ExprFlag.None());
                    p.print(")");
                    p.printBody(s.body);
                },
                .s_for_of => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("for");
                    if (s.is_await) {
                        p.print(" await");
                    }
                    p.printSpace();
                    p.print("(");
                    p.for_of_init_start = p.writer.written;
                    p.printForLoopInit(s.init);
                    p.printSpace();
                    p.printSpaceBeforeIdentifier();
                    p.print("of");
                    p.printSpace();
                    p.printExpr(s.value, .comma, ExprFlag.None());
                    p.print(")");
                    p.printBody(s.body);
                },
                .s_while => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("while");
                    p.printSpace();
                    p.print("(");
                    p.printExpr(s.test_, .lowest, ExprFlag.None());
                    p.print(")");
                    p.printBody(s.body);
                },
                .s_with => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("with");
                    p.printSpace();
                    p.print("(");
                    p.printExpr(s.value, .lowest, ExprFlag.None());
                    p.print(")");
                    p.printBody(s.body);
                },
                .s_label => |s| {
                    p.printIndent();
                    p.printSymbol(s.name.ref orelse Global.panic("Internal error: expected label to have a name {s}", .{s}));
                    p.print(":");
                    p.printBody(s.stmt);
                },
                .s_try => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("try");
                    p.printSpace();
                    p.printBlock(s.body_loc, s.body);

                    if (s.catch_) |catch_| {
                        p.printSpace();
                        p.print("catch");
                        if (catch_.binding) |binding| {
                            p.printSpace();
                            p.print("(");
                            p.printBinding(binding);
                            p.print(")");
                        }
                        p.printSpace();
                        p.printBlock(catch_.loc, catch_.body);
                    }

                    if (s.finally) |finally| {
                        p.printSpace();
                        p.print("finally");
                        p.printSpace();
                        p.printBlock(finally.loc, finally.stmts);
                    }

                    p.printNewline();
                },
                .s_for => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("for");
                    p.printSpace();
                    p.print("(");

                    if (s.init) |init_| {
                        p.printForLoopInit(init_);
                    }

                    p.print(";");

                    if (s.test_) |test_| {
                        p.printExpr(test_, .lowest, ExprFlag.None());
                    }

                    p.print(";");
                    p.printSpace();

                    if (s.update) |update| {
                        p.printExpr(update, .lowest, ExprFlag.None());
                    }

                    p.print(")");
                    p.printBody(s.body);
                },
                .s_switch => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("switch");
                    p.printSpace();
                    p.print("(");

                    p.printExpr(s.test_, .lowest, ExprFlag.None());

                    p.print(")");
                    p.printSpace();
                    p.print("{");
                    p.printNewline();
                    p.options.indent += 1;

                    for (s.cases) |c| {
                        p.printSemicolonIfNeeded();
                        p.printIndent();

                        if (c.value) |val| {
                            p.print("case");
                            p.printSpace();
                            p.printExpr(val, .logical_and, ExprFlag.None());
                        } else {
                            p.print("default");
                        }

                        p.print(":");

                        if (c.body.len == 1) {
                            switch (c.body[0].data) {
                                .s_block => {
                                    p.printSpace();
                                    p.printBlock(c.body[0].loc, c.body[0].data.s_block.stmts);
                                    p.printNewline();
                                    continue;
                                },
                                else => {},
                            }
                        }

                        p.printNewline();
                        p.options.indent += 1;
                        for (c.body) |st| {
                            p.printSemicolonIfNeeded();
                            p.printStmt(st) catch unreachable;
                        }
                        p.options.unindent();
                    }

                    p.options.unindent();
                    p.printIndent();
                    p.print("}");
                    p.printNewline();
                    p.needs_semicolon = false;
                },
                .s_import => |s| {

                    // TODO: check loader instead
                    switch (p.import_records[s.import_record_index].print_mode) {
                        .css => {
                            switch (p.options.css_import_behavior) {
                                .facade => {

                                    // This comment exists to let tooling authors know which files CSS originated from
                                    // To parse this, you just look for a line that starts with //@import url("
                                    p.print("//@import url(\"");
                                    // We do not URL escape here.
                                    p.print(p.import_records[s.import_record_index].path.text);

                                    // If they actually use the code, then we emit a facade that just echos whatever they write
                                    if (s.default_name) |name| {
                                        p.print("\"); css-module-facade\nvar ");
                                        p.printSymbol(name.ref.?);
                                        p.print(" = new Proxy({}, {get(_,className,__){return className;}});\n");
                                    } else {
                                        p.print("\"); css-import-facade\n");
                                    }

                                    return;
                                },

                                .auto_onimportcss, .facade_onimportcss => {
                                    p.print("globalThis.document?.dispatchEvent(new CustomEvent(\"onimportcss\", {detail: \"");
                                    p.print(p.import_records[s.import_record_index].path.text);
                                    p.print("\"}));\n");

                                    // If they actually use the code, then we emit a facade that just echos whatever they write
                                    if (s.default_name) |name| {
                                        p.print("var ");
                                        p.printSymbol(name.ref.?);
                                        p.print(" = new Proxy({}, {get(_,className,__){return className;}});\n");
                                    }
                                },
                                else => {},
                            }
                            return;
                        },
                        .import_path => {
                            if (s.default_name) |name| {
                                const quotes = p.bestQuoteCharForString(p.import_records[s.import_record_index].path.text, true);

                                p.print("var ");
                                p.printSymbol(name.ref.?);
                                p.print(" = ");
                                p.print(quotes);
                                p.printUTF8StringEscapedQuotes(p.import_records[s.import_record_index].path.text, quotes);
                                p.print(quotes);
                                p.printSemicolonAfterStatement();
                            }
                            return;
                        },
                        else => {},
                    }

                    const record = p.import_records[s.import_record_index];
                    var item_count: usize = 0;

                    p.printIndent();
                    p.printSpaceBeforeIdentifier();

                    if (record.path.isBun() and strings.eqlComptime(record.path.text, "test")) {
                        p.printBunJestImportStatement(s.*);
                        return;
                    }

                    if (is_inside_bundle) {
                        return p.printBundledImport(record, s);
                    }

                    if (record.wrap_with_to_module) {
                        const require_ref = p.options.require_ref.?;

                        const module_id = record.module_id;

                        if (std.mem.indexOfScalar(u32, p.imported_module_ids.items, module_id) == null) {
                            p.print("import * as ");
                            p.printModuleId(module_id);
                            p.print(" from \"");
                            p.print(record.path.text);
                            p.print("\";\n");
                            try p.imported_module_ids.append(module_id);
                        }

                        if (record.contains_import_star) {
                            p.print("var ");
                            p.printSymbol(s.namespace_ref);
                            p.print(" = ");
                            p.printSymbol(require_ref);
                            p.print("(");
                            p.printModuleId(module_id);

                            p.print(");\n");
                        }

                        if (s.items.len > 0 or s.default_name != null) {
                            p.printIndent();
                            p.printSpaceBeforeIdentifier();
                            p.print("var { ");

                            if (s.default_name) |default_name| {
                                p.print("default: ");
                                p.printSymbol(default_name.ref.?);

                                if (s.items.len > 0) {
                                    p.print(", ");
                                    for (s.items) |item, i| {
                                        p.print(item.alias);
                                        const name = p.renamer.nameForSymbol(item.name.ref.?);

                                        if (!strings.eql(name, item.alias)) {
                                            p.print(": ");
                                            p.printSymbol(item.name.ref.?);
                                        }

                                        if (i < s.items.len - 1) {
                                            p.print(", ");
                                        }
                                    }
                                }
                            } else {
                                for (s.items) |item, i| {
                                    p.print(item.alias);
                                    const name = p.renamer.nameForSymbol(item.name.ref.?);
                                    if (!strings.eql(name, item.alias)) {
                                        p.print(":");
                                        p.printSymbol(item.name.ref.?);
                                    }

                                    if (i < s.items.len - 1) {
                                        p.print(", ");
                                    }
                                }
                            }

                            p.print("} = ");

                            if (record.contains_import_star) {
                                p.printSymbol(s.namespace_ref);
                                p.print(";\n");
                            } else {
                                p.printSymbol(require_ref);
                                p.print("(");
                                p.printModuleId(module_id);
                                p.print(");\n");
                            }
                        }

                        return;
                    } else if (record.is_bundled) {
                        if (!record.path.is_disabled) {
                            if (!p.has_printed_bundled_import_statement) {
                                p.has_printed_bundled_import_statement = true;
                                p.print("import {");

                                const last = p.import_records.len - 1;
                                var needs_comma = false;
                                // This might be a determinsim issue
                                // But, it's not random
                                skip: for (p.import_records) |_record, i| {
                                    if (!_record.is_bundled or _record.module_id == 0) continue;

                                    if (i < last) {
                                        // Prevent importing the same module ID twice
                                        // We could use a map but we want to avoid allocating
                                        // and this should be pretty quick since it's just comparing a uint32
                                        for (p.import_records[i + 1 ..]) |_record2| {
                                            if (_record2.is_bundled and _record2.module_id > 0 and _record2.module_id == _record.module_id) {
                                                continue :skip;
                                            }
                                        }
                                    }

                                    if (needs_comma) p.print(", ");
                                    p.printLoadFromBundleWithoutCall(@truncate(u32, i));
                                    needs_comma = true;
                                }

                                p.print("} from ");

                                p.printQuotedUTF8(record.path.text, false);
                                p.printSemicolonAfterStatement();
                            }
                        } else {
                            p.print("var ");

                            p.printLoadFromBundleWithoutCall(s.import_record_index);

                            p.print(" = () => ({default: {}});\n");
                        }

                        p.printBundledImport(record, s);
                        return;
                    }

                    if (record.handles_import_errors and record.path.is_disabled and record.kind.isCommonJS()) {
                        return;
                    }

                    p.print("import");
                    p.printSpace();

                    if (s.default_name) |name| {
                        p.printSymbol(name.ref.?);
                        item_count += 1;
                    }

                    if (s.items.len > 0) {
                        if (item_count > 0) {
                            p.print(",");
                            p.printSpace();
                        }

                        p.print("{");
                        if (!s.is_single_line) {
                            p.options.unindent();
                        }

                        for (s.items) |*item, i| {
                            if (i != 0) {
                                p.print(",");
                                if (s.is_single_line) {
                                    p.printSpace();
                                }
                            }

                            if (!s.is_single_line) {
                                p.printNewline();
                                p.printIndent();
                            }

                            p.printClauseAlias(item.alias);
                            const name = p.renamer.nameForSymbol(item.name.ref.?);
                            if (!strings.eql(name, item.alias)) {
                                p.printSpace();
                                p.printSpaceBeforeIdentifier();
                                p.print("as ");
                                p.printIdentifier(name);
                            }
                        }

                        if (!s.is_single_line) {
                            p.options.unindent();
                            p.printNewline();
                            p.printIndent();
                        }
                        p.print("}");
                        item_count += 1;
                    }

                    if (s.star_name_loc != null) {
                        if (item_count > 0) {
                            p.print(",");
                            p.printSpace();
                        }

                        p.print("*");
                        p.printSpace();
                        p.print("as ");
                        p.printSymbol(s.namespace_ref);
                        item_count += 1;
                    }

                    if (item_count > 0) {
                        p.printSpace();
                        p.printSpaceBeforeIdentifier();
                        p.print("from");
                        p.printSpace();
                    }

                    p.printQuotedUTF8(p.import_records[s.import_record_index].path.text, false);
                    p.printSemicolonAfterStatement();
                },
                .s_block => |s| {
                    p.printIndent();
                    p.printBlock(stmt.loc, s.stmts);
                    p.printNewline();
                },
                .s_debugger => {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("debugger");
                    p.printSemicolonAfterStatement();
                },
                .s_directive => |s| {
                    const c = p.bestQuoteCharForString(s.value, false);
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print(c);
                    p.printQuotedUTF16(s.value, c);
                    p.print(c);
                    p.printSemicolonAfterStatement();
                },
                .s_break => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("break");
                    if (s.label) |label| {
                        p.print(" ");
                        p.printSymbol(label.ref.?);
                    }

                    p.printSemicolonAfterStatement();
                },
                .s_continue => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("continue");

                    if (s.label) |label| {
                        p.print(" ");
                        p.printSymbol(label.ref.?);
                    }
                    p.printSemicolonAfterStatement();
                },
                .s_return => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("return");

                    if (s.value) |value| {
                        p.printSpace();
                        p.printExpr(value, .lowest, ExprFlag.None());
                    }
                    p.printSemicolonAfterStatement();
                },
                .s_throw => |s| {
                    p.printIndent();
                    p.printSpaceBeforeIdentifier();
                    p.print("throw");
                    p.printSpace();
                    p.printExpr(s.value, .lowest, ExprFlag.None());
                    p.printSemicolonAfterStatement();
                },
                .s_expr => |s| {
                    p.printIndent();
                    p.stmt_start = p.writer.written;
                    p.printExpr(s.value, .lowest, ExprFlag.ExprResultIsUnused());
                    p.printSemicolonAfterStatement();
                },
                else => {
                    var slice = p.writer.slice();
                    const to_print: []const u8 = if (slice.len > 1024) slice[slice.len - 1024 ..] else slice;

                    if (to_print.len > 0) {
                        Global.panic("\n<r><red>voluntary crash<r> while printing:<r>\n{s}\n---This is a <b>bug<r>. Not your fault.\n", .{to_print});
                    } else {
                        Global.panic("\n<r><red>voluntary crash<r> while printing. This is a <b>bug<r>. Not your fault.\n", .{});
                    }
                },
            }
        }

        pub inline fn printModuleExportSymbol(p: *Printer) void {
            p.print("module.exports");
        }

        pub fn printBundledImport(p: *Printer, record: importRecord.ImportRecord, s: *S.Import) void {
            if (record.is_internal) {
                return;
            }

            const import_record = p.import_records[s.import_record_index];
            const is_disabled = import_record.path.is_disabled;
            const module_id = import_record.module_id;

            switch (ImportVariant.determine(&record, p.symbols.get(s.namespace_ref).?, s)) {
                .path_only => {
                    if (!is_disabled) {
                        p.printCallModuleID(module_id);
                        p.printSemicolonAfterStatement();
                    }
                },
                .import_items_and_default, .import_default => {
                    if (!is_disabled) {
                        p.print("var $");
                        p.printModuleId(module_id);
                        p.print(" = ");
                        p.printLoadFromBundle(s.import_record_index);

                        if (s.default_name) |default_name| {
                            p.print(", ");
                            p.printSymbol(default_name.ref.?);
                            p.print(" = ");

                            p.print("(\"default\" in $");
                            p.printModuleId(module_id);
                            p.print(" ? $");
                            p.printModuleId(module_id);
                            p.print(".default : $");
                            p.printModuleId(module_id);
                            p.print(")");
                        }
                    } else {
                        if (s.default_name) |default_name| {
                            p.print("var ");
                            p.printSymbol(default_name.ref.?);
                            p.print(" = ");
                            p.printDisabledImport();
                        }
                    }

                    p.printSemicolonAfterStatement();
                },
                .import_star_and_import_default => {
                    p.print("var ");
                    p.printSymbol(s.namespace_ref);
                    p.print(" = ");
                    p.printLoadFromBundle(s.import_record_index);

                    if (s.default_name) |default_name| {
                        p.print(", ");
                        p.printSymbol(default_name.ref.?);
                        p.print(" = ");

                        if (!bun) {
                            p.print("(\"default\" in ");
                            p.printSymbol(s.namespace_ref);
                            p.print(" ? ");
                            p.printSymbol(s.namespace_ref);
                            p.print(".default : ");
                            p.printSymbol(s.namespace_ref);
                            p.print(")");
                        } else {
                            p.printSymbol(s.namespace_ref);
                        }
                    }
                    p.printSemicolonAfterStatement();
                },
                .import_star => {
                    p.print("var ");
                    p.printSymbol(s.namespace_ref);
                    p.print(" = ");
                    p.printLoadFromBundle(s.import_record_index);
                    p.printSemicolonAfterStatement();
                },

                else => {
                    p.print("var $");
                    p.printModuleIdAssumeEnabled(module_id);
                    p.print(" = ");
                    p.printLoadFromBundle(s.import_record_index);
                    p.printSemicolonAfterStatement();
                },
            }
        }
        pub fn printLoadFromBundle(p: *Printer, import_record_index: u32) void {
            if (bun) {
                const record = p.import_records[import_record_index];
                p.print("module.require(\"");
                p.print(record.path.text);
                p.print("\")");
            } else {
                p.printLoadFromBundleWithoutCall(import_record_index);
                p.print("()");
            }
        }

        inline fn printDisabledImport(p: *Printer) void {
            p.print("(() => ({}))");
        }

        pub fn printLoadFromBundleWithoutCall(p: *Printer, import_record_index: u32) void {
            const record = p.import_records[import_record_index];
            if (record.path.is_disabled) {
                p.printDisabledImport();
                return;
            }

            @call(.{ .modifier = .always_inline }, printModuleId, .{ p, p.import_records[import_record_index].module_id });
        }

        pub fn printCallModuleID(p: *Printer, module_id: u32) void {
            printModuleId(p, module_id);
            p.print("()");
        }

        inline fn printModuleId(p: *Printer, module_id: u32) void {
            std.debug.assert(module_id != 0); // either module_id is forgotten or it should be disabled
            p.printModuleIdAssumeEnabled(module_id);
        }

        inline fn printModuleIdAssumeEnabled(p: *Printer, module_id: u32) void {
            p.print("$");
            std.fmt.formatInt(module_id, 16, .lower, .{}, p) catch unreachable;
        }

        pub fn printBundledRequire(p: *Printer, require: E.Require) void {
            if (p.import_records[require.import_record_index].is_internal) {
                return;
            }

            // the require symbol may not exist in bundled code
            // it is included at the top of the file.
            if (comptime is_inside_bundle) {
                p.print("__require");
            } else {
                p.printSymbol(p.options.runtime_imports.__require.?.ref);
            }

            // d is for default
            p.print(".d(");
            p.printLoadFromBundle(require.import_record_index);
            p.print(")");
        }

        pub fn printBundledRexport(p: *Printer, name: string, import_record_index: u32) void {
            p.print("Object.defineProperty(");
            p.printModuleExportSymbol();
            p.print(",");
            p.printQuotedUTF8(name, true);

            p.print(",{get: () => (");
            p.printLoadFromBundle(import_record_index);
            p.print("), enumerable: true, configurable: true})");
        }

        // We must use Object.defineProperty() to handle re-exports from ESM -> CJS
        // Here is an example where a runtime error occurs when assigning directly to module.exports
        // > 24077 |   module.exports.init = init;
        // >       ^
        // >  TypeError: Attempted to assign to readonly property.
        pub fn printBundledExport(p: *Printer, name: string, identifier: string) void {
            // In the event that
            p.print("Object.defineProperty(");
            p.printModuleExportSymbol();
            p.print(",");
            p.printQuotedUTF8(name, true);
            p.print(",{get: () => ");
            p.printIdentifier(identifier);
            p.print(", enumerable: true, configurable: true})");
        }

        pub fn printForLoopInit(p: *Printer, initSt: Stmt) void {
            switch (initSt.data) {
                .s_expr => |s| {
                    p.printExpr(
                        s.value,
                        .lowest,
                        ExprFlag{ .forbid_in = true, .expr_result_is_unused = true },
                    );
                },
                .s_local => |s| {
                    switch (s.kind) {
                        .k_var => {
                            p.printDecls("var", s.decls, ExprFlag{ .forbid_in = true });
                        },
                        .k_let => {
                            p.printDecls("let", s.decls, ExprFlag{ .forbid_in = true });
                        },
                        .k_const => {
                            p.printDecls("const", s.decls, ExprFlag{ .forbid_in = true });
                        },
                    }
                },
                else => {
                    Global.panic("Internal error: Unexpected stmt in for loop {s}", .{initSt});
                },
            }
        }
        pub fn printIf(p: *Printer, s: *const S.If) void {
            p.printSpaceBeforeIdentifier();
            p.print("if");
            p.printSpace();
            p.print("(");
            p.printExpr(s.test_, .lowest, ExprFlag.None());
            p.print(")");

            switch (s.yes.data) {
                .s_block => |block| {
                    p.printSpace();
                    p.printBlock(s.yes.loc, block.stmts);

                    if (s.no != null) {
                        p.printSpace();
                    } else {
                        p.printNewline();
                    }
                },
                else => {
                    if (wrapToAvoidAmbiguousElse(&s.yes.data)) {
                        p.printSpace();
                        p.print("{");
                        p.printNewline();

                        p.options.indent += 1;
                        p.printStmt(s.yes) catch unreachable;
                        p.options.unindent();
                        p.needs_semicolon = false;

                        p.printIndent();
                        p.print("}");

                        if (s.no != null) {
                            p.printSpace();
                        } else {
                            p.printNewline();
                        }
                    } else {
                        p.printNewline();
                        p.options.indent += 1;
                        p.printStmt(s.yes) catch unreachable;
                        p.options.unindent();

                        if (s.no != null) {
                            p.printIndent();
                        }
                    }
                },
            }

            if (s.no) |no_block| {
                p.printSemicolonIfNeeded();
                p.printSpaceBeforeIdentifier();
                p.print("else");

                switch (no_block.data) {
                    .s_block => {
                        p.printSpace();
                        p.printBlock(no_block.loc, no_block.data.s_block.stmts);
                        p.printNewline();
                    },
                    .s_if => {
                        p.printIf(no_block.data.s_if);
                    },
                    else => {
                        p.printNewline();
                        p.options.indent += 1;
                        p.printStmt(no_block) catch unreachable;
                        p.options.unindent();
                    },
                }
            }
        }

        pub fn wrapToAvoidAmbiguousElse(s_: *const Stmt.Data) bool {
            var s = s_;
            while (true) {
                switch (s.*) {
                    .s_if => |index| {
                        if (index.no) |*no| {
                            s = &no.data;
                        } else {
                            return true;
                        }
                    },
                    .s_for => |current| {
                        s = &current.body.data;
                    },
                    .s_for_in => |current| {
                        s = &current.body.data;
                    },
                    .s_for_of => |current| {
                        s = &current.body.data;
                    },
                    .s_while => |current| {
                        s = &current.body.data;
                    },
                    .s_with => |current| {
                        s = &current.body.data;
                    },
                    else => {
                        return false;
                    },
                }
            }
        }

        pub fn printDeclStmt(p: *Printer, is_export: bool, comptime keyword: string, decls: []G.Decl) void {
            if (rewrite_esm_to_cjs and keyword[0] == 'v' and is_export and is_inside_bundle) {
                // this is a top-level export
                if (decls.len == 1 and
                    std.meta.activeTag(decls[0].binding.data) == .b_identifier and
                    decls[0].binding.data.b_identifier.ref.eql(p.options.bundle_export_ref.?))
                {
                    p.print("// ");
                    p.print(p.options.source_path.?.pretty);
                    p.print("\nexport var $");
                    std.fmt.formatInt(p.options.module_hash, 16, .lower, .{}, p) catch unreachable;
                    p.print(" = ");
                    p.printExpr(decls[0].value.?, .comma, ExprFlag.None());
                    p.printSemicolonAfterStatement();
                    return;
                }
            }

            p.printIndent();
            p.printSpaceBeforeIdentifier();

            if (!rewrite_esm_to_cjs and is_export) {
                p.print("export ");
            }
            p.printDecls(keyword, decls, ExprFlag.None());
            p.printSemicolonAfterStatement();
            if (rewrite_esm_to_cjs and is_export and decls.len > 0) {
                p.printIndent();
                p.printSpaceBeforeIdentifier();
                p.print("Object.defineProperties(");
                p.printModuleExportSymbol();
                p.print(",{");
                for (decls) |decl, i| {
                    p.print("'");
                    p.printBinding(decl.binding);
                    p.print("': {get: () => ");
                    p.printBinding(decl.binding);

                    if (comptime !strings.eqlComptime(keyword, "const")) {
                        p.print(", set: ($_newValue) => {");
                        p.printBinding(decl.binding);
                        p.print(" = $_newValue;}");
                    }

                    p.print(", enumerable: true, configurable: true}");

                    if (i < decls.len - 1) {
                        p.print(",\n");
                    }
                }
                p.print("})");
                p.printSemicolonAfterStatement();
            }
        }

        pub fn printIdentifier(p: *Printer, identifier: string) void {
            if (comptime ascii_only) {
                p.printQuotedIdentifier(identifier);
            } else {
                p.print(identifier);
            }
        }

        fn printQuotedIdentifier(p: *Printer, identifier: string) void {
            var ascii_start: usize = 0;
            var is_ascii = false;
            var iter = CodepointIterator.init(identifier);
            var cursor = CodepointIterator.Cursor{};
            while (iter.next(&cursor)) {
                switch (cursor.c) {
                    first_ascii...last_ascii => {
                        if (!is_ascii) {
                            ascii_start = cursor.i;
                            is_ascii = true;
                        }
                    },
                    else => {
                        if (is_ascii) {
                            p.print(identifier[ascii_start..cursor.i]);
                            is_ascii = false;
                        }

                        switch (cursor.c) {
                            0...0xFFFF => {
                                p.print([_]u8{
                                    '\\',
                                    'u',
                                    hex_chars[cursor.c >> 12],
                                    hex_chars[(cursor.c >> 8) & 15],
                                    hex_chars[(cursor.c >> 4) & 15],
                                    hex_chars[cursor.c & 15],
                                });
                            },
                            else => {
                                p.print("\\u{");
                                std.fmt.formatInt(cursor.c, 16, .lower, .{}, p) catch unreachable;
                                p.print("}");
                            },
                        }
                    },
                }
            }

            if (is_ascii) {
                p.print(identifier[ascii_start..]);
            }
        }

        pub fn printIdentifierUTF16(p: *Printer, name: []const u16) !void {
            const n = name.len;
            var i: usize = 0;

            const CodeUnitType = u32;
            while (i < n) {
                var c: CodeUnitType = name[i];
                i += 1;

                if (c & ~@as(CodeUnitType, 0x03ff) == 0xd800 and i < n) {
                    c = 0x10000 + (((c & 0x03ff) << 10) | (name[i] & 0x03ff));
                    i += 1;
                }

                if ((comptime ascii_only) and c > last_ascii) {
                    switch (c) {
                        0...0xFFFF => {
                            p.print(
                                [_]u8{
                                    '\\',
                                    'u',
                                    hex_chars[c >> 12],
                                    hex_chars[(c >> 8) & 15],
                                    hex_chars[(c >> 4) & 15],
                                    hex_chars[c & 15],
                                },
                            );
                        },
                        else => {
                            p.print("\\u");
                            var buf_ptr = p.writer.reserve(4) catch unreachable;
                            p.writer.advance(strings.encodeWTF8RuneT(buf_ptr[0..4], CodeUnitType, c));
                        },
                    }
                    continue;
                }

                {
                    var buf_ptr = p.writer.reserve(4) catch unreachable;
                    p.writer.advance(strings.encodeWTF8RuneT(buf_ptr[0..4], CodeUnitType, c));
                }
            }
        }

        pub fn printIndentedComment(p: *Printer, _text: string) void {
            var text = _text;
            if (strings.startsWith(text, "/*")) {
                // Re-indent multi-line comments
                while (strings.indexOfChar(text, '\n')) |newline_index| {
                    p.printIndent();
                    p.print(text[0 .. newline_index + 1]);
                    text = text[newline_index + 1 ..];
                }
                p.printIndent();
                p.print(text);
                p.printNewline();
            } else {
                // Print a mandatory newline after single-line comments
                p.printIndent();
                p.print(text);
                p.print("\n");
            }
        }

        pub fn init(
            writer: Writer,
            tree: *const Ast,
            source: *const logger.Source,
            symbols: Symbol.Map,
            opts: Options,
            linker: ?*Linker,
        ) !Printer {
            if (imported_module_ids_list_unset) {
                imported_module_ids_list = std.ArrayList(u32).init(default_allocator);
                imported_module_ids_list_unset = false;
            }

            imported_module_ids_list.clearRetainingCapacity();

            return Printer{
                .import_records = tree.import_records,
                .options = opts,
                .symbols = symbols,
                .writer = writer,
                .linker = linker,
                .imported_module_ids = imported_module_ids_list,
                .renamer = rename.Renamer.init(symbols, source),
            };
        }
    };
}

pub fn NewWriter(
    comptime ContextType: type,
    writeByte: fn (ctx: *ContextType, char: u8) anyerror!usize,
    writeAllFn: fn (ctx: *ContextType, buf: anytype) anyerror!usize,
    getLastByte: fn (ctx: *const ContextType) u8,
    getLastLastByte: fn (ctx: *const ContextType) u8,
    reserveNext: fn (ctx: *ContextType, count: u32) anyerror![*]u8,
    advanceBy: fn (ctx: *ContextType, count: u32) void,
) type {
    return struct {
        const Self = @This();
        ctx: ContextType,
        written: i32 = -1,
        // Used by the printer
        prev_char: u8 = 0,
        prev_prev_char: u8 = 0,
        err: ?anyerror = null,
        orig_err: ?anyerror = null,

        pub fn init(ctx: ContextType) Self {
            return .{
                .ctx = ctx,
            };
        }

        pub fn isCopyFileRangeSupported() bool {
            return comptime std.meta.trait.hasFn("copyFileRange")(ContextType);
        }

        pub fn copyFileRange(ctx: ContextType, in_file: StoredFileDescriptorType, start: usize, end: usize) !void {
            ctx.sendfile(
                in_file,
                start,
                end,
            );
        }

        pub fn slice(this: *Self) string {
            return this.ctx.slice();
        }

        pub fn getError(writer: *const Self) anyerror!void {
            if (writer.orig_err) |orig_err| {
                return orig_err;
            }

            if (writer.err) |err| {
                return err;
            }
        }

        pub inline fn prevChar(writer: *const Self) u8 {
            return @call(.{ .modifier = .always_inline }, getLastByte, .{&writer.ctx});
        }

        pub inline fn prevPrevChar(writer: *const Self) u8 {
            return @call(.{ .modifier = .always_inline }, getLastLastByte, .{&writer.ctx});
        }

        pub fn reserve(writer: *Self, count: u32) anyerror![*]u8 {
            return try reserveNext(&writer.ctx, count);
        }

        pub fn advance(writer: *Self, count: u32) void {
            advanceBy(&writer.ctx, count);
            writer.written += @intCast(i32, count);
        }

        pub const Error = error{FormatError};

        pub fn writeAll(writer: *Self, bytes: anytype) Error!usize {
            const written = @maximum(writer.written, 0);
            writer.print(@TypeOf(bytes), bytes);
            return @intCast(usize, writer.written) - @intCast(usize, written);
        }

        pub inline fn print(writer: *Self, comptime ValueType: type, str: ValueType) void {
            if (FeatureFlags.disable_printing_null) {
                if (str == 0) {
                    Global.panic("Attempted to print null char", .{});
                }
            }

            switch (ValueType) {
                comptime_int, u16, u8 => {
                    const written = writeByte(&writer.ctx, @intCast(u8, str)) catch |err| brk: {
                        writer.orig_err = err;
                        break :brk 0;
                    };

                    writer.written += @intCast(i32, written);
                    writer.err = if (written == 0) error.WriteFailed else writer.err;
                },
                else => {
                    const written = writeAllFn(&writer.ctx, str) catch |err| brk: {
                        writer.orig_err = err;
                        break :brk 0;
                    };

                    writer.written += @intCast(i32, written);
                    if (written < str.len) {
                        writer.err = if (written == 0) error.WriteFailed else error.PartialWrite;
                    }
                },
            }
        }

        const hasFlush = std.meta.trait.hasFn("flush");
        pub fn flush(writer: *Self) !void {
            if (hasFlush(ContextType)) {
                try writer.ctx.flush();
            }
        }
        const hasDone = std.meta.trait.hasFn("done");
        pub fn done(writer: *Self) !void {
            if (hasDone(ContextType)) {
                try writer.ctx.done();
            }
        }
    };
}

pub const DirectWriter = struct {
    handle: FileDescriptorType,

    pub fn write(writer: *DirectWriter, buf: []const u8) !usize {
        return try std.os.write(writer.handle, buf);
    }

    pub fn writeAll(writer: *DirectWriter, buf: []const u8) !void {
        _ = try std.os.write(writer.handle, buf);
    }

    pub const Error = std.os.WriteError;
};

// Unbuffered           653ms
//   Buffered    65k     47ms
//   Buffered    16k     43ms
//   Buffered     4k     55ms
const FileWriterInternal = struct {
    file: std.fs.File,
    threadlocal var buffer: MutableString = undefined;
    threadlocal var has_loaded_buffer: bool = false;

    pub fn getBuffer() *MutableString {
        buffer.reset();
        return &buffer;
    }

    pub fn init(file: std.fs.File) FileWriterInternal {
        if (!has_loaded_buffer) {
            buffer = MutableString.init(default_allocator, 0) catch unreachable;
            has_loaded_buffer = true;
        }

        buffer.reset();

        return FileWriterInternal{
            .file = file,
        };
    }
    pub fn writeByte(_: *FileWriterInternal, byte: u8) anyerror!usize {
        try buffer.appendChar(byte);
        return 1;
    }
    pub fn writeAll(_: *FileWriterInternal, bytes: anytype) anyerror!usize {
        try buffer.append(bytes);
        return bytes.len;
    }

    pub fn slice(_: *@This()) string {
        return buffer.list.items;
    }

    pub fn getLastByte(_: *const FileWriterInternal) u8 {
        return if (buffer.list.items.len > 0) buffer.list.items[buffer.list.items.len - 1] else 0;
    }

    pub fn getLastLastByte(_: *const FileWriterInternal) u8 {
        return if (buffer.list.items.len > 1) buffer.list.items[buffer.list.items.len - 2] else 0;
    }

    pub fn reserveNext(_: *FileWriterInternal, count: u32) anyerror![*]u8 {
        try buffer.growIfNeeded(count);
        return @ptrCast([*]u8, &buffer.list.items.ptr[buffer.list.items.len]);
    }
    pub fn advanceBy(_: *FileWriterInternal, count: u32) void {
        if (comptime Environment.isDebug) std.debug.assert(buffer.list.items.len + count <= buffer.list.capacity);

        buffer.list.items = buffer.list.items.ptr[0 .. buffer.list.items.len + count];
    }

    pub fn done(
        ctx: *FileWriterInternal,
    ) anyerror!void {
        defer buffer.reset();
        var result_ = buffer.toOwnedSliceLeaky();
        var result = result_;

        while (result.len > 0) {
            switch (result.len) {
                0...4096 => {
                    const written = try ctx.file.write(result);
                    if (written == 0 or result.len - written == 0) return;
                    result = result[written..];
                },
                else => {
                    const first = result.ptr[0 .. result.len / 3];
                    const second = result[first.len..][0..first.len];
                    const remain = first.len + second.len;
                    const third: []const u8 = result[remain..];

                    var vecs = [_]std.os.iovec_const{
                        .{
                            .iov_base = first.ptr,
                            .iov_len = first.len,
                        },
                        .{
                            .iov_base = second.ptr,
                            .iov_len = second.len,
                        },
                        .{
                            .iov_base = third.ptr,
                            .iov_len = third.len,
                        },
                    };

                    const written = try std.os.writev(ctx.file.handle, vecs[0..@as(usize, if (third.len > 0) 3 else 2)]);
                    if (written == 0 or result.len - written == 0) return;
                    result = result[written..];
                },
            }
        }
    }

    pub fn flush(
        _: *FileWriterInternal,
    ) anyerror!void {}
};

pub const BufferWriter = struct {
    buffer: MutableString = undefined,
    written: []u8 = "",
    sentinel: [:0]u8 = "",
    append_null_byte: bool = false,
    approximate_newline_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !BufferWriter {
        return BufferWriter{
            .buffer = MutableString.init(
                allocator,
                0,
            ) catch unreachable,
        };
    }
    pub fn writeByte(ctx: *BufferWriter, byte: u8) anyerror!usize {
        try ctx.buffer.appendChar(byte);
        ctx.approximate_newline_count += @boolToInt(byte == '\n');
        return 1;
    }
    pub fn writeAll(ctx: *BufferWriter, bytes: anytype) anyerror!usize {
        try ctx.buffer.append(bytes);
        ctx.approximate_newline_count += @boolToInt(bytes.len > 0 and bytes[bytes.len - 1] == '\n');
        return bytes.len;
    }

    pub fn slice(self: *@This()) string {
        return self.buffer.list.items;
    }

    pub fn getLastByte(ctx: *const BufferWriter) u8 {
        return if (ctx.buffer.list.items.len > 0) ctx.buffer.list.items[ctx.buffer.list.items.len - 1] else 0;
    }

    pub fn getLastLastByte(ctx: *const BufferWriter) u8 {
        return if (ctx.buffer.list.items.len > 1) ctx.buffer.list.items[ctx.buffer.list.items.len - 2] else 0;
    }

    pub fn reserveNext(ctx: *BufferWriter, count: u32) anyerror![*]u8 {
        try ctx.buffer.growIfNeeded(count);
        return @ptrCast([*]u8, &ctx.buffer.list.items.ptr[ctx.buffer.list.items.len]);
    }
    pub fn advanceBy(ctx: *BufferWriter, count: u32) void {
        if (comptime Environment.isDebug) std.debug.assert(ctx.buffer.list.items.len + count < ctx.buffer.list.capacity);

        ctx.buffer.list.items = ctx.buffer.list.items.ptr[0 .. ctx.buffer.list.items.len + count];
    }

    pub fn reset(ctx: *BufferWriter) void {
        ctx.buffer.reset();
        ctx.approximate_newline_count = 0;
    }

    pub fn done(
        ctx: *BufferWriter,
    ) anyerror!void {
        if (ctx.append_null_byte) {
            ctx.sentinel = ctx.buffer.toOwnedSentinelLeaky();
            ctx.written = ctx.buffer.toOwnedSliceLeaky();
        } else {
            ctx.written = ctx.buffer.toOwnedSliceLeaky();
        }
    }

    pub fn flush(
        _: *BufferWriter,
    ) anyerror!void {}
};
pub const BufferPrinter = NewWriter(
    BufferWriter,
    BufferWriter.writeByte,
    BufferWriter.writeAll,
    BufferWriter.getLastByte,
    BufferWriter.getLastLastByte,
    BufferWriter.reserveNext,
    BufferWriter.advanceBy,
);
pub const FileWriter = NewWriter(
    FileWriterInternal,
    FileWriterInternal.writeByte,
    FileWriterInternal.writeAll,
    FileWriterInternal.getLastByte,
    FileWriterInternal.getLastLastByte,
    FileWriterInternal.reserveNext,
    FileWriterInternal.advanceBy,
);
pub fn NewFileWriter(file: std.fs.File) FileWriter {
    var internal = FileWriterInternal.init(file);
    return FileWriter.init(internal);
}

pub const Format = enum {
    esm,
    cjs,

    // bun.js must escape non-latin1 identifiers in the output This is because
    // we load JavaScript as a UTF-8 buffer instead of a UTF-16 buffer
    // JavaScriptCore does not support UTF-8 identifiers when the source code
    // string is loaded as const char* We don't want to double the size of code
    // in memory...
    esm_ascii,
    cjs_ascii,
};

pub fn printAst(
    comptime Writer: type,
    _writer: Writer,
    tree: Ast,
    symbols: js_ast.Symbol.Map,
    source: *const logger.Source,
    comptime ascii_only: bool,
    opts: Options,
    comptime LinkerType: type,
    linker: ?*LinkerType,
) !usize {
    const PrinterType = NewPrinter(ascii_only, Writer, LinkerType, false, false, false, false);
    var writer = _writer;

    var printer = try PrinterType.init(
        writer,
        &tree,
        source,
        symbols,
        opts,
        linker,
    );

    if (tree.prepend_part) |part| {
        for (part.stmts) |stmt| {
            try printer.printStmt(stmt);
            if (printer.writer.getError()) {} else |err| {
                return err;
            }
        }
    }

    for (tree.parts) |part| {
        for (part.stmts) |stmt| {
            try printer.printStmt(stmt);
            if (printer.writer.getError()) {} else |err| {
                return err;
            }
        }
    }

    try printer.writer.done();

    if (tree.symbol_pool) |symbol_pool| {
        js_ast.SymbolPool.release(symbol_pool);
    }

    return @intCast(usize, std.math.max(printer.writer.written, 0));
}

pub fn printJSON(
    comptime Writer: type,
    _writer: Writer,
    expr: Expr,
    source: *const logger.Source,
) !usize {
    const PrinterType = NewPrinter(false, Writer, void, false, false, false, true);
    var writer = _writer;
    var s_expr = S.SExpr{ .value = expr };
    var stmt = Stmt{ .loc = logger.Loc.Empty, .data = .{
        .s_expr = &s_expr,
    } };
    var stmts = &[_]js_ast.Stmt{stmt};
    var parts = &[_]js_ast.Part{.{ .stmts = stmts }};
    const ast = Ast.initTest(parts);
    var printer = try PrinterType.init(
        writer,
        &ast,
        source,
        std.mem.zeroes(Symbol.Map),
        .{},
        null,
    );

    printer.printExpr(expr, Level.lowest, ExprFlag{});
    if (printer.writer.getError()) {} else |err| {
        return err;
    }
    try printer.writer.done();

    return @intCast(usize, std.math.max(printer.writer.written, 0));
}

pub fn printCommonJS(
    comptime Writer: type,
    _writer: Writer,
    tree: Ast,
    symbols: js_ast.Symbol.Map,
    source: *const logger.Source,
    comptime ascii_only: bool,
    opts: Options,
    comptime LinkerType: type,
    linker: ?*LinkerType,
) !usize {
    const PrinterType = NewPrinter(ascii_only, Writer, LinkerType, true, false, false, false);
    var writer = _writer;
    var printer = try PrinterType.init(
        writer,
        &tree,
        source,
        symbols,
        opts,
        linker,
    );

    if (tree.prepend_part) |part| {
        for (part.stmts) |stmt| {
            try printer.printStmt(stmt);
            if (printer.writer.getError()) {} else |err| {
                return err;
            }
        }
    }
    for (tree.parts) |part| {
        for (part.stmts) |stmt| {
            try printer.printStmt(stmt);
            if (printer.writer.getError()) {} else |err| {
                return err;
            }
        }
    }

    // Add a couple extra newlines at the end
    printer.writer.print(@TypeOf("\n\n"), "\n\n");

    try printer.writer.done();

    if (tree.symbol_pool) |symbol_pool| {
        js_ast.SymbolPool.release(symbol_pool);
    }

    return @intCast(usize, std.math.max(printer.writer.written, 0));
}

pub const WriteResult = struct {
    off: u32,
    len: usize,
    end_off: u32,
};

pub fn printCommonJSThreaded(
    comptime Writer: type,
    _writer: Writer,
    tree: Ast,
    symbols: js_ast.Symbol.Map,
    source: *const logger.Source,
    comptime ascii_only: bool,
    opts: Options,
    comptime LinkerType: type,
    linker: ?*LinkerType,
    lock: *Lock,
    comptime GetPosType: type,
    getter: GetPosType,
    comptime getPos: fn (ctx: GetPosType) anyerror!u64,
    end_off_ptr: *u32,
) !WriteResult {
    const PrinterType = NewPrinter(ascii_only, Writer, LinkerType, true, false, true, false);
    var writer = _writer;
    var printer = try PrinterType.init(
        writer,
        &tree,
        source,
        symbols,
        opts,
        linker,
    );

    if (tree.prepend_part) |part| {
        for (part.stmts) |stmt| {
            try printer.printStmt(stmt);
            if (printer.writer.getError()) {} else |err| {
                return err;
            }
        }
    }

    for (tree.parts) |part| {
        for (part.stmts) |stmt| {
            try printer.printStmt(stmt);
            if (printer.writer.getError()) {} else |err| {
                return err;
            }
        }
    }

    // Add a couple extra newlines at the end
    printer.writer.print(@TypeOf("\n\n"), "\n\n");

    var result: WriteResult = .{ .off = 0, .len = 0, .end_off = 0 };
    {
        defer lock.unlock();
        lock.lock();
        result.off = @truncate(u32, try getPos(getter));
        if (comptime Environment.isMac or Environment.isLinux) {
            // Don't bother preallocate the file if it's less than 1 KB. Preallocating is potentially two syscalls
            if (printer.writer.written > 1024) {
                if (comptime Environment.isMac) {
                    try C.preallocate_file(
                        getter.handle,
                        @intCast(std.os.off_t, 0),
                        @intCast(std.os.off_t, printer.writer.written),
                    );
                }

                if (comptime Environment.isLinux) {
                    _ = std.os.system.fallocate(getter.handle, 0, @intCast(i64, result.off), printer.writer.written);
                }
            }
        }
        try printer.writer.done();
        @fence(.SeqCst);
        result.end_off = @truncate(u32, try getPos(getter));
        @atomicStore(u32, end_off_ptr, result.end_off, .SeqCst);
    }

    result.len = @intCast(usize, std.math.max(printer.writer.written, 0));
    if (tree.symbol_pool) |symbol_pool| {
        js_ast.SymbolPool.release(symbol_pool);
    }
    return result;
}
