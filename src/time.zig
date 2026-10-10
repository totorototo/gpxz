//! ISO 8601 timestamps (GPX `<time>`), to and from Unix epoch seconds.

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

/// The first second `epoch_s_to_iso8601` can write: `0000-01-01T00:00:00Z`.
pub const epoch_s_min: i64 = -62_167_219_200;
/// The last: `9999-12-31T23:59:59Z`. A timestamp has four digits of year.
pub const epoch_s_max: i64 = 253_402_300_799;

/// Returns `epoch_s` as `YYYY-MM-DDTHH:MM:SSZ`, the form `iso8601_to_epoch_s` reads back. A
/// time outside year 0000 to 9999 has no four-digit form: an error, since the seconds come
/// from a caller's data.
pub fn epoch_s_to_iso8601(epoch_s: i64) error{OutOfRange}![timestamp_length_min]u8 {
    if (epoch_s < epoch_s_min or epoch_s > epoch_s_max) return error.OutOfRange;
    const date = civil_from_days(@divFloor(epoch_s, seconds_per_day));
    const second_of_day = @mod(epoch_s, seconds_per_day);
    assert(second_of_day >= 0 and second_of_day < seconds_per_day);

    // Unsigned: a signed integer prints a "+" when it has a width.
    const second_of_day_unsigned: u32 = @intCast(second_of_day);
    var text: [timestamp_length_min]u8 = undefined;
    const written = std.fmt.bufPrint(
        &text,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, @intCast(date.year)),
            @as(u32, @intCast(date.month)),
            @as(u32, @intCast(date.day)),
            second_of_day_unsigned / 3600,
            second_of_day_unsigned % 3600 / 60,
            second_of_day_unsigned % 60,
        },
    ) catch unreachable; // Four-digit year, so the text is always 20 bytes.
    assert(written.len == timestamp_length_min);
    return text;
}

const Date = struct { year: i64, month: i64, day: i64 };

/// Returns the proleptic Gregorian date of a day count from 1970-01-01: the inverse of
/// `civil_to_epoch_s`, counting years from March for the same reason.
fn civil_from_days(days: i64) Date {
    const days_from_march_0000 = days + 719_468;
    const era = @divFloor(days_from_march_0000, 146_097);
    const day_of_era = days_from_march_0000 - era * 146_097;
    assert(day_of_era >= 0 and day_of_era < 146_097);
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) -
            @divFloor(day_of_era, 146_096),
        365,
    );
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_from_march = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_from_march + 2, 5) + 1;
    const month = if (month_from_march < 10) month_from_march + 3 else month_from_march - 9;
    const year = year_of_era + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    assert(month >= 1 and month <= 12);
    assert(day >= 1 and day <= 31);
    return .{ .year = year, .month = month, .day = day };
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

test "epoch_s_to_iso8601: known instants" {
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", &(try epoch_s_to_iso8601(0)));
    try testing.expectEqualStrings("2025-11-20T12:00:00Z", &(try epoch_s_to_iso8601(1763640000)));
    try testing.expectEqualStrings("2026-08-21T03:00:00Z", &(try epoch_s_to_iso8601(1787281200)));
    try testing.expectEqualStrings("2024-02-29T00:00:00Z", &(try epoch_s_to_iso8601(1709164800)));
    try testing.expectEqualStrings("2025-12-31T23:59:59Z", &(try epoch_s_to_iso8601(1767225599)));
    try testing.expectEqualStrings("2000-03-01T00:00:00Z", &(try epoch_s_to_iso8601(951868800)));
}

test "epoch_s_to_iso8601: before the epoch" {
    try testing.expectEqualStrings("1969-12-31T23:59:59Z", &(try epoch_s_to_iso8601(-1)));
    try testing.expectEqualStrings("1969-12-31T00:00:00Z", &(try epoch_s_to_iso8601(-86_400)));
}

test "epoch_s_to_iso8601: the first and last second it can write" {
    try testing.expectEqualStrings("0000-01-01T00:00:00Z", &(try epoch_s_to_iso8601(epoch_s_min)));
    try testing.expectEqualStrings("9999-12-31T23:59:59Z", &(try epoch_s_to_iso8601(epoch_s_max)));
    try testing.expectEqual(epoch_s_min, try iso8601_to_epoch_s("0000-01-01T00:00:00Z"));
    try testing.expectEqual(epoch_s_max, try iso8601_to_epoch_s("9999-12-31T23:59:59Z"));
}

test "epoch_s_to_iso8601: beyond year 0000 to 9999 is out of range" {
    try testing.expectError(error.OutOfRange, epoch_s_to_iso8601(epoch_s_min - 1));
    try testing.expectError(error.OutOfRange, epoch_s_to_iso8601(epoch_s_max + 1));
    try testing.expectError(error.OutOfRange, epoch_s_to_iso8601(std.math.minInt(i64)));
    try testing.expectError(error.OutOfRange, epoch_s_to_iso8601(std.math.maxInt(i64)));
}

test "epoch_s_to_iso8601: reads back as the same second, across every leap-year edge" {
    // A stride of a prime number of seconds visits every hour, minute and day of the range,
    // including each February 29 and the days either side of it.
    const stride_s: i64 = 1_000_003;
    var epoch_s: i64 = epoch_s_min;
    var count: u32 = 0;
    // Bounded: the range holds 3.2e11 seconds, so 315_000 steps cover all of it.
    while (epoch_s <= epoch_s_max and count < 400_000) : (count += 1) {
        const text = try epoch_s_to_iso8601(epoch_s);
        try testing.expectEqual(epoch_s, try iso8601_to_epoch_s(&text));
        epoch_s += stride_s;
    }
    try testing.expect(epoch_s > epoch_s_max);
}

test "epoch_s_to_iso8601: the days around the leap days of 1900, 2000 and 2100" {
    // 2000 is a leap year; 1900 and 2100 are not, though both divide by 4. The start of each
    // run is read by the other direction, so the two are checked against each other and
    // against the calendar.
    const Run = struct { start: []const u8, days: [4][]const u8 };
    const runs = [_]Run{
        .{ .start = "1900-02-28T00:00:00Z", .days = .{
            "1900-02-28T00:00:00Z",
            "1900-03-01T00:00:00Z",
            "1900-03-02T00:00:00Z",
            "1900-03-03T00:00:00Z",
        } },
        .{ .start = "2000-02-28T00:00:00Z", .days = .{
            "2000-02-28T00:00:00Z",
            "2000-02-29T00:00:00Z",
            "2000-03-01T00:00:00Z",
            "2000-03-02T00:00:00Z",
        } },
        .{ .start = "2100-02-28T00:00:00Z", .days = .{
            "2100-02-28T00:00:00Z",
            "2100-03-01T00:00:00Z",
            "2100-03-02T00:00:00Z",
            "2100-03-03T00:00:00Z",
        } },
    };
    for (runs) |run| {
        const start_s = try iso8601_to_epoch_s(run.start);
        for (run.days, 0..) |expected, day| {
            const epoch_s = start_s + @as(i64, @intCast(day)) * seconds_per_day;
            try testing.expectEqualStrings(expected, &(try epoch_s_to_iso8601(epoch_s)));
        }
    }
}
