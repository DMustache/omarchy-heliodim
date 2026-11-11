//! heliodim: screen brightness that follows the sun.
//!
//! A clear-sky curve gives a target brightness for every moment. Instead of
//! waking on a fixed interval, heliodim works out when the target next moves
//! by one step and sleeps until then, so the process is idle almost always.
//! When someone changes the brightness by hand it keeps that as an offset from
//! the curve and logs the moment with the sun's state, for later learning
//! (a hand change at noon is often clouds).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const sun = @import("sun.zig");
const location = @import("location.zig");

const usage =
    \\usage: heliodim [run|status]
    \\  run     follow the sun (default; meant for the systemd user service)
    \\  status  show location, sun, curve, offset and the next change
    \\
;

/// A hand change is recorded once the keys have been quiet this long.
const settle_ms = 2000;
/// Ramp size limit when the gap is large (start-up, resume).
const max_fade_steps = 10;

const Config = struct {
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Brightness at night and at the top of the curve, percent.
    min: f64 = 10,
    max: f64 = 100,
    /// Smallest change worth making, percent.
    step: f64 = 1,
    /// /sys/class/backlight entry; the first one when unset.
    device: ?[]const u8 = null,

    const Key = enum { lat, lon, min, max, step, device };

    fn load(arena: std.mem.Allocator, path: [:0]const u8) !Config {
        var cfg: Config = .{};
        const buf = try arena.alloc(u8, 16 * 1024);
        const text = sys.readFile(path, buf) catch |e| switch (e) {
            error.NotFound => return cfg,
            else => return e,
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return fail("{s}: expected key = value: {s}", .{ path, line });
            const name = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
            const key = std.meta.stringToEnum(Key, name) orelse return fail("{s}: unknown key {s}", .{ path, name });
            if (key == .device) {
                cfg.device = val;
                continue;
            }
            const v = std.fmt.parseFloat(f64, val) catch return fail("{s}: {s} is not a number", .{ path, val });
            switch (key) {
                .lat => cfg.lat = v,
                .lon => cfg.lon = v,
                .min => cfg.min = v,
                .max => cfg.max = v,
                .step => cfg.step = v,
                .device => unreachable,
            }
        }
        if (!(0 <= cfg.min and cfg.min <= cfg.max and cfg.max <= 100) or cfg.step <= 0)
            return fail("{s}: need 0 <= min <= max <= 100 and step > 0", .{path});
        return cfg;
    }
};

fn fail(comptime fmt: []const u8, args: anytype) error{Reported} {
    std.log.err(fmt, args);
    return error.Reported;
}

const Backlight = struct {
    name: []const u8,
    max: u32,
    /// `brightness`: the value last set, by anyone.
    value_fd: sys.fd_t,
    /// `actual_brightness`: the kernel raises POLLPRI on it after every set.
    event_fd: sys.fd_t,

    fn open(arena: std.mem.Allocator, io: std.Io, want: ?[]const u8) !Backlight {
        const name = want orelse first: {
            var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/backlight", .{ .iterate = true }) catch
                return fail("no /sys/class/backlight", .{});
            defer dir.close(io);
            var it = dir.iterate();
            const e = try it.next(io) orelse return fail("no backlight device (external monitors are not supported yet)", .{});
            break :first try arena.dupe(u8, e.name);
        };
        const dir = try std.fmt.allocPrint(arena, "/sys/class/backlight/{s}/", .{name});
        const path = struct {
            fn z(a: std.mem.Allocator, d: []const u8, f: []const u8) ![:0]u8 {
                return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ d, f }, 0);
            }
        }.z;
        const max_fd = sys.open(try path(arena, dir, "max_brightness"), .{}, 0) catch
            return fail("backlight {s} not found", .{name});
        defer sys.close(max_fd);
        const bl: Backlight = .{
            .name = name,
            .max = try readInt(max_fd),
            .value_fd = try sys.open(try path(arena, dir, "brightness"), .{}, 0),
            .event_fd = try sys.open(try path(arena, dir, "actual_brightness"), .{}, 0),
        };
        if (bl.max == 0) return fail("backlight {s} reports max_brightness 0", .{name});
        return bl;
    }

    fn readInt(fd: sys.fd_t) !u32 {
        var b: [32]u8 = undefined;
        return std.fmt.parseInt(u32, std.mem.trim(u8, try sys.pread(fd, &b, 0), " \n"), 10);
    }

    fn get(bl: Backlight) !u32 {
        return readInt(bl.value_fd);
    }

    /// Reading the notified attribute re-arms POLLPRI.
    fn rearm(bl: Backlight) void {
        _ = readInt(bl.event_fd) catch {};
    }

    /// Through brightnessctl, which goes through logind, so no root and no
    /// udev rules are needed. One short process per step.
    fn set(bl: Backlight, io: std.Io, raw: u32) !void {
        var buf: [16]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{d}", .{raw}) catch unreachable;
        var child = try std.process.spawn(io, .{
            .argv = &.{ "brightnessctl", "-q", "-d", bl.name, "set", arg },
            .stdin = .ignore,
            .stdout = .ignore,
        });
        const term = try child.wait(io);
        if (!term.success()) return fail("brightnessctl failed: {any}", .{term});
    }
};

