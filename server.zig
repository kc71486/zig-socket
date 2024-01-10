const std = @import("std");
const game = @import("game.zig");
const netobj = @import("netObject.zig");
const net = std.net;
const Thread = std.Thread;
const GPA = std.heap.GeneralPurposeAllocator(.{});
const Prng = std.rand.Xoroshiro128;
const Tetris = game.Tetris;
const stdin = std.io.getStdIn();
const stdout = std.io.getStdOut();
const connection = net.StreamServer.Connection;
const ClientObject = netobj.ClientObject;
const ServerObject = netobj.ServerObject;
const MatchResult = netobj.MatchResult;

var gpa = GPA{};
var alloc = gpa.allocator();

var prng = Prng.init(0);
var random = prng.random();
var rand_m = Thread.Mutex{};

const Player = struct {
    tetris: game.Tetris,
    tetris_m: Thread.Mutex = Thread.Mutex{},
    ready: bool = false,
    started: bool = false,
    prev_send: i64 = 0,
};

const Room = struct {
    a: ?*Player = null,
    b: ?*Player = null,
    state: RoomState = .MATCH,
};

const SessionData = struct {
    loc: RoomLocation,
    room: *Room,
    room_m: *Thread.Mutex,
    player: *Player,
    opponent: *Player,
};

const RoomState = enum {
    MATCH,
    WAIT,
    PLAY,
    ALOSE,
    ADISCONNECT,
    BLOSE,
    BDISCONNECT,
};

const RoomLocation = struct {
    idx: usize,
    is_a: bool,
};

const ReadInfo = struct {
    info_m: Thread.Mutex = .{},
    cli_obj: ClientObject = .{},
    occupied: bool = false,
    reach_end: bool = false,
    has_val: bool = false,
};

var rooms: [5]Room = [1]Room{.{}} ** 5;
var rooms_m: [5]Thread.Mutex = [1]Thread.Mutex{.{}} ** 5;
var readinfos: [10]ReadInfo = [1]ReadInfo{.{}} ** 10;

pub fn main() !void {
    var out = stdout.writer();
    var in = stdin.reader();
    var server = net.StreamServer.init(.{});

    var seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&seed));
    prng.seed(seed);

    try server.listen(try net.Address.parseIp("0.0.0.0", 7911));
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
        var conn = try server.accept(); // blocking
        _ = try std.Thread.spawn(.{}, service, .{conn});
    }
}

pub fn readSocket(stream: *const net.Stream, info: *ReadInfo) !void {
    var localobj: ClientObject = .{};
    var rbuf: []u8 = std.mem.asBytes(&localobj);

    while (true) {
        var rlen: usize = try stream.read(rbuf); // blocking
        if (rlen == 0) {
            info.info_m.lock();
            info.reach_end = true;
            info.info_m.unlock();
            break;
        }
        while (info.has_val) {} // only update when needed
        info.info_m.lock();
        info.cli_obj = localobj;
        info.has_val = true;
        info.info_m.unlock();
    }
}

