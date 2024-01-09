const std = @import("std");
const game = @import("game.zig");
const rawmode = @import("rawmode.zig");
const netobj = @import("netObject.zig");
const net = std.net;
const Thread = std.Thread;
const Tetris = game.Tetris;
const GPA = std.heap.GeneralPurposeAllocator(.{});
const out = std.io.getStdOut().writer();
const in = std.io.getStdIn().reader();
const assert = std.debug.assert;
const compfmt = std.fmt.comptimePrint;
const ClientObject = netobj.ClientObject;
const ServerObject = netobj.ServerObject;
const MatchResult = netobj.MatchResult;

const STARTSTR = "\x1b[60S\x1b[2J\x1b[H\x1b[?25l";
const QUITSTR = "\x1b[m\x1b[?25h\x1b[41Hexited\x1b[E";

var gpa = GPA{};
var alloc = gpa.allocator();

var cmd: u8 = 0; // write: in + game, read: game
var cmd_m: Thread.Mutex = Thread.Mutex{};

var tetris_opt: ?*Tetris = null; // write: game, read: game/out
var tetris_m: Thread.Mutex = Thread.Mutex{};

var rtetris_opt: ?*Tetris = null; // write: conn, read: out
var rtetris_m: Thread.Mutex = Thread.Mutex{};

const Status = struct {
    const This = @This();
    global: StatusType = .INIT, // write: all, read: all
    global_m: Thread.Mutex = Thread.Mutex{},
    conn: StatusType = .INIT, // write: conn, read: anyprobe
    game: StatusType = .INIT, // write: game, read: anyprobe
    in: StatusType = .INIT, // write: in, read: anyprobe
    out: StatusType = .INIT, // write: out, read: anyprobe
    fn waitAllInit(this: *This) void {
        this.global_m.lock();
        this.global = .MATCH;
        this.global_m.unlock();
        while (this.conn == .INIT) {}
        while (this.game == .INIT) {}
        while (this.in == .INIT) {}
        while (this.out == .INIT) {}
    }
};

const StatusType = enum {
    const This = @This();
    INIT, // initialize
    MATCH, // matching
    PLAY, // playing
    RESULT, // player/opponent lose or disconnect
    END, // end cause by manual exit
    fn syncwith(this: *This, other: *This) void {
        const global: *StatusType = &status.global;
        if (this.* != global.*)
            return;
        while (other.* != global.*) {}
    }
};

var status: Status = .{};
var matchresult: MatchResult = .PENDING; // write: conn + game, read: out
var matchresult_m: Thread.Mutex = Thread.Mutex{};

pub const Buffer = struct {
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
    try out.print(STARTSTR, .{});
    status.global_m.lock();
    status.global = .MATCH;
    status.global_m.unlock();
    var conn_th = try Thread.spawn(.{}, connectServer, .{});
    var game_th = try Thread.spawn(.{}, runGame, .{});
    var out_th = try Thread.spawn(.{}, display, .{});
    var in_th = try Thread.spawn(.{}, readInput, .{});
    in_th.join();
    out_th.detach(); // should already finish
    game_th.detach(); //should already finish
    conn_th.detach();
    try out.print(QUITSTR, .{});
}

fn readInput() !void {
    var input: u8 = undefined;
    status.in = .MATCH;
    status.waitAllInit();
    while (true) {
        input = try in.readByte(); //blocking
        if (input == 'q' or input == 3) { // 'q' or ^C
            status.in = .END;
            break;
        }
        cmd_m.lock();
        cmd = input;
        cmd_m.unlock();
        std.time.sleep(0);
    }
}

fn display() !void {
    const GH = game.DISPLAYHEIGHT;
    const GW = game.DISPLAYWIDTH;
    const GX = 13;
    const GY = 24;
    const OX = 48;
    const OY = 24;

    var out_buf: Buffer = .{};
    const grid_border = "|\x1b[A\x1b[D" ** GH;
    try out_buf.write(compfmt("\x1b[{d};{d}H", .{ GY, GX - 1 }));
    try out_buf.write(grid_border);
    try out_buf.write(compfmt("\x1b[{d};{d}H", .{ GY, GX + GW * 2 + 1 }));
    try out_buf.write(grid_border);
    try out_buf.write(compfmt("\x1b[{d};{d}H", .{ OY, OX - 1 }));
    try out_buf.write(grid_border);
    try out_buf.write(compfmt("\x1b[{d};{d}H", .{ OY, OX + GW * 2 + 1 }));
    try out_buf.write(grid_border);
    try out_buf.print();

    status.out = .MATCH;
    status.waitAllInit();

    while (true) {
        switch (status.global) {
            .INIT => {},
            .MATCH => try out_match(&out_buf),
            .PLAY => try out_play(&out_buf),
            .RESULT => try out_result(&out_buf),
            .END => break,
        }
        try Thread.yield();
    }
}

