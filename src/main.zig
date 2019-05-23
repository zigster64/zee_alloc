const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const FreeList = std.LinkedList([]u8);

export const default_min_size = @typeInfo(usize).Int.bits;

// export const wasm_allocator = &ZeeAlloc.init(std.heap.wasm_allocator, std.os.page_size, default_min_size).allocator;
export const fake_allocator = &ZeeAlloc.init(&NoopAllocator, std.os.page_size, default_min_size).allocator;

fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
    return old_mem;
}
fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
    return old_mem;
}
var NoopAllocator = Allocator{
    .reallocFn = realloc,
    .shrinkFn = shrink,
};

const large_index = 0;
const page_index = 1;

const ZeeAlloc = struct {
    pub allocator: Allocator,

    backing_allocator: *Allocator,
    page_size: usize,

    free_lists: []FreeList,
    unused_nodes: FreeList,

    fn inv_bitsize(ref: usize, target: usize) usize {
        return std.math.log2_int_ceil(usize, ref) - std.math.log2_int_ceil(usize, target);
    }

    pub fn init(backing_allocator: *Allocator, comptime page_size: usize, comptime min_size: usize) @This() {
        const total_lists = inv_bitsize(page_size, min_size) + page_index;
        var free_lists = []FreeList{FreeList.init()} ** total_lists;

        return ZeeAlloc{
            .allocator = Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
            .backing_allocator = backing_allocator,
            .page_size = page_size,

            .free_lists = free_lists[0..],
            .unused_nodes = FreeList.init(),
        };
    }

    fn replenishUnusedIfNeeded(self: *ZeeAlloc) !void {
        if (self.unused_nodes.first != null) {
            return;
        }
        var buffer = try self.backing_allocator.alloc(FreeList.Node, self.page_size / @sizeOf(FreeList.Node));
        for (buffer) |*node| {
            self.unused_nodes.append(node);
        }
    }

    fn alloc(self: *ZeeAlloc, memsize: usize, i: usize) Allocator.Error![]u8 {
        var free_list = self.free_lists[i];
        var it = free_list.first;
        while (it) |node| : (it = node.next) {
            if (node.data.len == memsize) {
                free_list.remove(node);
                self.unused_nodes.append(node);
                return node.data;
            }
        }

        if (i <= page_index) {
            return self.backing_allocator.alloc(u8, memsize);
        }

        const raw_mem = try self.alloc(memsize / 2, i - 1);

        try self.replenishUnusedIfNeeded();
        if (self.unused_nodes.pop()) |node| {
            node.data = raw_mem[memsize..];
            free_list.append(node);
        } else {
            std.debug.assert(false); // Not sure how we got here... replenishUnused() didn't get enough?
        }
        return raw_mem[0..memsize];
    }

    fn free(self: *ZeeAlloc, old_mem: []u8) []u8 {
        self.replenishUnusedIfNeeded() catch {
            // Can't allocate to process freed memory. Try to continue the best we can.
            //std.debug.warn("ZeeAlloc: replenishUnused failed\n");
        };

        const i = self.freeListIndex(old_mem.len);
        const node = self.unused_nodes.pop() orelse self.findLessImportantNode(std.math.max(i, page_index));
        if (node) |aNode| {
            aNode.data = old_mem;
            self.free_lists[i].append(aNode);
            return []u8{};
        }

        return old_mem;
    }

    fn freeListIndex(self: *ZeeAlloc, memsize: usize) usize {
        if (memsize > self.page_size) {
            return 0;
        }
        return std.math.min(self.free_lists.len - 1, inv_bitsize(self.page_size, memsize) + page_index);
    }

    fn findLessImportantNode(self: *ZeeAlloc, target_index: usize) ?*FreeList.Node {
        var i = self.free_lists.len - 1;
        while (i > target_index) : (i -= 1) {
            if (self.free_lists[i].pop()) |node| {
                //std.debug.warn("ZeeAlloc: using free_lists[{}]\n", i);
                return node;
            }
        }

        return null;
    }

    fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
        if (new_size <= old_mem.len and new_align <= new_size) {
            // TODO: maybe intelligently shrink?
            // We can't do anything with the memory, so tell the client to keep it.
            return error.OutOfMemory;
        } else {
            const self = @fieldParentPtr(ZeeAlloc, "allocator", allocator);
            const result = try self.alloc(new_size, self.freeListIndex(new_size));
            std.mem.copy(u8, result, old_mem);
            _ = self.free(old_mem);
            return result;
        }
    }

    fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        if (new_size == 0) {
            const self = @fieldParentPtr(ZeeAlloc, "allocator", allocator);
            return self.free(old_mem);
        } else {
            // TODO: maybe intelligently shrink?
            return old_mem;
        }
    }
};

// -- tests from std/heap.zig

fn testAllocator(allocator: *std.mem.Allocator) !void {
    var slice = try allocator.alloc(*i32, 100);
    testing.expect(slice.len == 100);
    for (slice) |*item, i| {
        item.* = try allocator.create(i32);
        item.*.* = @intCast(i32, i);
    }

    slice = try allocator.realloc(slice, 20000);
    testing.expect(slice.len == 20000);

    for (slice[0..100]) |item, i| {
        testing.expect(item.* == @intCast(i32, i));
        allocator.destroy(item);
    }

    slice = allocator.shrink(slice, 50);
    testing.expect(slice.len == 50);
    slice = allocator.shrink(slice, 25);
    testing.expect(slice.len == 25);
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
    slice = try allocator.realloc(slice, 10);
    testing.expect(slice.len == 10);

    allocator.free(slice);
}

test "DirectAllocator" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var zee_alloc = ZeeAlloc.init(&direct_allocator.allocator, std.os.page_size, default_min_size);
    try testAllocator(&zee_alloc.allocator);
}
