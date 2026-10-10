//! XML text as a GPX file holds it: the five predefined entities, numeric character
//! references and CDATA sections when reading, and the characters that must be escaped when
//! writing. Without this, a waypoint named `Col d&amp;Aubisque` reads back with its `&amp;`
//! and writes as `&amp;amp;`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const cdata_open = "<![CDATA[";
const cdata_close = "]]>";

/// The longest entity worth looking for: `&#x10FFFF;` is 10 bytes. A `&` with no `;` within
/// this reach is a plain ampersand, which keeps the scan bounded.
const entity_length_max = 10;

/// Returns `text` as the characters it stands for, in memory the caller owns: entities
/// replaced, CDATA sections unwrapped. What it cannot decode (an unknown entity, a reference
/// to a surrogate or to zero) is kept as written, since a name with a stray `&` is better
/// read as it is than rejected. The result is never longer than `text`.
pub fn unescape_alloc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var index: usize = 0;
    // Bounded: each iteration moves `index` forward by at least one byte.
    while (index < text.len) {
        const rest = text[index..];
        if (std.mem.startsWith(u8, rest, cdata_open)) {
            const inner = rest[cdata_open.len..];
            // An unclosed section runs to the end: the text as far as it goes.
            const length = std.mem.indexOf(u8, inner, cdata_close) orelse inner.len;
            out.appendSliceAssumeCapacity(inner[0..length]);
            index += cdata_open.len + length + @min(cdata_close.len, inner.len - length);
        } else if (rest[0] == '&') {
            const decoded = entity_decode(rest);
            if (decoded.length == 0) {
                out.appendAssumeCapacity('&');
                index += 1;
            } else {
                out.appendSliceAssumeCapacity(decoded.bytes[0..decoded.length]);
                index += decoded.consumed;
            }
        } else {
            out.appendAssumeCapacity(rest[0]);
            index += 1;
        }
    }
    assert(out.items.len <= text.len);
    return out.toOwnedSlice(allocator);
}

const Decoded = struct {
    bytes: [4]u8 = undefined,
    /// How many of `bytes` are the character; 0 when `text` starts no entity.
    length: u3 = 0,
    /// How many bytes of the text the entity took, `&` and `;` included.
    consumed: usize = 0,
};

/// Decodes the entity `text` starts with (`text[0]` is `&`), or says it is none.
fn entity_decode(text: []const u8) Decoded {
    assert(text.len > 0 and text[0] == '&');
    const reach = @min(text.len, entity_length_max);
    const semicolon = std.mem.indexOfScalar(u8, text[0..reach], ';') orelse return .{};
    const name = text[1..semicolon];

    var decoded: Decoded = .{ .consumed = semicolon + 1 };
    const named: ?u8 = if (std.mem.eql(u8, name, "amp"))
        '&'
    else if (std.mem.eql(u8, name, "lt"))
        '<'
    else if (std.mem.eql(u8, name, "gt"))
        '>'
    else if (std.mem.eql(u8, name, "quot"))
        '"'
    else if (std.mem.eql(u8, name, "apos"))
        '\''
    else
        null;
    if (named) |character| {
        decoded.bytes[0] = character;
        decoded.length = 1;
        return decoded;
    }

    const code_point = reference_parse(name) orelse return .{};
    const length = std.unicode.utf8Encode(code_point, &decoded.bytes) catch return .{};
    assert(length >= 1 and length <= 4);
    decoded.length = @intCast(length);
    // The reference is longer than what it decodes to, so the result never outgrows the text.
    assert(decoded.length <= decoded.consumed);
    return decoded;
}

/// Returns the code point of a numeric reference's body (`#233` or `#xE9`), or null when it
/// is not one, is zero, or is not a Unicode scalar value.
fn reference_parse(name: []const u8) ?u21 {
    if (name.len < 2 or name[0] != '#') return null;
    const hexadecimal = name[1] == 'x' or name[1] == 'X';
    const digits = if (hexadecimal) name[2..] else name[1..];
    if (digits.len == 0) return null;
    const value = std.fmt.parseInt(u32, digits, if (hexadecimal) 16 else 10) catch return null;
    if (value == 0 or value > std.math.maxInt(u21)) return null;
    const code_point: u21 = @intCast(value);
    if (!std.unicode.utf8ValidCodepoint(code_point)) return null;
    return code_point;
}

