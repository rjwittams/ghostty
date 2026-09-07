//! Generate a Windows import-library definition from the built public C ABI.
//! Zig also exports runtime symbols such as _DllMainCRTStartup. Importing
//! that symbol into a consumer DLL can bypass the consumer's CRT startup.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 3) return error.InvalidArguments;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], alloc, .unlimited);
    const coff = try std.coff.Coff.init(data, false);
    const directories = coff.getDataDirectories();
    if (directories.len == 0) return error.MissingExports;
    const exports = try atRva(coff, directories[0].virtual_address);
    // IMAGE_EXPORT_DIRECTORY: NumberOfNames and AddressOfNames.
    const count = try readU32(exports, 24);
    const names = try atRva(coff, try readU32(exports, 32));
    var output: std.Io.Writer.Allocating = .init(alloc);
    try output.writer.writeAll("LIBRARY ghostty-vt.dll\nEXPORTS\n");
    var public_count: usize = 0;
    for (0..count) |i| {
        const name_data = try atRva(coff, try readU32(names, i * 4));
        const end = std.mem.indexOfScalar(u8, name_data, 0) orelse return error.InvalidExportName;
        const name = name_data[0..end];
        if (!std.mem.startsWith(u8, name, "ghostty_")) continue;
        try output.writer.print("  {s}\n", .{name});
        public_count += 1;
    }
    if (public_count == 0) return error.MissingPublicExports;
    const file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer file.close(init.io);
    try file.writePositionalAll(init.io, output.written(), 0);
}

fn readU32(data: []const u8, offset: usize) !u32 {
    if (offset > data.len or data.len - offset < 4) return error.InvalidExportTable;
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn atRva(coff: std.coff.Coff, rva: u32) ![]const u8 {
    for (coff.getSectionHeaders()) |section| {
        if (rva < section.virtual_address) continue;
        const offset = rva - section.virtual_address;
        if (offset >= section.size_of_raw_data) continue;
        const start = @as(usize, section.pointer_to_raw_data) + offset;
        const end = @as(usize, section.pointer_to_raw_data) + section.size_of_raw_data;
        if (end > coff.data.len) return error.InvalidSection;
        return coff.data[start..end];
    }
    return error.InvalidRva;
}
