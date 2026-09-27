//! ISO 8601 timestamps (GPX `<time>`) to Unix epoch seconds.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// `YYYY-MM-DDTHH:MM:SSZ`.
const timestamp_length_min = 20;
/// `YYYY-MM-DDTHH:MM:SS+HH:MM`.
const timestamp_length_max = 25;
/// The date and time before the zone designator.
const date_time_length = 19;

const seconds_per_day = 86_400;

/// Returns the Unix epoch seconds of an ISO 8601 UTC or offset timestamp, such as
/// `2025-11-20T12:00:00Z` or `2025-11-20T12:00:00+01:00`. Fractional seconds are not accepted.
/// The bytes come from a GPX file, so anything else is an error, never an assertion.
pub fn iso8601_to_epoch_s(text: []const u8) error{InvalidFormat}!i64 {
    if (text.len < timestamp_length_min or text.len > timestamp_length_max) {
        return error.InvalidFormat;
    }
    const separators_valid = text[4] == '-' and text[7] == '-' and text[10] == 'T' and
        text[13] == ':' and text[16] == ':';
    if (!separators_valid) return error.InvalidFormat;

    const year = try digits_parse(text[0..4]);
    const month = try digits_parse(text[5..7]);
    const day = try digits_parse(text[8..10]);
    const hour = try digits_parse(text[11..13]);
    const minute = try digits_parse(text[14..16]);
    const second = try digits_parse(text[17..19]);
    if (month < 1 or month > 12) return error.InvalidFormat;
    if (day < 1 or day > days_in_month(year, month)) return error.InvalidFormat;
    // A leap second (60) is out: the epoch has no representation for it.
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidFormat;

    const offset_s = try zone_offset_s(text[date_time_length..]);
    const epoch_s = civil_to_epoch_s(year, month, day) + hour * 3600 + minute * 60 + second;
    return epoch_s - offset_s;
}

/// Parses a fixed-width run of ASCII digits. Unlike std.fmt.parseInt, it rejects a sign.
fn digits_parse(text: []const u8) error{InvalidFormat}!i64 {
    assert(text.len > 0);
    assert(text.len <= 4);
    var value: i64 = 0;
    for (text) |character| {
        if (character < '0' or character > '9') return error.InvalidFormat;
        value = value * 10 + (character - '0');
    }
    assert(value >= 0);
    return value;
}

/// Returns the zone designator's offset from UTC in seconds: 0 for `Z`, 3600 for `+01:00`.
fn zone_offset_s(text: []const u8) error{InvalidFormat}!i64 {
    assert(text.len <= timestamp_length_max - date_time_length);
    if (text.len == 1 and text[0] == 'Z') return 0;
    if (text.len != 6 or text[3] != ':') return error.InvalidFormat;

    const sign: i64 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.InvalidFormat,
    };
    const hours = try digits_parse(text[1..3]);
    const minutes = try digits_parse(text[4..6]);
    // Real offsets run from -12:00 to +14:00.
    if (hours > 14 or minutes > 59) return error.InvalidFormat;
    return sign * (hours * 3600 + minutes * 60);
}

