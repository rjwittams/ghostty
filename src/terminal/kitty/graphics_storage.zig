const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const terminal = @import("../main.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const LoadingImage = @import("graphics_image.zig").LoadingImage;
const Image = @import("graphics_image.zig").Image;
const Rect = @import("graphics_image.zig").Rect;
const Command = command.Command;

const log = std.log.scoped(.kitty_gfx);

/// Process-global counter backing all generation stamps (see
/// ImageStorage.generation and Image.generation). This is global rather
/// than per-storage so that stamps are unique across every storage in
/// the process: two mutation events never produce the same value, even
/// across separate screens (main vs. alt), storage resets, or separate
/// terminals. This lets consumers use a generation value alone as a
/// cache key without any ambiguity.
///
/// Thread-safe because separate terminals may mutate their storages
/// from different threads. On single-threaded targets this lowers to
/// plain operations.
var generation_counter: GenerationCounter = .{};

/// Returns the next generation stamp. Stamps are unique and strictly
/// monotonically increasing process-wide, starting at 1 (0 is reserved
/// to mean "never stamped").
pub fn nextGeneration() u64 {
    return generation_counter.next();
}

/// Backing implementation for the generation counter. We use a
/// lock-free atomic counter where we can, but not all targets support
/// 64-bit atomic operations (e.g. 32-bit ARM Android), so we fall back
/// to a mutex-protected counter on those. This is a cold path (only
/// invoked on content mutations) so the mutex cost is irrelevant.
///
/// The pointer-width check is a conservative proxy for 64-bit atomic
/// support: every 64-bit target supports 64-bit atomics, while 32-bit
/// targets may not (per the compiler's atomic operand validation).
const GenerationCounter = if (@bitSizeOf(usize) >= 64) struct {
    value: std.atomic.Value(u64) = .init(0),

    fn next(self: *@This()) u64 {
        return self.value.fetchAdd(1, .monotonic) + 1;
    }
} else struct {
    mutex: std.Thread.Mutex = .{},
    value: u64 = 0,

    fn next(self: *@This()) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += 1;
        return self.value;
    }
};

