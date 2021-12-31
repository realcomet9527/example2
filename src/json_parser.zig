const std = @import("std");
const logger = @import("logger.zig");
const js_lexer = @import("js_lexer.zig");
const importRecord = @import("import_record.zig");
const js_ast = @import("js_ast.zig");
const options = @import("options.zig");

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
usingnamespace @import("ast/base.zig");
usingnamespace js_ast.G;

const expect = std.testing.expect;
const ImportKind = importRecord.ImportKind;
const BindingNodeIndex = js_ast.BindingNodeIndex;

const StmtNodeIndex = js_ast.StmtNodeIndex;
const ExprNodeIndex = js_ast.ExprNodeIndex;
const ExprNodeList = js_ast.ExprNodeList;
const StmtNodeList = js_ast.StmtNodeList;
const BindingNodeList = js_ast.BindingNodeList;
const assert = std.debug.assert;

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

const LEXER_DEBUGGER_WORKAROUND = false;

const HashMapPool = struct {
    const HashMap = std.HashMap(u64, void, IdentityContext, 80);
    const LinkedList = std.SinglyLinkedList(HashMap);
    threadlocal var list: LinkedList = undefined;
    threadlocal var loaded: bool = false;

    const IdentityContext = struct {
        pub fn eql(_: @This(), a: u64, b: u64) bool {
            return a == b;
        }

        pub fn hash(_: @This(), a: u64) u64 {
            return a;
        }
    };

    pub fn get(_: std.mem.Allocator) *LinkedList.Node {
        if (loaded) {
            if (list.popFirst()) |node| {
                node.data.clearRetainingCapacity();
                return node;
            }
        }

        var new_node = default_allocator.create(LinkedList.Node) catch unreachable;
        new_node.* = LinkedList.Node{ .data = HashMap.initContext(default_allocator, IdentityContext{}) };
        return new_node;
    }

    pub fn release(node: *LinkedList.Node) void {
        if (loaded) {
            list.prepend(node);
            return;
        }

        list = LinkedList{ .first = node };
        loaded = true;
    }
};