const Engine = struct {
    cfg: Config,
    place: location.Place,
    bl: Backlight,
    /// One step of `cfg.step` percent, in raw backlight units.
    step_raw: u32,
    /// The hand-set difference from the curve, percentage points.
    offset: f64 = 0,
    events_path: [:0]const u8,

    fn curvePct(e: *const Engine, t: f64) f64 {
        const elev = sun.position(e.place.lat, e.place.lon, t).elevation;
        return e.cfg.min + (e.cfg.max - e.cfg.min) * sun.level(elev);
    }

    fn pctOf(e: *const Engine, raw: u32) f64 {
        return @as(f64, @floatFromInt(raw)) * 100.0 / @as(f64, @floatFromInt(e.bl.max));
    }

    fn targetRaw(e: *const Engine, t: f64) u32 {
        const pct = std.math.clamp(e.curvePct(t) + e.offset, 0.0, 100.0);
        const raw: u32 = @intFromFloat(@round(pct / 100.0 * @as(f64, @floatFromInt(e.bl.max))));
        return @max(1, raw); // 0 turns some panels off
    }

    /// The first minute after `from` when the target is a whole step away
    /// from `applied`. Flat nights and polar days sleep a full day at most.
    fn nextChange(e: *const Engine, from: f64, applied: u32) f64 {
        var k: f64 = 1;
        while (k <= 24 * 60) : (k += 1) {
            const t = from + 60 * k;
            if (absDiff(e.targetRaw(t), applied) >= e.step_raw) return t;
        }
        return from + 86400;
    }

    /// Moves to `target`, ramping when the gap is several steps. Returns the
    /// value the kernel now holds. Leaves a screen at 0 (switched off) alone.
    fn apply(e: *const Engine, io: std.Io, target: u32) !u32 {
        const cur = try e.bl.get();
        if (cur == 0 or cur == target) return cur;
        const n: u32 = std.math.clamp(absDiff(cur, target) / e.step_raw, 1, max_fade_steps);
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const c: i64 = cur;
            const v = c + @divTrunc((@as(i64, target) - c) * i, n);
            try e.bl.set(io, @intCast(v));
            if (i < n) sys.sleepMs(60);
        }
        return e.bl.get();
    }

    /// A hand change: becomes the new offset and one line in the event log.
    fn record(e: *Engine, raw: u32, t: f64) void {
        const pos = sun.position(e.place.lat, e.place.lon, t);
        const curve = e.curvePct(t);
        const pct = e.pctOf(raw);
        e.offset = pct - curve;
        std.log.info("hand change to {d:.1}% (curve {d:.1}%), offset now {d:.1}", .{ pct, curve, e.offset });

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf,
            \\{{"t":{d},"pct":{d:.2},"curve":{d:.2},"offset":{d:.2},"elev":{d:.2},"az":{d:.1},"clear":{d:.0}}}
            \\
        , .{ @as(i64, @intFromFloat(t)), pct, curve, e.offset, pos.elevation, pos.azimuth, sun.clearSky(pos.elevation) }) catch unreachable;
        const fd = sys.open(e.events_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch |err| {
            std.log.warn("cannot write {s}: {t}", .{ e.events_path, err });
            return;
        };
        defer sys.close(fd);
        sys.writeAll(fd, line) catch |err| std.log.warn("cannot write {s}: {t}", .{ e.events_path, err });
    }

    /// The offset from the last logged hand change, so a restart keeps it.
    fn loadOffset(e: *Engine) void {
        const fd = sys.open(e.events_path, .{}, 0) catch return;
        defer sys.close(fd);
        const len = sys.size(fd) catch return;
        var buf: [512]u8 = undefined;
        const take = @min(len, buf.len);
        const tail = std.mem.trimEnd(u8, sys.pread(fd, buf[0..take], len - take) catch return, "\n");
        const last = tail[if (std.mem.lastIndexOfScalar(u8, tail, '\n')) |i| i + 1 else 0 ..];
        const key = "\"offset\":";
        const at = (std.mem.indexOf(u8, last, key) orelse return) + key.len;
        const end = std.mem.indexOfAnyPos(u8, last, at, ",}") orelse return;
        e.offset = std.fmt.parseFloat(f64, last[at..end]) catch return;
    }
};

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn run(io: std.Io, e: *Engine) !void {
    std.log.info("{s}: {d} levels, step {d}% = {d} raw; {d:.4},{d:.4} from {s}; offset {d:.1}", .{
        e.bl.name, e.bl.max, e.cfg.step, e.step_raw, e.place.lat, e.place.lon, e.place.source, e.offset,
    });
    const timer = try sys.timerCreate();
    e.bl.rearm();
    var applied = try e.apply(io, e.targetRaw(sys.now()));
    try sys.timerArm(timer, e.nextChange(sys.now(), applied));

    var pending: ?u32 = null; // a hand-set value waiting for the keys to go quiet
    var fds = [_]linux.pollfd{
        .{ .fd = e.bl.event_fd, .events = linux.POLL.PRI | linux.POLL.ERR },
        .{ .fd = timer, .events = linux.POLL.IN },
    };
    while (true) {
        const ready = try sys.poll(&fds, if (pending != null) settle_ms else -1);
        if (ready == 0) {
            if (pending) |v| {
                e.record(v, sys.now());
                applied = v;
                pending = null;
                try sys.timerArm(timer, e.nextChange(sys.now(), applied));
            }
            continue;
        }
        if (fds[0].revents != 0) {
            e.bl.rearm();
            const v = try e.bl.get();
            // Our own writes read back as `applied`; 0 is a screen switched off.
            if (v == applied) pending = null else if (v != 0) pending = v;
        }
        if (fds[1].revents != 0) {
            sys.timerAck(timer);
            if (pending == null) applied = try e.apply(io, e.targetRaw(sys.now()));
            try sys.timerArm(timer, e.nextChange(sys.now(), applied));
        }
    }
}