/// An image storage is associated with a terminal screen (i.e. main
/// screen, alt screen) and contains all the transmitted images and
/// placements.
pub const ImageStorage = struct {
    const ImageMap = std.AutoHashMapUnmanaged(u32, Image);
    const PlacementMap = std.AutoHashMapUnmanaged(PlacementKey, Placement);

    /// Dirty is set to true if placements or images change. This is
    /// purely informational for the renderer and doesn't affect the
    /// correctness of the program. The renderer must set this to false
    /// if it cares about this value.
    ///
    /// Note that dirty is also set by scrolling and resizing (outside
    /// of this struct) because those move placement pins, even though
    /// the set of images/placements itself is unchanged. See generation
    /// for a signal that only tracks content mutations.
    ///
    /// Invariant: dirty is always set when generation changes
    /// (markMutated sets both); dirty set without a generation change
    /// means a geometry-only event.
    dirty: bool = false,

    /// Generation stamp of the last content mutation to this storage:
    /// any image transmit/replace, placement add, or delete of either.
    /// Zero means the storage has never been mutated (and is therefore
    /// empty).
    ///
    /// Unlike dirty, this is NOT updated by scrolling/resizing, so an
    /// unchanged generation means the placement set and all image data
    /// are identical; only placement geometry (pins) may have moved.
    /// Values come from a process-global monotonic counter, so a value
    /// observed from any storage never recurs for different content,
    /// even across screen switches or storage resets.
    ///
    /// This field must only be written via markMutated.
    generation: u64 = 0,

    /// This is the next automatically assigned image ID. We start mid-way
    /// through the u32 range to avoid collisions with buggy programs.
    /// TODO: This isn't good enough, it's perfectly legal for programs
    ///       to use IDs in the latter half of the range and collisions
    ///       are not gracefully handled.
    next_image_id: u32 = 2147483647,

    /// This is the next automatically assigned placement ID. This is never
    /// user-facing so we can start at 0. This is 32-bits because we use
    /// the same space for external placement IDs. We can start at zero
    /// because any number is valid.
    next_internal_placement_id: u32 = 0,

    /// The set of images that are currently known.
    images: ImageMap = .{},

    /// The set of placements for loaded images.
    placements: PlacementMap = .{},

    /// Non-null if there is an in-progress loading image.
    loading: ?*LoadingImage = null,

    /// The limits of what medium types are allowed for image loading.
    image_limits: LoadingImage.Limits = .direct,

    /// The total bytes of image data that have been loaded and the limit.
    /// If the limit is reached, the oldest images will be evicted to make
    /// space. Unused images take priority.
    total_bytes: usize = 0,
    total_limit: usize = 320 * 1000 * 1000, // 320MB

    pub fn deinit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
    ) void {
        if (self.loading) |loading| loading.destroy(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);

        self.clearPlacements(s);
        self.placements.deinit(alloc);
    }

    /// Kitty image protocol is enabled if we have a non-zero limit.
    pub fn enabled(self: *const ImageStorage) bool {
        return self.total_limit != 0;
    }

    /// Record a content mutation: marks the storage dirty and assigns a
    /// fresh generation stamp. Must be called by anything that changes
    /// the set of images or placements (or image contents).
    ///
    /// Do NOT call this for geometry-only events (scrolling, resizing,
    /// screen switches); those must set only the dirty flag directly.
    /// Bumping the generation for geometry changes would break the
    /// contract that an unchanged generation means unchanged contents.
    fn markMutated(self: *ImageStorage) void {
        self.dirty = true;
        self.generation = nextGeneration();
    }

    /// Sets the limit in bytes for the total amount of image data that
    /// can be loaded. If this limit is lower, this will do an eviction
    /// if necessary. If the value is zero, then Kitty image protocol will
    /// be disabled.
    pub fn setLimit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        limit: usize,
    ) !void {
        // Special case disabling by quickly deleting all
        if (limit == 0) {
            const image_limits = self.image_limits;
            self.deinit(alloc, s);
            self.* = .{ .image_limits = image_limits };
            self.markMutated();
        }

        // If we re lowering our limit, check if we need to evict.
        if (limit < self.total_bytes) {
            const req_bytes = self.total_bytes - limit;
            log.info("evicting images to lower limit, evicting={}", .{req_bytes});
            if (!try self.evictImage(alloc, req_bytes)) {
                log.warn("failed to evict enough images for required bytes", .{});
            }
        }

        self.total_limit = limit;
    }

    /// Add an already-loaded image to the storage. This will automatically
    /// free any existing image with the same ID.
    pub fn addImage(self: *ImageStorage, alloc: Allocator, img: Image) Allocator.Error!void {
        // If the image itself is over the limit, then error immediately
        if (img.data.len > self.total_limit) return error.OutOfMemory;

        // If this would put us over the limit, then evict.
        const total_bytes = self.total_bytes + img.data.len;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            log.info("evicting images to make space for {} bytes", .{req_bytes});
            if (!try self.evictImage(alloc, req_bytes)) {
                log.warn("failed to evict enough images for required bytes", .{});
                return error.OutOfMemory;
            }
        }

        // Do the gop op first so if it fails we don't get a partial state
        const gop = try self.images.getOrPut(alloc, img.id);

        log.debug("addImage image={}", .{img: {
            var copy = img;
            copy.data = "";
            break :img copy;
        }});

        // Write our new image
        if (gop.found_existing) {
            self.total_bytes -= gop.value_ptr.data.len;
            gop.value_ptr.deinit(alloc);
        }

        gop.value_ptr.* = img;
        self.total_bytes += img.data.len;

        // Stamp the stored image with a fresh generation. This gives
        // every add/replace a unique stamp even when the same image ID
        // is retransmitted with identical dimensions, so consumers
        // (e.g. renderer texture caches) can detect content changes.
        self.markMutated();
        gop.value_ptr.generation = self.generation;
    }

    /// Add a placement for a given image. The caller must verify in advance
    /// the image exists to prevent memory corruption.
    pub fn addPlacement(
        self: *ImageStorage,
        alloc: Allocator,
        image_id: u32,
        placement_id: u32,
        p: Placement,
    ) !void {
        assert(self.images.get(image_id) != null);
        log.debug("placement image_id={} placement_id={} placement={}\n", .{
            image_id,
            placement_id,
            p,
        });

        // The important piece here is that the placement ID needs to
        // be marked internal if it is zero. This allows multiple placements
        // to be added for the same image. If it is non-zero, then it is
        // an external placement ID and we can only have one placement
        // per (image id, placement id) pair.
        const key: PlacementKey = .{
            .image_id = image_id,
            .placement_id = if (placement_id == 0) .{
                .tag = .internal,
                .id = id: {
                    defer self.next_internal_placement_id +%= 1;
                    break :id self.next_internal_placement_id;
                },
            } else .{
                .tag = .external,
                .id = placement_id,
            },
        };

        const gop = try self.placements.getOrPut(alloc, key);
        gop.value_ptr.* = p;

        self.markMutated();
    }

    /// The maximum depth of a relative-placement parent chain. Matches Kitty's
    /// PARENT_DEPTH_LIMIT; the spec requires supporting at least 8.
    pub const parent_depth_limit: usize = 8;

    /// Resolve the absolute top-left pin for a placement.
    ///
    /// For pin placements this is simply the tracked pin. For relative
    /// placements (P/Q/H/V) it walks the parent chain, accumulating each level's
    /// signed cell offset onto the resolved parent position. Returns null when
    /// the chain cannot be resolved: a missing parent (e.g. it was deleted), a
    /// chain deeper than `parent_depth_limit`, or a virtual placement (which has
    /// no direct pin — virtual parents are resolved separately).
    pub fn resolvePin(
        self: *const ImageStorage,
        p: *const Placement,
        t: *const terminal.Terminal,
    ) ?PageList.Pin {
        return self.resolvePinDepth(p, t, 0);
    }

    fn resolvePinDepth(
        self: *const ImageStorage,
        p: *const Placement,
        t: *const terminal.Terminal,
        depth: usize,
    ) ?PageList.Pin {
        switch (p.location) {
            .pin => |pin| return pin.*,

            // Virtual placements have no direct pin; a relative placement whose
            // parent is virtual is resolved in a later milestone (M3).
            .virtual => return null,

            .relative => |rel| {
                if (depth >= parent_depth_limit) return null;

                // Look up and resolve the parent's top-left.
                const parent = self.placements.get(rel.parent) orelse return null;
                const base = self.resolvePinDepth(&parent, t, depth + 1) orelse
                    return null;

                // Apply the vertical cell offset.
                var pin: PageList.Pin = base;
                if (rel.offset_y > 0) {
                    pin = switch (pin.downOverflow(@intCast(rel.offset_y))) {
                        .offset => |v| v,
                        .overflow => |v| v.end,
                    };
                } else if (rel.offset_y < 0) {
                    pin = switch (pin.upOverflow(@intCast(-rel.offset_y))) {
                        .offset => |v| v,
                        .overflow => |v| v.end,
                    };
                }

                // Apply the horizontal cell offset, clamped to the grid.
                const col: i64 = @as(i64, pin.x) + rel.offset_x;
                pin.x = @intCast(std.math.clamp(
                    col,
                    0,
                    @as(i64, @intCast(t.cols)) - 1,
                ));
                return pin;
            },
        }
    }

    /// Resolve the parent placement referenced by a relative placement's P
    /// (parent image id) and Q (parent placement id) keys into a concrete
    /// PlacementKey, or null if no such placement exists.
    ///
    /// When Q is 0 the parent is unspecified, so we bind to the parent image's
    /// "first" placement under a deterministic order (lowest (tag, id)). This is
    /// resolved at creation time so the binding is stable for the placement's
    /// lifetime (matching Kitty's create-time binding).
    pub fn resolveParentKey(
        self: *const ImageStorage,
        parent_image_id: u32,
        parent_placement_id: u32,
    ) ?PlacementKey {
        if (parent_placement_id != 0) {
            const key: PlacementKey = .{
                .image_id = parent_image_id,
                .placement_id = .{ .tag = .external, .id = parent_placement_id },
            };
            return if (self.placements.contains(key)) key else null;
        }

        // Q == 0: pick the parent image's first placement deterministically.
        var best: ?PlacementKey = null;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.image_id != parent_image_id) continue;
            if (best == null or placementKeyLess(k, best.?)) best = k;
        }
        return best;
    }

    fn placementKeyLess(a: PlacementKey, b: PlacementKey) bool {
        const at = @intFromEnum(a.placement_id.tag);
        const bt = @intFromEnum(b.placement_id.tag);
        if (at != bt) return at < bt;
        return a.placement_id.id < b.placement_id.id;
    }

    pub const RelativeAncestryError = enum { cycle, too_deep };

    /// Validate the ancestry of a relative placement being created with parent
    /// `start_parent` and (optional) own key `child`. Returns .cycle if `child`
    /// appears in the parent chain, .too_deep if the chain exceeds
    /// `parent_depth_limit`, else null (ok). A direct self-reference
    /// (start_parent == child) is the caller's responsibility (EINVAL).
    pub fn relativeAncestryError(
        self: *const ImageStorage,
        start_parent: PlacementKey,
        child: ?PlacementKey,
    ) ?RelativeAncestryError {
        var key = start_parent;
        var depth: usize = 1; // the child -> start_parent hop
        while (true) {
            if (child) |c| {
                if (std.meta.eql(key, c)) return .cycle;
            }
            const p = self.placements.get(key) orelse return null;
            switch (p.location) {
                .relative => |rel| {
                    if (depth >= parent_depth_limit) return .too_deep;
                    depth += 1;
                    key = rel.parent;
                },
                // Reached a root (pin/virtual): chain is finite and in-bounds.
                else => return null,
            }
        }
    }

    /// Remove relative placements whose parent placement no longer exists,
    /// transitively. This implements the "group" lifetime from the spec:
    /// deleting or evicting a parent placement cascades to its relative
    /// descendants. Relative placements own no screen resources (they have no
    /// pin — see Placement.deinit), so removal needs neither a screen nor an
    /// allocator.
    fn removeOrphanedRelatives(self: *ImageStorage) void {
        // We restart the scan after each removal because removing an entry
        // invalidates the iterator, and because removing one orphan can orphan
        // its own children (transitive cascade). Placement counts are small.
        while (true) {
            var removed = false;
            var it = self.placements.iterator();
            while (it.next()) |entry| {
                const rel = switch (entry.value_ptr.location) {
                    .relative => |r| r,
                    else => continue,
                };
                if (self.placements.contains(rel.parent)) continue;
                self.placements.removeByPtr(entry.key_ptr);
                self.dirty = true;
                removed = true;
                break;
            }
            if (!removed) break;
        }
    }

    fn clearPlacements(self: *ImageStorage, s: *terminal.Screen) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(s);
        self.placements.clearRetainingCapacity();
    }

    /// Get an image by its ID. If the image doesn't exist, null is returned.
    pub fn imageById(self: *const ImageStorage, image_id: u32) ?Image {
        return self.images.get(image_id);
    }

    /// Get an image by its number. If the image doesn't exist, return null.
    pub fn imageByNumber(self: *const ImageStorage, image_number: u32) ?Image {
        var newest: ?Image = null;

        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number == image_number) {
                if (newest == null or
                    kv.value_ptr.generation > newest.?.generation)
                {
                    newest = kv.value_ptr.*;
                }
            }
        }

        return newest;
    }

    /// Delete placements, images.
    pub fn delete(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        cmd: command.Delete,
    ) void {
        // Deletes only ever remove placements/images, so comparing counts
        // before and after tells us whether anything actually changed.
        // Only then do we mark a mutation. This matters because a
        // delete-all runs on every screen clear (e.g. `ESC [ 2 J`), and
        // we don't want empty clears to dirty the image state or bump
        // the generation.
        const placements_before = self.placements.count();
        const images_before = self.images.count();
        defer if (self.placements.count() != placements_before or
            self.images.count() != images_before) self.markMutated();

        switch (cmd) {
            .all => |delete_images| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    // Skip virtual placements
                    switch (entry.value_ptr.location) {
                        .pin, .relative => {},
                        .virtual => continue,
                    }

                    // Deinit the placement and remove it
                    const image_id = entry.key_ptr.image_id;
                    entry.value_ptr.deinit(t.screens.active);
                    self.placements.removeByPtr(entry.key_ptr);
                    if (delete_images) self.deleteIfUnused(alloc, image_id);
                }

                if (delete_images) {
                    var image_it = self.images.iterator();
                    while (image_it.next()) |kv| self.deleteIfUnused(alloc, kv.key_ptr.*);
                }
            },

            .id => |v| self.deleteById(
                alloc,
                t.screens.active,
                v.image_id,
                v.placement_id,
                v.delete,
            ),

            .newest => |v| newest: {
                const img = self.imageByNumber(v.image_number) orelse break :newest;
                self.deleteById(
                    alloc,
                    t.screens.active,
                    img.id,
                    v.placement_id,
                    v.delete,
                );
            },

            .intersect_cursor => |delete_images| {
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = t.screens.active.cursor.x,
                        .y = t.screens.active.cursor.y,
                    } },
                    delete_images,
                    {},
                    null,
                );
            },

            .intersect_cell => |v| intersect_cell: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell,
                    } },
                    v.delete,
                    {},
                    null,
                );
            },

            .intersect_cell_z => |v| intersect_cell_z: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell_z;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell_z,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell_z,
                    } },
                    v.delete,
                    v.z,
                    struct {
                        fn filter(ctx: i32, p: Placement) bool {
                            return p.z == ctx;
                        }
                    }.filter,
                );
            },

            .column => |v| column: {
                if (v.x <= 0) {
                    log.warn("delete column must be greater than zero", .{});
                    break :column;
                }

                const x = v.x - 1;
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t, self) orelse continue;
                    if (rect.top_left.x <= x and rect.bottom_right.x >= x) {
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },

            .row => |v| row: {
                if (v.y <= 0) {
                    log.warn("delete row must be greater than zero", .{});
                    break :row;
                }

                // v.y is in active coords so we want to convert it to a pin
                // so we can compare by page offsets.
                const target_pin = t.screens.active.pages.pin(.{ .active = .{
                    .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :row,
                } }) orelse break :row;

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t, self) orelse continue;

                    // We need to copy our pin to ensure we are at least at
                    // the top-left x.
                    var target_pin_copy = target_pin;
                    target_pin_copy.x = rect.top_left.x;
                    if (target_pin_copy.isBetween(rect.top_left, rect.bottom_right)) {
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },

            .z => |v| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    switch (entry.value_ptr.location) {
                        .pin, .relative => {},

                        // Virtual placeholders cannot delete by z according
                        // to the spec.
                        .virtual => continue,
                    }

                    if (entry.value_ptr.z == v.z) {
                        const image_id = entry.key_ptr.image_id;
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }
            },

            .range => |v| range: {
                if (v.first <= 0 or v.last <= 0) {
                    log.warn("delete range values must be greater than zero", .{});
                    break :range;
                }
                if (v.first > v.last) {
                    log.warn("delete range 'x' ({}) must be less than or equal to 'y' ({})", .{ v.first, v.last });
                    break :range;
                }

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.image_id >= v.first or entry.key_ptr.image_id <= v.last) {
                        const image_id = entry.key_ptr.image_id;
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }
            },

            // We don't support animation frames yet so they are successfully
            // deleted!
            .animation_frames => {},
        }

        // Any relative placement whose parent was just removed is cascaded.
        self.removeOrphanedRelatives();
    }

    fn deleteById(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        delete_unused: bool,
    ) void {
        // If no placement, we delete all placements with the ID
        if (placement_id == 0) {
            var it = self.placements.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.image_id == image_id) {
                    entry.value_ptr.deinit(s);
                    self.placements.removeByPtr(entry.key_ptr);
                }
            }
        } else {
            if (self.placements.getEntry(.{
                .image_id = image_id,
                .placement_id = .{ .tag = .external, .id = placement_id },
            })) |entry| {
                entry.value_ptr.deinit(s);
                self.placements.removeByPtr(entry.key_ptr);
            }
        }

        // If this is specified, then we also delete the image
        // if it is no longer in use.
        if (delete_unused) self.deleteIfUnused(alloc, image_id);
    }

    /// Delete an image if it is unused.
    fn deleteIfUnused(self: *ImageStorage, alloc: Allocator, image_id: u32) void {
        var it = self.placements.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.image_id == image_id) {
                return;
            }
        }

        // If we get here, we can delete the image.
        if (self.images.getEntry(image_id)) |entry| {
            self.total_bytes -= entry.value_ptr.data.len;
            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
        }
    }

    /// Deletes all placements intersecting a screen point.
    fn deleteIntersecting(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        p: point.Point,
        delete_unused: bool,
        filter_ctx: anytype,
        comptime filter: ?fn (@TypeOf(filter_ctx), Placement) bool,
    ) void {
        // Convert our target point to a pin for comparison.
        const target_pin = t.screens.active.pages.pin(p) orelse return;

        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const img = self.imageById(entry.key_ptr.image_id) orelse continue;
            const rect = entry.value_ptr.rect(img, t, self) orelse continue;
            if (pinIntersectsRect(target_pin, rect)) {
                if (filter) |f| if (!f(filter_ctx, entry.value_ptr.*)) continue;
                entry.value_ptr.deinit(t.screens.active);
                self.placements.removeByPtr(entry.key_ptr);
                if (delete_unused) self.deleteIfUnused(alloc, img.id);
            }
        }
    }

    fn pinIntersectsRect(pin: PageList.Pin, rect: Rect) bool {
        if (pin.x < rect.top_left.x or pin.x > rect.bottom_right.x) return false;
        // Pin y values are page-local, so vertical bounds need page-order
        // comparison to handle placements that cross page nodes.
        return !pin.before(rect.top_left) and !rect.bottom_right.before(pin);
    }

    /// Evict image to make space. This will evict the oldest image,
    /// prioritizing unused images first, as recommended by the published
    /// Kitty spec.
    ///
    /// This will evict as many images as necessary to make space for
    /// req bytes.
    fn evictImage(self: *ImageStorage, alloc: Allocator, req: usize) !bool {
        assert(req <= self.total_limit);

        // Ironically we allocate to evict. We should probably redesign the
        // data structures to avoid this but for now allocating a little
        // bit is fine compared to the megabytes we're looking to save.
        const Candidate = struct {
            id: u32,
            generation: u64,
            used: bool,
        };

        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| {
            const img = kv.value_ptr;

            // This is a huge waste. See comment above about redesigning
            // our data structures to avoid this. Eviction should be very
            // rare though and we never have that many images/placements
            // so hopefully this will last a long time.
            const used = used: {
                var p_it = self.placements.iterator();
                while (p_it.next()) |p_kv| {
                    if (p_kv.key_ptr.image_id == img.id) {
                        break :used true;
                    }
                }

                break :used false;
            };

            try candidates.append(alloc, .{
                .id = img.id,
                .generation = img.generation,
                .used = used,
            });
        }

        // Sort
        std.mem.sortUnstable(
            Candidate,
            candidates.items,
            {},
            struct {
                fn lessThan(
                    ctx: void,
                    lhs: Candidate,
                    rhs: Candidate,
                ) bool {
                    _ = ctx;

                    // If their usage matches, then it's based on the
                    // generation stamp, which orders by transmit time.
                    // (Stamps are unique but tie-break by ID anyway to
                    // stay deterministic for hand-built test images.)
                    if (lhs.used == rhs.used) return if (lhs.generation == rhs.generation)
                        lhs.id < rhs.id
                    else
                        lhs.generation < rhs.generation;

                    // If not used, then its a better candidate
                    return !lhs.used;
                }
            }.lessThan,
        );

        // Evicting anything is a content mutation. This matters for the
        // setLimit path in particular, which doesn't otherwise mark it.
        var any_evicted = false;
        defer if (any_evicted) self.markMutated();

        // They're in order of best to evict.
        var evicted: usize = 0;
        var enough = false;
        for (candidates.items) |c| {
            // Delete all the placements for this image and the image.
            var p_it = self.placements.iterator();
            while (p_it.next()) |entry| {
                if (entry.key_ptr.image_id == c.id) {
                    self.placements.removeByPtr(entry.key_ptr);
                    any_evicted = true;
                }
            }

            if (self.images.getEntry(c.id)) |entry| {
                log.info("evicting image id={} bytes={}", .{ c.id, entry.value_ptr.data.len });

                evicted += entry.value_ptr.data.len;
                self.total_bytes -= entry.value_ptr.data.len;

                entry.value_ptr.deinit(alloc);
                self.images.removeByPtr(entry.key_ptr);
                any_evicted = true;

                if (evicted > req) {
                    enough = true;
                    break;
                }
            }
        }

        // Evicting an image removes its placements, which can orphan relative
        // placements that pointed at them; cascade those away too.
        self.removeOrphanedRelatives();

        return enough;
    }

    /// Every placement is uniquely identified by the image ID and the
    /// placement ID. If an image ID isn't specified it is assumed to be 0.
    /// Likewise, if a placement ID isn't specified it is assumed to be 0.
    pub const PlacementKey = struct {
        image_id: u32,
        placement_id: packed struct {
            tag: enum(u1) { internal, external },
            id: u32,
        },
    };

    pub const Placement = struct {
        /// The location where this placement should be drawn.
        location: Location,

        /// Offset of the x/y from the top-left of the cell.
        x_offset: u32 = 0,
        y_offset: u32 = 0,

        /// Source rectangle for the image to pull from
        source_x: u32 = 0,
        source_y: u32 = 0,
        source_width: u32 = 0,
        source_height: u32 = 0,

        /// The columns/rows this image occupies.
        columns: u32 = 0,
        rows: u32 = 0,

        /// The z-index for this placement.
        z: i32 = 0,

        pub const Location = union(enum) {
            /// Exactly placed on a screen pin.
            pin: *PageList.Pin,

            /// Virtual placement (U=1) for unicode placeholders.
            virtual: void,

            /// Relative placement (P/Q/H/V): positioned relative to a parent
            /// placement. The parent is resolved and bound at creation time so
            /// `parent` is a concrete key. The position is derived by walking
            /// the parent chain at resolution time (see ImageStorage.resolvePin),
            /// so a relative placement has no pin of its own.
            relative: Relative,
        };

        pub const Relative = struct {
            /// The resolved parent placement this is positioned relative to.
            parent: PlacementKey,

            /// Cell offset from the parent's top-left (H/V), signed.
            offset_x: i32 = 0,
            offset_y: i32 = 0,
        };

        pub fn deinit(
            self: *const Placement,
            s: *terminal.Screen,
        ) void {
            switch (self.location) {
                .pin => |p| s.pages.untrackPin(p),
                .virtual, .relative => {},
            }
        }

        /// Returns the size of this placement's image in pixels,
        /// taking into account the source rectangle, specified
        /// rows/columns, and aspect ratio.
        pub fn pixelSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            width: u32,
            height: u32,
        } {
            // Height / width of the image in px.
            const width = if (self.source_width > 0) self.source_width else image.width;
            const height = if (self.source_height > 0) self.source_height else image.height;

            // If we don't have any specified cols or rows then the placement
            // should be the native size of the image, and doesn't need to be
            // re-scaled.
            if (self.columns == 0 and self.rows == 0) return .{
                .width = width,
                .height = height,
            };

            // We calculate the size of a cell so that we can multiply
            // it by the specified cols/rows to get the correct px size.
            //
            // We assume that the width is divided evenly by the column
            // count and the height by the row count, because it should be.
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;

            const width_f64: f64 = @floatFromInt(width);
            const height_f64: f64 = @floatFromInt(height);

            // If we have a specified cols AND rows then we calculate
            // the width and height from them directly, we don't need
            // to adjust for aspect ratio.
            if (self.columns > 0 and self.rows > 0) {
                const calc_width = cell_width * self.columns;
                const calc_height = cell_height * self.rows;

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }

            // Either the columns or the rows were specified, but not both,
            // so we need to calculate the other one based on the aspect ratio.

            // If only the columns were specified, we determine
            // the height of the image based on the aspect ratio.
            if (self.columns > 0) {
                const aspect = height_f64 / width_f64;
                const calc_width: u32 = cell_width * self.columns;
                const calc_height: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(calc_width)) * aspect,
                ));

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }

            // Otherwise, only the rows were specified, so we
            // determine the width based on the aspect ratio.
            {
                const aspect = width_f64 / height_f64;
                const calc_height: u32 = cell_height * self.rows;
                const calc_width: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(calc_height)) * aspect,
                ));

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }
        }

        /// Returns the size in grid cells that this placement takes up.
        pub fn gridSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            cols: u32,
            rows: u32,
        } {
            // If we have a specified columns and rows then this is trivial.
            if (self.columns > 0 and self.rows > 0) return .{
                .cols = self.columns,
                .rows = self.rows,
            };

            // Otherwise we calculate the pixel size, divide by
            // cell size, and round up to the nearest integer.
            const calc_size = self.pixelSize(image, t);
            return .{
                .cols = std.math.divCeil(
                    u32,
                    calc_size.width + self.x_offset,
                    t.width_px / t.cols,
                ) catch 0,
                .rows = std.math.divCeil(
                    u32,
                    calc_size.height + self.y_offset,
                    t.height_px / t.rows,
                ) catch 0,
            };
            // NOTE: Above `divCeil`s can only fail if the cell size is 0,
            //       in such a case it seems safe to return 0 for this.
        }

        /// Returns a selection of the entire rectangle this placement
        /// occupies within the screen. This can return null if the placement
        /// doesn't have an associated rect (i.e. a virtual placement).
        pub fn rect(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
            storage: *const ImageStorage,
        ) ?Rect {
            const grid_size = self.gridSize(image, t);

            // Resolve the top-left position. For relative placements this walks
            // the parent chain; for virtual placements there is no rect.
            const pin = storage.resolvePin(&self, t) orelse return null;

            var br = switch (pin.downOverflow(grid_size.rows - 1)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };
            br.x = @min(
                // We need to sub one here because the x value is
                // one width already. So if the image is width "1"
                // then we add zero to X because X itself is width 1.
                pin.x + (grid_size.cols - 1),
                t.cols - 1,
            );

            return .{
                .top_left = pin,
                .bottom_right = br,
            };
        }
    };
};

