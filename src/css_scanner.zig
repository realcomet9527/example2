const Fs = @import("fs.zig");
const std = @import("std");
const _global = @import("global.zig");
const string = _global.string;
const Output = _global.Output;
const Global = _global.Global;
const Environment = _global.Environment;
const strings = _global.strings;
const MutableString = _global.MutableString;
const CodePoint = _global.CodePoint;
const StoredFileDescriptorType = _global.StoredFileDescriptorType;
const FeatureFlags = _global.FeatureFlags;
const stringZ = _global.stringZ;
const default_allocator = _global.default_allocator;
const C = _global.C;
const options = @import("./options.zig");
const import_record = @import("import_record.zig");
const logger = @import("./logger.zig");
const Options = options;
const resolver = @import("./resolver/resolver.zig");
const _linker = @import("./linker.zig");

const replacementCharacter: CodePoint = 0xFFFD;

pub const Chunk = struct {
    // Entire chunk
    range: logger.Range,
    content: Content,

    pub const Content = union(Tag) {
        t_url: TextContent,
        t_import: Import,
        t_verbatim: Verbatim,
    };

    pub fn raw(chunk: *const Chunk, source: *const logger.Source) string {
        return source.contents[@intCast(usize, chunk.range.loc.start)..][0..@intCast(usize, chunk.range.len)];
    }

    // pub fn string(chunk: *const Chunk, source: *const logger.Source) string {
    //     switch (chunk.content) {
    //         .t_url => |url| {
    //             var str = url.utf8;
    //             var start: i32 = 4;
    //             var end: i32 = chunk.range.len - 1;

    //             while (start < end and isWhitespace(str[start])) {
    //                 start += 1;
    //             }

    //             while (start < end and isWhitespace(str[end - 1])) {
    //                 end -= 1;
    //             }

    //             return str;
    //         },
    //         .t_import => |import| {
    //             if (import.url) {}
    //         },
    //         else => {
    //             return chunk.raw(source);
    //         },
    //     }
    // }

    pub const TextContent = struct {
        quote: Quote = .none,
        utf8: string,
        valid: bool = true,
        needs_decode_escape: bool = false,

        pub const Quote = enum {
            none,
            double,
            single,
        };
    };
    pub const Import = struct {
        url: bool = false,
        text: TextContent,

        supports: string = "",

        // @import can contain media queries and other stuff
        media_queries_str: string = "",

        suffix: string = "",
    };
    pub const Verbatim = struct {};

    pub const Tag = enum {
        t_url,
        t_verbatim,
        t_import,
    };
};

pub const Token = enum {
    t_end_of_file,
    t_semicolon,
    t_whitespace,
    t_at_import,
    t_url,
    t_verbatim,
    t_string,
    t_bad_string,
};

