const std = @import("std");
const game = @import("game.zig");
const rawmode = @import("rawmode.zig");
const net = std.net;
const Thread = std.Thread;
const Tetris = game.Tetris;
const GPA = std.heap.GeneralPurposeAllocator(.{});
const out = std.io.getStdOut().writer();
const in = std.io.getStdIn().reader();
const compfmt = std.fmt.comptimePrint;

const STARTSTR = "\x1b[60S\x1b[2J\x1b[H\x1b[?25l";
const QUITSTR = "\x1b[m\x1b[?25h\x1b[2J\x1b[Hexited\x1b[E";

var gpa = GPA{};
var alloc = gpa.allocator();

var read_buf: Buffer = .{};
var write_buf: Buffer = .{};

var cmd: u8 = 0;
var cmd_m: Thread.Mutex = Thread.Mutex{};

var tetris_opt: ?*Tetris = null;
var tetris_m: Thread.Mutex = Thread.Mutex{};

const Buffer = struct {
    const This = @This();
    buf: [65536]u8 = undefined,
    end: usize = 0,
    pub fn write(this: *This, bytes: []const u8) !void {
        const n = bytes.len;
        if (this.end + n >= this.buf.len)
            return error.NoSpaceLeft;
        @memcpy(this.buf[this.end..][0..n], bytes[0..n]);
        this.end += n;
    }
    pub fn print(this: *This) !void {
        const end = this.end;
        try out.print("{s}", .{this.buf[0..end]});
        this.end = 0;
    }
};

pub fn main() !void {
    rawmode.enableRawMode();
    var conn_thread = try Thread.spawn(.{}, connectServer, .{});
    var stdin_thread = try Thread.spawn(.{}, readInput, .{});
    var stdout_thread = try Thread.spawn(.{}, display, .{});
    var game_thread = try Thread.spawn(.{}, runGame, .{});
    stdin_thread.join();
    game_thread.detach();
    conn_thread.detach();
    stdout_thread.detach();
}

pub fn readInput() !void {
    var input: u8 = undefined;
    while (true) {
        input = try in.readByte(); //blocking
        if (input == 'q') { // quit
            try out.print(QUITSTR, .{});
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

pub fn display() !void {
    const GRIDHEIGHT = 20;
    const GRIDWIDTH = 10;
    const GX = 13;
    const GY = 24;
    try out.print(STARTSTR, .{});
    var out_buf: Buffer = .{};
    while (true) {
        try out_buf.write(compfmt("\x1b[{d};{d}H", .{ GY - 20, GX - 1 }));
        for (0..GRIDHEIGHT) |_| {
            try out_buf.write("|\x1b[B\x1b[D");
        }
        try out_buf.write(compfmt("\x1b[{d};{d}H", .{ GY - 20, GX + 21 }));
        for (0..GRIDHEIGHT) |_| {
            try out_buf.write("|\x1b[B\x1b[D");
        }
        try out_buf.write(compfmt("\x1b[{d};{d}H", .{ GY, GX }));
        if (tetris_opt) |tetris| {
            tetris_m.lock();
            for (0..GRIDHEIGHT) |row| {
                for (0..GRIDWIDTH) |col| {
                    const c: game.Cell = tetris.grid[row][col];
                    switch (c) {
                        .empty => try out_buf.write("  "),
                        .I => try out_buf.write("\x1b[36m██"),
                        .J => try out_buf.write("\x1b[31m██"),
                        .L => try out_buf.write("\x1b[34m██"),
                        .O => try out_buf.write("\x1b[33m██"),
                        .S => try out_buf.write("\x1b[32m██"),
                        .Z => try out_buf.write("\x1b[37m██"),
                        .T => try out_buf.write("\x1b[35m██"),
                    }
                }
                try out_buf.write("\x1b[A\x1b[13G");
            }
            const cur_blocks: [4]game.CoordI = tetris.getCurrentBlocks();
            for (cur_blocks) |block| {
                if (block.y >= 20) {
                    continue;
                }
                const xpos = GX + block.x * 2;
                const ypos = GY - block.y;
                var buf_str: [10]u8 = undefined;
                var pos_str = try std.fmt.bufPrint(&buf_str, "\x1b[{};{}H", .{ ypos, xpos });
                try out_buf.write(pos_str);
                switch (tetris.current.shape) {
                    .I => try out_buf.write("\x1b[36m▮▮"),
                    .J => try out_buf.write("\x1b[31m▮▮"),
                    .L => try out_buf.write("\x1b[34m▮▮"),
                    .O => try out_buf.write("\x1b[33m▮▮"),
                    .S => try out_buf.write("\x1b[32m▮▮"),
                    .Z => try out_buf.write("\x1b[37m▮▮"),
                    .T => try out_buf.write("\x1b[35m▮▮"),
                }
            }
            tetris_m.unlock();
            try out_buf.write("\x1b[39m");
        }
        try out_buf.print();
        std.time.sleep(1_000_000); // 1 ms
    }
}

pub fn connectServer() !void {
    var stream = try net.tcpConnectToHost(alloc, "140.116.72.41", 7911);
    defer stream.close();

    const message = "connect";
    _ = try stream.write(message);

    var readbuffer: Buffer = .{};
    readbuffer.end = try stream.read(&readbuffer.buf);
    while (true) {}
}

pub fn runGame() !void {
    var tetris: *Tetris = try Tetris.create(alloc);
    tetris_opt = tetris;
    defer {
        tetris.destroy();
        tetris_opt = null;
    }
    tetris.grid[3][3] = .I;
    tetris.current.shape = .T;
    while (true) {
        cmd_m.lock(); //mutex
        tetris_m.lock();
        switch (cmd) {
            'a' => _ = tetris.moveLeft(),
            'd' => _ = tetris.moveRight(),
            's' => _ = tetris.moveDown(true),
            'z' => _ = tetris.rotateLeft(),
            'c' => _ = tetris.rotateRight(),
            ' ' => {},
            'h' => {},
            else => {},
        }
        tetris_m.unlock();
        cmd = 0;
        cmd_m.unlock();
    }
}