// Our pin for the placement
fn trackPin(
    t: *terminal.Terminal,
    pt: point.Coordinate,
) !*PageList.Pin {
    return try t.screens.active.pages.trackPin(t.screens.active.pages.pin(.{
        .active = pt,
    }).?);
}

test "storage: add placement with zero placement id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    try s.addPlacement(alloc, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 0 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 1 },
    }) != null);
}

test "storage: delete all placements and images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements and images preserves limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 5000;
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 5000), s.total_limit);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .all = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{ .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id and unused images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{ .delete = true, .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete placement by specific id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 2,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: delete intersecting cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(alloc, &t, .{ .intersect_cursor = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor plus unused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor hits multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(26, 26);

    s.dirty = false;
    s.delete(alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete intersecting cursor respects placement columns on interior rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 10, .height = 10 });
    try s.addImage(alloc, .{ .id = 2, .width = 10, .height = 10 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });

    t.screens.active.cursorAbsolute(25, 5);
    s.delete(alloc, &t, .{ .intersect_cursor = false });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete intersecting cell respects placement columns on interior rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 10, .height = 10 });
    try s.addImage(alloc, .{ .id = 2, .width = 10, .height = 10 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });

    s.delete(alloc, &t, .{ .intersect_cell = .{
        .delete = false,
        .x = 26,
        .y = 6,
    } });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .column = .{
        .delete = false,
        .x = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by column 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 0 }) } });

    s.delete(alloc, &t, .{ .column = .{
        .delete = false,
        .x = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete by row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .row = .{
        .delete = false,
        .y = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by row 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) } });
    try s.addPlacement(alloc, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 1 }) } });
    try s.addPlacement(alloc, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 2 }) } });

    s.delete(alloc, &t, .{ .row = .{
        .delete = false,
        .y = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete images by range 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 1 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    try s.addImage(alloc, .{ .id = 2 });
    try s.addImage(alloc, .{ .id = 3 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 1 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: aspect ratio calculation when only columns or rows specified" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 1000; // 10 px per col
    t.height_px = 2000; // 20 px per row

    // Case 1: Only columns specified
    {
        const image = Image{ .id = 1, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 10,
            .rows = 0,
        };

        // Image is 16x9, set to a width of 10 columns, at 10px per column
        // that's 100px width. 100px * (9 / 16) = 56.25, which should round
        // to a height of 56px.

        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 100), calc_size.width);
        try testing.expectEqual(@as(u32, 56), calc_size.height);
    }

    // Case 2: Only rows specified
    {
        const image = Image{ .id = 2, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 0,
            .rows = 5,
        };

        // Image is 16x9, set to a height of 5 rows, at 20px per row that's
        // 100px height. 100px * (16 / 9) = 177.77..., which should round to
        // a width of 178px.

        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 178), calc_size.width);
        try testing.expectEqual(@as(u32, 100), calc_size.height);
    }
}

