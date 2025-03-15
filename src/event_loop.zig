const std = @import("std");
const print = std.debug.print;

const Timeout = struct {
    const Self = @This();
    name: []const u8,
    threashold: usize,
    current_tick: usize,

    fn tick(self: *Self) void {
        self.current_tick += 1;
    }

    fn fired(self: *Self) bool {
        return self.current_tick >= self.threashold;
    }
};

const Events = struct {
    const Self = @This();
    io: *IO,
    fast_ticker: Timeout,
    slow_ticker: Timeout,

    fn slowPrint(self: *Self) void {
        print("slow printing {}\n", .{self.slow_ticker.current_tick});
        self.slow_ticker.current_tick = 0;
    }

    fn fastPrint(self: *Self) void {
        print("fast printing {}\n", .{self.fast_ticker.current_tick});
        self.fast_ticker.current_tick = 0;
    }

    pub fn init(io: *IO) Self {
        return .{
            .io = io,
            .fast_ticker = .{ .name = "fast_ticker", .threashold = 5, .current_tick = 0 },
            .slow_ticker = .{ .name = "slow_ticker", .threashold = 10, .current_tick = 0 },
        };
    }
    pub fn tick(self: *Self) void {
        const timeouts = .{
            .{
                &self.fast_ticker, fastPrint,
            },
            .{
                &self.slow_ticker, slowPrint,
            },
        };
        // Check tasks completed from callback?

        inline for (timeouts) |timeout| {
            timeout[0].tick();
        }
        inline for (timeouts) |timeout| {
            if (timeout[0].fired()) timeout[1](self);
        }

        // Read from ring, queue to io queue.
        // Read from cq queue, update/write ring.
        // Flush and wait??
    }
};

const IO = struct {
    pub fn run_for_ns(_: *IO, ns: u64) void {
        _ = ns;
        std.Thread.sleep(100_000_000);
        //Do tigerbeetle io stuff??
    }
};

pub fn main() !void {
    var io = IO{};
    var events = Events.init(&io);
    while (true) {
        events.tick();
        io.run_for_ns(1000);
    }
}
