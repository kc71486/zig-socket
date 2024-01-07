const std = @import("std");
const ts = @import("game.zig");
const expect = std.testing.expect;
const GPA = std.heap.GeneralPurposeAllocator(.{});

var gpa = GPA{};
var alloc = gpa.allocator();

test "collision" {
    var tetris = try ts.Tetris.init(alloc);
    defer tetris.deinit();
    try expect(tetris.grid[15][5] == ts.Cell.empty);
    tetris.grid[0][0] = ts.Cell.I;
    tetris.grid[1][1] = ts.Cell.J;
    var arr = [4]ts.CoordI{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 1 },
    };
    const result = tetris.collisionCheck(arr);
    try expect(result == false);
}
test "offset" {
    var offset = ts.getBlockOffset(ts.Shape.I, ts.Direction.zero);
    try expect(offset[0].x == -1);
    try expect(offset[1].y == 0);
    try expect(offset[2].x == 1);
}

test "move" {
    var tetris = try ts.Tetris.create(alloc);
    defer tetris.destroy();
    var cur = &tetris.current;
    cur.position = .{ .x = 5, .y = 5 };
    var moved: bool = undefined;
    moved = tetris.moveLeft();
    try expect(moved == true);
    try expect(tetris.current.position.x == 4);
    moved = tetris.moveRight();
    try expect(moved == true);
    try expect(tetris.current.position.x == 5);
    moved = tetris.rotateRight();
    try expect(moved == true);
    try expect(tetris.current.direction == .right);
    moved = tetris.rotateLeft();
    try expect(moved == true);
    try expect(tetris.current.direction == .zero);
}

test "rotate" {
    var tetris = try ts.Tetris.create(alloc);
    defer tetris.destroy();
    var cur = &tetris.current;
    cur.shape = .T;
    cur.direction = .zero;
    cur.position = .{ .x = 5, .y = 5 };
    tetris.grid[4][5] = .I;
    var moved: bool = undefined;
    var result: bool = undefined;
    result = tetris.collisionCheck(tetris.getCurrentBlocks());
    try expect(result == true);
    moved = tetris.rotateRight();
    try expect(moved == true);
    try expect(cur.position.x == 4);
    try expect(cur.position.y == 5);
    result = tetris.collisionCheck(tetris.getCurrentBlocks());
    try expect(result == true);
}

test "loadstore" {
    var tetris1 = try ts.Tetris.init(alloc);
    var tetris2 = try ts.Tetris.init(alloc);
    var buf: [1000]u8 = [1]u8{0} ** 1000;
    var src = &tetris1;
    var dst = &tetris2;
    try expect(src.current.position.y == 22);
    try expect(dst.current.position.y == 22);
    src.grid[10][3] = .O;
    src.current = .{ .direction = .zero, .position = .{ .x = 3, .y = 15 }, .shape = .T };
    try src.store(&buf);
    try dst.load(&buf);
    try expect(dst.grid[10][3] == .O);
    try expect(dst.current.position.y == 15);
}