test "storage: generation stamps on image add and replace" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Fresh storage has generation zero (never mutated).
    try testing.expectEqual(@as(u64, 0), s.generation);

    try s.addImage(alloc, .{ .id = 1, .width = 1, .height = 1 });
    const gen1 = s.generation;
    try testing.expect(gen1 > 0);

    const img1 = s.imageById(1).?;
    try testing.expectEqual(gen1, img1.generation);

    // A second image gets a strictly greater stamp.
    try s.addImage(alloc, .{ .id = 2, .width = 1, .height = 1 });
    const gen2 = s.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, s.imageById(2).?.generation);

    // Retransmitting the same image ID (identical dimensions) gets a
    // fresh stamp: this is what makes same-sized retransmissions
    // detectable by renderers.
    try s.addImage(alloc, .{ .id = 1, .width = 1, .height = 1 });
    const gen3 = s.generation;
    try testing.expect(gen3 > gen2);
    try testing.expectEqual(gen3, s.imageById(1).?.generation);

    // Image 2 kept its stamp.
    try testing.expectEqual(gen2, s.imageById(2).?.generation);
}

test "storage: generation bumps on placement and delete" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1 });
    const gen_add = s.generation;

    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen_place = s.generation;
    try testing.expect(gen_place > gen_add);

    // Reads don't change the generation.
    _ = s.imageById(1);
    _ = s.imageByNumber(1);
    try testing.expectEqual(gen_place, s.generation);

    s.delete(alloc, &t, .{ .all = true });
    try testing.expect(s.generation > gen_place);
}

