const std = @import("std");
const assert = std.debug.assert;
const Prng = std.rand.Xoroshiro128;
const Allocator = std.mem.Allocator;

pub const GRIDHEIGHT = 30;
pub const GRIDWIDTH = 10;
pub const DISPLAYHEIGHT = 20;
pub const DISPLAYWIDTH = 10;
pub const DROP_INTERVAL = 1_000_000;

pub const Tetris = struct {
    const This = @This();
    grid: [GRIDHEIGHT][GRIDWIDTH]Cell = [_][GRIDWIDTH]Cell{[_]Cell{.empty} ** 10} ** 30,
    current: Piece = .{
        .shape = .I,
        .direction = .zero,
        .position = .{ .x = 4, .y = 21 },
    },
    hold: Shape = Shape.I,
    queue: Shape = Shape.I,
    prev_drop_time: i64 = 0,
    end: bool = false,
    alloc: Allocator,
    prng: *Prng,
    random: std.rand.Random,
    pub fn init(alloc: Allocator) !This {
        var prng: *Prng = try alloc.create(Prng);

        return This{
            .alloc = alloc,
            .prng = prng,
            .random = prng.random(),
        };
    }
    pub fn deinit(this: *This) void {
        this.alloc.destroy(this.prng);
    }
    pub fn create(alloc: Allocator) !*This {
        var ret: *This = try alloc.create(This);
        var prng: *Prng = try alloc.create(Prng);
        ret.* = .{
            .alloc = alloc,
            .prng = prng,
            .random = prng.random(),
        };
        return ret;
    }
    pub fn destroy(this: *This) void {
        var alloc = this.alloc;
        alloc.destroy(this.prng);
        alloc.destroy(this);
    }
    pub fn setSeed(this: *This, seed: u64) void {
        this.prng.seed(seed);
        this.current.shape = this.random.enumValue(Shape);
        this.hold = this.random.enumValue(Shape);
        this.queue = this.random.enumValue(Shape);
    }
    pub fn start(this: *This) void {
        this.grid = [_][GRIDWIDTH]Cell{[_]Cell{.empty} ** 10} ** 30;
        this.prev_drop_time = std.time.microTimestamp();
        this.end = false;
    }
    pub fn store(this: *This, state: *TetrisState) void {
        state.grid = this.grid;
        state.current = this.current;
        state.hold = this.hold;
        state.queue = this.queue;
        state.prev_drop_time = this.prev_drop_time;
    }
    pub fn load(this: *This, state: *const TetrisState) void {
        this.grid = state.grid;
        this.current = state.current;
        this.hold = state.hold;
        this.queue = state.queue;
        this.prev_drop_time = state.prev_drop_time;
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
        const new_direction = current.direction.rotateRight();
        const blocks = getBlockOffset(current.shape, new_direction);
        for (0..5) |i| {
            const idx: u32 = @intCast(i);
            const kick_rot_right = 0;
            const motion = getKick(current.shape, current.direction, kick_rot_right, idx);
            const moved: [4]CoordI = getMoved(current.position, blocks, motion);
            const canmove = this.collisionCheck(moved);
            if (canmove) {
                current.position.x = addOffset(current.position.x, motion.x);
                current.position.y = addOffset(current.position.y, motion.y);
                current.direction = new_direction;
                return true;
            }
        }
        return false;
    }
    pub fn rotateLeft(this: *This) bool {
        var current: *Piece = &this.current;
        const new_direction = current.direction.rotateLeft();
        const blocks = getBlockOffset(current.shape, new_direction);
        for (0..5) |i| {
            const idx: u32 = @intCast(i);
            const kick_rot_left = 1;
            const motion = getKick(current.shape, current.direction, kick_rot_left, idx);
            const moved: [4]CoordI = getMoved(current.position, blocks, motion);
            const canmove = this.collisionCheck(moved);
            if (canmove) {
                current.position.x = addOffset(current.position.x, motion.x);
                current.position.y = addOffset(current.position.y, motion.y);
                current.direction = new_direction;
                return true;
            }
        }
        return false;
    }
    pub fn immDrop(this: *This) void {
        const tp = this.getPredictedBlocks();
        if (tp.dropamt == 0 and this.willEnd()) {
            this.end = true;
            return;
        }
        this.current.position.y -= tp.dropamt;
        this.solidify();
    }
    pub fn autoDrop(this: *This) void {
        var current: *Piece = &this.current;
        const blocks = getBlockOffset(current.shape, current.direction);
        const motion = CoordI{ .x = 0, .y = -1 };
        const moved: [4]CoordI = getMoved(current.position, blocks, motion);
        const canmove = this.collisionCheck(moved);
        if (canmove) {
            current.position.y -= 1;
            this.prev_drop_time = this.prev_drop_time + DROP_INTERVAL;
        } else {
            this.solidify();
        }
    }
    fn solidify(this: *This) void {
        const cb = this.getCurrentBlocks();
        assert(this.collisionCheck(cb));
        const cell = this.current.shape.toCell();
        for (cb) |block| {
            const bx: usize = @intCast(block.x);
            const by: usize = @intCast(block.y);
            this.grid[by][bx] = cell;
        }
        var iy: usize = DISPLAYHEIGHT - 1;
        while (iy < GRIDHEIGHT) : (iy -%= 1) {
            var blockcount: u32 = 0;
            for (0..DISPLAYWIDTH) |ix| {
                if (this.grid[iy][ix] != .empty) {
                    blockcount += 1;
                }
            }
            if (blockcount == DISPLAYWIDTH) {
                for (iy..DISPLAYHEIGHT) |cy| {
                    std.mem.copyForwards(Cell, &this.grid[cy], &this.grid[cy + 1]);
                }
            }
        }
        if (this.willEnd()) {
            this.end = true;
            return;
        }
        this.queue = this.random.enumValue(Shape);
        this.current = .{
            .shape = this.queue,
            .direction = .zero,
            .position = .{ .x = 4, .y = 21 },
        };
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
    pub fn willEnd(this: *This) bool {
        const blocks = this.getCurrentBlocks();
        for (blocks) |block| {
            if (!block.inBound(DISPLAYWIDTH, DISPLAYHEIGHT)) {
                return true;
            }
        }
        return false;
    }
    pub fn getCurrentBlocks(this: *This) [4]CoordI {
        const cur: *Piece = &this.current;
        const offset = getBlockOffset(cur.shape, cur.direction);
        var moved: [4]CoordI = undefined;
        const bx: isize = @intCast(cur.position.x);
        const by: isize = @intCast(cur.position.y);
        for (offset, 1..) |a, i| {
            moved[i - 1] = .{ .x = a.x + bx, .y = a.y + by };
        }
        return moved;
    }
    pub fn getPredictedBlocks(this: *This) PredictedRet {
        var predicted: [4]CoordI = this.getCurrentBlocks();
        for (0..(GRIDHEIGHT * 2)) |amt| {
            for (predicted, 0..) |_, i| {
                predicted[i].y -= 1;
            }
            const canmove = this.collisionCheck(predicted);
            if (!canmove) {
                for (predicted, 0..) |_, i| {
                    predicted[i].y += 1;
                }
                return .{
                    .dropamt = amt,
                    .blocks = predicted,
                };
            }
        }
        unreachable;
    }
};

pub const PredictedRet = struct {
    dropamt: usize,
    blocks: [4]CoordI,
};

const BufferError = error{
    BufferSize,
};

pub const TetrisState = struct {
    const This = @This();
    grid: [GRIDHEIGHT][GRIDWIDTH]Cell = [_][GRIDWIDTH]Cell{[_]Cell{.empty} ** 10} ** 30,
    current: Piece = .{
        .shape = .I,
        .direction = .zero,
        .position = .{ .x = 0, .y = 0 },
    },
    hold: Shape = .I,
    queue: Shape = .I,
    prev_drop_time: i64 = 0,
};

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

pub const Cell = enum(u8) {
    empty = 0,
    I = 1,
    J = 2,
    L = 3,
    O = 4,
    S = 5,
    Z = 6,
    T = 7,
};

pub const Piece = struct {
    shape: Shape,
    direction: Direction,
    position: CoordU,
};

pub const Shape = enum(u8) {
    const This = @This();
    I = 1,
    J = 2,
    L = 3,
    O = 4,
    S = 5,
    Z = 6,
    T = 7,
    pub fn toCell(this: This) Cell {
        return @enumFromInt(@intFromEnum(this));
    }
};

pub const Direction = enum(u8) {
    const This = @This();
    zero = 0,
    right = 1,
    two = 2,
    left = 3,
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

const Offset_I = [4][4]CoordI{ [4]CoordI{
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 2, .y = 0 },
}, [4]CoordI{
    .{ .x = 0, .y = -2 },
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 1 },
}, [4]CoordI{
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = 0 },
    .{ .x = 1, .y = 0 },
    .{ .x = 2, .y = 0 },
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
    assert(index < 5);
    assert(rot == (rot & 1));
    // rot = 0: right, 1: left
    switch (shape) {
        .J, .L, .S, .T, .Z => {
            switch (direction) {
                .zero => {
                    return kickData_JLSTZ[0 ^ rot][index - 1];
                },
                .right => {
                    return kickData_JLSTZ[1 ^ rot][index - 1];
                },
                .two => {
                    return kickData_JLSTZ[2 ^ rot][index - 1];
                },
                .left => {
                    return kickData_JLSTZ[3 ^ rot][index - 1];
                },
            }
        },
        .I => {
            switch (direction) {
                .zero => {
                    return kickData_I[0 ^ rot][index - 1];
                },
                .right => {
                    return kickData_I[2 ^ rot][index - 1];
                },
                .two => {
                    return kickData_I[1 ^ rot][index - 1];
                },
                .left => {
                    return kickData_I[3 ^ rot][index - 1];
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
    std.debug.assert(ia + b >= 0);
    return @intCast(ia + b);
}
