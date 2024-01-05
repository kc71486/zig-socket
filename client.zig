const std = @import("std");
const game = @import("game.zig");
const net = std.net;
const GPA = std.heap.GeneralPurposeAllocator(.{});
const stdout = std.io.getStdOut();

pub fn main() !void {
    var out = stdout.writer();
    var gpa = GPA{};
    var alloc = gpa.allocator();
    var stream = try net.tcpConnectToHost(alloc, "140.116.72.41", 7911);
    defer stream.close();

    const message = "GET";
    _ = try stream.write(message);

    var readbuffer: [100]u8 = undefined;
    const readsize = try stream.read(&readbuffer);
    try out.print("{s}\n", .{readbuffer[0..readsize]});
}