test "storage: generation bumps when setLimit evicts or disables" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    const data = try alloc.dupe(u8, "1234");
    try s.addImage(alloc, .{ .id = 1, .width = 1, .height = 1, .data = data });
    const gen_add = s.generation;

    // Lowering the limit evicts the image and must mark a mutation.
    s.dirty = false;
    try s.setLimit(alloc, t.screens.active, 1);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_add);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    const gen_evict = s.generation;

    // Disabling (limit=0) resets the storage and must mark a mutation.
    s.dirty = false;
    try s.setLimit(alloc, t.screens.active, 0);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_evict);
}

test "storage: imageByNumber returns most recently transmitted" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Two images sharing a number: the newest transmission wins,
    // regardless of insertion order or clock resolution.
    try s.addImage(alloc, .{ .id = 1, .number = 7 });
    try s.addImage(alloc, .{ .id = 2, .number = 7 });
    try testing.expectEqual(@as(u32, 2), s.imageByNumber(7).?.id);

    // Retransmit the first: it becomes the newest.
    try s.addImage(alloc, .{ .id = 1, .number = 7 });
    try testing.expectEqual(@as(u32, 1), s.imageByNumber(7).?.id);
}

test "storage: nextGeneration is unique and monotonic" {
    const testing = std.testing;
    const a = nextGeneration();
    const b = nextGeneration();
    try testing.expect(b > a);
    try testing.expect(a > 0);
}