fn days_in_month(year: i64, month: i64) i64 {
    assert(year >= 0 and year <= 9999);
    assert(month >= 1 and month <= 12);
    return switch (month) {
        2 => if (is_leap_year(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        1, 3, 5, 7, 8, 10, 12 => 31,
        else => unreachable,
    };
}

fn is_leap_year(year: i64) bool {
    assert(year >= 0);
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

/// Returns the epoch seconds of midnight UTC on a proleptic Gregorian date. It counts years
/// from March, so the leap day falls at the end of the year and needs no special case.
fn civil_to_epoch_s(year: i64, month: i64, day: i64) i64 {
    assert(month >= 1 and month <= 12);
    assert(day >= 1 and day <= 31);
    const year_from_march = if (month <= 2) year - 1 else year;
    const month_from_march = if (month <= 2) month + 12 else month;
    const days = 365 * year_from_march + @divFloor(year_from_march, 4) -
        @divFloor(year_from_march, 100) + @divFloor(year_from_march, 400) +
        @divFloor(153 * month_from_march - 457, 5) + day - 719_469;
    return days * seconds_per_day;
}

test "iso8601_to_epoch_s: UTC" {
    try testing.expectEqual(@as(i64, 1763640000), try iso8601_to_epoch_s("2025-11-20T12:00:00Z"));
    try testing.expectEqual(@as(i64, 0), try iso8601_to_epoch_s("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(i64, 946684800), try iso8601_to_epoch_s("2000-01-01T00:00:00Z"));
    try testing.expectEqual(@as(i64, 1709164800), try iso8601_to_epoch_s("2024-02-29T00:00:00Z"));
    try testing.expectEqual(@as(i64, 1767225599), try iso8601_to_epoch_s("2025-12-31T23:59:59Z"));
}

test "iso8601_to_epoch_s: before the epoch is negative" {
    try testing.expectEqual(@as(i64, -1), try iso8601_to_epoch_s("1969-12-31T23:59:59Z"));
}

test "iso8601_to_epoch_s: an offset is subtracted to reach UTC" {
    const utc = try iso8601_to_epoch_s("2025-11-20T12:00:00Z");
    // 12:00 at +01:00 is 11:00 UTC, one hour earlier; 12:00 at -05:00 is 17:00 UTC.
    try testing.expectEqual(utc - 3600, try iso8601_to_epoch_s("2025-11-20T12:00:00+01:00"));
    try testing.expectEqual(utc + 18000, try iso8601_to_epoch_s("2025-11-20T12:00:00-05:00"));
    const plus_0530 = try iso8601_to_epoch_s("2025-11-20T12:00:00+05:30");
    try testing.expectEqual(utc - (5 * 3600 + 30 * 60), plus_0530);
    try testing.expectEqual(utc, try iso8601_to_epoch_s("2025-11-20T13:00:00+01:00"));
    try testing.expectEqual(utc, try iso8601_to_epoch_s("2025-11-20T07:00:00-05:00"));
    try testing.expectEqual(utc, try iso8601_to_epoch_s("2025-11-20T12:00:00+00:00"));
}

test "iso8601_to_epoch_s: the length bounds" {
    // 19 and 26 bytes: one short of the minimum, one past the maximum.
    try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s("2025-11-20T12:00:00"));
    const too_long = "2025-11-20T12:00:00+01:000";
    try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s(too_long));
    try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s(""));
}

test "iso8601_to_epoch_s: rejects bad separators" {
    const invalid = [_][]const u8{
        "2025-11-20 12:00:00Z",
        "20251120T12:00:00Zxx",
        "2025-11-20T120000Zxx",
        "2025/11/20T12:00:00Z",
    };
    for (invalid) |text| try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s(text));
}

test "iso8601_to_epoch_s: rejects out-of-range fields" {
    const invalid = [_][]const u8{
        "2025-00-20T12:00:00Z",
        "2025-13-20T12:00:00Z",
        "2025-11-00T12:00:00Z",
        "2025-11-31T12:00:00Z",
        "2025-02-29T12:00:00Z", // 2025 isn't a leap year.
        "1900-02-29T12:00:00Z", // Divisible by 100 but not 400.
        "2025-11-20T24:00:00Z",
        "2025-11-20T12:60:00Z",
        "2025-11-20T12:00:60Z",
    };
    for (invalid) |text| try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s(text));
    // The last day of each boundary month is valid.
    _ = try iso8601_to_epoch_s("2000-02-29T00:00:00Z");
    _ = try iso8601_to_epoch_s("2025-04-30T23:59:59Z");
}

test "iso8601_to_epoch_s: rejects signs, spaces and letters in digit fields" {
    const invalid = [_][]const u8{
        "2025-+1-20T12:00:00Z",
        "2025-11- 1T12:00:00Z",
        "20a5-11-20T12:00:00Z",
    };
    for (invalid) |text| try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s(text));
}

test "iso8601_to_epoch_s: rejects bad zone designators" {
    const invalid = [_][]const u8{
        "2025-11-20T12:00:00z",
        "2025-11-20T12:00:00+0100",
        "2025-11-20T12:00:00+1:00",
        "2025-11-20T12:00:00*01:00",
        "2025-11-20T12:00:00+15:00",
        "2025-11-20T12:00:00+01:60",
        "2025-11-20T12:00:00.5Z",
    };
    for (invalid) |text| try testing.expectError(error.InvalidFormat, iso8601_to_epoch_s(text));
    _ = try iso8601_to_epoch_s("2025-11-20T12:00:00+14:00");
    _ = try iso8601_to_epoch_s("2025-11-20T12:00:00-12:00");
}

test "days_in_month: leap year rules" {
    try testing.expectEqual(@as(i64, 29), days_in_month(2024, 2));
    try testing.expectEqual(@as(i64, 28), days_in_month(2025, 2));
    try testing.expectEqual(@as(i64, 29), days_in_month(2000, 2));
    try testing.expectEqual(@as(i64, 28), days_in_month(1900, 2));
    try testing.expectEqual(@as(i64, 31), days_in_month(2025, 1));
    try testing.expectEqual(@as(i64, 30), days_in_month(2025, 11));
}
