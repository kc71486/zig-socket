const std = @import("std");
const assert = std.debug.assert;
const Prng = std.rand.DefaultPrng;

pub const TetrisState = struct {
    const This = @This();
    const GRIDHEIGHT = 30;
    const GRIDWIDTH = 10;
    grid: [GRIDHEIGHT][GRIDWIDTH]Cell = [_][GRIDWIDTH]Cell{[_]Cell{.empty} ** 10} ** 30,
    current: Piece,
    hold: Shape,
    queue: Shape,
    prev_drop_time: i64,
};

const Buffer = error{
    BufferSize,
};

pub const Tetris = struct {
    const This = @This();
    const GRIDHEIGHT = 30;
    const GRIDWIDTH = 10;
    const NS_PER_SEC = 1_000_000_000;
    grid: [GRIDHEIGHT][GRIDWIDTH]Cell = [_][GRIDWIDTH]Cell{[_]Cell{.empty} ** 10} ** 30,
    current: Piece,
    hold: Shape,
    queue: Shape,
    prev_drop_time: i64,
    random: std.rand.Random,
    pub fn init() !This {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        var prng = Prng.init(seed);
        var rand = prng.random();
        return This{
            .current = .{ .shape = rand.enumValue(Shape), .direction = .zero, .position = .{ .x = 4, .y = 22 } },
            .hold = rand.enumValue(Shape),
            .queue = rand.enumValue(Shape),
            .prev_drop_time = std.time.microTimestamp(),
            .random = rand,
        };
    }
    pub fn deinit(this: *This) void {
        _ = this;
    }
    pub fn store(this: *This, bytes: []u8) Buffer!void {
        const size: usize = @sizeOf(TetrisState);
        if (bytes.len < size) {
            return Buffer.BufferSize;
        }
        var state: *TetrisState = @ptrCast(@alignCast(bytes[0..size]));
        state.grid = this.grid;
        state.current = this.current;
        state.hold = this.hold;
        state.queue = this.queue;
        state.prev_drop_time = this.prev_drop_time;
    }
    pub fn load(this: *This, bytes: []u8) Buffer!void {
        const size: usize = @sizeOf(TetrisState);
        if (bytes.len < size) {
            return Buffer.BufferSize;
        }
        var state: *TetrisState = @ptrCast(@alignCast(bytes[0..size]));
        this.grid = state.grid;
        this.current = state.current;
        this.hold = state.hold;
        this.queue = state.queue;
        this.prev_drop_time = state.prev_drop_time;
    }
    pub fn collisionCheck(this: *This, blocks: [4]CoordI) bool {
        for (blocks) |block| {
            if (!block.inBound(GRIDWIDTH, GRIDHEIGHT)) {
                return false;
            }
            const block_u = block.toCoordU();
            switch (this.grid[block_u.y][block_u.x]) {
                .I, .J, .L, .O, .S, .Z, .T => return false,
                .empty => {},
            }
        }
        return true;
    }
    pub fn moveRight(this: *This) bool {
        var current: *Piece = &this.current;
        const blocks = getBlockOffset(current.shape, current.direction);
        const motion = CoordI{ .x = 1, .y = 0 };
        const moved: [4]CoordI = getMoved(current.position, blocks, motion);
        const canmove = this.collisionCheck(moved);
        if (canmove) {
            current.position.x += 1;
        }
        return canmove;
    }
    pub fn moveLeft(this: *This) bool {
        var current: *Piece = &this.current;
        const blocks = getBlockOffset(current.shape, current.direction);
        const motion = CoordI{ .x = -1, .y = 0 };
        const moved: [4]CoordI = getMoved(current.position, blocks, motion);
        const canmove = this.collisionCheck(moved);
        if (canmove) {
            current.position.x -= 1;
        }
        return canmove;
    }
    pub fn moveDown(this: *This) bool {
        var current: *Piece = &this.current;
        const blocks = getBlockOffset(current.shape, current.direction);
        const motion = CoordI{ .x = 0, .y = -1 };
        const moved: [4]CoordI = getMoved(current.position, blocks, motion);
        const canmove = this.collisionCheck(moved);
        if (canmove) {
            current.position.y -= 1;
            this.prev_drop_time = std.time.microTimestamp();
        }
        return canmove;
    }
    pub fn rotateRight(this: *This) bool {
        var current: *Piece = &this.current;
        const blocks = getBlockOffset(current.shape, current.direction);
        current.direction = current.direction.rotateRight();
        for (0..5) |i| {
            const idx: u32 = @intCast(i);
            const kick_rot_right = 0;
            const motion = getKick(current.shape, current.direction, kick_rot_right, idx);
            const moved: [4]CoordI = getMoved(current.position, blocks, motion);
            const canmove = this.collisionCheck(moved);
            if (canmove) {
                current.position.x = addOffset(current.position.x, motion.x);
                current.position.y = addOffset(current.position.y, motion.y);
                return true;
            }
        }
        current.direction = current.direction.rotateLeft();
        return false;
    }
    pub fn rotateLeft(this: *This) bool {
        var current: *Piece = &this.current;
        const blocks = getBlockOffset(current.shape, current.direction);
        current.direction = current.direction.rotateLeft();
        for (0..5) |i| {
            const idx: u32 = @intCast(i);
            const kick_rot_left = 1;
            const motion = getKick(current.shape, current.direction, kick_rot_left, idx);
            const moved: [4]CoordI = getMoved(current.position, blocks, motion);
            const canmove = this.collisionCheck(moved);
            if (canmove) {
                current.position.x = addOffset(current.position.x, motion.x);
                current.position.y = addOffset(current.position.y, motion.y);
                return true;
            }
        }
        current.direction = current.direction.rotateRight();
        return false;
    }
};