const escLineFeed = 0x0C;
// This is not a CSS parser.
// All this does is scan for URLs and @import statements
// Once found, it resolves & rewrites them
// Eventually, there will be a real CSS parser in here.
// But, no time yet.
pub const Scanner = struct {
    current: usize = 0,
    start: usize = 0,
    end: usize = 0,
    log: *logger.Log,

    has_newline_before: bool = false,
    has_delimiter_before: bool = false,
    allocator: std.mem.Allocator,

    source: *const logger.Source,
    codepoint: CodePoint = -1,
    approximate_newline_count: usize = 0,

    did_warn_tailwind: bool = false,

    pub fn init(log: *logger.Log, allocator: std.mem.Allocator, source: *const logger.Source) Scanner {
        return Scanner{ .log = log, .source = source, .allocator = allocator };
    }

    pub fn range(scanner: *Scanner) logger.Range {
        return logger.Range{
            .loc = .{ .start = @intCast(i32, scanner.start) },
            .len = @intCast(i32, scanner.end - scanner.start),
        };
    }

    pub fn step(scanner: *Scanner) void {
        scanner.codepoint = scanner.nextCodepoint();
        scanner.approximate_newline_count += @boolToInt(scanner.codepoint == '\n');
    }
    pub fn raw(_: *Scanner) string {}

    pub fn isValidEscape(scanner: *Scanner) bool {
        if (scanner.codepoint != '\\') return false;
        const slice = scanner.nextCodepointSlice(false);
        return switch (slice.len) {
            0 => false,
            1 => true,
            2 => (std.unicode.utf8Decode2(slice) catch 0) > 0,
            3 => (std.unicode.utf8Decode3(slice) catch 0) > 0,
            4 => (std.unicode.utf8Decode4(slice) catch 0) > 0,
            else => false,
        };
    }

    pub fn consumeString(
        scanner: *Scanner,
        comptime quote: CodePoint,
    ) ?string {
        const start = scanner.current;
        scanner.step();

        while (true) {
            switch (scanner.codepoint) {
                '\\' => {
                    scanner.step();
                    // Handle Windows CRLF
                    if (scanner.codepoint == '\r') {
                        scanner.step();
                        if (scanner.codepoint == '\n') {
                            scanner.step();
                        }
                        continue;
                    }

                    // Otherwise, fall through to ignore the character after the backslash
                },
                -1 => {
                    scanner.end = scanner.current;
                    scanner.log.addRangeError(
                        scanner.source,
                        scanner.range(),
                        "Unterminated string token",
                    ) catch unreachable;
                    return null;
                },
                '\n', '\r', escLineFeed => {
                    scanner.end = scanner.current;
                    scanner.log.addRangeError(
                        scanner.source,
                        scanner.range(),
                        "Unterminated string token",
                    ) catch unreachable;
                    return null;
                },
                quote => {
                    const result = scanner.source.contents[start..scanner.end];
                    scanner.step();
                    return result;
                },
                else => {},
            }
            scanner.step();
        }
        unreachable;
    }

    pub fn consumeToEndOfMultiLineComment(scanner: *Scanner, start_range: logger.Range) void {
        while (true) {
            switch (scanner.codepoint) {
                '*' => {
                    scanner.step();
                    if (scanner.codepoint == '/') {
                        scanner.step();
                        return;
                    }
                },
                -1 => {
                    scanner.log.addRangeError(scanner.source, start_range, "Expected \"*/\" to terminate multi-line comment") catch {};
                    return;
                },
                else => {
                    scanner.step();
                },
            }
        }
    }
    pub fn consumeToEndOfSingleLineComment(scanner: *Scanner) void {
        while (!isNewline(scanner.codepoint) and scanner.codepoint != -1) {
            scanner.step();
        }

        // scanner.log.addRangeWarning(
        //     scanner.source,
        //     scanner.range(),
        //     "Comments in CSS use \"/* ... */\" instead of \"//\"",
        // ) catch {};
    }

    pub fn consumeURL(scanner: *Scanner) Chunk.TextContent {
        var text = Chunk.TextContent{ .utf8 = "" };
        const start = scanner.end;
        validURL: while (true) {
            switch (scanner.codepoint) {
                ')' => {
                    text.utf8 = scanner.source.contents[start..scanner.end];
                    scanner.step();
                    return text;
                },
                -1 => {
                    const loc = logger.Loc{ .start = @intCast(i32, scanner.end) };
                    scanner.log.addError(scanner.source, loc, "Expected \")\" to end URL token") catch {};
                    return text;
                },
                '\t', '\n', '\r', escLineFeed => {
                    scanner.step();
                    while (isWhitespace(scanner.codepoint)) {
                        scanner.step();
                    }

                    text.utf8 = scanner.source.contents[start..scanner.end];

                    if (scanner.codepoint != ')') {
                        const loc = logger.Loc{ .start = @intCast(i32, scanner.end) };
                        scanner.log.addError(scanner.source, loc, "Expected \")\" to end URL token") catch {};
                        break :validURL;
                    }
                    scanner.step();

                    return text;
                },
                '"', '\'', '(' => {
                    const r = logger.Range{ .loc = logger.Loc{ .start = @intCast(i32, start) }, .len = @intCast(i32, scanner.end - start) };

                    scanner.log.addRangeError(scanner.source, r, "Expected \")\" to end URL token") catch {};
                    break :validURL;
                },
                '\\' => {
                    text.needs_decode_escape = true;
                    if (!scanner.isValidEscape()) {
                        var loc = logger.Loc{
                            .start = @intCast(i32, scanner.end),
                        };
                        scanner.log.addError(scanner.source, loc, "Expected \")\" to end URL token") catch {};
                        break :validURL;
                    }
                    _ = scanner.consumeEscape();
                },
                else => {
                    if (isNonPrintable(scanner.codepoint)) {
                        const r = logger.Range{
                            .loc = logger.Loc{
                                .start = @intCast(i32, start),
                            },
                            .len = 1,
                        };
                        scanner.log.addRangeError(scanner.source, r, "Invalid escape") catch {};
                        break :validURL;
                    }
                    scanner.step();
                },
            }
        }
        text.valid = false;
        // Consume the remnants of a bad url
        while (true) {
            switch (scanner.codepoint) {
                ')', -1 => {
                    scanner.step();
                    text.utf8 = scanner.source.contents[start..scanner.end];
                    return text;
                },
                '\\' => {
                    text.needs_decode_escape = true;
                    if (scanner.isValidEscape()) {
                        _ = scanner.consumeEscape();
                    }
                },
                else => {},
            }

            scanner.step();
        }

        return text;
    }

    pub fn warnTailwind(scanner: *Scanner, start: usize) void {
        if (scanner.did_warn_tailwind) return;
        scanner.did_warn_tailwind = true;
        scanner.log.addWarningFmt(
            scanner.source,
            logger.usize2Loc(start),
            scanner.allocator,
            "To use Tailwind with Bun, use the Tailwind CLI and import the processed .css file.\nLearn more: https://tailwindcss.com/docs/installation#watching-for-changes",
            .{},
        ) catch {};
    }

    pub fn next(
        scanner: *Scanner,
        comptime import_behavior: ImportBehavior,
        comptime WriterType: type,
        writer: WriterType,
        writeChunk: (fn (ctx: WriterType, Chunk) anyerror!void),
    ) !void {
        scanner.has_newline_before = scanner.end == 0;
        scanner.has_delimiter_before = false;
        scanner.step();

        restart: while (true) {
            var chunk = Chunk{
                .range = logger.Range{
                    .loc = .{ .start = @intCast(i32, scanner.end) },
                    .len = 0,
                },
                .content = .{
                    .t_verbatim = .{},
                },
            };
            scanner.start = scanner.end;

            toplevel: while (true) {

                // We only care about two things.
                // 1. url()
                // 2. @import
                // To correctly parse, url(), we need to verify that the character preceding it is either whitespace, a colon, or a comma
                // We also need to parse strings and comments, or else we risk resolving comments like this /* url(hi.jpg) */
                switch (scanner.codepoint) {
                    -1 => {
                        chunk.range.len = @intCast(i32, scanner.end) - chunk.range.loc.start;
                        chunk.content.t_verbatim = .{};
                        try writeChunk(writer, chunk);
                        return;
                    },

                    '\t', '\n', '\r', escLineFeed => {
                        scanner.has_newline_before = true;
                        scanner.step();
                        continue;
                    },
                    // Ensure whitespace doesn't affect scanner.has_delimiter_before
                    ' ' => {},

                    ':', ',' => {
                        scanner.has_delimiter_before = true;
                    },
                    '{', '}' => {
                        scanner.has_delimiter_before = false;

                        // Heuristic:
                        // If we're only scanning the imports, as soon as there's a curly brace somewhere we can assume that @import is done.
                        // @import only appears at the top of the file. Only @charset is allowed to be above it.
                        if (import_behavior == .scan) {
                            return;
                        }
                    },
                    // this is a little hacky, but it should work since we're not parsing scopes
                    ';' => {
                        scanner.has_delimiter_before = false;
                    },
                    'u', 'U' => {
                        // url() always appears on the property value side
                        // so we should ignore it if it's part of a different token
                        if (!scanner.has_delimiter_before) {
                            scanner.step();
                            continue :toplevel;
                        }

                        var url_start = scanner.end;
                        scanner.step();
                        switch (scanner.codepoint) {
                            'r', 'R' => {},
                            else => {
                                continue;
                            },
                        }
                        scanner.step();
                        switch (scanner.codepoint) {
                            'l', 'L' => {},
                            else => {
                                continue;
                            },
                        }
                        scanner.step();
                        if (scanner.codepoint != '(') {
                            continue;
                        }

                        scanner.step();

                        var url_text: Chunk.TextContent = undefined;

                        switch (scanner.codepoint) {
                            '\'' => {
                                const str = scanner.consumeString('\'') orelse return error.SyntaxError;
                                if (scanner.codepoint != ')') {
                                    continue;
                                }
                                scanner.step();
                                url_text = .{ .utf8 = str, .quote = .double };
                            },
                            '"' => {
                                const str = scanner.consumeString('"') orelse return error.SyntaxError;
                                if (scanner.codepoint != ')') {
                                    continue;
                                }
                                scanner.step();
                                url_text = .{ .utf8 = str, .quote = .single };
                            },
                            else => {
                                url_text = scanner.consumeURL();
                            },
                        }

                        chunk.range.len = @intCast(i32, url_start) - chunk.range.loc.start;
                        chunk.content = .{ .t_verbatim = .{} };
                        // flush the pending chunk
                        try writeChunk(writer, chunk);

                        chunk.range.loc.start = @intCast(i32, url_start);
                        chunk.range.len = @intCast(i32, scanner.end) - chunk.range.loc.start;
                        chunk.content = .{ .t_url = url_text };
                        try writeChunk(writer, chunk);
                        scanner.has_delimiter_before = false;

                        continue :restart;
                    },

                    '@' => {
                        const start = scanner.end;

                        scanner.step();
                        switch (scanner.codepoint) {
                            'i' => {},
                            't' => {
                                scanner.step();
                                if (scanner.codepoint != 'a') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != 'i') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != 'l') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != 'w') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != 'i') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != 'n') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != 'd') continue :toplevel;
                                scanner.step();
                                if (scanner.codepoint != ' ') continue :toplevel;
                                scanner.step();

                                const word_start = scanner.end;

                                while (switch (scanner.codepoint) {
                                    'a'...'z', 'A'...'Z' => true,
                                    else => false,
                                }) {
                                    scanner.step();
                                }

                                var word = scanner.source.contents[word_start..scanner.end];

                                while (switch (scanner.codepoint) {
                                    ' ', '\n', '\r' => true,
                                    else => false,
                                }) {
                                    scanner.step();
                                }

                                if (scanner.codepoint != ';') continue :toplevel;

                                switch (word[0]) {
                                    'b' => {
                                        if (strings.eqlComptime(word, "base")) {
                                            scanner.warnTailwind(start);
                                        }
                                    },
                                    'c' => {
                                        if (strings.eqlComptime(word, "components")) {
                                            scanner.warnTailwind(start);
                                        }
                                    },
                                    'u' => {
                                        if (strings.eqlComptime(word, "utilities")) {
                                            scanner.warnTailwind(start);
                                        }
                                    },
                                    's' => {
                                        if (strings.eqlComptime(word, "screens")) {
                                            scanner.warnTailwind(start);
                                        }
                                    },
                                    else => continue :toplevel,
                                }

                                continue :toplevel;
                            },

                            else => continue :toplevel,
                        }
                        scanner.step();
                        if (scanner.codepoint != 'm') continue :toplevel;
                        scanner.step();
                        if (scanner.codepoint != 'p') continue :toplevel;
                        scanner.step();
                        if (scanner.codepoint != 'o') continue :toplevel;
                        scanner.step();
                        if (scanner.codepoint != 'r') continue :toplevel;
                        scanner.step();
                        if (scanner.codepoint != 't') continue :toplevel;
                        scanner.step();
                        if (scanner.codepoint != ' ') continue :toplevel;

                        // Now that we know to expect an import url, we flush the chunk
                        chunk.range.len = @intCast(i32, start) - chunk.range.loc.start;
                        chunk.content = .{ .t_verbatim = .{} };
                        // flush the pending chunk
                        try writeChunk(writer, chunk);

                        // Don't write the .start until we know it's an @import rule
                        // We want to avoid messing with other rules
                        scanner.start = start;

                        // "Imported rules must precede all other types of rule"
                        // https://developer.mozilla.org/en-US/docs/Web/CSS/@import
                        // @import url;
                        // @import url list-of-media-queries;
                        // @import url supports( supports-query );
                        // @import url supports( supports-query ) list-of-media-queries;

                        while (isWhitespace(scanner.codepoint)) {
                            scanner.step();
                        }

                        var import = Chunk.Import{
                            .text = .{
                                .utf8 = "",
                            },
                        };

                        switch (scanner.codepoint) {
                            // spongebob-case url() are supported, I guess.
                            // uRL()
                            // uRL()
                            // URl()
                            'u', 'U' => {
                                scanner.step();
                                switch (scanner.codepoint) {
                                    'r', 'R' => {},
                                    else => {
                                        scanner.log.addError(
                                            scanner.source,
                                            logger.Loc{ .start = @intCast(i32, scanner.end) },
                                            "Expected @import to start with a string or url()",
                                        ) catch {};
                                        return error.SyntaxError;
                                    },
                                }
                                scanner.step();
                                switch (scanner.codepoint) {
                                    'l', 'L' => {},
                                    else => {
                                        scanner.log.addError(
                                            scanner.source,
                                            logger.Loc{ .start = @intCast(i32, scanner.end) },
                                            "Expected @import to start with a \", ' or url()",
                                        ) catch {};
                                        return error.SyntaxError;
                                    },
                                }
                                scanner.step();
                                if (scanner.codepoint != '(') {
                                    scanner.log.addError(
                                        scanner.source,
                                        logger.Loc{ .start = @intCast(i32, scanner.end) },
                                        "Expected \"(\" in @import url",
                                    ) catch {};
                                    return error.SyntaxError;
                                }

                                scanner.step();

                                var url_text: Chunk.TextContent = undefined;

                                switch (scanner.codepoint) {
                                    '\'' => {
                                        const str = scanner.consumeString('\'') orelse return error.SyntaxError;
                                        if (scanner.codepoint != ')') {
                                            continue;
                                        }
                                        scanner.step();

                                        url_text = .{ .utf8 = str, .quote = .single };
                                    },
                                    '"' => {
                                        const str = scanner.consumeString('"') orelse return error.SyntaxError;
                                        if (scanner.codepoint != ')') {
                                            continue;
                                        }
                                        scanner.step();
                                        url_text = .{ .utf8 = str, .quote = .double };
                                    },
                                    else => {
                                        url_text = scanner.consumeURL();
                                    },
                                }

                                import.text = url_text;
                            },
                            '"' => {
                                import.text.quote = .double;
                                if (scanner.consumeString('"')) |str| {
                                    import.text.utf8 = str;
                                } else {
                                    return error.SyntaxError;
                                }
                            },
                            '\'' => {
                                import.text.quote = .single;
                                if (scanner.consumeString('\'')) |str| {
                                    import.text.utf8 = str;
                                } else {
                                    return error.SyntaxError;
                                }
                            },
                            else => {
                                return error.SyntaxError;
                            },
                        }

                        var suffix_start = scanner.end;

                        get_suffix: while (true) {
                            switch (scanner.codepoint) {
                                ';' => {
                                    scanner.step();
                                    import.suffix = scanner.source.contents[suffix_start..scanner.end];
                                    scanner.has_delimiter_before = false;
                                    break :get_suffix;
                                },
                                -1 => {
                                    scanner.log.addError(
                                        scanner.source,
                                        logger.Loc{ .start = @intCast(i32, scanner.end) },
                                        "Expected \";\" at end of @import",
                                    ) catch {};
                                    return;
                                },
                                else => {},
                            }
                            scanner.step();
                        }
                        if (import_behavior == .scan or import_behavior == .keep) {
                            chunk.range.len = @intCast(i32, scanner.end) - std.math.max(chunk.range.loc.start, 0);
                            chunk.content = .{ .t_import = import };
                            try writeChunk(writer, chunk);
                        }
                        scanner.step();
                        continue :restart;
                    },

                    // We don't actually care what the values are here, we just want to avoid confusing strings for URLs.
                    '\'' => {
                        scanner.has_delimiter_before = false;
                        if (scanner.consumeString('\'') == null) {
                            return error.SyntaxError;
                        }
                    },
                    '"' => {
                        scanner.has_delimiter_before = false;
                        if (scanner.consumeString('"') == null) {
                            return error.SyntaxError;
                        }
                    },
                    // Skip comments
                    '/' => {
                        scanner.step();
                        switch (scanner.codepoint) {
                            '*' => {
                                scanner.step();
                                chunk.range.len = @intCast(i32, scanner.end);
                                scanner.consumeToEndOfMultiLineComment(chunk.range);
                            },
                            '/' => {
                                scanner.step();
                                scanner.consumeToEndOfSingleLineComment();
                                continue;
                            },
                            else => {
                                continue;
                            },
                        }
                    },
                    else => {
                        scanner.has_delimiter_before = false;
                    },
                }

                scanner.step();
            }
        }
    }

    pub fn consumeEscape(scanner: *Scanner) CodePoint {
        scanner.step();

        var c = scanner.codepoint;

        if (isHex(c)) |__hex| {
            var hex = __hex;
            scanner.step();
            value: {
                if (isHex(scanner.codepoint)) |_hex| {
                    scanner.step();
                    hex = hex * 16 + _hex;
                } else {
                    break :value;
                }

                if (isHex(scanner.codepoint)) |_hex| {
                    scanner.step();
                    hex = hex * 16 + _hex;
                } else {
                    break :value;
                }

                if (isHex(scanner.codepoint)) |_hex| {
                    scanner.step();
                    hex = hex * 16 + _hex;
                } else {
                    break :value;
                }

                if (isHex(scanner.codepoint)) |_hex| {
                    scanner.step();
                    hex = hex * 16 + _hex;
                } else {
                    break :value;
                }

                break :value;
            }

            if (isWhitespace(scanner.codepoint)) {
                scanner.step();
            }
            return switch (hex) {
                0, 0xD800...0xDFFF, 0x10FFFF...std.math.maxInt(CodePoint) => replacementCharacter,
                else => hex,
            };
        }

        if (c == -1) return replacementCharacter;

        scanner.step();
        return c;
    }

    inline fn nextCodepointSlice(it: *Scanner, comptime advance: bool) []const u8 {
        @setRuntimeSafety(false);

        const cp_len = strings.utf8ByteSequenceLength(it.source.contents[it.current]);
        if (advance) {
            it.end = it.current;
            it.current += cp_len;
        }

        return if (!(it.current > it.source.contents.len)) it.source.contents[it.current - cp_len .. it.current] else "";
    }

    pub inline fn nextCodepoint(it: *Scanner) CodePoint {
        const slice = it.nextCodepointSlice(true);
        @setRuntimeSafety(false);

        return switch (slice.len) {
            0 => -1,
            1 => @intCast(CodePoint, slice[0]),
            2 => @intCast(CodePoint, std.unicode.utf8Decode2(slice) catch unreachable),
            3 => @intCast(CodePoint, std.unicode.utf8Decode3(slice) catch unreachable),
            4 => @intCast(CodePoint, std.unicode.utf8Decode4(slice) catch unreachable),
            else => unreachable,
        };
    }
};