fn JSONLikeParser(opts: js_lexer.JSONOptions) type {
    return struct {
        const Lexer = js_lexer.NewLexer(if (LEXER_DEBUGGER_WORKAROUND) js_lexer.JSONOptions{} else opts);

        lexer: Lexer,
        log: *logger.Log,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, source_: logger.Source, log: *logger.Log) !Parser {
            return Parser{
                .lexer = try Lexer.init(log, source_, allocator),
                .allocator = allocator,
                .log = log,
            };
        }

        pub inline fn source(p: *const Parser) *const logger.Source {
            return &p.lexer.source;
        }

        const Parser = @This();

        pub fn e(_: *Parser, t: anytype, loc: logger.Loc) Expr {
            const Type = @TypeOf(t);
            if (@typeInfo(Type) == .Pointer) {
                return Expr.init(std.meta.Child(Type), t.*, loc);
            } else {
                return Expr.init(Type, t, loc);
            }
        }
        pub fn parseExpr(p: *Parser, comptime maybe_auto_quote: bool) anyerror!Expr {
            const loc = p.lexer.loc();

            switch (p.lexer.token) {
                .t_false => {
                    try p.lexer.next();
                    return p.e(E.Boolean{
                        .value = false,
                    }, loc);
                },
                .t_true => {
                    try p.lexer.next();
                    return p.e(E.Boolean{
                        .value = true,
                    }, loc);
                },
                .t_null => {
                    try p.lexer.next();
                    return p.e(E.Null{}, loc);
                },
                .t_string_literal => {
                    var str: E.String = p.lexer.toEString();

                    try p.lexer.next();
                    return p.e(str, loc);
                },
                .t_numeric_literal => {
                    const value = p.lexer.number;
                    try p.lexer.next();
                    return p.e(E.Number{ .value = value }, loc);
                },
                .t_minus => {
                    try p.lexer.next();
                    const value = p.lexer.number;
                    try p.lexer.expect(.t_numeric_literal);
                    return p.e(E.Number{ .value = -value }, loc);
                },
                .t_open_bracket => {
                    try p.lexer.next();
                    var is_single_line = !p.lexer.has_newline_before;
                    var exprs = std.ArrayList(Expr).init(p.allocator);

                    while (p.lexer.token != .t_close_bracket) {
                        if (exprs.items.len > 0) {
                            if (p.lexer.has_newline_before) {
                                is_single_line = false;
                            }

                            if (!try p.parseMaybeTrailingComma(.t_close_bracket)) {
                                break;
                            }

                            if (p.lexer.has_newline_before) {
                                is_single_line = false;
                            }
                        }

                        exprs.append(try p.parseExpr(false)) catch unreachable;
                    }

                    if (p.lexer.has_newline_before) {
                        is_single_line = false;
                    }
                    try p.lexer.expect(.t_close_bracket);
                    return p.e(E.Array{ .items = exprs.items }, loc);
                },
                .t_open_brace => {
                    try p.lexer.next();
                    var is_single_line = !p.lexer.has_newline_before;
                    var properties = std.ArrayList(G.Property).init(p.allocator);

                    const DuplicateNodeType = comptime if (opts.json_warn_duplicate_keys) *HashMapPool.LinkedList.Node else void;
                    const HashMapType = comptime if (opts.json_warn_duplicate_keys) HashMapPool.HashMap else void;

                    var duplicates_node: DuplicateNodeType = if (comptime opts.json_warn_duplicate_keys)
                        HashMapPool.get(p.allocator)
                    else
                        void{};

                    var duplicates: HashMapType = if (comptime opts.json_warn_duplicate_keys)
                        duplicates_node.data
                    else
                        void{};

                    defer {
                        if (comptime opts.json_warn_duplicate_keys) {
                            duplicates_node.data = duplicates;
                            HashMapPool.release(duplicates_node);
                        }
                    }

                    while (p.lexer.token != .t_close_brace) {
                        if (properties.items.len > 0) {
                            if (p.lexer.has_newline_before) {
                                is_single_line = false;
                            }
                            if (!try p.parseMaybeTrailingComma(.t_close_brace)) {
                                break;
                            }
                            if (p.lexer.has_newline_before) {
                                is_single_line = false;
                            }
                        }

                        const str = p.lexer.toEString();
                        const key_range = p.lexer.range();

                        if (comptime opts.json_warn_duplicate_keys) {
                            const hash_key = str.hash();
                            const duplicate_get_or_put = duplicates.getOrPut(hash_key) catch unreachable;
                            duplicate_get_or_put.key_ptr.* = hash_key;

                            // Warn about duplicate keys
                            if (duplicate_get_or_put.found_existing) {
                                p.log.addRangeWarningFmt(p.source(), key_range, p.allocator, "Duplicate key \"{s}\" in object literal", .{p.lexer.string_literal_slice}) catch unreachable;
                            }
                        }

                        const key = p.e(str, key_range.loc);
                        try p.lexer.expect(.t_string_literal);

                        try p.lexer.expect(.t_colon);
                        const value = try p.parseExpr(false);
                        properties.append(G.Property{ .key = key, .value = value }) catch unreachable;
                    }

                    if (p.lexer.has_newline_before) {
                        is_single_line = false;
                    }
                    try p.lexer.expect(.t_close_brace);
                    return p.e(E.Object{
                        .properties = properties.items,
                        .is_single_line = is_single_line,
                    }, loc);
                },
                else => {
                    if (comptime maybe_auto_quote) {
                        p.lexer = try Lexer.initJSON(p.log, p.source().*, p.allocator);
                        try p.lexer.parseStringLiteral(0);
                        return p.parseExpr(false);
                    }

                    try p.lexer.unexpected();
                    if (comptime Environment.isDebug) {
                        std.io.getStdErr().writeAll("\nThis range: \n") catch {};
                        std.io.getStdErr().writeAll(
                            p.lexer.source.contents[p.lexer.range().loc.toUsize()..p.lexer.range().end().toUsize()],
                        ) catch {};

                        @breakpoint();
                    }
                    return error.ParserError;
                },
            }
        }

        pub fn parseMaybeTrailingComma(p: *Parser, closer: T) !bool {
            const comma_range = p.lexer.range();
            try p.lexer.expect(.t_comma);

            if (p.lexer.token == closer) {
                if (comptime !opts.allow_trailing_commas) {
                    p.log.addRangeError(p.source(), comma_range, "JSON does not support trailing commas") catch unreachable;
                }
                return false;
            }

            return true;
        }
    };
}