fn status(io: std.Io, e: *Engine) !void {
    const t = sys.now();
    const pos = sun.position(e.place.lat, e.place.lon, t);
    const cur = try e.bl.get();
    const next = e.nextChange(t, cur);
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    try out.print(
        \\location   {d:.4}, {d:.4}  ({s})
        \\sun        elevation {d:.2}°, azimuth {d:.1}°, clear sky {d:.0} W/m²
        \\backlight  {s}: {d}/{d} = {d:.1}%  (1 raw = {d:.4}%, step {d}% = {d} raw)
        \\curve      {d:.1}%  (min {d}%, max {d}%)
        \\offset     {d:.1}  → target {d:.1}%
        \\next step  in {d:.0} min
        \\events     {s}
        \\
    , .{
        e.place.lat,     e.place.lon,                               e.place.source,
        pos.elevation,   pos.azimuth,                               sun.clearSky(pos.elevation),
        e.bl.name,       cur,                                       e.bl.max,
        e.pctOf(cur),    100.0 / @as(f64, @floatFromInt(e.bl.max)), e.cfg.step,
        e.step_raw,      e.curvePct(t),                             e.cfg.min,
        e.cfg.max,       e.offset,                                  e.pctOf(e.targetRaw(t)),
        (next - t) / 60, e.events_path,
    });
    try out.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cmd = if (args.len > 1) args[1] else "run";
    const is_run = std.mem.eql(u8, cmd, "run");
    if (!is_run and !std.mem.eql(u8, cmd, "status")) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }

    const env = init.environ_map;
    const home = env.get("HOME") orelse return fail("HOME is not set", .{});
    const config_home = env.get("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(arena, "{s}/.config", .{home});
    const state_home = env.get("XDG_STATE_HOME") orelse try std.fmt.allocPrint(arena, "{s}/.local/state", .{home});
    const z = struct {
        fn z(a: std.mem.Allocator, comptime fmt: []const u8, args_: anytype) ![:0]u8 {
            return std.fmt.allocPrintSentinel(a, fmt, args_, 0);
        }
    }.z;

    const config_path = try z(arena, "{s}/heliodim/config", .{config_home});
    const cfg = Config.load(arena, config_path) catch |e| switch (e) {
        error.Reported => std.process.exit(1),
        else => return e,
    };
    const place = location.resolve(arena, cfg.lat, cfg.lon, .{
        .shell_json = try z(arena, "{s}/omarchy/shell.json", .{config_home}),
        .weather_json = try z(arena, "{s}/.local/state/omarchy/settings/weather.json", .{home}),
    }) catch {
        std.log.err(
            \\location unknown (the time zone names no city). Any one of:
            \\  - lat = 55.75 / lon = 37.62 in {s}
            \\  - pick your city as "here" in the Elsewhen clock
            \\  - omarchy-weather-location --set NAME LAT,LON
        , .{config_path});
        std.process.exit(1);
    };
    const bl = Backlight.open(arena, io, cfg.device) catch |e| switch (e) {
        error.Reported => std.process.exit(1),
        else => return e,
    };

    const state_dir = try z(arena, "{s}/heliodim", .{state_home});
    var engine: Engine = .{
        .cfg = cfg,
        .place = place,
        .bl = bl,
        .step_raw = @max(1, @as(u32, @intFromFloat(@round(cfg.step / 100.0 * @as(f64, @floatFromInt(bl.max)))))),
        .events_path = try z(arena, "{s}/events.jsonl", .{state_dir}),
    };
    engine.loadOffset();

    if (!is_run) return status(io, &engine);
    try sys.mkdir(try z(arena, "{s}", .{state_home}));
    try sys.mkdir(state_dir);
    run(io, &engine) catch |e| switch (e) {
        error.Reported => std.process.exit(1),
        else => return e,
    };
}

test {
    _ = sun;
    _ = location;
}
