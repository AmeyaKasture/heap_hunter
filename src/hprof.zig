//! HPROF 1.0.2 heap dump parser.

pub const Types = @import("hprof/Types.zig");
pub const Header = @import("hprof/Header.zig");

const ReaderModule = @import("hprof/Reader.zig");
pub const Reader = ReaderModule.Reader;

const RecordModule = @import("hprof/Record.zig");
pub const Record = RecordModule.Record;
pub const Frame = RecordModule.Frame;
pub const Trace = RecordModule.Trace;

const HeapDumpModule = @import("hprof/HeapDump.zig");
pub const HeapDumpReader = HeapDumpModule.Reader;
pub const HeapRecord = HeapDumpModule.HeapRecord;
pub const ClassDump = HeapDumpModule.ClassDump;
pub const InstanceDump = HeapDumpModule.InstanceDump;
pub const ObjectArrayDump = HeapDumpModule.ObjectArrayDump;
pub const PrimitiveArrayDump = HeapDumpModule.PrimitiveArrayDump;

pub const Id = Types.Id;
pub const Error = Types.Error;
pub const RecordTag = Types.RecordTag;
pub const HeapSubtag = Types.HeapSubtag;
pub const PrimitiveType = Types.PrimitiveType;
pub const Value = Types.Value;
pub const Cursor = Types.Cursor;
pub const readPrimitiveType = Types.readPrimitiveType;