// This is a special JSON parser that stops as soon as it finds
// {
//    "name": "NAME_IN_HERE",
//    "version": "VERSION_IN_HERE",
// }
// and then returns the name and version.
// More precisely, it stops as soon as it finds a top-level "name" and "version" property which are strings
// In most cases, it should perform zero heap allocations because it does not create arrays or objects (It just skips them)
pub const PackageJSONVersionChecker = struct {
    const Lexer = js_lexer.NewLexer(opts);

    lexer: Lexer,
    source: *const logger.Source,
    log: *logger.Log,
    allocator: std.mem.Allocator,
    depth: usize = 0,

    found_version_buf: [1024]u8 = undefined,
    found_name_buf: [1024]u8 = undefined,

    found_name: []const u8 = "",
    found_version: []const u8 = "",

    has_found_name: bool = false,
    has_found_version: bool = false,

    const opts = if (LEXER_DEBUGGER_WORKAROUND) js_lexer.JSONOptions{} else js_lexer.JSONOptions{
        .is_json = true,
        .json_warn_duplicate_keys = false,
        .allow_trailing_commas = true,
    };

    pub fn init(allocator: std.mem.Allocator, source: *const logger.Source, log: *logger.Log) !Parser {
        return Parser{
            .lexer = try Lexer.init(log, source.*, allocator),
            .allocator = allocator,
            .log = log,
            .source = source,
        };
    }

    const Parser = @This();

    pub fn e(_: *Parser, t: anytype, loc: logger.Loc) Expr {
        const Type = @TypeOf(t);
        if (@typeInfo(Type) == .Pointer) {
            return Expr.init(std.meta.Child(Type), t.*, loc);
        } else {
            return Expr.init(Type, t, loc);
        }
    }
    pub fn parseExpr(p: *Parser) anyerror!Expr {
        const loc = p.lexer.loc();

        if (p.has_found_name and p.has_found_version) return p.e(E.Missing{}, loc);

        switch (p.lexer.token) {
            .t_false => {
                try p.lexer.next();
                return p.e(E.Boolean{
                    .value = false,
                }, loc);
            },
            .t_true => {
                try p.lexer.next();
                return p.e(E.Boolean{
                    .value = true,
                }, loc);
            },
            .t_null => {
                try p.lexer.next();
                return p.e(E.Null{}, loc);
            },
            .t_string_literal => {
                var str: E.String = p.lexer.toEString();

                try p.lexer.next();
                return p.e(str, loc);
            },
            .t_numeric_literal => {
                const value = p.lexer.number;
                try p.lexer.next();
                return p.e(E.Number{ .value = value }, loc);
            },
            .t_minus => {
                try p.lexer.next();
                const value = p.lexer.number;
                try p.lexer.expect(.t_numeric_literal);
                return p.e(E.Number{ .value = -value }, loc);
            },
            .t_open_bracket => {
                try p.lexer.next();
                var has_exprs = false;

                while (p.lexer.token != .t_close_bracket) {
                    if (has_exprs) {
                        if (!try p.parseMaybeTrailingComma(.t_close_bracket)) {
                            break;
                        }
                    }

                    _ = try p.parseExpr();
                    has_exprs = true;
                }

                try p.lexer.expect(.t_close_bracket);
                return p.e(E.Missing{}, loc);
            },
            .t_open_brace => {
                try p.lexer.next();
                p.depth += 1;
                defer p.depth -= 1;

                var has_properties = false;
                while (p.lexer.token != .t_close_brace) {
                    if (has_properties) {
                        if (!try p.parseMaybeTrailingComma(.t_close_brace)) {
                            break;
                        }
                    }

                    const str = p.lexer.toEString();
                    const key_range = p.lexer.range();

                    const key = p.e(str, key_range.loc);
                    try p.lexer.expect(.t_string_literal);

                    try p.lexer.expect(.t_colon);
                    const value = try p.parseExpr();

                    if (p.depth == 1) {
                        // if you have multiple "name" fields in the package.json....
                        // first one wins
                        if (key.data == .e_string and value.data == .e_string) {
                            if (!p.has_found_name and strings.eqlComptime(key.data.e_string.utf8, "name")) {
                                const len = @minimum(
                                    value.data.e_string.utf8.len,
                                    p.found_name_buf.len,
                                );

                                std.mem.copy(u8, &p.found_name_buf, value.data.e_string.utf8[0..len]);
                                p.found_name = p.found_name_buf[0..len];
                                p.has_found_name = true;
                            } else if (!p.has_found_version and strings.eqlComptime(key.data.e_string.utf8, "version")) {
                                const len = @minimum(
                                    value.data.e_string.utf8.len,
                                    p.found_version_buf.len,
                                );
                                std.mem.copy(u8, &p.found_version_buf, value.data.e_string.utf8[0..len]);
                                p.found_version = p.found_version_buf[0..len];
                                p.has_found_version = true;
                            }
                        }
                    }

                    if (p.has_found_name and p.has_found_version) return p.e(E.Missing{}, loc);
                    has_properties = true;
                }

                try p.lexer.expect(.t_close_brace);
                return p.e(E.Missing{}, loc);
            },
            else => {
                try p.lexer.unexpected();
                if (comptime Environment.isDebug) {
                    @breakpoint();
                }
                return error.ParserError;
            },
        }
    }

    pub fn parseMaybeTrailingComma(p: *Parser, closer: T) !bool {
        const comma_range = p.lexer.range();
        try p.lexer.expect(.t_comma);

        if (p.lexer.token == closer) {
            if (comptime !opts.allow_trailing_commas) {
                p.log.addRangeError(p.source(), comma_range, "JSON does not support trailing commas") catch unreachable;
            }
            return false;
        }

        return true;
    }
};

