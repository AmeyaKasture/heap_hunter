//! Stage 9: read-only query engine over a published index.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Scanner = @import("Scanner.zig");
const CatalogSorter = @import("CatalogSorter.zig");
const Csr = @import("Csr.zig");
const Regex = @import("../Regex.zig");
const log = @import("log");

pub const Error = error{
    MissingIndexDir,
    MissingIndexFile,
    InvalidManifest,
    CorruptIndexFile,
    SourceFileNotFound,
    SourceFingerprintMismatch,
    InvalidObjectId,
    ObjectNotFound,
    SourceNotAvailable,
    InvalidSourceOffset,
    InvalidFieldType,
    LimitTooLarge,
    InvalidDirection,
};

const MappedFile = struct {
    file: Io.File,
    mm: Io.File.MemoryMap,

    fn open(io: Io, path: []const u8) !MappedFile {
        const dir = Io.Dir.cwd();
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const len = try file.length(io);
        const mm = try Io.File.MemoryMap.create(io, file, .{
            .len = len,
            .protection = .{ .read = true, .write = false },
            // Rely on demand paging; MAP_POPULATE (the default) would fault
            // in the entire file up front, costing ~17s for a 3.9GB catalog.
            .populate = false,
        });
        return .{ .file = file, .mm = mm };
    }

    fn close(self: *MappedFile, io: Io) void {
        self.mm.destroy(io);
        self.file.close(io);
    }

    fn data(self: *const MappedFile) []const u8 {
        return self.mm.memory;
    }
};

pub const ClassInfo = struct {
    class_id: hprof.Id,
    super_class_id: hprof.Id,
    instance_size: u32,
    name: []const u8,
};

pub const FieldInfo = struct {
    name: []const u8,
    type: hprof.PrimitiveType,
    byte_offset: u32,
    declaring_class_id: hprof.Id,
};

pub const LayoutInfo = struct {
    class_id: hprof.Id,
    fields: []const FieldInfo,
    reference_offsets: []const u32,
};

/// In-memory root record loaded from `roots.bin`.
const RootInfo = struct {
    target_ordinal: u32,
    root_kind: u8,
};

/// A decoded view of one object, ready for JSON serialization.
pub const ObjectView = struct {
    raw_id: hprof.Id,
    ordinal: u32,
    class_raw_id: hprof.Id,
    class_name: []const u8,
    shallow_size: u32,
    kind: Scanner.CatalogKind,
    /// Union discriminated by `kind`.
    payload: Payload,

    pub fn deinit(self: ObjectView, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .instance => |fields| allocator.free(fields),
            .object_array => |arr| allocator.free(arr.elements),
            .primitive_array => |arr| allocator.free(arr.values),
            .class => |cv| allocator.free(cv.static_fields),
        }
    }

    pub const Payload = union(Scanner.CatalogKind) {
        instance: []const FieldValue,
        object_array: ObjectArrayView,
        primitive_array: PrimitiveArrayView,
        class: ClassView,
    };
};

pub const FieldValue = struct {
    name: []const u8,
    declared_by: ?[]const u8,
    primitive: ?FieldPrimitive,
    ref: ?FieldRef,
};

pub const FieldPrimitive = union(hprof.PrimitiveType) {
    array_object: void,
    object: void,
    boolean: bool,
    char: u16,
    float: f32,
    double: f64,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
};

pub const FieldRef = struct {
    raw_id: hprof.Id,
    ordinal: ?u32,
    class_name: []const u8,
};

pub const ObjectArrayView = struct {
    element_count: u32,
    elements: []const ?FieldRef,
    truncated: bool,
};

pub const PrimitiveArrayView = struct {
    element_type: hprof.PrimitiveType,
    element_count: u32,
    values: []const FieldPrimitive,
    truncated: bool,
};

pub const ClassView = struct {
    super_class_id: hprof.Id,
    super_class_name: []const u8,
    instance_size: u32,
    static_fields: []const StaticFieldValue,
};

pub const StaticFieldValue = struct {
    name: []const u8,
    primitive: ?FieldPrimitive,
    ref: ?FieldRef,
};

pub const RefsOptions = struct {
    offset: u32 = 0,
    limit: u32 = 64,
};

pub const RootsOptions = struct {
    max_visited: u32 = 1_000_000,
};

pub const TreeOptions = struct {
    direction: []const u8 = "from",
    depth: u32 = 4,
    max_nodes: u32 = 256,
};

pub const ObjectsOptions = struct {
    offset: u32 = 0,
    limit: u32 = 100,
    reverse: bool = false,
};

// Alias so callers can open the reader via the file namespace.
pub const open = Reader.open;

pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    source_path: []const u8,
    manifest: Manifest.IndexManifest,
    id_size: u32,
    n_objects: u64,
    virtual_root_ordinal: u32,

    mapped: std.ArrayList(MappedFile),
    source: ?MappedFile,

    catalog_data: []const u8,
    out_offsets: []const u8,
    out_targets: []const u8,
    in_offsets: []const u8,
    in_sources: []const u8,
    roots_data: []const u8,

    classes_data: []const u8,
    fields_data: []const u8,

    classes: []const ClassInfo,
    layouts: []const LayoutInfo,
    class_index: std.AutoHashMap(hprof.Id, usize),
    layout_index: std.AutoHashMap(hprof.Id, usize),
    root_kinds: std.AutoHashMap(u32, u8),

    pub fn open(
        allocator: std.mem.Allocator,
        io: Io,
        index_dir: []const u8,
        source_override: ?[]const u8,
    ) !Reader {
        log.debug("IndexReader.open: index_dir={s}, source_override={?s}", .{ index_dir, source_override });

        const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
        defer allocator.free(manifest_path);

        const manifest = try Manifest.IndexManifest.parseFromFile(allocator, io, manifest_path);
        errdefer manifest.deinit(allocator);

        if (manifest.format_version != 1) {
            return error.InvalidManifest;
        }

        const source_path = source_override orelse manifest.source_path orelse return error.SourceFileNotFound;
        const source_path_owned = try allocator.dupe(u8, source_path);
        errdefer allocator.free(source_path_owned);

        const index_dir_owned = try allocator.dupe(u8, index_dir);
        errdefer allocator.free(index_dir_owned);

        var self: Reader = .{
            .allocator = allocator,
            .io = io,
            .index_dir = index_dir_owned,
            .source_path = source_path_owned,
            .manifest = manifest,
            .id_size = manifest.fingerprint.id_size,
            .n_objects = manifest.n_objects,
            .virtual_root_ordinal = manifest.virtual_root_ordinal,
            .mapped = std.ArrayList(MappedFile).empty,
            .source = null,
            .catalog_data = &.{},
            .out_offsets = &.{},
            .out_targets = &.{},
            .in_offsets = &.{},
            .in_sources = &.{},
            .roots_data = &.{},
            .classes_data = &.{},
            .fields_data = &.{},
            .classes = &.{},
            .layouts = &.{},
            .class_index = std.AutoHashMap(hprof.Id, usize).init(allocator),
            .layout_index = std.AutoHashMap(hprof.Id, usize).init(allocator),
            .root_kinds = std.AutoHashMap(u32, u8).init(allocator),
        };
        errdefer self.deinit();

        // Open and validate the source dump.
        try self.openSource();

        // Map the core CSR and catalog files.
        self.catalog_data = try self.mapFile("catalog.bin");
        self.out_offsets = try self.mapFile("out_offsets.bin");
        self.out_targets = try self.mapFile("out_targets.bin");
        self.in_offsets = try self.mapFile("in_offsets.bin");
        self.in_sources = try self.mapFile("in_sources.bin");
        self.roots_data = try self.mapFile("roots.bin");

        try self.validateSizes();

        // Load small metadata files into memory.
        self.classes_data = try self.readFile("classes.bin");
        self.fields_data = try self.readFile("fields.bin");

        try self.parseClasses();
        try self.parseFields();
        try self.parseRoots();

        log.debug("IndexReader.open complete: n_objects={d}, n_edges={d}, n_roots={d}", .{ self.n_objects, self.out_targets.len / self.id_size, self.roots_data.len / 8 });

        return self;
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.classes);
        for (self.layouts) |layout| {
            self.allocator.free(layout.fields);
            self.allocator.free(layout.reference_offsets);
        }
        self.allocator.free(self.layouts);
        self.class_index.deinit();
        self.layout_index.deinit();
        self.root_kinds.deinit();

        if (self.source) |*s| s.close(self.io);
        for (self.mapped.items) |*mf| mf.close(self.io);
        self.mapped.deinit(self.allocator);

        self.allocator.free(self.classes_data);
        self.allocator.free(self.fields_data);

        self.allocator.free(self.index_dir);
        self.allocator.free(self.source_path);
        self.manifest.deinit(self.allocator);
    }

    fn openSource(self: *Reader) !void {
        const dir = Io.Dir.cwd();
        var file = try dir.openFile(self.io, self.source_path, .{});
        errdefer file.close(self.io);

        const len = try file.length(self.io);
        if (len == 0) return error.SourceFileNotFound;
        if (len != self.manifest.fingerprint.file_length) return error.SourceFingerprintMismatch;

        const mm = try Io.File.MemoryMap.create(self.io, file, .{
            .len = len,
            .protection = .{ .read = true, .write = false },
            // The 10.6GB source dump must not be prefaulted; only the pages
            // actually touched by a query should be read.
            .populate = false,
        });
        self.source = .{ .file = file, .mm = mm };

        const header = try hprof.Header.parse(mm.memory);
        if (header.id_size != self.id_size or
            header.timestamp != self.manifest.fingerprint.hprof_timestamp)
        {
            return error.SourceFingerprintMismatch;
        }

        const fp = try Manifest.computeFingerprint(self.allocator, mm.memory, header, 0);
        defer fp.deinit(self.allocator);
        if (!fp.eql(self.manifest.fingerprint)) {
            return error.SourceFingerprintMismatch;
        }
    }

    fn mapFile(self: *Reader, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.index_dir, name });
        defer self.allocator.free(path);
        const mf = try MappedFile.open(self.io, path);
        try self.mapped.append(self.allocator, mf);
        return mf.data();
    }

    fn readFile(self: *Reader, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.index_dir, name });
        defer self.allocator.free(path);
        return try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
    }

    fn validateSizes(self: *const Reader) !void {
        if (self.catalog_data.len % Scanner.catalog_row_size != 0) return error.CorruptIndexFile;
        if (self.catalog_data.len / Scanner.catalog_row_size != self.n_objects) return error.CorruptIndexFile;

        const expected_offsets = (self.n_objects + 2) * Csr.offset_entry_size;
        if (self.out_offsets.len != expected_offsets) return error.CorruptIndexFile;
        if (self.in_offsets.len != expected_offsets) return error.CorruptIndexFile;

        if (self.out_targets.len % 4 != 0) return error.CorruptIndexFile;
        if (self.in_sources.len % 4 != 0) return error.CorruptIndexFile;

        const out_end = std.mem.readInt(u64, self.out_offsets[self.out_offsets.len - Csr.offset_entry_size ..][0..8], .little);
        if (out_end * 4 != self.out_targets.len) return error.CorruptIndexFile;
        const in_end = std.mem.readInt(u64, self.in_offsets[self.in_offsets.len - Csr.offset_entry_size ..][0..8], .little);
        if (in_end * 4 != self.in_sources.len) return error.CorruptIndexFile;

        if (self.manifest.n_edges * 4 != self.out_targets.len) return error.CorruptIndexFile;
        if (self.manifest.n_edges * 4 != self.in_sources.len) return error.CorruptIndexFile;
        if (self.roots_data.len % Csr.roots_bin_record_size != 0) return error.CorruptIndexFile;
    }

    fn parseClasses(self: *Reader) !void {
        var list = std.ArrayList(ClassInfo).empty;
        errdefer list.deinit(self.allocator);

        var offset: usize = 0;
        while (offset < self.classes_data.len) {
            if (offset + 24 > self.classes_data.len) return error.CorruptIndexFile;
            const class_id = std.mem.readInt(u64, self.classes_data[offset..][0..8], .little);
            offset += 8;
            const super_class_id = std.mem.readInt(u64, self.classes_data[offset..][0..8], .little);
            offset += 8;
            const instance_size = std.mem.readInt(u32, self.classes_data[offset..][0..4], .little);
            offset += 4;
            const name_len = std.mem.readInt(u32, self.classes_data[offset..][0..4], .little);
            offset += 4;
            if (offset + name_len > self.classes_data.len) return error.CorruptIndexFile;
            const name = self.classes_data[offset..][0..name_len];
            offset += name_len;
            try list.append(self.allocator, .{
                .class_id = class_id,
                .super_class_id = super_class_id,
                .instance_size = instance_size,
                .name = name,
            });
        }

        self.classes = try list.toOwnedSlice(self.allocator);
        for (self.classes, 0..) |info, i| {
            try self.class_index.put(info.class_id, i);
        }
    }

    fn parseFields(self: *Reader) !void {
        var list = std.ArrayList(LayoutInfo).empty;
        errdefer {
            for (list.items) |layout| {
                self.allocator.free(layout.fields);
                self.allocator.free(layout.reference_offsets);
            }
            list.deinit(self.allocator);
        }

        var offset: usize = 0;
        while (offset < self.fields_data.len) {
            if (offset + 12 > self.fields_data.len) return error.CorruptIndexFile;
            const class_id = std.mem.readInt(u64, self.fields_data[offset..][0..8], .little);
            offset += 8;
            const field_count = std.mem.readInt(u32, self.fields_data[offset..][0..4], .little);
            offset += 4;

            var fields = std.ArrayList(FieldInfo).empty;
            errdefer fields.deinit(self.allocator);
            var ref_offsets = std.ArrayList(u32).empty;
            errdefer ref_offsets.deinit(self.allocator);

            var i: usize = 0;
            while (i < field_count) : (i += 1) {
                if (offset + 2 > self.fields_data.len) return error.CorruptIndexFile;
                const name_len = std.mem.readInt(u16, self.fields_data[offset..][0..2], .little);
                offset += 2;
                if (offset + name_len + 13 > self.fields_data.len) return error.CorruptIndexFile;
                const name = self.fields_data[offset..][0..name_len];
                offset += name_len;
                const type_byte = self.fields_data[offset];
                offset += 1;
                const field_type = primitiveTypeFromInt(type_byte) orelse return error.InvalidFieldType;
                const byte_offset = std.mem.readInt(u32, self.fields_data[offset..][0..4], .little);
                offset += 4;
                const declaring_class_id = std.mem.readInt(u64, self.fields_data[offset..][0..8], .little);
                offset += 8;
                try fields.append(self.allocator, .{
                    .name = name,
                    .type = field_type,
                    .byte_offset = byte_offset,
                    .declaring_class_id = declaring_class_id,
                });
                if (field_type == .object or field_type == .array_object) {
                    try ref_offsets.append(self.allocator, byte_offset);
                }
            }

            try list.append(self.allocator, .{
                .class_id = class_id,
                .fields = try fields.toOwnedSlice(self.allocator),
                .reference_offsets = try ref_offsets.toOwnedSlice(self.allocator),
            });
        }

        self.layouts = try list.toOwnedSlice(self.allocator);
        for (self.layouts, 0..) |layout, i| {
            try self.layout_index.put(layout.class_id, i);
        }
    }

    fn parseRoots(self: *Reader) !void {
        const n = self.roots_data.len / Csr.roots_bin_record_size;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = Csr.readRootRecord(self.roots_data[i * Csr.roots_bin_record_size ..][0..Csr.roots_bin_record_size]);
            try self.root_kinds.put(rec.target_ordinal, rec.root_kind);
        }
    }

    pub fn ordinalForRawId(self: *const Reader, raw_id: hprof.Id) ?u32 {
        return CatalogSorter.ordinalForRawId(self.catalog_data, raw_id);
    }

    pub fn rawIdForOrdinal(self: *const Reader, ordinal: u32) ?hprof.Id {
        if (ordinal >= self.n_objects) return null;
        const row = self.catalogRow(ordinal);
        return row.raw_id;
    }

    pub fn catalogRow(self: *const Reader, ordinal: u32) Scanner.CatalogRow {
        const buf = self.catalog_data[ordinal * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size];
        return Scanner.readCatalogRow(buf) catch unreachable;
    }

    pub fn classInfo(self: *const Reader, class_id: hprof.Id) ?*const ClassInfo {
        const idx = self.class_index.get(class_id) orelse return null;
        return &self.classes[idx];
    }

    pub fn className(self: *const Reader, class_id: hprof.Id) []const u8 {
        if (self.classInfo(class_id)) |info| {
            if (info.name.len > 0) return info.name;
        }
        return "unknown";
    }

    pub fn layoutForClass(self: *const Reader, class_id: hprof.Id) ?*const LayoutInfo {
        const idx = self.layout_index.get(class_id) orelse return null;
        return &self.layouts[idx];
    }

    pub fn outEdges(self: *const Reader, ordinal: u32) []align(1) const u32 {
        return self.csrRange(self.out_offsets, self.out_targets, ordinal);
    }

    pub fn inEdges(self: *const Reader, ordinal: u32) []align(1) const u32 {
        return self.csrRange(self.in_offsets, self.in_sources, ordinal);
    }

    fn csrRange(self: *const Reader, offsets: []const u8, adjacency: []const u8, ordinal: u32) []align(1) const u32 {
        if (ordinal > self.n_objects) return &[_]u32{};
        const off = ordinal * Csr.offset_entry_size;
        const start = std.mem.readInt(u64, offsets[off..][0..8], .little);
        const end = std.mem.readInt(u64, offsets[off + Csr.offset_entry_size ..][0..8], .little);
        const base = start * 4;
        const len = (end - start) * 4;
        const bytes = adjacency[base .. base + len];
        return std.mem.bytesAsSlice(u32, bytes);
    }

    /// Decode the HPROF sub-record at the catalog's stored source offset.
    pub fn decodeRecordAt(self: *const Reader, offset: u64) !hprof.HeapRecord {
        const src = self.source orelse return error.SourceNotAvailable;
        const data = src.data();
        if (offset == 0 or offset > data.len) return error.InvalidSourceOffset;
        var hr = hprof.HeapDumpReader.initWithOffset(data[offset - 1 ..], self.id_size, offset - 1);
        const wo = try hr.nextWithOffset() orelse return error.InvalidSourceOffset;
        if (wo.body_offset != offset) return error.InvalidSourceOffset;
        return wo.record;
    }

    pub fn decodeObject(self: *const Reader, ordinal: u32) !ObjectView {
        if (ordinal >= self.n_objects) return error.ObjectNotFound;
        const row = self.catalogRow(ordinal);
        const class_name = self.className(row.class_raw_id);

        switch (row.kind) {
            .instance => {
                const rec = self.decodeRecordAt(row.source_offset) catch |err| {
                    if (err == error.SourceNotAvailable) return err;
                    return error.InvalidSourceOffset;
                };
                if (rec != .gc_instance_dump) return error.InvalidSourceOffset;
                const inst = rec.gc_instance_dump;
                const fields = try self.decodeInstanceFields(inst.class_id, inst.bytes);
                return .{
                    .raw_id = row.raw_id,
                    .ordinal = ordinal,
                    .class_raw_id = row.class_raw_id,
                    .class_name = class_name,
                    .shallow_size = row.shallow_size,
                    .kind = .instance,
                    .payload = .{ .instance = fields },
                };
            },
            .object_array => {
                const rec = self.decodeRecordAt(row.source_offset) catch |err| {
                    if (err == error.SourceNotAvailable) return err;
                    return error.InvalidSourceOffset;
                };
                if (rec != .gc_obj_array_dump) return error.InvalidSourceOffset;
                const arr = rec.gc_obj_array_dump;
                const view = try self.decodeObjectArray(arr);
                return .{
                    .raw_id = row.raw_id,
                    .ordinal = ordinal,
                    .class_raw_id = row.class_raw_id,
                    .class_name = class_name,
                    .shallow_size = row.shallow_size,
                    .kind = .object_array,
                    .payload = .{ .object_array = view },
                };
            },
            .primitive_array => {
                const rec = self.decodeRecordAt(row.source_offset) catch |err| {
                    if (err == error.SourceNotAvailable) return err;
                    return error.InvalidSourceOffset;
                };
                if (rec != .gc_prim_array_dump) return error.InvalidSourceOffset;
                const arr = rec.gc_prim_array_dump;
                const view = try self.decodePrimitiveArray(arr);
                return .{
                    .raw_id = row.raw_id,
                    .ordinal = ordinal,
                    .class_raw_id = row.class_raw_id,
                    .class_name = class_name,
                    .shallow_size = row.shallow_size,
                    .kind = .primitive_array,
                    .payload = .{ .primitive_array = view },
                };
            },
            .class => {
                const rec = self.decodeRecordAt(row.source_offset) catch |err| {
                    if (err == error.SourceNotAvailable) return err;
                    return error.InvalidSourceOffset;
                };
                if (rec != .gc_class_dump) return error.InvalidSourceOffset;
                const cd = rec.gc_class_dump;
                const view = try self.decodeClassDump(cd);
                return .{
                    .raw_id = row.raw_id,
                    .ordinal = ordinal,
                    .class_raw_id = row.class_raw_id,
                    .class_name = class_name,
                    .shallow_size = row.shallow_size,
                    .kind = .class,
                    .payload = .{ .class = view },
                };
            },
        }
    }

    fn decodeInstanceFields(self: *const Reader, class_id: hprof.Id, bytes: []const u8) ![]const FieldValue {
        const layout = self.layoutForClass(class_id);
        if (layout == null) {
            return &[_]FieldValue{};
        }
        const layout_ref = layout.?;
        const result = try self.allocator.alloc(FieldValue, layout_ref.fields.len);
        errdefer self.allocator.free(result);

        for (layout_ref.fields, 0..) |field, i| {
            const declared_by = if (field.declaring_class_id == class_id) null else self.className(field.declaring_class_id);
            if (field.type == .object or field.type == .array_object) {
                const target_id = readIdAt(bytes, field.byte_offset, self.id_size);
                result[i] = .{
                    .name = field.name,
                    .declared_by = declared_by,
                    .primitive = null,
                    .ref = if (target_id == 0) null else self.makeFieldRef(target_id),
                };
            } else {
                result[i] = .{
                    .name = field.name,
                    .declared_by = declared_by,
                    .primitive = self.readPrimitiveAt(bytes, field.byte_offset, field.type),
                    .ref = null,
                };
            }
        }
        return result;
    }

    fn decodeObjectArray(self: *const Reader, arr: hprof.ObjectArrayDump) !ObjectArrayView {
        const max_elements = 256;
        const count = arr.element_count;
        const out_count = @min(count, max_elements);
        const elements = try self.allocator.alloc(?FieldRef, out_count);
        errdefer self.allocator.free(elements);

        var i: u32 = 0;
        while (i < out_count) : (i += 1) {
            const id = try arr.element(i, self.id_size);
            elements[i] = if (id == 0) null else self.makeFieldRef(id);
        }
        return .{
            .element_count = count,
            .elements = elements,
            .truncated = count > max_elements,
        };
    }

    fn decodePrimitiveArray(self: *const Reader, arr: hprof.PrimitiveArrayDump) !PrimitiveArrayView {
        const max_elements = 256;
        const count = arr.element_count;
        const out_count = @min(count, max_elements);
        const values = try self.allocator.alloc(FieldPrimitive, out_count);
        errdefer self.allocator.free(values);

        var i: u32 = 0;
        while (i < out_count) : (i += 1) {
            const offset = i * arr.element_type.size(self.id_size);
            values[i] = self.readPrimitiveAt(arr.bytes, offset, arr.element_type);
        }
        return .{
            .element_type = arr.element_type,
            .element_count = count,
            .values = values,
            .truncated = count > max_elements,
        };
    }

    fn decodeClassDump(self: *const Reader, cd: hprof.ClassDump) !ClassView {
        var fields = std.ArrayList(StaticFieldValue).empty;
        errdefer fields.deinit(self.allocator);

        var it = cd.staticFieldIterator(self.id_size);
        while (try it.next()) |sf| {
            if (sf.type == .object or sf.type == .array_object) {
                const id = switch (sf.value) {
                    .object => |v| v,
                    .array_object => |v| v,
                    else => 0,
                };
                try fields.append(self.allocator, .{
                    .name = self.utf8Name(sf.name_id),
                    .primitive = null,
                    .ref = if (id == 0) null else self.makeFieldRef(id),
                });
            } else {
                try fields.append(self.allocator, .{
                    .name = self.utf8Name(sf.name_id),
                    .primitive = primitiveValue(sf.value),
                    .ref = null,
                });
            }
        }

        return .{
            .super_class_id = cd.super_class_id,
            .super_class_name = self.className(cd.super_class_id),
            .instance_size = cd.instance_size,
            .static_fields = try fields.toOwnedSlice(self.allocator),
        };
    }

    fn makeFieldRef(self: *const Reader, raw_id: hprof.Id) ?FieldRef {
        const target_ord = self.ordinalForRawId(raw_id);
        return .{
            .raw_id = raw_id,
            .ordinal = target_ord,
            .class_name = if (target_ord) |ord| blk: {
                const row = self.catalogRow(ord);
                break :blk self.className(row.class_raw_id);
            } else "unknown",
        };
    }

    fn readPrimitiveAt(self: *const Reader, bytes: []const u8, offset: u32, ty: hprof.PrimitiveType) FieldPrimitive {
        var c = hprof.Cursor.init(bytes[offset..]);
        return primitiveValue(c.readValue(ty, self.id_size) catch unreachable);
    }

    fn utf8Name(self: *const Reader, name_id: hprof.Id) []const u8 {
        // At query time we do not have the UTF8 table; fall back to the raw id.
        _ = self;
        _ = name_id;
        return "?";
    }
};