fn connectServer() !void {
    var stream = try net.tcpConnectToHost(alloc, "140.116.72.41", 7911);
    defer stream.close();

    var rtetris: *Tetris = try Tetris.create(alloc);
    rtetris_opt = rtetris;

    var cli_obj: ClientObject = ClientObject{};
    var ser_obj: ServerObject = ServerObject{};
    var wbuf: []u8 = std.mem.asBytes(&cli_obj);
    var rbuf: []u8 = std.mem.asBytes(&ser_obj);
    cli_obj.payload = .syn;
    _ = try stream.write(wbuf);
    _ = try stream.read(rbuf);
    assert(ser_obj.payload == .ack);

    status.conn = .MATCH;
    status.waitAllInit();

    while (true) {
        switch (status.global) {
            .INIT => {},
            .MATCH => try conn_match(&stream, &cli_obj, &ser_obj),
            .PLAY => try conn_play(&stream, &cli_obj, &ser_obj),
            .RESULT => try conn_result(&stream, &cli_obj, &ser_obj),
            .END => break,
        }
        try Thread.yield();
    }
}

fn runGame() !void {
    var tetris: *Tetris = try Tetris.create(alloc);
    tetris_opt = tetris;

    status.game = .MATCH;
    status.waitAllInit();

    while (true) {
        switch (status.global) {
            .INIT => {},
            .MATCH => game_match(),
            .PLAY => game_play(),
            .RESULT => game_result(),
            .END => break,
        }
        try Thread.yield();
    }
    tetris.destroy();
    tetris_opt = null;
}

fn conn_match(stream: *net.Stream, cli_obj: *ClientObject, ser_obj: *ServerObject) !void {
    var wbuf: []u8 = std.mem.asBytes(cli_obj);
    var rbuf: []u8 = std.mem.asBytes(ser_obj);
    var rsize: usize = 0;

    cli_obj.payload = .joinreq;
    _ = try stream.write(wbuf);
    rsize = try stream.read(rbuf);
    if (rsize == 0) return;
    assert(ser_obj.payload == .roomdata);
    var seed: u64 = ser_obj.payload.roomdata.seed;
    tetris_m.lock();
    tetris_opt.?.setSeed(seed);
    tetris_m.unlock();

    cli_obj.payload = .playreq;
    _ = try stream.write(wbuf);
    rsize = try stream.read(rbuf);
    if (rsize == 0) return;
    assert(ser_obj.payload == .playsig);
    status.conn = .PLAY;
    tetris_opt.?.start();
    status.global_m.lock();
    status.global = .PLAY;
    status.global_m.unlock();
}

fn conn_play(stream: *net.Stream, cli_obj: *ClientObject, ser_obj: *ServerObject) !void {
    status.conn = .PLAY;
    var wbuf: []u8 = std.mem.asBytes(cli_obj);
    var rbuf: []u8 = std.mem.asBytes(ser_obj);
    var rsize: usize = 0;

    rsize = try stream.read(rbuf);
    if (rsize == 0) return;
    switch (ser_obj.payload) {
        .tetris => |state| {
            std.debug.print("{}\n", .{state.grid[10][5]});
            rtetris_m.lock();
            rtetris_opt.?.load(&state);
            rtetris_m.unlock();
        },
        .result => |res| {
            matchresult_m.lock();
            matchresult = res;
            matchresult_m.unlock();
            status.global_m.lock();
            status.global = .RESULT;
            status.global_m.unlock();
        },
        .ack, .roomdata, .playsig => {},
    }

    if (tetris_opt.?.end) {
        cli_obj.payload = .{ .result = .PLAYERLOSE };
        _ = try stream.write(wbuf);
    }
    {
        cli_obj.payload = .{ .tetris = .{} };
        var state: *game.TetrisState = &cli_obj.payload.tetris;
        tetris_m.lock();
        tetris_opt.?.store(state);
        tetris_m.unlock();
        _ = try stream.write(wbuf);
    }
}

fn conn_result(stream: *net.Stream, cli_obj: *ClientObject, ser_obj: *ServerObject) !void {
    status.conn = .MATCH;
    var wbuf: []u8 = std.mem.asBytes(cli_obj);
    var rbuf: []u8 = std.mem.asBytes(ser_obj);
    _ = stream;
    _ = rbuf;
    _ = wbuf;
}

fn game_match() void {
    status.game = .MATCH;
}

