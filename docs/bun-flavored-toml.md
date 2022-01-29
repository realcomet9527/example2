# Bun-flavored TOML

[TOML](https://toml.io/) is a minimal configuration file format designed to be easy for humans to read.

Bun implements a TOML parser with a few tweaks designed for better interopability with INI files and with JavaScript.

### `:` == `=`

Like `=`, `:` also assigns values to properties.

```toml
# In Bun-flavored TOML, these are semantically identical
foo = '12345'
foo : '12345'
```

### ';`&nbsp;==&nbsp;`#`

In Bun-flavored TOML, comments start with `#` or `;`

```ini
# This is a comment
; This is also a comment
```

This matches the behavior of INI files.

In TOML, comments start with `#`

```toml
# This is a comment
```

### String escape characters

Bun-flavored adds a few more escape sequences to TOML to work better with JavaScript strings.

```
# Bun-flavored TOML extras
\x{XX}     - ASCII           (U+00XX)
\u{x+}     - unicode         (U+0000000X) - (U+XXXXXXXX)
\v         - vertical tab

# Regular TOML
\b         - backspace       (U+0008)
\t         - tab             (U+0009)
\n         - linefeed        (U+000A)
\f         - form feed       (U+000C)
\r         - carriage return (U+000D)
\"         - quote           (U+0022)
\\         - backslash       (U+005C)
\uXXXX     - unicode         (U+XXXX)
\UXXXXXXXX - unicode         (U+XXXXXXXX)
```