const JSONParser = JSONLikeParser(js_lexer.JSONOptions{ .is_json = true });
const RemoteJSONParser = JSONLikeParser(js_lexer.JSONOptions{ .is_json = true, .json_warn_duplicate_keys = false });
const DotEnvJSONParser = JSONLikeParser(js_lexer.JSONOptions{
    .ignore_leading_escape_sequences = true,
    .ignore_trailing_escape_sequences = true,
    .allow_trailing_commas = true,
    .is_json = true,
});
var empty_string = E.String{ .utf8 = "" };
const TSConfigParser = JSONLikeParser(js_lexer.JSONOptions{ .allow_comments = true, .is_json = true, .allow_trailing_commas = true });
var empty_object = E.Object{};
var empty_array = E.Array{ .items = &[_]ExprNodeIndex{} };
var empty_string_data = Expr.Data{ .e_string = &empty_string };
var empty_object_data = Expr.Data{ .e_object = &empty_object };
var empty_array_data = Expr.Data{ .e_array = &empty_array };

pub fn ParseJSON(source: *const logger.Source, log: *logger.Log, allocator: std.mem.Allocator) !Expr {
    var parser = try JSONParser.init(allocator, source.*, log);
    switch (source.contents.len) {
        // This is to be consisntent with how disabled JS files are handled
        0 => {
            return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data };
        },
        // This is a fast pass I guess
        2 => {
            if (strings.eqlComptime(source.contents[0..1], "\"\"") or strings.eqlComptime(source.contents[0..1], "''")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_string_data };
            } else if (strings.eqlComptime(source.contents[0..1], "{}")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data };
            } else if (strings.eqlComptime(source.contents[0..1], "[]")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_array_data };
            }
        },
        else => {},
    }

    return try parser.parseExpr(false);
}

