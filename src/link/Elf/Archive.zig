path: []const u8,
data: []const u8,

objects: std.ArrayListUnmanaged(Object) = .{},
strtab: []const u8 = &[0]u8{},

pub fn isArchive(path: []const u8) !bool {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const reader = file.reader();
    const magic = reader.readBytesNoEof(SARMAG) catch return false;
    if (!mem.eql(u8, &magic, ARMAG)) return false;
    return true;
}

pub fn deinit(self: *Archive, allocator: Allocator) void {
    allocator.free(self.path);
    allocator.free(self.data);
    self.objects.deinit(allocator);
}

pub fn parse(self: *Archive, elf_file: *Elf) !void {
    const gpa = elf_file.base.allocator;

    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();
    _ = try reader.readBytesNoEof(SARMAG);

    while (true) {
        if (stream.pos >= self.data.len) break;

        if (stream.pos % 2 != 0) {
            stream.pos += 1;
        }
        const hdr = try reader.readStruct(ar_hdr);

        if (!mem.eql(u8, &hdr.ar_fmag, ARFMAG)) {
            // TODO convert into an error
            log.debug(
                "{s}: invalid header delimiter: expected '{s}', found '{s}'",
                .{ self.path, std.fmt.fmtSliceEscapeLower(ARFMAG), std.fmt.fmtSliceEscapeLower(&hdr.ar_fmag) },
            );
            return;
        }

        const size = try hdr.size();
        defer {
            _ = stream.seekBy(size) catch {};
        }

        if (hdr.isSymtab()) continue;
        if (hdr.isStrtab()) {
            self.strtab = self.data[stream.pos..][0..size];
            continue;
        }

        const name = ar_hdr.getValue(&hdr.ar_name);

        if (mem.eql(u8, name, "__.SYMDEF") or mem.eql(u8, name, "__.SYMDEF SORTED")) continue;

        const object_name = blk: {
            if (name[0] == '/') {
                const off = try std.fmt.parseInt(u32, name[1..], 10);
                const object_name = self.getString(off);
                break :blk try gpa.dupe(u8, object_name[0 .. object_name.len - 1]); // To account for trailing '/'
            }
            break :blk try gpa.dupe(u8, name);
        };

        const object = Object{
            .archive = try gpa.dupe(u8, self.path),
            .path = object_name,
            .data = try gpa.dupe(u8, self.data[stream.pos..][0..size]),
            .index = undefined,
            .alive = false,
        };

        log.debug("extracting object '{s}' from archive '{s}'", .{ object.path, self.path });

        try self.objects.append(gpa, object);
    }
}

fn getString(self: Archive, off: u32) []const u8 {
    assert(off < self.strtab.len);
    return mem.sliceTo(@as([*:strtab_delimiter]const u8, @ptrCast(self.strtab.ptr + off)), 0);
}

pub fn setArHdr(opts: struct {
    name: union(enum) {
        symtab: void,
        strtab: void,
        name: []const u8,
        name_off: u32,
    },
    size: u32,
}) ar_hdr {
    var hdr: ar_hdr = .{
        .ar_name = undefined,
        .ar_date = undefined,
        .ar_uid = undefined,
        .ar_gid = undefined,
        .ar_mode = undefined,
        .ar_size = undefined,
        .ar_fmag = undefined,
    };
    @memset(mem.asBytes(&hdr), 0x20);
    @memcpy(&hdr.ar_fmag, Archive.ARFMAG);

    {
        var stream = std.io.fixedBufferStream(&hdr.ar_name);
        const writer = stream.writer();
        switch (opts.name) {
            .symtab => writer.print("{s}", .{Archive.SYM64NAME}) catch unreachable,
            .strtab => writer.print("//", .{}) catch unreachable,
            .name => |x| writer.print("{s}", .{x}) catch unreachable,
            .name_off => |x| writer.print("/{d}", .{x}) catch unreachable,
        }
    }
    {
        var stream = std.io.fixedBufferStream(&hdr.ar_size);
        stream.writer().print("{d}", .{opts.size}) catch unreachable;
    }

    return hdr;
}

// Archive files start with the ARMAG identifying string.  Then follows a
// `struct ar_hdr', and as many bytes of member file data as its `ar_size'
// member indicates, for each member file.
/// String that begins an archive file.
pub const ARMAG: *const [SARMAG:0]u8 = "!<arch>\n";
/// Size of that string.
pub const SARMAG = 8;

/// String in ar_fmag at the end of each header.
const ARFMAG: *const [2:0]u8 = "`\n";

/// Strtab identifier
const STRNAME: *const [2:0]u8 = "//";

/// 32-bit symtab identifier
const SYMNAME: *const [1:0]u8 = "/";

/// 64-bit symtab identifier
const SYM64NAME: *const [7:0]u8 = "/SYM64/";

const strtab_delimiter = '\n';

pub const ar_hdr = extern struct {
    /// Member file name, sometimes / terminated.
    ar_name: [16]u8,

    /// File date, decimal seconds since Epoch.
    ar_date: [12]u8,

    /// User ID, in ASCII format.
    ar_uid: [6]u8,

    /// Group ID, in ASCII format.
    ar_gid: [6]u8,

    /// File mode, in ASCII octal.
    ar_mode: [8]u8,

    /// File size, in ASCII decimal.
    ar_size: [10]u8,

    /// Always contains ARFMAG.
    ar_fmag: [2]u8,

    fn date(self: ar_hdr) !u64 {
        const value = getValue(&self.ar_date);
        return std.fmt.parseInt(u64, value, 10);
    }

    fn size(self: ar_hdr) !u32 {
        const value = getValue(&self.ar_size);
        return std.fmt.parseInt(u32, value, 10);
    }

    fn getValue(raw: []const u8) []const u8 {
        return mem.trimRight(u8, raw, &[_]u8{@as(u8, 0x20)});
    }

    fn isStrtab(self: ar_hdr) bool {
        return mem.eql(u8, getValue(&self.ar_name), STRNAME);
    }

    fn isSymtab(self: ar_hdr) bool {
        return mem.eql(u8, getValue(&self.ar_name), SYMNAME) or mem.eql(u8, getValue(&self.ar_name), SYM64NAME);
    }
};

