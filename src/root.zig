const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const MPSCRingBuffer = @import("mpsc_shm_ringbuf.zig").MPSCRingBuffer;
const SPMCRingBuffer = @import("spmc_shm_ringbuf.zig").SPMCRingBuffer;
const RingBufferType = @import("ringbuf.zig").RingBufferType;

const Role = enum { master, worker, not_connected };

const Message = struct {};
threadlocal var worker: ?u8 = null;
threadlocal var role: Role = .not_connected;
const mpsc_path = "/mpsc_buffer";

/// Sets up a new instance of ZigPipe this makes you master needs to be no other master.
export fn init() !void {
    //FIXME: Add a check for if there is another master.
    if (role != .not_connected) {
        return error.AlreadyConnectedToCluster;
    }
    role = .master;
    var mspc_buffer = try MPSCRingBuffer(Message, 1000, .Consumer, mpsc_path).init();
    defer mspc_buffer.deinit();
    var spmc_buffer = try SPMCRingBuffer(Message, 1000, .Producer, mpsc_path).init();
    defer spmc_buffer.deinit();
    var buffer = RingBufferType(Message, 1000);

    // Main event loop
    while (true) {
        if (!spmc_buffer.full) {
            if (buffer.head()) |item| {
                spmc_buffer.push(item);
                buffer.advance_head();
            }
        } else if (!buffer.is_full) {
            if (mspc_buffer.pop()) |item| {
                buffer.push(item);
                mspc_buffer.advance_tail();
            }
        }
    }
}

const ExternalAddress = struct {
    url: []const ?u8,
    ip_address: ?u8,
    port: ?u16,
};

/// Joins a cluster and optinally registers a worker (if dissconected)
/// TODO: Add support for ip_address, zombie pid problem?
export fn join(cluster_id: u8, worker_pid: ?u8, ext_adrs: ExternalAddress) u8 {
    if (worker_pid) {
        worker = worker_pid;
    }
    _ = cluster_id;
    _ = ext_adrs;
    return worker_pid orelse "hello";
}

/// For the master node to register a worker that has joined. (Maybe just watch the mpsc_shm for this?)
export fn register(worker_id: u8) void {
    assert(role == .master);
    worker = worker_id;
}

export fn disconnect() bool {
    return true;
}