pub const JSONParseResult = struct {
    expr: Expr,
    tag: Tag,

    pub const Tag = enum {
        expr,
        ascii,
        empty,
    };
};

pub fn ParseJSONForBundling(source: *const logger.Source, log: *logger.Log, allocator: std.mem.Allocator) !JSONParseResult {
    var parser = try JSONParser.init(allocator, source.*, log);
    switch (source.contents.len) {
        // This is to be consisntent with how disabled JS files are handled
        0 => {
            return JSONParseResult{ .expr = Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data }, .tag = .empty };
        },
        // This is a fast pass I guess
        2 => {
            if (strings.eqlComptime(source.contents[0..1], "\"\"") or strings.eqlComptime(source.contents[0..1], "''")) {
                return JSONParseResult{ .expr = Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_string_data }, .tag = .expr };
            } else if (strings.eqlComptime(source.contents[0..1], "{}")) {
                return JSONParseResult{ .expr = Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data }, .tag = .expr };
            } else if (strings.eqlComptime(source.contents[0..1], "[]")) {
                return JSONParseResult{ .expr = Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_array_data }, .tag = .expr };
            }
        },
        else => {},
    }

    const result = try parser.parseExpr(false);
    return JSONParseResult{
        .tag = if (!LEXER_DEBUGGER_WORKAROUND and parser.lexer.is_ascii_only) JSONParseResult.Tag.ascii else JSONParseResult.Tag.expr,
        .expr = result,
    };
}

// threadlocal var env_json_auto_quote_buffer: MutableString = undefined;
// threadlocal var env_json_auto_quote_buffer_loaded: bool = false;
pub fn ParseEnvJSON(source: *const logger.Source, log: *logger.Log, allocator: std.mem.Allocator) !Expr {
    var parser = try DotEnvJSONParser.init(allocator, source.*, log);
    switch (source.contents.len) {
        // This is to be consisntent with how disabled JS files are handled
        0 => {
            return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data };
        },
        // This is a fast pass I guess
        2 => {
            if (strings.eqlComptime(source.contents[0..1], "\"\"") or strings.eqlComptime(source.contents[0..1], "''")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_string_data };
            } else if (strings.eqlComptime(source.contents[0..1], "{}")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data };
            } else if (strings.eqlComptime(source.contents[0..1], "[]")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_array_data };
            }
        },
        else => {},
    }

    switch (source.contents[0]) {
        '{', '[', '0'...'9', '"', '\'' => {
            return try parser.parseExpr(false);
        },
        else => {
            switch (parser.lexer.token) {
                .t_true => {
                    return Expr{ .loc = logger.Loc{ .start = 0 }, .data = .{ .e_boolean = E.Boolean{ .value = true } } };
                },
                .t_false => {
                    return Expr{ .loc = logger.Loc{ .start = 0 }, .data = .{ .e_boolean = E.Boolean{ .value = false } } };
                },
                .t_null => {
                    return Expr{ .loc = logger.Loc{ .start = 0 }, .data = .{ .e_null = E.Null{} } };
                },
                .t_identifier => {
                    if (strings.eqlComptime(parser.lexer.identifier, "undefined")) {
                        return Expr{ .loc = logger.Loc{ .start = 0 }, .data = .{ .e_undefined = E.Undefined{} } };
                    }

                    return try parser.parseExpr(true);
                },
                else => {
                    return try parser.parseExpr(true);
                },
            }
        },
    }
}

