const std = @import("std");
const game = @import("game.zig");
const rawmode = @import("rawmode.zig");
const net = std.net;
const Thread = std.Thread;
const GPA = std.heap.GeneralPurposeAllocator(.{});
var out = std.io.getStdOut().writer();
var in = std.io.getStdIn().reader();

var gpa = GPA{};
var alloc = gpa.allocator();
const newl = "\x1b[S\x1b[E";

var read_buf: [1024]u8 = undefined;
var write_buf: [1024]u8 = undefined;

var cmd: u8 = 0;
var cmd_m: Thread.Mutex = Thread.Mutex{};

pub fn main() !void {
    rawmode.enableRawMode();
    try out.print(newl ** 50, .{});
    var conn_thread = try Thread.spawn(.{}, connectServer, .{});
    defer conn_thread.detach();
    var stdin_thread = try Thread.spawn(.{}, readInput, .{});
    var game_thread = try Thread.spawn(.{}, runGame, .{});
    defer game_thread.detach();
    //conn_thread.join();
    stdin_thread.join();
    //game_thread.join();
}

pub fn readInput() !void {
    var input: u8 = undefined;
    while (true) {
        input = try in.readByte(); //blocking
        if (input == 'q') { // quit
            try out.print(newl ++ "exited" ++ newl, .{});
            break; //quit
        }
        if (input == 3) { //ctrl + c
            break;
        }
        cmd_m.lock(); //mutex
        cmd = input;
        cmd_m.unlock();
    }
}

pub fn connectServer() !void {
    var stream = try net.tcpConnectToHost(alloc, "140.116.72.41", 7911);
    defer stream.close();

    const message = "connect";
    _ = try stream.write(message);

    var readbuffer: [100]u8 = undefined;
    const readsize = try stream.read(&readbuffer);
    try out.print("{s}" ++ newl, .{readbuffer[0..readsize]});
    while (true) {}
}

pub fn runGame() !void {
    var tetris = try game.Tetris.init();
    _ = tetris;
    while (true) {
        cmd_m.lock(); //mutex
        if (cmd != 0) {
            try out.print("{c}", .{cmd + 1});
        }
        cmd = 0;
        cmd_m.unlock();
    }
}