const Offset_I = [4][4]CoordI{ [4]CoordI{
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 2, .y = 0 },
}, [4]CoordI{
    .{ .x = 1, .y = -2 },
    .{ .x = 1, .y = -1 },
    .{ .x = 1, .y = 0 },
    .{ .x = 1, .y = 1 },
}, [4]CoordI{
    .{ .x = -1, .y = -1 },
    .{ .x = 0, .y = -1 },
    .{ .x = 1, .y = -1 },
    .{ .x = 2, .y = -1 },
}, [4]CoordI{
    .{ .x = 0, .y = -2 },
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
} };

const Offset_J = [4][4]CoordI{ [4]CoordI{
    .{ .x = -1, .y = 1 },
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
}, [4]CoordI{
    .{ .x = 1, .y = 1 },
    .{ .x = 0, .y = 1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = -1 },
}, [4]CoordI{
    .{ .x = 1, .y = -1 },
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = -1, .y = 0 },
}, [4]CoordI{
    .{ .x = -1, .y = -1 },
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
} };
const Offset_L = [4][4]CoordI{ [4]CoordI{
    .{ .x = 1, .y = 1 },
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = -1, .y = 0 },
}, [4]CoordI{
    .{ .x = 1, .y = -1 },
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
}, [4]CoordI{
    .{ .x = -1, .y = -1 },
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
}, [4]CoordI{
    .{ .x = -1, .y = 1 },
    .{ .x = 0, .y = 1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = -1 },
} };
const Offset_O = [4]CoordI{
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 1 },
    .{ .x = 1, .y = 0 },
};
const Offset_S = [4][4]CoordI{ [4]CoordI{
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 1 },
}, [4]CoordI{
    .{ .x = 0, .y = 1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 1, .y = -1 },
}, [4]CoordI{
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = -1 },
    .{ .x = -1, .y = -1 },
}, [4]CoordI{
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 0 },
    .{ .x = -1, .y = 0 },
    .{ .x = -1, .y = 1 },
} };
const Offset_T = [4][4]CoordI{ [4]CoordI{
    .{ .x = 0, .y = 0 },
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 0 },
}, [4]CoordI{
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = -1 },
}, [4]CoordI{
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = -1 },
    .{ .x = -1, .y = 0 },
}, [4]CoordI{
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = -1 },
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 1 },
} };
const Offset_Z = [4][4]CoordI{ [4]CoordI{
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = -1, .y = 1 },
}, [4]CoordI{
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 1, .y = 1 },
}, [4]CoordI{
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = -1 },
    .{ .x = 1, .y = -1 },
}, [4]CoordI{
    .{ .x = 0, .y = 1 },
    .{ .x = 0, .y = 0 },
    .{ .x = -1, .y = 0 },
    .{ .x = -1, .y = -1 },
} };

pub fn getBlockOffset(shape: Shape, direction: Direction) [4]CoordI {
    switch (shape) {
        .I => {
            switch (direction) {
                .zero => return Offset_I[0],
                .right => return Offset_I[1],
                .two => return Offset_I[2],
                .left => return Offset_I[3],
            }
        },
        .J => {
            switch (direction) {
                .zero => return Offset_J[0],
                .right => return Offset_J[1],
                .two => return Offset_J[2],
                .left => return Offset_J[3],
            }
        },
        .L => {
            switch (direction) {
                .zero => return Offset_L[0],
                .right => return Offset_L[1],
                .two => return Offset_L[2],
                .left => return Offset_L[3],
            }
        },
        .O => return Offset_O,
        .S => {
            switch (direction) {
                .zero => return Offset_S[0],
                .right => return Offset_S[1],
                .two => return Offset_S[2],
                .left => return Offset_S[3],
            }
        },
        .T => {
            switch (direction) {
                .zero => return Offset_T[0],
                .right => return Offset_T[1],
                .two => return Offset_T[2],
                .left => return Offset_T[3],
            }
        },
        .Z => {
            switch (direction) {
                .zero => return Offset_Z[0],
                .right => return Offset_Z[1],
                .two => return Offset_Z[2],
                .left => return Offset_Z[3],
            }
        },
    }
}