fn game_play() void {
    status.game = .PLAY;
    var tetris = tetris_opt.?;
    if (tetris.end) {
        return;
    }
    cmd_m.lock(); //mutex
    tetris_m.lock();
    switch (cmd) {
        'a' => _ = tetris.moveLeft(),
        'd' => _ = tetris.moveRight(),
        's' => _ = tetris.moveDown(),
        'j' => _ = tetris.rotateLeft(),
        'l' => _ = tetris.rotateRight(),
        ' ' => tetris.immDrop(),
        'h' => {},
        else => {},
    }
    if (tetris.end) {
        return;
    }
    tetris_m.unlock();
    cmd = 0;
    cmd_m.unlock();
    tetris_m.lock();
    var cur_time: i64 = std.time.microTimestamp();
    if (cur_time - tetris.prev_drop_time > game.DROP_INTERVAL) {
        tetris.autoDrop();
    }
    if (tetris.end) {
        return;
    }
    tetris_m.unlock();
}

fn game_result() void {}

fn out_match(out_buf: *Buffer) !void {
    _ = out_buf;
}

fn out_play(out_buf: *Buffer) !void {
    const GH = game.DISPLAYHEIGHT;
    const GW = game.DISPLAYWIDTH;
    const GX = 13;
    const GY = 24;
    const OX = 48;
    const OY = 24;

    status.out = .PLAY;
    var tetris = tetris_opt.?;
    var rtetris = rtetris_opt.?;
    tetris_m.lock();
    try out_buf.write(compfmt("\x1b[A\x1b[{};{}H", .{ GY, GX }));
    for (0..GH) |row| {
        for (0..GW) |col| {
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
        try out_buf.write(compfmt("\x1b[A\x1b[{}G", .{GX}));
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
        try out_buf.write(compfmt("\x1b[A\x1b[{}G", .{GX}));
    }
    tetris_m.unlock();
    rtetris_m.lock();
    try out_buf.write(compfmt("\x1b[A\x1b[{};{}H", .{ OY, OX }));
    for (0..GH) |row| {
        for (0..GW) |col| {
            const c: game.Cell = rtetris.grid[row][col];
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
        try out_buf.write(compfmt("\x1b[A\x1b[{}G", .{OX}));
    }
    const cur_rblocks: [4]game.CoordI = rtetris.getCurrentBlocks();
    for (cur_rblocks) |block| {
        if (block.y >= 20) {
            continue;
        }
        const xpos = OX + block.x * 2;
        const ypos = OY - block.y;
        var buf_str: [10]u8 = undefined;
        var pos_str = try std.fmt.bufPrint(&buf_str, "\x1b[{};{}H", .{ ypos, xpos });
        try out_buf.write(pos_str);
        switch (rtetris.current.shape) {
            .I => try out_buf.write("\x1b[36m▮▮"),
            .J => try out_buf.write("\x1b[31m▮▮"),
            .L => try out_buf.write("\x1b[34m▮▮"),
            .O => try out_buf.write("\x1b[33m▮▮"),
            .S => try out_buf.write("\x1b[32m▮▮"),
            .Z => try out_buf.write("\x1b[37m▮▮"),
            .T => try out_buf.write("\x1b[35m▮▮"),
        }
        try out_buf.write(compfmt("\x1b[A\x1b[{}G", .{OX}));
    }
    rtetris_m.unlock();
    try out_buf.write("\x1b[39m");
    try out_buf.print();
}

fn out_result(out_buf: *Buffer) !void {
    const GX = 13;
    const GY = 24;
    const OX = 48;
    const OY = 24;

    const fmts = "\x1b[{d};{d}H{s}";
    const win = "YOU WIN";
    const lose = "YOU_LOSE";
    const dc = "DISCONNECT";
    const pw = compfmt(fmts, .{ GY - 10, GX + 6, win });
    const pl = compfmt(fmts, .{ GY - 10, GX + 6, lose });
    const pd = compfmt(fmts, .{ GY - 10, GX + 6, dc });
    const ow = compfmt(fmts, .{ OY - 10, OX + 6, win });
    const ol = compfmt(fmts, .{ OY - 10, OX + 6, lose });
    const od = compfmt(fmts, .{ OY - 10, OX + 6, dc });

    assert(matchresult != .PENDING);
    switch (matchresult) {
        .PENDING => unreachable,
        .PLAYERLOSE => {
            try out_buf.write(pl ++ ow);
        },
        .PLAYERDISCONNECT => {
            try out_buf.write(pd ++ ow);
        },
        .OPPONENTLOSE => {
            try out_buf.write(pw ++ ol);
        },
        .OPPONENTDISCONNECT => {
            try out_buf.write(pw ++ od);
        },
    }
    try out_buf.print();
}