test "storage: no-op delete does not mark a mutation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A delete-all on an empty storage (this runs on every screen
    // clear) must not dirty the state or bump the generation.
    s.delete(alloc, &t, .{ .all = true });
    try testing.expect(!s.dirty);
    try testing.expectEqual(@as(u64, 0), s.generation);

    // Same for a delete that matches nothing.
    try s.addImage(alloc, .{ .id = 1 });
    try s.addPlacement(alloc, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen = s.generation;
    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{ .image_id = 42 } });
    try testing.expect(!s.dirty);
    try testing.expectEqual(gen, s.generation);

    // But a delete that removes something does mark a mutation.
    s.delete(alloc, &t, .{ .id = .{ .image_id = 1 } });
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
}

test "storage: relative placement resolves to parent position + offset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 1, .width = 10, .height = 10 });
    try s.addImage(alloc, .{ .id = 2, .width = 10, .height = 10 });

    // Parent pinned at active (3, 4).
    try s.addPlacement(alloc, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 4 }) },
    });
    // Child relative to the parent, offset (+10, +5).
    try s.addPlacement(alloc, 2, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .offset_x = 10,
            .offset_y = 5,
        } },
    });

    const child = s.placements.get(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const pin = s.resolvePin(&child, &t).?;
    const pt = t.screens.active.pages.pointFromPin(.active, pin).?;
    try testing.expectEqual(@as(u32, 13), pt.active.x); // 3 + 10
    try testing.expectEqual(@as(u32, 9), pt.active.y); // 4 + 5
}

test "storage: relative placement with missing parent does not resolve" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, .{ .id = 2, .width = 10, .height = 10 });

    // Child references a parent placement that does not exist.
    try s.addPlacement(alloc, 2, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .offset_x = 1,
            .offset_y = 1,
        } },
    });

    const child = s.placements.get(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    try testing.expect(s.resolvePin(&child, &t) == null);
}
