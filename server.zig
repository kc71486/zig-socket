const std = @import("std");
const game = @import("game.zig");
const net = std.net;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();
const connection = net.StreamServer.Connection;

pub fn main() !void {
    var out = stdout.writer();
    var in = stdin.reader();
    var server = net.StreamServer.init(.{});

    try server.listen(try net.Address.parseIp("140.116.72.41", 7911));
    server.reuse_address = true;
    try out.print("listening on {}\n", .{server.listen_address});

    var host_thread = try std.Thread.spawn(.{}, hostServer, .{&server});
    var buf: [255]u8 = undefined;
    var fixbuf_stream = std.io.fixedBufferStream(&buf);
    while (true) {
        try in.streamUntilDelimiter(fixbuf_stream.writer(), '\n', buf.len); //blocking
        var written = fixbuf_stream.getWritten();
        if (written.len > 0) {
            if (std.mem.eql(u8, buf[0..written.len], "q")) {
                host_thread.detach();
                break;
            }
        }
    }
}

pub fn hostServer(server: *net.StreamServer) !void {
    defer server.deinit();
    while (true) {
        var conn = try server.accept(); //blocking
        _ = try std.Thread.spawn(.{}, service, .{conn});
    }
}

pub fn service(conn: connection) !void {
    defer conn.stream.close();

    var tetris = try game.Tetris.init();
    _ = tetris;
    var message = "200";

    _ = try conn.stream.write(message);
}
