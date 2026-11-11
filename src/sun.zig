//! Where the sun is and how bright a clear sky would be.
//!
//! The position math is the one Omarchy's Elsewhen clock draws its daylight
//! strip with (shell/plugins/panels/elsewhen/GlobeModel.js `subsolarPoint`), so
//! heliodim's sunrise is the one the clock shows. Good to a fraction of a degree.

const std = @import("std");
const math = std.math;

const deg = math.pi / 180.0;
const axial_tilt = 23.44;

pub const Pos = struct {
    /// Degrees above the horizon, negative below it.
    elevation: f64,
    /// Degrees clockwise from north.
    azimuth: f64,
};

fn wrap180(x: f64) f64 {
    return @mod(x + 540.0, 360.0) - 180.0;
}

/// The point on Earth with the sun straight overhead, in degrees.
fn subsolar(unix: f64) struct { lat: f64, lon: f64 } {
    const n = unix / 86400.0 + 2440587.5 - 2451545.0; // days since J2000
    const L = @mod(280.460 + 0.9856474 * n, 360.0); // mean longitude
    const g = @mod(357.528 + 0.9856003 * n, 360.0) * deg; // mean anomaly
    const lambda = (L + 1.915 * @sin(g) + 0.020 * @sin(2 * g)) * deg; // ecliptic longitude
    const eps = (axial_tilt - 0.0000004 * n) * deg; // obliquity

    const decl = math.asin(@sin(eps) * @sin(lambda)) / deg;
    const alpha = math.atan2(@cos(eps) * @sin(lambda), @cos(lambda)) / deg;
    const eot = wrap180(L - alpha); // equation of time, degrees
    const utc_hours = @mod(unix, 86400.0) / 3600.0;
    return .{ .lat = decl, .lon = wrap180(-15.0 * (utc_hours - 12.0) - eot) };
}

pub fn position(lat: f64, lon: f64, unix: f64) Pos {
    const s = subsolar(unix);
    const p = lat * deg;
    const d = s.lat * deg;
    const h = (s.lon - lon) * deg;
    const cosz = @sin(p) * @sin(d) + @cos(p) * @cos(d) * @cos(h);
    const az = math.atan2(@sin(h) * @cos(d), @cos(p) * @sin(d) - @sin(p) * @cos(d) * @cos(h)) / deg;
    return .{
        .elevation = math.asin(math.clamp(cosz, -1.0, 1.0)) / deg,
        .azimuth = @mod(az + 360.0, 360.0),
    };
}

/// Clear-sky global horizontal irradiance, W/m² (Haurwitz 1945).
pub fn clearSky(elevation: f64) f64 {
    if (elevation <= 0) return 0;
    const cz = @sin(elevation * deg);
    return 1098.0 * cz * @exp(-0.057 / cz);
}

/// The clear-sky brightness curve, 0..1. Eyes are closer to logarithmic than
/// linear, so the square root lifts the dim end: 10° of sun is ~37%, 30° ~70%.
pub fn level(elevation: f64) f64 {
    return @sqrt(math.clamp(clearSky(elevation) / 1000.0, 0.0, 1.0));
}

test "noon in Moscow on the equinox" {
    // 2025-03-20 09:30 UTC is close to local solar noon at 37.6°E.
    const p = position(55.75, 37.62, 1742463000);
    try std.testing.expectApproxEqAbs(@as(f64, 90 - 55.75), p.elevation, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 180), p.azimuth, 3.0);
}

test "curve" {
    try std.testing.expectEqual(@as(f64, 0), level(-5));
    try std.testing.expect(level(10) > 0.3 and level(10) < 0.45);
    try std.testing.expect(level(60) > 0.9);
}
