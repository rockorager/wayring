//! Bounded protocol-independent wl_shm metadata validation.

const std = @import("std");

pub const Error = error{
    InvalidConfig,
    InvalidPoolSize,
    PoolTooLarge,
    InvalidResize,
    InvalidDimensions,
    InvalidStride,
    OutOfBounds,
    SizeOverflow,
};

/// Compositor-supplied metadata for an advertised wl_shm format. Keeping the
/// byte width beside the protocol value permits stricter stride validation for
/// both core and compositor-added formats.
pub const Format = struct {
    value: u32,
    bytes_per_pixel: u8,
};

pub const Limits = struct {
    max_pool_bytes: usize,

    pub fn validate(limits: Limits) Error!void {
        if (limits.max_pool_bytes == 0 or
            limits.max_pool_bytes > std.math.maxInt(i32))
            return error.InvalidConfig;
    }
};

pub const Buffer = struct {
    offset: usize,
    width: u32,
    height: u32,
    stride: usize,
    format: Format,

    /// Bytes conservatively reserved in the pool, including final-row
    /// padding. This matches established compositor behavior and makes sibling
    /// overlap checks possible without repeating arithmetic.
    extent: usize,

    pub fn end(buffer: Buffer) usize {
        return buffer.offset + buffer.extent;
    }
};

pub fn createPool(limits: Limits, requested_size: i32) Error!usize {
    try limits.validate();
    if (requested_size <= 0) return error.InvalidPoolSize;
    const size: usize = @intCast(requested_size);
    if (size > limits.max_pool_bytes) return error.PoolTooLarge;
    return size;
}

pub fn resizePool(limits: Limits, current_size: usize, requested_size: i32) Error!usize {
    const size = try createPool(limits, requested_size);
    if (size < current_size) return error.InvalidResize;
    return size;
}

/// Validates immutable wl_buffer metadata against one declared pool size.
/// Every multiplication and addition is checked before state publication.
pub fn createBuffer(
    pool_size: usize,
    format: Format,
    offset_value: i32,
    width_value: i32,
    height_value: i32,
    stride_value: i32,
) Error!Buffer {
    if (format.bytes_per_pixel == 0) return error.InvalidConfig;
    if (offset_value < 0) return error.OutOfBounds;
    if (width_value <= 0 or height_value <= 0) return error.InvalidDimensions;
    if (stride_value <= 0) return error.InvalidStride;

    const offset: usize = @intCast(offset_value);
    const width: usize = @intCast(width_value);
    const height: usize = @intCast(height_value);
    const stride: usize = @intCast(stride_value);
    const row_bytes = std.math.mul(
        usize,
        width,
        format.bytes_per_pixel,
    ) catch return error.SizeOverflow;
    if (stride < row_bytes) return error.InvalidStride;
    const extent = std.math.mul(usize, stride, height) catch
        return error.SizeOverflow;
    const end = std.math.add(usize, offset, extent) catch
        return error.SizeOverflow;
    if (end > pool_size) return error.OutOfBounds;

    return .{
        .offset = offset,
        .width = @intCast(width),
        .height = @intCast(height),
        .stride = stride,
        .format = format,
        .extent = extent,
    };
}

test "pool creation and growth enforce configured bounds" {
    const limits: Limits = .{ .max_pool_bytes = 4096 };
    try std.testing.expectError(error.InvalidPoolSize, createPool(limits, 0));
    try std.testing.expectError(error.PoolTooLarge, createPool(limits, 4097));
    try std.testing.expectEqual(@as(usize, 4096), try createPool(limits, 4096));
    try std.testing.expectError(error.InvalidResize, resizePool(limits, 4096, 2048));
    try std.testing.expectEqual(@as(usize, 4096), try resizePool(limits, 2048, 4096));
    try std.testing.expectError(error.InvalidConfig, createPool(.{
        .max_pool_bytes = 0,
    }, 1));
}

test "buffer validation is format-aware and overflow-safe" {
    const argb8888: Format = .{ .value = 0, .bytes_per_pixel = 4 };
    const buffer = try createBuffer(4096, argb8888, 16, 8, 4, 40);
    try std.testing.expectEqual(@as(usize, 160), buffer.extent);
    try std.testing.expectEqual(@as(usize, 176), buffer.end());

    try std.testing.expectError(
        error.InvalidStride,
        createBuffer(4096, argb8888, 0, 8, 4, 31),
    );
    try std.testing.expectError(
        error.OutOfBounds,
        createBuffer(4096, argb8888, 4000, 8, 4, 32),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        createBuffer(4096, argb8888, 0, 0, 4, 32),
    );
    try std.testing.expectError(
        error.OutOfBounds,
        createBuffer(4096, argb8888, -1, 8, 4, 32),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        createBuffer(4096, .{ .value = 1, .bytes_per_pixel = 0 }, 0, 1, 1, 1),
    );
}
