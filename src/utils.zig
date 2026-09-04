const std = @import("std");
const AtomicUsize = std.atomic.Value(usize);
const Thread = std.Thread;
const cache_line = std.atomic.cache_line;

pub const Range = struct { start: usize, end: usize };

/// Padded so it lives in its own cache line (and doesn't evict useful data when incremented).
const AtomicCounter = struct {
    value: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0),
    _padding: [cache_line - @sizeOf(AtomicUsize)]u8 = undefined,
};

/// Simple index-based partitioner to support lock-free multithreading
pub const AtomicRangeIter = struct {
    r: AtomicCounter = .{}, // index of the next range
    // r: AtomicUsize = AtomicUsize.init(0),
    num_ranges: usize, // number of ranges
    quotient: usize, // base length given to all ranges
    remainder: usize, // remaining length split among early ranges
    start: usize, // start index
    const Self = @This();

    /// Creates a range iterator that subdivides the range from [start, end).
    pub fn init(start: usize, end: usize, num_partitions: usize) !Self {
        if (start > end) return error.InvalidIndexes;
        if (num_partitions < 1) return error.InvalidNumberPartitions;
        if (start == end) {
            return .{ .num_ranges = 1, .quotient = 0, .remainder = 0, .start = start };
        } else {
            const n = @min(num_partitions, end - start);
            const total_len = end - start;
            return .{
                .num_ranges = n,
                .quotient = total_len / n,
                .remainder = total_len % n,
                .start = start,
            };
        }
    }

    /// Gets the next range, or null if all ranges were already retrieved.
    pub fn next(self: *Self) ?Range {
        const i = self.r.value.fetchAdd(1, .monotonic);
        // const i = self.r.fetchAdd(1, .monotonic);
        if (i >= self.num_ranges) return null;
        // previous i ranges will have had remainder distributed among them
        const rem_accumulated = @min(i, self.remainder);
        const range_start = self.start + rem_accumulated + i * self.quotient;
        const len = self.quotient + @intFromBool(i < self.remainder);
        return .{ .start = range_start, .end = range_start + len };
    }
};

/// Wraps a slice of caller-owned memory, tracking how much of it is filled.
/// Holds mutable cursor state: always pass/store by pointer (`*BoundedList(T)`).
pub fn BoundedList(comptime T: type) type {
    return struct {
        index: usize = 0,
        items: []T = undefined,
        const Self = @This();

        /// Inits an empty list backed by a slice of caller-owned memory.
        pub fn init(slice: []T) Self {
            return .{ .items = slice };
        }

        /// Appends an item; returns BufferCapacityExceeded if at capacity.
        pub fn add(self: *Self, item: T) !void {
            if (self.index >= self.items.len) return error.BufferCapacityExceeded;
            self.items[self.index] = item;
            self.index += 1;
        }

        /// Empties the list without releasing its backing memory.
        pub fn clear(self: *Self) void {
            self.index = 0;
        }

        /// Gets a slice containing the current items.
        pub fn getItems(self: *const Self) []T {
            return self.items[0..self.index];
        }

        pub fn sortAsc(self: *Self) void {
            std.sort.pdq(T, self.items[0..self.index], {}, asc);
        }

        pub fn sortDesc(self: *Self) void {
            std.sort.pdq(T, self.items[0..self.index], {}, desc);
        }

        fn asc(_: void, a: T, b: T) bool {
            return a < b;
        }
        fn desc(_: void, a: T, b: T) bool {
            return a > b;
        }
    };
}

const testing = std.testing;

test "test range iterator" {
    const desired_parts = 13;
    const len_max = 1000;
    const num_tests = 1000;
    const start_max = 1000;
    var prng = std.Random.DefaultPrng.init(0);
    var random = prng.random();
    for (0..num_tests) |_| {
        const start = random.uintAtMost(usize, start_max);
        const end = start + random.uintAtMost(usize, len_max);
        var len_covered: usize = 0;
        var range_iter = try AtomicRangeIter.init(start, end, desired_parts);
        while (range_iter.next()) |p| {
            try testing.expect(p.start >= start);
            try testing.expect(p.end <= end);
            len_covered += p.end - p.start;
        }
        try testing.expectEqual(len_covered, end - start);
    }
}

test "check AtomicRangeIter layout" {
    std.debug.print("alignOf(AtomicRangeIter) = {}\n", .{@alignOf(AtomicRangeIter)});
    std.debug.print("sizeOf(AtomicRangeIter)  = {}\n", .{@sizeOf(AtomicRangeIter)});
    std.debug.print("alignOf(AtomicUsize)     = {}\n", .{@alignOf(AtomicUsize)});
    std.debug.print("cache line               = {}\n", .{std.atomic.cache_line});

    std.debug.print("offset r          = {}\n", .{@offsetOf(AtomicRangeIter, "r")});
    std.debug.print("offset num_ranges  = {}\n", .{@offsetOf(AtomicRangeIter, "num_ranges")});
    std.debug.print("offset quotient    = {}\n", .{@offsetOf(AtomicRangeIter, "quotient")});
    std.debug.print("offset remainder   = {}\n", .{@offsetOf(AtomicRangeIter, "remainder")});
    std.debug.print("offset start       = {}\n", .{@offsetOf(AtomicRangeIter, "start")});
}