pub const ArSymtab = struct {
    symtab: std.ArrayListUnmanaged(Entry) = .{},
    strtab: StringTable = .{},

    pub fn deinit(ar: *ArSymtab, allocator: Allocator) void {
        ar.symtab.deinit(allocator);
        ar.strtab.deinit(allocator);
    }

    pub fn sort(ar: *ArSymtab) void {
        mem.sort(Entry, ar.symtab.items, {}, Entry.lessThan);
    }

    pub fn size(ar: ArSymtab, kind: enum { p32, p64 }) usize {
        const ptr_size: usize = switch (kind) {
            .p32 => 4,
            .p64 => 8,
        };
        var ss: usize = ptr_size + ar.symtab.items.len * ptr_size;
        for (ar.symtab.items) |entry| {
            ss += ar.strtab.getAssumeExists(entry.off).len + 1;
        }
        return ss;
    }

    pub fn write(ar: ArSymtab, kind: enum { p32, p64 }, elf_file: *Elf, writer: anytype) !void {
        assert(kind == .p64); // TODO p32
        const hdr = setArHdr(.{ .name = .symtab, .size = @intCast(ar.size(.p64)) });
        try writer.writeAll(mem.asBytes(&hdr));

        const gpa = elf_file.base.allocator;
        var offsets = std.AutoHashMap(File.Index, u64).init(gpa);
        defer offsets.deinit();
        try offsets.ensureUnusedCapacity(@intCast(elf_file.objects.items.len + 1));

        if (elf_file.zigObjectPtr()) |zig_object| {
            offsets.putAssumeCapacityNoClobber(zig_object.index, zig_object.output_ar_state.file_off);
        }

        // Number of symbols
        try writer.writeInt(u64, @as(u64, @intCast(ar.symtab.items.len)), .big);

        // Offsets to files
        for (ar.symtab.items) |entry| {
            const off = offsets.get(entry.file_index).?;
            try writer.writeInt(u64, off, .big);
        }

        // Strings
        for (ar.symtab.items) |entry| {
            try writer.print("{s}\x00", .{ar.strtab.getAssumeExists(entry.off)});
        }
    }

    pub fn format(
        ar: ArSymtab,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = ar;
        _ = unused_fmt_string;
        _ = options;
        _ = writer;
        @compileError("do not format ar symtab directly; use fmt instead");
    }

    const FormatContext = struct {
        ar: ArSymtab,
        elf_file: *Elf,
    };

    pub fn fmt(ar: ArSymtab, elf_file: *Elf) std.fmt.Formatter(format2) {
        return .{ .data = .{
            .ar = ar,
            .elf_file = elf_file,
        } };
    }

    fn format2(
        ctx: FormatContext,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = unused_fmt_string;
        _ = options;
        const ar = ctx.ar;
        const elf_file = ctx.elf_file;
        for (ar.symtab.items, 0..) |entry, i| {
            const name = ar.strtab.getAssumeExists(entry.off);
            const file = elf_file.file(entry.file_index).?;
            try writer.print("  {d}: {s} in file({d})({})\n", .{ i, name, entry.file_index, file.fmtPath() });
        }
    }

    const Entry = struct {
        /// Offset into the string table.
        off: u32,
        /// Index of the file defining the global.
        file_index: File.Index,

        pub fn lessThan(ctx: void, lhs: Entry, rhs: Entry) bool {
            _ = ctx;
            if (lhs.off == rhs.off) return lhs.file_index < rhs.file_index;
            return lhs.off < rhs.off;
        }
    };
};

pub const ArStrtab = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},

    pub fn deinit(ar: *ArStrtab, allocator: Allocator) void {
        ar.buffer.deinit(allocator);
    }

    pub fn insert(ar: *ArStrtab, allocator: Allocator, name: []const u8) error{OutOfMemory}!u32 {
        const off = @as(u32, @intCast(ar.buffer.items.len));
        try ar.buffer.writer(allocator).print("{s}/{c}", .{ name, strtab_delimiter });
        return off;
    }

    pub fn size(ar: ArStrtab) usize {
        return ar.buffer.items.len;
    }

    pub fn write(ar: ArStrtab, writer: anytype) !void {
        const hdr = setArHdr(.{ .name = .strtab, .size = @intCast(ar.size()) });
        try writer.writeAll(mem.asBytes(&hdr));
        try writer.writeAll(ar.buffer.items);
    }

    pub fn format(
        ar: ArStrtab,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = unused_fmt_string;
        _ = options;
        try writer.print("{s}", .{std.fmt.fmtSliceEscapeLower(ar.buffer.items)});
    }
};

pub const ArState = struct {
    /// Name offset in the string table.
    name_off: u32 = 0,

    /// File offset of the ar_hdr describing the contributing
    /// object in the archive.
    file_off: u64 = 0,

    /// Total size of the contributing object (excludes ar_hdr).
    size: u64 = 0,
};

const std = @import("std");
const assert = std.debug.assert;
const elf = std.elf;
const fs = std.fs;
const log = std.log.scoped(.link);
const mem = std.mem;

const Allocator = mem.Allocator;
const Archive = @This();
const Elf = @import("../Elf.zig");
const File = @import("file.zig").File;
const Object = @import("Object.zig");
const StringTable = @import("../StringTable.zig");
