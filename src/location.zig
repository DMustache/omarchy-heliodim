//! Where the screen is, from the most deliberate source to the roughest:
//!   1. lat/lon in heliodim's own config
//!   2. the "here" city of Omarchy's Elsewhen clock, while the system zone is
//!      still that city's zone (the clock's own rule)
//!   3. Omarchy's weather location, when it has coordinates
//!   4. the system time zone's reference city from tzdata's zone1970.tab
//! Nothing here goes to the network.

const std = @import("std");
const sys = @import("sys.zig");
const json = std.json;

pub const Place = struct {
    lat: f64,
    lon: f64,
    source: []const u8,
};

pub const Paths = struct {
    shell_json: [:0]const u8, // ~/.config/omarchy/shell.json
    weather_json: [:0]const u8, // ~/.local/state/omarchy/settings/weather.json
};

pub fn resolve(arena: std.mem.Allocator, lat: ?f64, lon: ?f64, paths: Paths) !Place {
    if (lat != null and lon != null) return .{ .lat = lat.?, .lon = lon.?, .source = "config" };

    var zbuf: [256]u8 = undefined;
    const zone = localZone(&zbuf);

    if (zone) |z| if (elsewhenHere(arena, paths.shell_json, z)) |p| return p;
    if (fromJson(arena, paths.weather_json, "latitude", "longitude")) |p|
        return .{ .lat = p.lat, .lon = p.lon, .source = "omarchy weather location" };
    if (zone) |z| if (zoneCity(arena, z)) |p| return p;
    return error.LocationUnknown;
}

/// The IANA name /etc/localtime points at, e.g. "Europe/Moscow".
pub fn localZone(buf: []u8) ?[]const u8 {
    const target = sys.readLink("/etc/localtime", buf) catch return null;
    const marker = "zoneinfo/";
    const at = std.mem.lastIndexOf(u8, target, marker) orelse return null;
    return target[at + marker.len ..];
}

fn readAlloc(arena: std.mem.Allocator, path: [:0]const u8, max: usize) ?[]u8 {
    const buf = arena.alloc(u8, max) catch return null;
    return sys.readFile(path, buf) catch null;
}

fn num(v: ?json.Value) ?f64 {
    return switch (v orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn fromJson(arena: std.mem.Allocator, path: [:0]const u8, lat_key: []const u8, lon_key: []const u8) ?struct { lat: f64, lon: f64 } {
    const text = readAlloc(arena, path, 64 * 1024) orelse return null;
    const root = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return null;
    if (root != .object) return null;
    return .{
        .lat = num(root.object.get(lat_key)) orelse return null,
        .lon = num(root.object.get(lon_key)) orelse return null,
    };
}

fn elsewhenHere(arena: std.mem.Allocator, path: [:0]const u8, zone: []const u8) ?Place {
    const text = readAlloc(arena, path, 1024 * 1024) orelse return null;
    const root = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return null;
    if (root != .object) return null;
    const bar = root.object.get("bar") orelse return null;
    if (bar != .object) return null;
    const layout = bar.object.get("layout") orelse return null;
    if (layout != .object) return null;
    for (layout.object.values()) |section| {
        if (section != .array) continue;
        for (section.array.items) |w| {
            if (w != .object) continue;
            const id = w.object.get("id") orelse continue;
            if (id != .string or !std.mem.eql(u8, id.string, "omarchy.elsewhen")) continue;
            const here = w.object.get("here") orelse return null;
            if (here != .object) return null;
            const hz = here.object.get("zone") orelse return null;
            if (hz != .string or !std.mem.eql(u8, hz.string, zone)) return null;
            return .{
                .lat = num(here.object.get("lat")) orelse return null,
                .lon = num(here.object.get("lon")) orelse return null,
                .source = "Elsewhen clock (here)",
            };
        }
    }
    return null;
}

fn zoneCity(arena: std.mem.Allocator, zone: []const u8) ?Place {
    const text = readAlloc(arena, "/usr/share/zoneinfo/zone1970.tab", 256 * 1024) orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        _ = f.next();
        const coords = f.next() orelse continue;
        const name = f.next() orelse continue;
        if (!std.mem.eql(u8, name, zone)) continue;
        const p = parseIso6709(coords) orelse return null;
        return .{ .lat = p[0], .lon = p[1], .source = "time zone (zone1970.tab)" };
    }
    return null;
}

/// "+5545+03735" or "+404251-0740023": ±DDMM[SS]±DDDMM[SS].
fn parseIso6709(s: []const u8) ?[2]f64 {
    const split = std.mem.indexOfAnyPos(u8, s, 1, "+-") orelse return null;
    return .{
        dms(s[0..split], 2) orelse return null,
        dms(s[split..], 3) orelse return null,
    };
}

fn dms(s: []const u8, deg_digits: usize) ?f64 {
    if (s.len < 1 + deg_digits + 2) return null;
    const sign: f64 = if (s[0] == '-') -1 else 1;
    const d = std.fmt.parseInt(u32, s[1 .. 1 + deg_digits], 10) catch return null;
    const m = std.fmt.parseInt(u32, s[1 + deg_digits .. 3 + deg_digits], 10) catch return null;
    const sec: u32 = if (s.len >= 5 + deg_digits)
        std.fmt.parseInt(u32, s[3 + deg_digits .. 5 + deg_digits], 10) catch return null
    else
        0;
    return sign * (@as(f64, @floatFromInt(d)) + @as(f64, @floatFromInt(m)) / 60 + @as(f64, @floatFromInt(sec)) / 3600);
}

test parseIso6709 {
    const m = parseIso6709("+5545+03735").?;
    try std.testing.expectApproxEqAbs(@as(f64, 55.75), m[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 37.5833), m[1], 1e-3);
    const ny = parseIso6709("+404251-0740023").?;
    try std.testing.expectApproxEqAbs(@as(f64, -74.0064), ny[1], 1e-3);
}