pub fn ParseTSConfig(source: *const logger.Source, log: *logger.Log, allocator: std.mem.Allocator) !Expr {
    switch (source.contents.len) {
        // This is to be consisntent with how disabled JS files are handled
        0 => {
            return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data };
        },
        // This is a fast pass I guess
        2 => {
            if (strings.eqlComptime(source.contents[0..1], "\"\"") or strings.eqlComptime(source.contents[0..1], "''")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_string_data };
            } else if (strings.eqlComptime(source.contents[0..1], "{}")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_object_data };
            } else if (strings.eqlComptime(source.contents[0..1], "[]")) {
                return Expr{ .loc = logger.Loc{ .start = 0 }, .data = empty_array_data };
            }
        },
        else => {},
    }

    var parser = try TSConfigParser.init(allocator, source.*, log);

    return parser.parseExpr(false);
}

const duplicateKeyJson = "{ \"name\": \"valid\", \"name\": \"invalid\" }";

const js_printer = @import("js_printer.zig");
const renamer = @import("renamer.zig");
const SymbolList = [][]Symbol;

const Bundler = @import("./bundler.zig").Bundler;
const ParseResult = @import("./bundler.zig").ParseResult;
fn expectPrintedJSON(_contents: string, expected: string) !void {
    Expr.Data.Store.create(default_allocator);
    Stmt.Data.Store.create(default_allocator);
    defer {
        Expr.Data.Store.reset();
        Stmt.Data.Store.reset();
    }
    var contents = default_allocator.alloc(u8, _contents.len + 1) catch unreachable;
    std.mem.copy(u8, contents, _contents);
    contents[contents.len - 1] = ';';
    var log = logger.Log.init(default_allocator);
    defer log.msgs.deinit();

    var source = logger.Source.initPathString(
        "source.json",
        contents,
    );
    const expr = try ParseJSON(&source, &log, default_allocator);

    if (log.msgs.items.len > 0) {
        Global.panic("--FAIL--\nExpr {s}\nLog: {s}\n--FAIL--", .{ expr, log.msgs.items[0].data.text });
    }

    var buffer_writer = try js_printer.BufferWriter.init(default_allocator);
    var writer = js_printer.BufferPrinter.init(buffer_writer);
    const written = try js_printer.printJSON(@TypeOf(&writer), &writer, expr, &source);
    var js = writer.ctx.buffer.list.items.ptr[0 .. written + 1];

    if (js.len > 1) {
        while (js[js.len - 1] == '\n') {
            js = js[0 .. js.len - 1];
        }

        if (js[js.len - 1] == ';') {
            js = js[0 .. js.len - 1];
        }
    }

    try std.testing.expectEqualStrings(expected, js);
}

test "ParseJSON" {
    try expectPrintedJSON("true", "true");
    try expectPrintedJSON("false", "false");
    try expectPrintedJSON("1", "1");
    try expectPrintedJSON("10", "10");
    try expectPrintedJSON("100", "100");
    try expectPrintedJSON("100.1", "100.1");
    try expectPrintedJSON("19.1", "19.1");
    try expectPrintedJSON("19.12", "19.12");
    try expectPrintedJSON("3.4159820837456", "3.4159820837456");
    try expectPrintedJSON("-10000.25", "-10000.25");
    try expectPrintedJSON("\"hi\"", "\"hi\"");
    try expectPrintedJSON("{\"hi\": 1, \"hey\": \"200\", \"boom\": {\"yo\": true}}", "{\"hi\": 1, \"hey\": \"200\", \"boom\": {\"yo\": true } }");
    try expectPrintedJSON("{\"hi\": \"hey\"}", "{\"hi\": \"hey\" }");
    try expectPrintedJSON(
        "{\"hi\": [\"hey\", \"yo\"]}",
        \\{"hi": [
        \\  "hey",
        \\  "yo"
        \\] }
        ,
    );

    // TODO: emoji?
}