fn isWhitespace(c: CodePoint) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', escLineFeed => true,
        else => false,
    };
}

fn isNewline(c: CodePoint) bool {
    return switch (c) {
        '\t', '\n', '\r', escLineFeed => true,
        else => false,
    };
}

fn isNonPrintable(c: CodePoint) bool {
    return switch (c) {
        0...0x08, 0x0B, 0x0E...0x1F, 0x7F => true,
        else => false,
    };
}

pub fn isHex(c: CodePoint) ?CodePoint {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c + (10 - 'a'),
        'A'...'F' => c + (10 - 'A'),
        else => null,
    };
}

pub const ImportBehavior = enum { keep, omit, scan };

pub fn NewWriter(
    comptime WriterType: type,
    comptime LinkerType: type,
    comptime import_path_format: Options.BundleOptions.ImportPathFormat,
    comptime BuildContextType: type,
) type {
    return struct {
        const Writer = @This();

        ctx: WriterType,
        linker: LinkerType,
        source: *const logger.Source,
        written: usize = 0,
        buildCtx: BuildContextType = undefined,
        log: *logger.Log,

        pub fn init(
            source: *const logger.Source,
            ctx: WriterType,
            linker: LinkerType,
            log: *logger.Log,
        ) Writer {
            return Writer{
                .ctx = ctx,
                .linker = linker,
                .source = source,
                .written = 0,
                .log = log,
            };
        }

        pub fn scan(
            writer: *Writer,
            log: *logger.Log,
            allocator: std.mem.Allocator,
            did_warn_tailwind: *bool,
        ) !void {
            var scanner = Scanner.init(
                log,

                allocator,
                writer.source,
            );

            scanner.did_warn_tailwind = did_warn_tailwind.*;
            try scanner.next(.scan, @TypeOf(writer), writer, scanChunk);
            did_warn_tailwind.* = scanner.did_warn_tailwind;
        }

        pub fn append(
            writer: *Writer,
            log: *logger.Log,
            allocator: std.mem.Allocator,
            did_warn_tailwind: *bool,
        ) !usize {
            var scanner = Scanner.init(
                log,

                allocator,
                writer.source,
            );

            scanner.did_warn_tailwind = did_warn_tailwind.*;

            try scanner.next(.omit, @TypeOf(writer), writer, writeBundledChunk);
            did_warn_tailwind.* = scanner.did_warn_tailwind;

            return scanner.approximate_newline_count;
        }

        pub fn run(
            writer: *Writer,
            log: *logger.Log,
            allocator: std.mem.Allocator,
            did_warn_tailwind: *bool,
        ) !void {
            var scanner = Scanner.init(
                log,

                allocator,
                writer.source,
            );
            scanner.did_warn_tailwind = did_warn_tailwind.*;

            try scanner.next(.keep, @TypeOf(writer), writer, commitChunk);
            did_warn_tailwind.* = scanner.did_warn_tailwind;
        }

        fn writeString(writer: *Writer, str: string, quote: Chunk.TextContent.Quote) !void {
            switch (quote) {
                .none => {
                    try writer.ctx.writeAll(str);
                    writer.written += str.len;
                    return;
                },
                .single => {
                    try writer.ctx.writeAll("'");
                    writer.written += 1;
                    try writer.ctx.writeAll(str);
                    writer.written += str.len;
                    try writer.ctx.writeAll("'");
                    writer.written += 1;
                },
                .double => {
                    try writer.ctx.writeAll("\"");
                    writer.written += 1;
                    try writer.ctx.writeAll(str);
                    writer.written += str.len;
                    try writer.ctx.writeAll("\"");
                    writer.written += 1;
                },
            }
        }

        fn writeURL(writer: *Writer, url_str: string, text: Chunk.TextContent) !void {
            switch (text.quote) {
                .none => {
                    try writer.ctx.writeAll("url(");
                    writer.written += "url(".len;
                },
                .single => {
                    try writer.ctx.writeAll("url('");
                    writer.written += "url('".len;
                },
                .double => {
                    try writer.ctx.writeAll("url(\"");
                    writer.written += "url(\"".len;
                },
            }
            try writer.ctx.writeAll(url_str);
            writer.written += url_str.len;
            switch (text.quote) {
                .none => {
                    try writer.ctx.writeAll(")");
                    writer.written += ")".len;
                },
                .single => {
                    try writer.ctx.writeAll("')");
                    writer.written += "')".len;
                },
                .double => {
                    try writer.ctx.writeAll("\")");
                    writer.written += "\")".len;
                },
            }
        }

        pub fn scanChunk(writer: *Writer, chunk: Chunk) !void {
            switch (chunk.content) {
                .t_url => {},
                .t_import => |import| {
                    const resolved = writer.linker.resolveCSS(
                        writer.source.path,
                        import.text.utf8,
                        chunk.range,
                        import_record.ImportKind.at,
                        Options.BundleOptions.ImportPathFormat.absolute_path,
                        true,
                    ) catch |err| {
                        switch (err) {
                            error.ModuleNotFound, error.FileNotFound => {
                                writer.log.addResolveError(
                                    writer.source,
                                    chunk.range,
                                    writer.buildCtx.allocator,
                                    "Not Found - \"{s}\"",
                                    .{import.text.utf8},
                                    import_record.ImportKind.at,
                                ) catch {};
                            },
                            else => {},
                        }
                        return err;
                    };

                    // TODO: just check is_external instead
                    if (strings.startsWith(import.text.utf8, "https://") or strings.startsWith(import.text.utf8, "http://")) {
                        return;
                    }

                    try writer.buildCtx.addCSSImport(resolved);
                },
                .t_verbatim => {},
            }
        }

        pub fn commitChunk(writer: *Writer, chunk: Chunk) !void {
            return try writeChunk(writer, chunk, false);
        }

        pub fn writeBundledChunk(writer: *Writer, chunk: Chunk) !void {
            return try writeChunk(writer, chunk, true);
        }

        pub fn writeChunk(writer: *Writer, chunk: Chunk, comptime omit_imports: bool) !void {
            switch (chunk.content) {
                .t_url => |url| {
                    const url_str = try writer.linker.resolveCSS(
                        writer.source.path,
                        url.utf8,
                        chunk.range,
                        import_record.ImportKind.url,
                        import_path_format,
                        true,
                    );
                    try writer.writeURL(url_str, url);
                },
                .t_import => |import| {
                    if (!omit_imports) {
                        const url_str = try writer.linker.resolveCSS(
                            writer.source.path,
                            import.text.utf8,
                            chunk.range,
                            import_record.ImportKind.at,
                            import_path_format,
                            false,
                        );

                        try writer.ctx.writeAll("@import ");
                        writer.written += "@import ".len;

                        if (import.url) {
                            try writer.writeURL(url_str, import.text);
                        } else {
                            try writer.writeString(url_str, import.text.quote);
                        }

                        try writer.ctx.writeAll(import.suffix);
                        writer.written += import.suffix.len;
                        try writer.ctx.writeAll("\n");

                        writer.written += 1;
                    }
                },
                .t_verbatim => {
                    defer writer.written += @intCast(usize, chunk.range.len);
                    if (comptime std.meta.trait.hasFn("copyFileRange")(WriterType)) {
                        try writer.ctx.copyFileRange(
                            @intCast(usize, chunk.range.loc.start),
                            @intCast(
                                usize,
                                @intCast(
                                    usize,
                                    chunk.range.len,
                                ),
                            ),
                        );
                    } else {
                        try writer.ctx.writeAll(
                            writer.source.contents[@intCast(usize, chunk.range.loc.start)..][0..@intCast(
                                usize,
                                chunk.range.len,
                            )],
                        );
                    }
                },
            }
        }
    };
}