pub fn service(conn: connection) !void {
    const stream = conn.stream;
    var out = stdout.writer();
    defer stream.close();

    var ser_obj: ServerObject = ServerObject{};
    var cli_obj: ClientObject = ClientObject{};
    var wbuf: []u8 = std.mem.asBytes(&ser_obj);
    var rbuf: []u8 = std.mem.asBytes(&cli_obj);
    var rlen: usize = 0;

    rlen = try stream.read(rbuf);
    if (rlen == 0) {
        try out.print("empty start message detected, detach.\n", .{});
        return;
    }
    if (cli_obj.payload != .syn) {
        try out.print("start message not syn, detach.\n", .{});
        return;
    }

    var info_o: ?*ReadInfo = null;
    for (readinfos, 0..) |_, i| {
        var info: *ReadInfo = &readinfos[i];
        info.info_m.lock();
        if (!info.occupied) {
            info.occupied = true;
            info_o = info;
            info.info_m.unlock();
            break;
        }
        info.info_m.unlock();
    }
    if (info_o == null) {
        try out.print("insufficient space for service, detach.\n", .{});
        return;
    }
    var info = info_o.?;

    ser_obj.payload = .ack;
    _ = try stream.write(wbuf);

    var data_o: ?SessionData = null;

    _ = try std.Thread.spawn(.{}, readSocket, .{ &stream, info_o.? });

    while (true) {
        info.info_m.lock();
        var info_local: ReadInfo = info_o.?.*; // copy
        cli_obj = info.cli_obj; // copy
        info.info_m.unlock();
        if (info_local.reach_end) {
            try out.print("client disconnected.\n", .{});
            break;
        }
        if (info_local.has_val) {
            switch (cli_obj.payload) {
                .joinreq => {
                    var loc = try findRoom(); // blocking
                    var room = &rooms[loc.idx];
                    data_o = .{
                        .loc = loc,
                        .room = room,
                        .room_m = &rooms_m[loc.idx],
                        .player = if (loc.is_a) room.a.? else room.b.?,
                        .opponent = if (loc.is_a) room.b.? else room.a.?,
                    };
                    var seed = random.int(u64);
                    ser_obj.payload = .{ .roomdata = .{ .seed = seed } };
                    _ = try stream.write(wbuf);

                    var data = data_o.?;
                    data.room_m.lock();
                    if (data.room.state == .MATCH)
                        data.room.state = .WAIT;
                    data.room_m.unlock();
                },
                .playreq => {
                    if (data_o) |data| {
                        data.player.ready = true;
                    }
                },
                .tetris => |state| {
                    if (data_o) |data| {
                        data.player.tetris_m.lock();
                        data.player.tetris.load(&state);
                        data.player.tetris_m.unlock();
                    }
                },
                .result => |res| {
                    if (data_o) |data| {
                        if (res == .PLAYERLOSE) {
                            data.room_m.lock();
                            if (data.loc.is_a)
                                data.room.state = .ALOSE
                            else
                                data.room.state = .BLOSE;
                            data.room_m.unlock();
                        }
                    }
                },
                .syn, .sync => {},
            }
            info.info_m.lock();
            info.has_val = false;
            info.info_m.unlock();
        }
        if (data_o) |data| {
            var room = data.room;
            var room_m = data.room_m;
            var player = data.player;
            var opponent = data.opponent;
            var loc = data.loc;
            switch (room.state) {
                .MATCH => {},
                .WAIT => {
                    if (player.ready and opponent.ready) {
                        if (!player.started) {
                            ser_obj.payload = .playsig;
                            _ = try stream.write(wbuf);
                            player.started = true;
                            player.prev_send = std.time.microTimestamp() + 1000;
                        }
                        if (player.started and opponent.started) {
                            room_m.lock();
                            if (room.state == .WAIT)
                                room.state = .PLAY;
                            room_m.unlock();
                        }
                    }
                },
                .PLAY => {
                    var cur_time: i64 = std.time.microTimestamp();
                    if (cur_time > player.prev_send + 1000) { // every 1ms
                        ser_obj.payload = .{ .tetris = .{} };
                        var state: *game.TetrisState = &ser_obj.payload.tetris;
                        opponent.tetris_m.lock();
                        opponent.tetris.store(state);
                        opponent.tetris_m.unlock();
                        _ = try stream.write(wbuf);
                        player.prev_send += 1000;
                    }
                },
                .ALOSE => {
                    if (loc.is_a) {
                        ser_obj.payload = .{ .result = .PLAYERLOSE };
                        _ = try stream.write(wbuf);
                    } else {
                        ser_obj.payload = .{ .result = .OPPONENTLOSE };
                        _ = try stream.write(wbuf);
                    }
                    break;
                },
                .ADISCONNECT => {
                    if (!loc.is_a) {
                        ser_obj.payload = .{ .result = .OPPONENTDISCONNECT };
                        _ = try stream.write(wbuf);
                    }
                    break;
                },
                .BLOSE => {
                    if (loc.is_a) {
                        ser_obj.payload = .{ .result = .OPPONENTLOSE };
                        _ = try stream.write(wbuf);
                    } else {
                        ser_obj.payload = .{ .result = .PLAYERLOSE };
                        _ = try stream.write(wbuf);
                    }
                    break;
                },
                .BDISCONNECT => {
                    if (loc.is_a) {
                        ser_obj.payload = .{ .result = .OPPONENTDISCONNECT };
                        _ = try stream.write(wbuf);
                    }
                    break;
                },
            }
        }
    }
    if (data_o) |data| {
        data.room_m.lock();
        alloc.destroy(data.player);
        if (data.loc.is_a) {
            if (data.room.state == .PLAY) {
                data.room.state = .ADISCONNECT;
            } else if (rooms[data.loc.idx].b == null) {
                data.room.state = .MATCH;
            }
            rooms[data.loc.idx].a = null;
        } else {
            if (data.room.state == .PLAY) {
                data.room.state = .BDISCONNECT;
            } else if (rooms[data.loc.idx].a == null) {
                data.room.state = .MATCH;
            }
            rooms[data.loc.idx].b = null;
        }
        data.room_m.unlock();
    }
    info.occupied = false;
}

fn findRoom() !RoomLocation {
    var location: ?RoomLocation = null;
    while (location == null) {
        for (rooms, 0..) |_, idx| {
            rooms_m[idx].lock();
            if (rooms[idx].a == null and rooms[idx].b != null) {
                rooms[idx].a = try alloc.create(Player);
                rooms[idx].a.?.* = .{ .tetris = try Tetris.init(alloc) };
                rooms_m[idx].unlock();
                return .{ .idx = idx, .is_a = true };
            }
            if (rooms[idx].a != null and rooms[idx].b == null) {
                rooms[idx].b = try alloc.create(Player);
                rooms[idx].b.?.* = .{ .tetris = try Tetris.init(alloc) };
                rooms_m[idx].unlock();
                return .{ .idx = idx, .is_a = false };
            }
            rooms_m[idx].unlock();
        }
        for (rooms, 0..) |_, idx| {
            rooms_m[idx].lock();
            if (rooms[idx].a == null) {
                rooms[idx].a = try alloc.create(Player);
                rooms[idx].a.?.* = .{ .tetris = try Tetris.init(alloc) };
                location = .{ .idx = idx, .is_a = true };
                rooms_m[idx].unlock();
                break;
            } else if (rooms[idx].b == null) {
                rooms[idx].b = try alloc.create(Player);
                rooms[idx].b.?.* = .{ .tetris = try Tetris.init(alloc) };
                location = .{ .idx = idx, .is_a = false };
                rooms_m[idx].unlock();
                break;
            } else rooms_m[idx].unlock();
        }
    }
    var loc = location.?;
    if (loc.is_a) {
        var room = &rooms[loc.idx];
        while (room.b == null) {}
    } else {
        var room = &rooms[loc.idx];
        while (room.a == null) {}
    }
    return loc;
}
