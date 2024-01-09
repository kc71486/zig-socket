const TetrisState = @import("game.zig").TetrisState;

pub const ClientObject = struct {
    magic: u32 = 0x23456789,
    payload: ClientPayload = .syn,
};

pub const ServerObject = struct {
    magic: u32 = 0x12345678,
    payload: ServerPayload = .ack,
};

pub const ClientPayload = union(enum) {
    syn: void, // first conn
    joinreq: void, // join room
    playreq: void, // all resource ready
    tetris: TetrisState, // player tetris info
    result: MatchResult, // result
    sync: void, // manual sync, will get tetris
};

pub const ServerPayload = union(enum) {
    ack: void, // first conn
    roomdata: RoomData, // successfully join
    playsig: void, // start playing
    tetris: TetrisState, // opponent tetris info
    result: MatchResult, // result
};

pub const RoomData = struct {
    seed: u64,
};

pub const MatchResult = enum {
    PENDING,
    PLAYERLOSE,
    PLAYERDISCONNECT,
    OPPONENTLOSE,
    OPPONENTDISCONNECT,
};
