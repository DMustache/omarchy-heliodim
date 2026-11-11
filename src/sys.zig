//! Thin wrappers over Linux syscalls. heliodim only talks to sysfs, a few
//! small text files and one timerfd, so it skips std.Io for those.

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;
pub const Error = error{ NotFound, Interrupted, Canceled, Sys };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT, .NOTDIR => error.NotFound,
        .INTR => error.Interrupted,
        .CANCELED => error.Canceled,
        else => error.Sys,
    };
}

pub fn open(path: [:0]const u8, flags: linux.O, mode: linux.mode_t) Error!fd_t {
    var f = flags;
    f.CLOEXEC = true;
    return @intCast(try check(linux.open(path, f, mode)));
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn pread(fd: fd_t, buf: []u8, off: u64) Error![]u8 {
    const n = try check(linux.pread(fd, buf.ptr, buf.len, @intCast(off)));
    return buf[0..n];
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len > 0) rest = rest[try check(linux.write(fd, rest.ptr, rest.len))..];
}

pub fn size(fd: fd_t) Error!u64 {
    return try check(@intCast(linux.lseek(fd, 0, linux.SEEK.END)));
}

/// Reads a whole small file into `buf`; error.NotFound if it is absent.
pub fn readFile(path: [:0]const u8, buf: []u8) Error![]u8 {
    const fd = try open(path, .{}, 0);
    defer close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = try pread(fd, buf[n..], n);
        if (got.len == 0) break;
        n += got.len;
    }
    return buf[0..n];
}

pub fn readLink(path: [:0]const u8, buf: []u8) Error![]u8 {
    return buf[0..try check(linux.readlink(path, buf.ptr, buf.len))];
}

/// mkdir that treats an existing directory as success.
pub fn mkdir(path: [:0]const u8) Error!void {
    const rc = linux.mkdir(path, 0o755);
    if (linux.errno(rc) == .EXIST) return;
    _ = try check(rc);
}

/// Wall-clock time as fractional Unix seconds.
pub fn now() f64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

pub fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
}

/// A timer on the wall clock at an absolute moment. Unlike a poll timeout it
/// counts suspended time (it fires right after resume when the moment has
/// passed) and wakes early when the clock is set, so the schedule is redone.
pub fn timerCreate() Error!fd_t {
    return @intCast(try check(linux.timerfd_create(.REALTIME, .{ .CLOEXEC = true, .NONBLOCK = true })));
}

pub fn timerArm(fd: fd_t, at_unix: f64) Error!void {
    const sec: isize = @intFromFloat(@floor(at_unix));
    const nsec: isize = @intFromFloat((at_unix - @floor(at_unix)) * 1e9);
    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = sec, .nsec = nsec },
    };
    _ = try check(linux.timerfd_settime(fd, .{ .ABSTIME = true, .CANCEL_ON_SET = true }, &spec, null));
}

/// Clears a fired (or clock-change-canceled) timer.
pub fn timerAck(fd: fd_t) void {
    var buf: [8]u8 = undefined;
    _ = linux.read(fd, &buf, buf.len);
}

pub fn poll(fds: []linux.pollfd, timeout_ms: i32) Error!usize {
    return check(linux.poll(fds.ptr, fds.len, timeout_ms)) catch |e| switch (e) {
        error.Interrupted => 0,
        else => e,
    };
}