fn readIdAt(bytes: []const u8, offset: u32, id_size: u32) hprof.Id {
    var c = hprof.Cursor.init(bytes[offset..]);
    return c.readId(id_size) catch 0;
}

fn primitiveTypeFromInt(ty: u8) ?hprof.PrimitiveType {
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        if (field.value == ty) return @as(hprof.PrimitiveType, @enumFromInt(ty));
    }
    return null;
}

fn primitiveValue(v: hprof.Value) FieldPrimitive {
    return switch (v) {
        .array_object => .{ .array_object = {} },
        .object => .{ .object = {} },
        .boolean => |b| .{ .boolean = b },
        .char => |c| .{ .char = c },
        .float => |f| .{ .float = f },
        .double => |d| .{ .double = d },
        .byte => |b| .{ .byte = b },
        .short => |s| .{ .short = s },
        .int => |x| .{ .int = x },
        .long => |x| .{ .long = x },
    };
}

pub fn parseRawId(s: []const u8) !hprof.Id {
    return std.fmt.parseInt(hprof.Id, s, 0) catch return error.InvalidObjectId;
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON output helpers
// ─────────────────────────────────────────────────────────────────────────────

fn writeId(writer: *Io.Writer, id: hprof.Id) !void {
    try writer.print("\"0x{x:0>16}\"", .{id});
}

fn writeRawIdOrNull(writer: *Io.Writer, id: hprof.Id) !void {
    if (id == 0) {
        try writer.writeAll("null");
    } else {
        try writeId(writer, id);
    }
}

fn writeJsonString(writer: *Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 32) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

fn writeOptionalStringField(writer: *Io.Writer, name: []const u8, value: ?[]const u8) !void {
    if (value) |v| {
        try writer.print(",\"{s}\":", .{name});
        try writeJsonString(writer, v);
    }
}

fn writeFieldPrimitive(writer: *Io.Writer, p: FieldPrimitive) !void {
    switch (p) {
        .boolean => |b| try writer.print("{}", .{b}),
        .char => |c| try writer.print("{d}", .{c}),
        .float => |f| try writer.print("{d}", .{f}),
        .double => |d| try writer.print("{d}", .{d}),
        .byte => |b| try writer.print("{d}", .{b}),
        .short => |s| try writer.print("{d}", .{s}),
        .int => |x| try writer.print("{d}", .{x}),
        .long => |x| try writer.print("{d}", .{x}),
        .array_object, .object => try writer.writeAll("null"),
    }
}

fn writeFieldRef(writer: *Io.Writer, ref: ?FieldRef) !void {
    if (ref) |r| {
        try writer.writeAll("{\"id\":");
        try writeId(writer, r.raw_id);
        try writer.writeAll(",\"ordinal\":");
        if (r.ordinal) |ord| {
            try writer.print("{d}", .{ord});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"class\":");
        try writeJsonString(writer, r.class_name);
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeObjectView(writer: *Io.Writer, view: ObjectView) !void {
    try writeObjectViewContent(writer, view);
    try writer.writeByte('\n');
}

fn writeObjectViewContent(writer: *Io.Writer, view: ObjectView) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"id\":");
    try writeId(writer, view.raw_id);
    try writer.print(",\"ordinal\":{d}", .{view.ordinal});
    try writer.writeAll(",\"class\":");
    try writeJsonString(writer, view.class_name);
    try writer.print(",\"shallow_bytes\":{d}", .{view.shallow_size});

    switch (view.payload) {
        .instance => |fields| {
            try writer.writeAll(",\"fields\":[");
            for (fields, 0..) |field, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeAll("{");
                try writer.writeAll("\"name\":");
                try writeJsonString(writer, field.name);
                try writeOptionalStringField(writer, "declared_by", field.declared_by);
                if (field.ref) |r| {
                    try writer.writeAll(",\"ref\":");
                    try writeId(writer, r.raw_id);
                    try writer.writeAll(",\"ordinal\":");
                    if (r.ordinal) |ord| {
                        try writer.print("{d}", .{ord});
                    } else {
                        try writer.writeAll("null");
                    }
                    try writer.writeAll(",\"class\":");
                    try writeJsonString(writer, r.class_name);
                } else if (field.primitive) |p| {
                    try writer.writeAll(",\"value\":");
                    try writeFieldPrimitive(writer, p);
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]");
        },
        .object_array => |arr| {
            try writer.print(",\"element_count\":{d}", .{arr.element_count});
            try writer.writeAll(",\"elements\":[");
            for (arr.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeByte(',');
                try writeFieldRef(writer, elem);
            }
            try writer.writeAll("]");
            if (arr.truncated) {
                try writer.writeAll(",\"truncated\":true");
            }
        },
        .primitive_array => |arr| {
            try writer.writeAll(",\"element_type\":");
            try writeJsonString(writer, @tagName(arr.element_type));
            try writer.print(",\"element_count\":{d}", .{arr.element_count});
            try writer.writeAll(",\"values\":[");
            for (arr.values, 0..) |v, i| {
                if (i > 0) try writer.writeByte(',');
                try writeFieldPrimitive(writer, v);
            }
            try writer.writeAll("]");
            if (arr.truncated) {
                try writer.writeAll(",\"truncated\":true");
            }
        },
        .class => |cv| {
            try writer.writeAll(",\"super_class\":");
            try writeRawIdOrNull(writer, cv.super_class_id);
            try writer.print(",\"instance_size\":{d}", .{cv.instance_size});
            try writer.writeAll(",\"static_fields\":[");
            for (cv.static_fields, 0..) |sf, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeAll("{");
                try writer.writeAll("\"name\":");
                try writeJsonString(writer, sf.name);
                if (sf.ref) |r| {
                    try writer.writeAll(",\"ref\":");
                    try writeId(writer, r.raw_id);
                    try writer.writeAll(",\"ordinal\":");
                    if (r.ordinal) |ord| {
                        try writer.print("{d}", .{ord});
                    } else {
                        try writer.writeAll("null");
                    }
                    try writer.writeAll(",\"class\":");
                    try writeJsonString(writer, r.class_name);
                } else if (sf.primitive) |p| {
                    try writer.writeAll(",\"value\":");
                    try writeFieldPrimitive(writer, p);
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("]");
        },
    }
    try writer.writeAll("}");
}

// ─────────────────────────────────────────────────────────────────────────────
// Command implementations
// ─────────────────────────────────────────────────────────────────────────────

fn validateRefsOptions(opts: RefsOptions) !void {
    if (opts.limit > 1024) return error.LimitTooLarge;
}

fn writeRefsHeader(writer: *Io.Writer, raw_id: hprof.Id, direction: []const u8) !void {
    try writer.writeAll("{\"object\":");
    try writeId(writer, raw_id);
    try writer.print(",\"direction\":\"{s}\",\"items\":[", .{direction});
}

fn classNameForOrdinal(self: *const Reader, ordinal: u32) []const u8 {
    if (ordinal == self.virtual_root_ordinal) return "virtual root";
    const row = self.catalogRow(ordinal);
    return self.className(row.class_raw_id);
}

fn writeRelationLabel(
    self: *const Reader,
    writer: *Io.Writer,
    source_ordinal: u32,
    target_raw_id: hprof.Id,
) !void {
    if (source_ordinal == self.virtual_root_ordinal) {
        if (self.ordinalForRawId(target_raw_id)) |target_ord| {
            if (self.root_kinds.get(target_ord)) |kind| {
                try writer.writeByte('"');
                try writeRootKindName(writer, kind);
                try writer.writeByte('"');
                return;
            }
        }
        try writer.writeAll("\"root\"");
        return;
    }
    if (source_ordinal >= self.n_objects) {
        try writer.writeAll("\"?\"");
        return;
    }
    const row = self.catalogRow(source_ordinal);
    switch (row.kind) {
        .instance => {
            const rec = self.decodeRecordAt(row.source_offset) catch {
                try writer.writeAll("\"?\"");
                return;
            };
            if (rec != .gc_instance_dump) {
                try writer.writeAll("\"?\"");
                return;
            }
            const inst = rec.gc_instance_dump;
            const layout = self.layoutForClass(inst.class_id);
            if (layout == null) {
                try writer.writeAll("\"?\"");
                return;
            }
            for (layout.?.fields) |field| {
                if (field.type == .object or field.type == .array_object) {
                    const id = readIdAt(inst.bytes, field.byte_offset, self.id_size);
                    if (id == target_raw_id) {
                        try writeJsonString(writer, field.name);
                        return;
                    }
                }
            }
            try writer.writeAll("\"?\"");
        },
        .object_array => {
            const rec = self.decodeRecordAt(row.source_offset) catch {
                try writer.writeAll("\"?\"");
                return;
            };
            if (rec != .gc_obj_array_dump) {
                try writer.writeAll("\"?\"");
                return;
            }
            const arr = rec.gc_obj_array_dump;
            var i: u32 = 0;
            while (i < arr.element_count) : (i += 1) {
                const id = arr.element(i, self.id_size) catch break;
                if (id == target_raw_id) {
                    try writer.print("\"[{d}]\"", .{i});
                    return;
                }
            }
            try writer.writeAll("\"?\"");
        },
        .class => {
            const rec = self.decodeRecordAt(row.source_offset) catch {
                try writer.writeAll("\"?\"");
                return;
            };
            if (rec != .gc_class_dump) {
                try writer.writeAll("\"?\"");
                return;
            }
            const cd = rec.gc_class_dump;
            var it = cd.staticFieldIterator(self.id_size);
            while (try it.next()) |sf| {
                if (sf.type == .object or sf.type == .array_object) {
                    const id = switch (sf.value) {
                        .object => |v| v,
                        .array_object => |v| v,
                        else => 0,
                    };
                    if (id == target_raw_id) {
                        try writeJsonString(writer, self.utf8Name(sf.name_id));
                        return;
                    }
                }
            }
            try writer.writeAll("\"?\"");
        },
        .primitive_array => try writer.writeAll("\"?\""),
    }
}

pub fn writeRefsFrom(
    self: *const Reader,
    writer: *Io.Writer,
    raw_id: hprof.Id,
    opts: RefsOptions,
) !void {
    try validateRefsOptions(opts);
    const ordinal = self.ordinalForRawId(raw_id) orelse return error.ObjectNotFound;
    const edges = self.outEdges(ordinal);

    try writeRefsHeader(writer, raw_id, "outbound");

    var i: usize = opts.offset;
    const end = @min(edges.len, @as(usize, opts.offset) + opts.limit);
    while (i < end) : (i += 1) {
        if (i > opts.offset) try writer.writeByte(',');
        const target_ord = edges[i];
        const target_id = self.rawIdForOrdinal(target_ord) orelse 0;
        try writer.writeAll("{\"id\":");
        try writeId(writer, target_id);
        try writer.print(",\"ordinal\":{d},\"class\":", .{target_ord});
        try writeJsonString(writer, classNameForOrdinal(self, target_ord));
        try writer.writeAll(",\"relation\":");
        try writeRelationLabel(self, writer, ordinal, target_id);
        try writer.writeAll("}");
    }

    const next_offset: ?u32 = if (end < edges.len) @intCast(end) else null;
    try writer.writeAll("],\"next_offset\":");
    if (next_offset) |no| {
        try writer.print("{d}}}", .{no});
    } else {
        try writer.writeAll("null}\n");
    }
}

pub fn writeRefsTo(
    self: *const Reader,
    writer: *Io.Writer,
    raw_id: hprof.Id,
    opts: RefsOptions,
) !void {
    try validateRefsOptions(opts);
    const ordinal = self.ordinalForRawId(raw_id) orelse return error.ObjectNotFound;
    const edges = self.inEdges(ordinal);

    try writeRefsHeader(writer, raw_id, "inbound");

    var i: usize = opts.offset;
    const end = @min(edges.len, @as(usize, opts.offset) + opts.limit);
    while (i < end) : (i += 1) {
        if (i > opts.offset) try writer.writeByte(',');
        const source_ord = edges[i];
        const source_id = self.rawIdForOrdinal(source_ord) orelse 0;
        try writer.writeAll("{\"id\":");
        try writeId(writer, source_id);
        try writer.print(",\"ordinal\":{d},\"class\":", .{source_ord});
        try writeJsonString(writer, classNameForOrdinal(self, source_ord));
        try writer.writeAll(",\"relation\":");
        try writeRelationLabel(self, writer, source_ord, raw_id);
        try writer.writeAll("}");
    }

    const next_offset: ?u32 = if (end < edges.len) @intCast(end) else null;
    try writer.writeAll("],\"next_offset\":");
    if (next_offset) |no| {
        try writer.print("{d}}}", .{no});
    } else {
        try writer.writeAll("null}\n");
    }
}

pub fn writeRoots(
    self: *const Reader,
    writer: *Io.Writer,
    raw_id: hprof.Id,
    opts: RootsOptions,
) !void {
    const ordinal = self.ordinalForRawId(raw_id) orelse return error.ObjectNotFound;

    var queue = std.ArrayList(u32).empty;
    defer queue.deinit(self.allocator);
    var pred = std.AutoHashMap(u32, u32).init(self.allocator);
    defer pred.deinit();
    var visited = std.AutoHashMap(u32, void).init(self.allocator);
    defer visited.deinit();

    try queue.append(self.allocator, ordinal);
    try visited.put(ordinal, {});
    var visited_count: usize = 0;
    var found = false;
    var truncated = false;

    while (queue.items.len > 0) {
        const ord = queue.orderedRemove(0);
        visited_count += 1;
        if (visited_count > opts.max_visited) {
            truncated = true;
            break;
        }
        if (ord == self.virtual_root_ordinal) {
            found = true;
            break;
        }
        const sources = self.inEdges(ord);
        for (sources) |src| {
            if (!visited.contains(src)) {
                try visited.put(src, {});
                try pred.put(src, ord);
                try queue.append(self.allocator, src);
            }
        }
    }

    try writer.writeAll("{\"object\":");
    try writeId(writer, raw_id);
    try writer.print(",\"ordinal\":{d},\"found\":{},\"truncated\":{},\"path\":[", .{
        ordinal,
        found,
        truncated,
    });

    if (found) {
        // Reconstruct path from virtual root back to the target.
        var path = std.ArrayList(u32).empty;
        defer path.deinit(self.allocator);
        var cur = self.virtual_root_ordinal;
        try path.append(self.allocator, cur);
        while (cur != ordinal) {
            const next = pred.get(cur) orelse break;
            try path.append(self.allocator, next);
            cur = next;
        }

        for (path.items, 0..) |ord, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            if (ord == self.virtual_root_ordinal) {
                try writer.writeAll("null");
                try writer.print(",\"ordinal\":{d},\"class\":\"virtual root\"}}", .{ord});
            } else {
                const id = self.rawIdForOrdinal(ord) orelse 0;
                try writeId(writer, id);
                try writer.print(",\"ordinal\":{d},\"class\":", .{ord});
                try writeJsonString(writer, classNameForOrdinal(self, ord));
                try writer.writeAll("}");
            }
        }
    }

    try writer.writeAll("]}\n");
}

pub fn writeTree(
    self: *const Reader,
    writer: *Io.Writer,
    raw_id: hprof.Id,
    opts: TreeOptions,
) !void {
    const direction = std.mem.eql(u8, opts.direction, "from");
    const reverse = std.mem.eql(u8, opts.direction, "to");
    if (!direction and !reverse) return error.InvalidDirection;

    const ordinal = self.ordinalForRawId(raw_id) orelse return error.ObjectNotFound;
    var nodes_used: u32 = 0;
    var path = std.AutoHashMap(u32, void).init(self.allocator);
    defer path.deinit();
    var emitted = std.AutoHashMap(u32, void).init(self.allocator);
    defer emitted.deinit();

    try writer.writeAll("{\"root\":");
    try writeTreeNode(self, writer, ordinal, 0, opts.depth, direction, &path, &emitted, &nodes_used, opts.max_nodes);
    try writer.writeAll(",\"nodes_used\":");
    try writer.print("{d}}}", .{nodes_used});
    try writer.writeByte('\n');
}

fn matchingClassIds(self: *const Reader, pattern: []const u8) !std.AutoHashMap(hprof.Id, void) {
    var set = std.AutoHashMap(hprof.Id, void).init(self.allocator);
    errdefer set.deinit();
    // Accept Java-style dotted class names in addition to the JVM internal
    // slashed form the index actually stores. See Regex.normalizeForClassName.
    const normalized = try Regex.normalizeForClassName(self.allocator, pattern);
    defer self.allocator.free(normalized);
    for (self.classes) |info| {
        if (Regex.matches(normalized, info.name)) {
            try set.put(info.class_id, {});
        }
    }
    return set;
}

pub fn writeObjectsList(
    self: *const Reader,
    writer: *Io.Writer,
    pattern: []const u8,
    opts: ObjectsOptions,
) !void {
    const limit = opts.limit;
    var matches = try matchingClassIds(self, pattern);
    defer matches.deinit();

    try writer.writeAll("{\"pattern\":");
    try writeJsonString(writer, pattern);
    try writer.print(",\"limit\":{d},\"offset\":{d},\"reverse\":{}", .{ limit, opts.offset, opts.reverse });
    try writer.writeAll(",\"items\":[");

    var skipped: u32 = 0;
    var emitted: u32 = 0;
    var has_more = false;

    if (self.n_objects > 0) {
        const n: i64 = @intCast(self.n_objects);
        var ord: i64 = if (opts.reverse) n - 1 else 0;
        const end: i64 = if (opts.reverse) -1 else n;
        const step: i64 = if (opts.reverse) -1 else 1;

        while (ord != end) : (ord += step) {
            const ordinal: u32 = @intCast(ord);
            const row = self.catalogRow(ordinal);
            if (!matches.contains(row.class_raw_id)) continue;

            if (skipped < opts.offset) {
                skipped += 1;
                continue;
            }

            if (emitted < limit) {
                if (emitted > 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try writeId(writer, row.raw_id);
                try writer.print(",\"ordinal\":{d},\"class\":", .{ordinal});
                try writeJsonString(writer, self.className(row.class_raw_id));
                try writer.print(",\"kind\":\"{s}\",\"shallow_bytes\":{d}", .{ @tagName(row.kind), row.shallow_size });
                try writer.writeAll("}");
                emitted += 1;
            } else {
                has_more = true;
                break;
            }
        }
    }

    try writer.writeAll("],\"next_offset\":");
    if (has_more) {
        try writer.print("{d}", .{opts.offset + limit});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

pub fn writeSampleList(
    self: *const Reader,
    writer: *Io.Writer,
    pattern: []const u8,
    opts: ObjectsOptions,
) !void {
    const limit = opts.limit;
    var matches = try matchingClassIds(self, pattern);
    defer matches.deinit();

    try writer.writeAll("{\"pattern\":");
    try writeJsonString(writer, pattern);
    try writer.print(",\"limit\":{d},\"offset\":{d},\"reverse\":{}", .{ limit, opts.offset, opts.reverse });
    try writer.writeAll(",\"items\":[");

    var skipped: u32 = 0;
    var emitted: u32 = 0;
    var has_more = false;

    if (self.n_objects > 0) {
        const n: i64 = @intCast(self.n_objects);
        var ord: i64 = if (opts.reverse) n - 1 else 0;
        const end: i64 = if (opts.reverse) -1 else n;
        const step: i64 = if (opts.reverse) -1 else 1;

        while (ord != end) : (ord += step) {
            const ordinal: u32 = @intCast(ord);
            const row = self.catalogRow(ordinal);
            if (!matches.contains(row.class_raw_id)) continue;

            if (skipped < opts.offset) {
                skipped += 1;
                continue;
            }

            if (emitted < limit) {
                if (emitted > 0) try writer.writeByte(',');
                var view = try self.decodeObject(ordinal);
                defer view.deinit(self.allocator);
                try writeObjectViewContent(writer, view);
                emitted += 1;
            } else {
                has_more = true;
                break;
            }
        }
    }

    try writer.writeAll("],\"next_offset\":");
    if (has_more) {
        try writer.print("{d}", .{opts.offset + limit});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

fn writeTreeNode(
    self: *const Reader,
    writer: *Io.Writer,
    ordinal: u32,
    depth: u32,
    max_depth: u32,
    forward: bool,
    path: *std.AutoHashMap(u32, void),
    emitted: *std.AutoHashMap(u32, void),
    nodes_used: *u32,
    max_nodes: u32,
) !void {
    const is_cycle = path.contains(ordinal);
    const is_repeat = !is_cycle and emitted.contains(ordinal);
    const is_virtual = ordinal == self.virtual_root_ordinal;

    try writer.writeAll("{\"id\":");
    if (is_virtual) {
        try writer.writeAll("null");
    } else {
        const id = self.rawIdForOrdinal(ordinal) orelse 0;
        try writeId(writer, id);
    }
    try writer.print(",\"ordinal\":{d},\"class\":", .{ordinal});
    try writeJsonString(writer, classNameForOrdinal(self, ordinal));

    if (is_cycle) {
        try writer.writeAll(",\"marker\":\"cycle\"}");
        return;
    }
    if (is_repeat) {
        try writer.writeAll(",\"marker\":\"repeat\"}");
        return;
    }

    nodes_used.* += 1;
    try emitted.put(ordinal, {});

    const children = if (forward) self.outEdges(ordinal) else self.inEdges(ordinal);
    const can_expand = depth < max_depth and nodes_used.* < max_nodes and children.len > 0;

    try writer.writeAll(",\"children\":[");
    if (can_expand) {
        try path.put(ordinal, {});
        for (children, 0..) |child, i| {
            if (i > 0) try writer.writeByte(',');
            if (nodes_used.* >= max_nodes) {
                try writer.writeAll("{\"marker\":\"truncated\"}");
                break;
            }
            try writeTreeNode(self, writer, child, depth + 1, max_depth, forward, path, emitted, nodes_used, max_nodes);
        }
        _ = path.remove(ordinal);
    }
    try writer.writeAll("]}");
}

fn writeRootKindName(writer: *Io.Writer, kind: u8) !void {
    switch (kind) {
        @intFromEnum(hprof.HeapSubtag.gc_root_unknown) => try writer.writeAll("unknown"),
        @intFromEnum(hprof.HeapSubtag.gc_root_jni_global) => try writer.writeAll("jni_global"),
        @intFromEnum(hprof.HeapSubtag.gc_root_jni_local) => try writer.writeAll("jni_local"),
        @intFromEnum(hprof.HeapSubtag.gc_root_java_frame) => try writer.writeAll("java_frame"),
        @intFromEnum(hprof.HeapSubtag.gc_root_native_stack) => try writer.writeAll("native_stack"),
        @intFromEnum(hprof.HeapSubtag.gc_root_sticky_class) => try writer.writeAll("sticky_class"),
        @intFromEnum(hprof.HeapSubtag.gc_root_thread_block) => try writer.writeAll("thread_block"),
        @intFromEnum(hprof.HeapSubtag.gc_root_monitor_used) => try writer.writeAll("monitor_used"),
        @intFromEnum(hprof.HeapSubtag.gc_root_thread_object) => try writer.writeAll("thread_object"),
        else => try writer.writeAll("root"),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "parse raw id accepts hex and decimal" {
    try std.testing.expectEqual(@as(hprof.Id, 0x1234), try parseRawId("0x1234"));
    try std.testing.expectEqual(@as(hprof.Id, 4660), try parseRawId("4660"));
}
