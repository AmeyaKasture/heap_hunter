//! Small, allocation-free regular expression matcher for CLI filters.
//!
//! Supported syntax: `^`, `$`, `.`, `*`, `+`, `?`, escaped literals, and
//! character classes such as `[abc]`, `[^a-z]`, and `[0-9]`.
const std = @import("std");

pub const Error = error{
    DanglingEscape,
    UnclosedCharacterClass,
    DanglingQuantifier,
};

pub fn validate(pattern: []const u8) Error!void {
    var pos: usize = 0;
    while (pos < pattern.len) {
        if (isQuantifier(pattern[pos])) return error.DanglingQuantifier;
        pos = try tokenEnd(pattern, pos);
        if (pos < pattern.len and isQuantifier(pattern[pos])) pos += 1;
    }
}

/// Returns a rewritten copy of `pattern` in which every `\.` (literal dot) is
/// replaced with the character class `[/\\.]`, so it also matches `/` and
/// `\`. This lets users write Java-style dotted class names such as
/// `com\.example\.Foo` and have them match the JVM internal slashed form
/// `com/example/Foo` that the index stores.
///
/// Patterns without `\.` are returned unchanged (modulo a copy). The caller
/// owns the returned slice and must free it with `allocator.free`.
pub fn normalizeForClassName(allocator: std.mem.Allocator, pattern: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, pattern.len + 8);
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + 1 < pattern.len and pattern[i] == '\\' and pattern[i + 1] == '.') {
            // Emit `[/\\.]`: slash, escaped backslash, literal dot. The `\\`
            // is two bytes in the pattern so the regex engine sees a literal
            // backslash inside the character class.
            try out.appendSlice(allocator, "[/\\\\.]");
            i += 2;
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn matches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '^') return matchHere(pattern[1..], text);

    var start: usize = 0;
    while (true) {
        if (matchHere(pattern, text[start..])) return true;
        if (start == text.len) return false;
        start += 1;
    }
}

fn matchHere(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len == 1 and pattern[0] == '$') return text.len == 0;

    const end = tokenEnd(pattern, 0) catch return false;
    if (end < pattern.len and isQuantifier(pattern[end])) {
        return switch (pattern[end]) {
            '*' => matchStar(pattern[0..end], pattern[end + 1 ..], text),
            '+' => matchPlus(pattern[0..end], pattern[end + 1 ..], text),
            '?' => matchQuestion(pattern[0..end], pattern[end + 1 ..], text),
            else => unreachable,
        };
    }

    return text.len > 0 and tokenMatches(pattern[0..end], text[0]) and matchHere(pattern[end..], text[1..]);
}

fn matchStar(token: []const u8, rest: []const u8, text: []const u8) bool {
    var remaining = text;
    while (true) {
        if (matchHere(rest, remaining)) return true;
        if (remaining.len == 0 or !tokenMatches(token, remaining[0])) return false;
        remaining = remaining[1..];
    }
}

fn matchPlus(token: []const u8, rest: []const u8, text: []const u8) bool {
    if (text.len == 0 or !tokenMatches(token, text[0])) return false;
    return matchStar(token, rest, text[1..]);
}

fn matchQuestion(token: []const u8, rest: []const u8, text: []const u8) bool {
    if (matchHere(rest, text)) return true;
    return text.len > 0 and tokenMatches(token, text[0]) and matchHere(rest, text[1..]);
}

fn tokenEnd(pattern: []const u8, start: usize) Error!usize {
    if (pattern[start] == '\\') {
        if (start + 1 >= pattern.len) return error.DanglingEscape;
        return start + 2;
    }
    if (pattern[start] != '[') return start + 1;

    var pos = start + 1;
    if (pos < pattern.len and pattern[pos] == '^') pos += 1;
    while (pos < pattern.len) : (pos += 1) {
        if (pattern[pos] == '\\') {
            if (pos + 1 >= pattern.len) return error.DanglingEscape;
            pos += 1;
        } else if (pattern[pos] == ']') {
            return pos + 1;
        }
    }
    return error.UnclosedCharacterClass;
}

fn tokenMatches(token: []const u8, byte: u8) bool {
    if (token[0] == '.') return true;
    if (token[0] == '\\') return token[1] == byte;
    if (token[0] != '[') return token[0] == byte;

    var pos: usize = 1;
    const negated = token[pos] == '^';
    if (negated) pos += 1;
    var found = false;
    while (pos < token.len - 1) {
        const first = classByte(token, &pos);
        if (pos < token.len - 2 and token[pos] == '-') {
            pos += 1;
            const last = classByte(token, &pos);
            if (first <= byte and byte <= last) found = true;
        } else if (first == byte) {
            found = true;
        }
    }
    return if (negated) !found else found;
}

fn classByte(token: []const u8, pos: *usize) u8 {
    if (token[pos.*] == '\\') pos.* += 1;
    const result = token[pos.*];
    pos.* += 1;
    return result;
}

fn isQuantifier(byte: u8) bool {
    return byte == '*' or byte == '+' or byte == '?';
}

test "matches supported regular expression syntax" {
    try validate("^java\\.lang\\.[A-Z].*");
    try validate("[a-z]+\\[\\]$");
    try validate("[^a-z]+\\[\\]$");
    try @import("std").testing.expect(matches("^java\\.lang\\.[A-Z].*", "java.lang.String"));
    try @import("std").testing.expect(matches("[a-z]+\\[\\]$", "int[]"));
    try @import("std").testing.expect(matches("[^a-z]+\\[\\]$", "INT[]"));
    try @import("std").testing.expect(!matches("^java", "xjava.lang.String"));
    try @import("std").testing.expectError(error.UnclosedCharacterClass, validate("[abc"));
    try @import("std").testing.expectError(error.DanglingQuantifier, validate("*abc"));
}

test "normalizeForClassName rewrites escaped dots into a slash-or-dot class" {
    const allocator = @import("std").testing.allocator;

    // Escaped dots become a character class matching /, \, or literal .
    {
        const p = try normalizeForClassName(allocator, "com\\.example\\.Foo");
        defer allocator.free(p);
        try @import("std").testing.expectEqualStrings("com[/\\\\.]example[/\\\\.]Foo", p);
    }

    // Patterns without any `\.` are returned unchanged (modulo copy)
    {
        const p = try normalizeForClassName(allocator, "com/example/Foo");
        defer allocator.free(p);
        try @import("std").testing.expectEqualStrings("com/example/Foo", p);
    }

    // Other escapes (e.g. `\$`) are preserved verbatim
    {
        const p = try normalizeForClassName(allocator, "a\\$b\\.c");
        defer allocator.free(p);
        try @import("std").testing.expectEqualStrings("a\\$b[/\\\\.]c", p);
    }
}

test "normalizeForClassName lets dotted patterns match JVM internal names" {
    const allocator = @import("std").testing.allocator;

    const p = try normalizeForClassName(allocator, "^java\\.lang\\.[A-Z].*$");
    defer allocator.free(p);

    try @import("std").testing.expect(matches(p, "java.lang.String"));
    try @import("std").testing.expect(matches(p, "java/lang/String"));
    try @import("std").testing.expect(matches(p, "java\\lang\\String"));
    try @import("std").testing.expect(!matches(p, "javaXlangXString"));
}
