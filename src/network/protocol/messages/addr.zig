const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();
const protocol = @import("../lib.zig");

const ServiceFlags = protocol.ServiceFlags;

const Endian = std.builtin.Endian;
const Sha256 = std.crypto.hash.sha2.Sha256;

const CompactSizeUint = @import("bitcoin-primitives").types.CompatSizeUint;

/// AddrMessage represents the "addr" message
///
/// https://developer.bitcoin.org/reference/p2p_networking.html#addr
pub const NetworkIPAddr = struct {
    time: u32, // Unix epoch time
    services: u64, // Services offered by the node
    ip: [16]u8, // IPv6 address (including IPv4-mapped)
    port: u16, // Port number
               //
               //

// NetworkIPAddr eql
pub fn eql(self: *const NetworkIPAddr, other: *const NetworkIPAddr) bool {
    return self.time == other.time
        and self.services == other.services
        and std.mem.eql(u8, &self.ip, &other.ip)
        and self.port == other.port;
}
};

pub const AddrMessage = struct {
    ip_address_count: CompactSizeUint,
    ip_addresses: []NetworkIPAddr,


    pub inline fn name() *const [12]u8 {
        return protocol.CommandNames.ADDR ++ [_]u8{0} ** 8;
    }

    /// Returns the message checksum
    ///
    /// Computed as `Sha256(Sha256(self.serialize()))[0..4]`
    pub fn checksum(self: AddrMessage) [4]u8 {
        var digest: [32]u8 = undefined;
        var hasher = Sha256.init(.{});
        const writer = hasher.writer();
        self.serializeToWriter(writer) catch unreachable; // Sha256.write is infaible
        hasher.final(&digest);

        Sha256.hash(&digest, &digest, .{});

        return digest[0..4].*;
    }

    /// Free the `user_agent` if there is one
    pub fn deinit(self: AddrMessage, allocator: std.mem.Allocator) void {
        if (self.ip_addresses.len > 0) {
            allocator.free(self.ip_addresses);
        }
    }

    /// Serialize the message as bytes and write them to the Writer.
    ///
    /// `w` should be a valid `Writer`.
    pub fn serializeToWriter(self: *const AddrMessage, w: anytype) !void {
        comptime {
            if (!std.meta.hasFn(@TypeOf(w), "writeInt")) @compileError("Expects r to have fn 'writeInt'.");
            if (!std.meta.hasFn(@TypeOf(w), "writeAll")) @compileError("Expects r to have fn 'writeAll'.");
        }
// Serialize number of IP addresses
        //
        try self.ip_address_count.encodeToWriter(w);

        // Serialize each IP address
        for (self.ip_addresses) |ip_address| {
            try w.writeInt(u32, ip_address.time, .little);
            try w.writeInt(u64, ip_address.services, .little);
        try w.writeAll(std.mem.asBytes(&ip_address.ip));
            try w.writeInt(u16, ip_address.port, .big);
        }
    }

    /// Serialize a message as bytes and write them to the buffer.
    ///
    /// buffer.len must be >= than self.hintSerializedLen()
    pub fn serializeToSlice(self: *const AddrMessage, buffer: []u8) !void {
        var fbs = std.io.fixedBufferStream(buffer);
        const writer = fbs.writer();
        try self.serializeToWriter(writer);
    }

    /// Serialize a message as bytes and return them.
    pub fn serialize(self: *const AddrMessage, allocator: std.mem.Allocator) ![]u8 {
        const serialized_len = self.hintSerializedLen();

        const ret = try allocator.alloc(u8, serialized_len);
        errdefer allocator.free(ret);

        try self.serializeToSlice(ret);

        return ret;
    }

    /// Deserialize a Reader bytes as a `AddrMessage`
    pub fn deserializeReader(allocator: std.mem.Allocator, r: anytype) !AddrMessage {
        comptime {
            if (!std.meta.hasFn(@TypeOf(r), "readInt")) @compileError("Expects r to have fn 'readInt'.");
            if (!std.meta.hasFn(@TypeOf(r), "readNoEof")) @compileError("Expects r to have fn 'readNoEof'.");
            if (!std.meta.hasFn(@TypeOf(r), "readAll")) @compileError("Expects r to have fn 'readAll'.");
        }

        var vm: AddrMessage = undefined;
        const ip_address_count = try CompactSizeUint.decodeReader(r);

        // Allocate space for IP addresses
        const ip_addresses = try allocator.alloc(NetworkIPAddr, ip_address_count.value());
        errdefer allocator.free(ip_addresses);

        vm.ip_addresses = ip_addresses;

        for (vm.ip_addresses) |*ip_address| {
            ip_address.time = try r.readInt(u32, .little);
            ip_address.services = try r.readInt(u64, .little);
            try r.readNoEof(&ip_address.ip);
            ip_address.port = try r.readInt(u16, .big);
        }

        return vm;
    }

    /// Deserialize bytes into a `AddrMessage`
    pub fn deserializeSlice(allocator: std.mem.Allocator, bytes: []const u8) !AddrMessage {
        var fbs = std.io.fixedBufferStream(bytes);
        const reader = fbs.reader();
        return try AddrMessage.deserializeReader(allocator, reader);
    }

    pub fn hintSerializedLen(self: AddrMessage) usize {
        // 4 + 8 + 16 + 2
        const fixed_length_per_ip = 30;
        return 1 +  self.ip_address_count.value() * fixed_length_per_ip;// 1 for CompactSizeUint

    }

    pub fn eql(self: *const AddrMessage, other: *const AddrMessage) bool {
    if (self.ip_address_count.value() != other.ip_address_count.value()) return false;

    const count = @as(usize, self.ip_address_count.value()); // Convert to usize
    for (0..count) |i| {
        if (!self.ip_addresses[i].eql(&other.ip_addresses[i])) return false;
    }

    return true;
    }
};

// TESTS

test "ok_full_flow_AddrMessage" {
    const allocator = std.testing.allocator;

    {
    const ips = [_]NetworkIPAddr{
        NetworkIPAddr{
        .time = 1414012889,
        .services = ServiceFlags.NODE_NETWORK,
        .ip = [_]u8{13} ** 16,
        .port = 33,
        
        }, 
    };
    const am = AddrMessage{
        .ip_address_count = CompactSizeUint.new(1),
        .ip_addresses = try allocator.alloc(NetworkIPAddr, 1),
    };
        defer allocator.free(am.ip_addresses); // Ensure to free the allocated memory

        am.ip_addresses[0] = ips[0];

        const payload = try am.serialize(allocator);
        defer allocator.free(payload);
        const deserialized_am = try AddrMessage.deserializeSlice(allocator, payload);
        defer deserialized_am.deinit(allocator);

        try std.testing.expect(am.eql(&deserialized_am));
    }

}