/// Writes `text` as the content of an element: `&`, `<` and `>` as entities. A control
/// character (other than tab, newline and carriage return) has no form in XML 1.0, so it is
/// left out rather than written into a file no parser would accept.
pub fn escape_write(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var run_start: usize = 0;
    for (text, 0..) |character, index| {
        const replacement: ?[]const u8 = switch (character) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            0...8, 11, 12, 14...31 => "",
            else => null,
        };
        const replace = replacement orelse continue;
        try writer.writeAll(text[run_start..index]);
        try writer.writeAll(replace);
        run_start = index + 1;
    }
    try writer.writeAll(text[run_start..]);
}

fn unescaped(text: []const u8) ![]u8 {
    return unescape_alloc(testing.allocator, text);
}

test "unescape_alloc: plain text is returned as it is" {
    for ([_][]const u8{ "", "Col du Tourmalet", "Vielle-Aure é ü 山", "a < b" }) |text| {
        const result = try unescaped(text);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(text, result);
    }
}

test "unescape_alloc: the five predefined entities" {
    const result = try unescaped("a&amp;b &lt;c&gt; &quot;d&quot; &apos;e&apos;");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a&b <c> \"d\" 'e'", result);
}

test "unescape_alloc: numeric references, decimal and hexadecimal" {
    const result = try unescaped("&#39;&#233;&#xE9;&#X4E2D;&#x1F3C3;");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("'éé中🏃", result);
}

test "unescape_alloc: what is not an entity is kept as written" {
    const cases = [_][]const u8{
        "fish & chips",
        "&unknown;",
        "&amp",
        "&",
        "&;",
        "&#;",
        "&#x;",
        "&#0;",
        "&#xD800;",
        "&#1114112;",
        "&#99999999999;",
        "&#xZZ;",
        "&-too-far-from-any-semicolon-to-be-an-entity;",
    };
    for (cases) |text| {
        const result = try unescaped(text);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(text, result);
    }
}

test "unescape_alloc: an entity is decoded once, not twice" {
    const result = try unescaped("&amp;amp; &amp;lt;");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("&amp; &lt;", result);
}

test "unescape_alloc: CDATA is unwrapped and its content is not decoded" {
    const result = try unescaped("<![CDATA[GRP 2026 <Ultra> &amp; Co]]> &amp;<![CDATA[x]]>");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("GRP 2026 <Ultra> &amp; Co &x", result);
}

test "unescape_alloc: an unclosed CDATA runs to the end" {
    const result = try unescaped("a<![CDATA[b&amp;c");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("ab&amp;c", result);
}

test "unescape_alloc: never longer than the text" {
    // The worst case for length: every byte an entity that decodes to one byte, then the
    // longest references, each decoding to four.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..64) |_| try text.appendSlice(testing.allocator, "&lt;");
    for (0..8) |_| try text.appendSlice(testing.allocator, "&#x10FFFF;");

    const result = try unescaped(text.items);
    defer testing.allocator.free(result);
    try testing.expect(result.len <= text.items.len);
    try testing.expectEqual(@as(usize, 64 + 8 * 4), result.len);
}

fn escaped(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try escape_write(&out.writer, text);
    return out.toOwnedSlice();
}

test "escape_write: ampersand, less-than and greater-than" {
    const result = try escaped(testing.allocator, "Col d'Aubisque & <Soulor> \"x\"");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Col d'Aubisque &amp; &lt;Soulor&gt; \"x\"", result);
}

test "escape_write: text with nothing to escape is written as it is" {
    const result = try escaped(testing.allocator, "Vielle-Aure é 山\ttab\nline\r");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Vielle-Aure é 山\ttab\nline\r", result);
}

test "escape_write: control characters are left out" {
    const result = try escaped(testing.allocator, "a\x00b\x01c\x0bd\x1fe");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcde", result);
}

test "escape_write: unescape_alloc reads back what it wrote" {
    const texts = [_][]const u8{
        "",
        "&",
        "&amp;",
        "a < b && c > d",
        "&lt;already&gt;",
        "Col d'Aubisque (retour) & Soulor",
        "<![CDATA[not a section]]>",
    };
    for (texts) |text| {
        const written = try escaped(testing.allocator, text);
        defer testing.allocator.free(written);
        const read = try unescaped(written);
        defer testing.allocator.free(read);
        try testing.expectEqualStrings(text, read);
    }
}