const kickData_JLSTZ = [4][4]CoordI{
    [_]CoordI{
        .{ .x = -1, .y = 0 },
        .{ .x = -1, .y = 1 },
        .{ .x = 0, .y = -2 },
        .{ .x = -1, .y = -2 },
    },
    [_]CoordI{
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = -1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
    },
    [_]CoordI{
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = -2 },
        .{ .x = 1, .y = -2 },
    },
    [_]CoordI{
        .{ .x = -1, .y = 0 },
        .{ .x = -1, .y = -1 },
        .{ .x = 0, .y = 2 },
        .{ .x = -1, .y = 2 },
    },
};

const kickData_I = [4][4]CoordI{ [_]CoordI{
    .{ .x = -2, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = -2, .y = -1 },
    .{ .x = 1, .y = 2 },
}, [_]CoordI{
    .{ .x = 2, .y = 0 },
    .{ .x = -1, .y = 0 },
    .{ .x = 2, .y = 1 },
    .{ .x = -1, .y = -2 },
}, [_]CoordI{
    .{ .x = -1, .y = 0 },
    .{ .x = 2, .y = 0 },
    .{ .x = -1, .y = 2 },
    .{ .x = 2, .y = -1 },
}, [_]CoordI{
    .{ .x = 1, .y = 0 },
    .{ .x = -2, .y = 0 },
    .{ .x = 1, .y = -2 },
    .{ .x = -2, .y = 1 },
} };

fn getKick(shape: Shape, direction: Direction, rot: u32, index: u32) CoordI {
    if (index == 0) {
        return .{ .x = 0, .y = 0 };
    }
    std.debug.assert(index < 5);
    std.debug.assert(rot == (rot & 1));
    switch (shape) {
        .J, .L, .S, .T, .Z => {
            switch (direction) {
                .zero => {
                    return kickData_JLSTZ[0 ^ rot][index];
                },
                .right => {
                    return kickData_JLSTZ[1 ^ rot][index];
                },
                .two => {
                    return kickData_JLSTZ[2 ^ rot][index];
                },
                .left => {
                    return kickData_JLSTZ[3 ^ rot][index];
                },
            }
        },
        .I => {
            switch (direction) {
                .zero => {
                    return kickData_I[0 ^ rot][index];
                },
                .right => {
                    return kickData_I[2 ^ rot][index];
                },
                .two => {
                    return kickData_I[1 ^ rot][index];
                },
                .left => {
                    return kickData_I[3 ^ rot][index];
                },
            }
        },
        .O => return .{ .x = 0, .y = 0 },
    }
}

fn getMoved(base: CoordU, offset: [4]CoordI, motion: CoordI) [4]CoordI {
    var moved: [4]CoordI = undefined;
    const basex: isize = @intCast(base.x);
    const basey: isize = @intCast(base.y);
    const bx: isize = basex + motion.x;
    const by: isize = basey + motion.y;
    for (offset, 1..) |a, i| {
        moved[i - 1] = .{ .x = a.x + bx, .y = a.y + by };
    }
    return moved;
}

fn addOffset(a: usize, b: isize) usize {
    const ia: isize = @intCast(a);
    std.debug.assert(ia > b);
    return @intCast(ia + b);
}

pub const CoordU = struct {
    const This = @This();
    x: usize,
    y: usize,
    pub fn inBound(this: This, boundx: usize, boundy: usize) bool {
        return this.x < boundx and this.y < boundy;
    }
    pub fn toCoordI(this: This) CoordI {
        return .{ .x = @intCast(this.x), .y = @intCast(this.y) };
    }
};

pub const CoordI = struct {
    const This = @This();
    x: isize,
    y: isize,
    pub fn inBound(this: This, boundx: isize, boundy: isize) bool {
        return this.x >= 0 and this.y >= 0 and this.x < boundx and this.y < boundy;
    }
    pub fn toCoordU(this: This) CoordU {
        return .{ .x = @intCast(this.x), .y = @intCast(this.y) };
    }
};

pub const Cell = enum(u8) { empty, I, J, L, O, S, Z, T };

pub const Piece = struct {
    shape: Shape,
    direction: Direction,
    position: CoordU,
};

pub const Shape = enum(u8) { I, J, L, O, S, Z, T };

pub const Direction = enum(u8) {
    const This = @This();
    zero,
    right,
    two,
    left,
    pub fn rotateRight(this: This) This {
        switch (this) {
            .zero => return .right,
            .right => return .two,
            .two => return .left,
            .left => return .zero,
        }
    }
    pub fn rotateLeft(this: This) This {
        switch (this) {
            .zero => return .left,
            .right => return .zero,
            .two => return .right,
            .left => return .two,
        }
    }
};