pub const CodeCount = struct {
    approximate_newline_count: usize = 0,
    written: usize = 0,
};

const ImportQueueFifo = std.fifo.LinearFifo(u32, .Dynamic);
const QueuedList = std.ArrayList(u32);
threadlocal var global_queued: QueuedList = undefined;
threadlocal var global_import_queud: ImportQueueFifo = undefined;
threadlocal var global_bundle_queud: QueuedList = undefined;
threadlocal var has_set_global_queue = false;
threadlocal var int_buf_print: [256]u8 = undefined;
pub fn NewBundler(
    comptime Writer: type,
    comptime Linker: type,
    comptime FileReader: type,
    comptime Watcher: type,
    comptime FSType: type,
    comptime hot_module_reloading: bool,
) type {
    return struct {
        const CSSBundler = @This();
        queued: *QueuedList,
        import_queue: *ImportQueueFifo,
        bundle_queue: *QueuedList,
        writer: Writer,
        watcher: *Watcher,
        fs_reader: FileReader,
        fs: FSType,
        allocator: std.mem.Allocator,
        pub fn bundle(
            absolute_path: string,
            fs: FSType,
            writer: Writer,
            watcher: *Watcher,
            fs_reader: FileReader,
            hash: u32,
            _: ?StoredFileDescriptorType,
            allocator: std.mem.Allocator,
            log: *logger.Log,
            linker: Linker,
        ) !CodeCount {
            if (!has_set_global_queue) {
                global_queued = QueuedList.init(default_allocator);
                global_import_queud = ImportQueueFifo.init(default_allocator);
                global_bundle_queud = QueuedList.init(default_allocator);
                has_set_global_queue = true;
            } else {
                global_queued.clearRetainingCapacity();
                global_import_queud.head = 0;
                global_import_queud.count = 0;
                global_bundle_queud.clearRetainingCapacity();
            }

            var this = CSSBundler{
                .queued = &global_queued,
                .import_queue = &global_import_queud,
                .bundle_queue = &global_bundle_queud,
                .writer = writer,
                .fs_reader = fs_reader,
                .fs = fs,

                .allocator = allocator,
                .watcher = watcher,
            };
            const CSSWriter = NewWriter(*CSSBundler, Linker, .absolute_url, *CSSBundler);

            var css = CSSWriter.init(
                undefined,
                &this,
                linker,
                log,
            );
            css.buildCtx = &this;

            try this.addCSSImport(absolute_path);
            var did_warn_tailwind: bool = false;

            while (this.import_queue.readItem()) |item| {
                const watcher_id = this.watcher.indexOf(item) orelse unreachable;
                const watch_item = this.watcher.watchlist.get(watcher_id);
                const source = try this.getSource(watch_item.file_path, watch_item.fd);
                css.source = &source;
                try css.scan(log, allocator, &did_warn_tailwind);
            }

            // This exists to identify the entry point
            // When we do HMR, ask the entire bundle to be regenerated
            // But, we receive a file change event for a file within the bundle
            // So the inner ID is used to say "does this bundle need to be reloaded?"
            // The outer ID is used to say "go ahead and reload this"
            if (hot_module_reloading and FeatureFlags.css_supports_fence and this.bundle_queue.items.len > 0) {
                try this.writeAll("\n@supports (hmr-bid:");
                const int_buf_size = std.fmt.formatIntBuf(&int_buf_print, hash, 10, .upper, .{});
                try this.writeAll(int_buf_print[0..int_buf_size]);
                try this.writeAll(") {}\n");
            }
            var lines_of_code: usize = 0;

            // We LIFO
            var i: i32 = @intCast(i32, this.bundle_queue.items.len - 1);
            while (i >= 0) : (i -= 1) {
                const item = this.bundle_queue.items[@intCast(usize, i)];
                const watcher_id = this.watcher.indexOf(item) orelse unreachable;
                const watch_item = this.watcher.watchlist.get(watcher_id);
                const source = try this.getSource(watch_item.file_path, watch_item.fd);
                css.source = &source;
                const file_path = fs.relativeTo(watch_item.file_path);
                if (hot_module_reloading and FeatureFlags.css_supports_fence) {
                    try this.writeAll("\n@supports (hmr-wid:");
                    const int_buf_size = std.fmt.formatIntBuf(&int_buf_print, item, 10, .upper, .{});
                    try this.writeAll(int_buf_print[0..int_buf_size]);
                    try this.writeAll(") and (hmr-file:\"");
                    try this.writeAll(file_path);
                    try this.writeAll("\") {}\n");
                }
                try this.writeAll("/* ");
                try this.writeAll(file_path);
                try this.writeAll("*/\n");
                lines_of_code += try css.append(log, allocator, &did_warn_tailwind);
            }

            try this.writer.done();

            return CodeCount{
                .written = css.written,
                .approximate_newline_count = lines_of_code,
            };
        }

        pub fn getSource(this: *CSSBundler, url: string, input_fd: StoredFileDescriptorType) !logger.Source {
            const entry = try this.fs_reader.readFile(this.fs, url, 0, true, input_fd);
            const file = Fs.File{ .path = Fs.Path.init(url), .contents = entry.contents };
            return logger.Source.initFile(file, this.allocator);
        }

        pub fn addCSSImport(this: *CSSBundler, absolute_path: string) !void {
            const hash = Watcher.getHash(absolute_path);
            if (this.queued.items.len > 0 and std.mem.indexOfScalar(u32, this.queued.items, hash) != null) {
                return;
            }

            const watcher_index = this.watcher.indexOf(hash);

            if (watcher_index == null) {
                var file = try std.fs.openFileAbsolute(absolute_path, .{ .read = true });

                try this.watcher.appendFile(file.handle, absolute_path, hash, .css, 0, null, true);
                if (this.watcher.watchloop_handle == null) {
                    try this.watcher.start();
                }
            }

            try this.import_queue.writeItem(hash);
            try this.queued.append(hash);
            try this.bundle_queue.append(hash);
        }

        pub fn writeAll(this: *CSSBundler, buf: anytype) !void {
            _ = try this.writer.writeAll(buf);
        }

        // pub fn copyFileRange(this: *CSSBundler, buf: anytype) !void {}
    };
}
