//! CLI styling, help generation, and argument-parsing helpers for hunt.
const std = @import("std");
const Io = std.Io;

const Style = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";

    pub const black = "\x1b[30m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";

    pub const bright_black = "\x1b[90m";
    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_magenta = "\x1b[95m";
    pub const bright_cyan = "\x1b[96m";
    pub const bright_white = "\x1b[97m";
};

/// Returns true if stderr is connected to a terminal. Used to decide whether
/// to render the animated progress bar or plain checkpoint lines.
pub fn isStderrTty(io: Io) bool {
    const file = Io.File.stderr();
    return file.isTty(io) catch false;
}

/// Returns whether colored output is enabled. Colors are kept disabled for
/// agent-friendly plain-text output.
pub fn colorsEnabled() bool {
    return false;
}

/// Returns true for errors that are caused by user input or environment
/// problems and have already been explained to the user. These should result
/// in a clean non-zero exit rather than a stack trace.
pub fn isUserError(err: anyerror) bool {
    return err == error.InvalidArgument or
        err == error.UnknownCommand or
        err == error.ObjectNotFound or
        err == error.EmptyFile or
        err == error.FileNotFound or
        err == error.NotDir or
        err == error.IsDir or
        err == error.AccessDenied or
        err == error.TooManyObjects or
        err == error.SourceFingerprintMismatch or
        err == error.CacheMissing or
        err == error.CacheCorrupt or
        err == error.CacheVersionMismatch or
        err == error.CacheFingerprintMismatch;
}

fn writeStyled(writer: *Io.Writer, comptime color: []const u8, text: []const u8) !void {
    _ = color;
    try writer.writeAll(text);
}

fn printStyled(writer: *Io.Writer, comptime color: []const u8, comptime fmt: []const u8, args: anytype) !void {
    _ = color;
    try writer.print(fmt, args);
}

pub fn printMissingConfig(writer: *Io.Writer, candidates: []const []const u8, explicit_path: ?[]const u8) !void {
    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold ++ Style.red, "error");
    try writer.writeAll(": no configuration file found\n\n");

    if (explicit_path) |p| {
        try writer.writeAll("The config file specified with ");
        try writeStyled(writer, Style.yellow, "--config");
        try writer.print(" does not exist:\n  {s}\n\n", .{p});
    } else if (candidates.len > 0) {
        try writer.writeAll("Searched the following default locations:\n");
        for (candidates) |c| {
            try writer.writeAll("  ");
            try writeStyled(writer, Style.dim, c);
            try writer.writeAll("\n");
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("Create a config file with the following contents:\n\n");
    try writeStyled(writer, Style.cyan, "config.json\n");
    try writer.writeAll("{\n");
    try writer.writeAll("  \"index-dir\": \"/path/to/hunt/indexes\",\n");
    try writer.writeAll("  \"sorting-budget-mb\": 4096\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("For ");
    try writeStyled(writer, Style.cyan, "index");
    try writer.writeAll(" and ");
    try writeStyled(writer, Style.cyan, "overview");
    try writer.writeAll(" commands, ");
    try writeStyled(writer, Style.yellow, "index-dir");
    try writer.writeAll(" is treated as a base directory:\n");
    try writer.writeAll("  <index-dir>/<stem>.idx/\n\n");

    try writer.writeAll("For query commands, ");
    try writeStyled(writer, Style.yellow, "index-dir");
    try writer.writeAll(" is used as the literal index directory.\n\n");

    try writer.writeAll("Alternatively, pass ");
    try writeStyled(writer, Style.yellow, "--index-dir <dir>");
    try writer.writeAll(" directly.\n");
}

pub fn writeSpaces(writer: *Io.Writer, n: usize) !void {
    var remaining = n;
    const spaces: []const u8 = "                              ";
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try writer.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}

pub fn printError(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writeStyled(writer, Style.bold ++ Style.red, "error");
    try writer.writeAll(": ");
    try writer.print(fmt, args);
    try writer.writeAll("\n");
}

pub fn printWarning(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writeStyled(writer, Style.bold ++ Style.yellow, "warning");
    try writer.writeAll(": ");
    try writer.print(fmt, args);
    try writer.writeAll("\n");
}

pub fn printSuccess(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writeStyled(writer, Style.bold ++ Style.green, "done");
    try writer.writeAll(": ");
    try writer.print(fmt, args);
    try writer.writeAll("\n");
}

pub fn printInfo(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writeStyled(writer, Style.bold ++ Style.cyan, "info");
    try writer.writeAll(": ");
    try writer.print(fmt, args);
    try writer.writeAll("\n");
}

pub fn printHeading(writer: *Io.Writer, text: []const u8) !void {
    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold ++ Style.cyan, text);
    try writer.writeAll("\n");
}

pub fn printSubHeading(writer: *Io.Writer, text: []const u8) !void {
    try writeStyled(writer, Style.bold, text);
    try writer.writeAll("\n");
}

pub const Option = struct {
    flags: []const u8,
    argument: ?[]const u8,
    description: []const u8,
    /// Optional default value shown in help.
    default_value: ?[]const u8 = null,
    /// Optional example value shown after the description.
    example: ?[]const u8 = null,
};

pub const ExitCode = struct {
    code: u8,
    description: []const u8,
};

pub const Command = struct {
    name: []const u8,
    /// Short one-line description shown in global help and command listings.
    description: []const u8,
    /// Longer description shown in per-command help.
    long_description: []const u8 = "",
    usage: []const u8,
    options: []const Option = &.{},
    examples: []const []const u8 = &.{},
    exit_codes: []const ExitCode = &.{},
    /// Names of related commands, without the "hunt" prefix.
    see_also: []const []const u8 = &.{},
    /// Optional notes shown at the bottom of per-command help.
    notes: []const u8 = "",
};

pub const commands = [_]Command{
    .{
        .name = "index",
        .description = "Build a persistent heap-graph index from an HPROF dump.",
        .long_description =
            "Reads a Java HPROF heap dump and builds a persistent on-disk index " ++
            "consisting of a sorted object catalog, class metadata, field layouts, " ++
            "and a bidirectional reference graph. Once built, the index can be " ++
            "queried with objects, sample, object, refs-from, refs-to, roots, and tree. " ++
            "If an up-to-date index already exists for the same dump, the command " ++
            "reports reuse instead of rebuilding.",
        .usage = "hunt index <file.hprof> [options]",
        .options = &.{
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory where the index will be written. Defaults to the config value, or <base>/<stem>.idx/ when the config is a base directory." },
            .{ .flags = "--sorting-budget-mb", .argument = "<n>", .description = "Memory budget in megabytes for external sorting.", .default_value = "4096" },
            .{ .flags = "--force", .argument = null, .description = "Rebuild the index even if a matching index already exists." },
            .{ .flags = "--no-progress", .argument = null, .description = "Suppress the progress spinner and checkpoint output." },
        },
        .examples = &.{
            "hunt index heap.hprof --index-dir ./idx",
            "hunt index heap.hprof --index-dir ./idx --force --sorting-budget-mb 1024",
            "hunt --config ~/.config/hunt/config.json index heap.hprof",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Index built or reused successfully." },
            .{ .code = 1, .description = "Invalid argument, missing file, or missing index directory." },
        },
        .see_also = &.{"overview", "objects", "refs-from"},
        .notes = "Large dumps may take several minutes. Progress is shown on stderr.",
    },
    .{
        .name = "overview",
        .description = "Build a cached overview file from an HPROF dump for fast summary queries.",
        .long_description =
            "Scans the HPROF dump once and builds a small binary overview cache " ++
            "(overview.bin) containing header information, a class histogram, and the " ++
            "loaded classes list. This cache is used by info, histogram, and classes.",
        .usage = "hunt overview <file.hprof> [options]",
        .options = &.{
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory where the overview cache will be written. Defaults to the config value, or <base>/<stem>.idx/ when the config is a base directory." },
            .{ .flags = "--force", .argument = null, .description = "Overwrite the existing overview cache if it exists." },
            .{ .flags = "--no-progress", .argument = null, .description = "Suppress the progress spinner and checkpoint output." },
        },
        .examples = &.{
            "hunt overview heap.hprof --index-dir ./idx",
            "hunt overview heap.hprof --index-dir ./idx --force",
            "hunt --config ~/.config/hunt/config.json overview heap.hprof",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Overview cache built successfully." },
            .{ .code = 1, .description = "Invalid argument, missing file, or cache already exists." },
        },
        .see_also = &.{"index", "info", "histogram"},
    },
    .{
        .name = "info",
        .description = "Show HPROF header and a high-level summary of the dump.",
        .long_description =
            "Prints the HPROF header (id size and timestamp) and a high-level " ++
            "summary including total objects, arrays, classes, classloaders, " ++
            "and total heap bytes. Requires the overview cache produced by overview.",
        .usage = "hunt info [file.hprof] [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the overview cache. Overrides the derived/default index directory." },
        },
        .examples = &.{
            "hunt info heapdump.hprof",
            "hunt info --index-dir ./idx",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Summary printed successfully." },
            .{ .code = 1, .description = "Invalid argument or missing overview cache." },
        },
        .see_also = &.{"overview", "histogram", "classes"},
    },
    .{
        .name = "histogram",
        .description = "Print a class-level histogram of instance counts and shallow heap.",
        .long_description =
            "Lists classes ordered by total shallow heap size. By default the output " ++
            "is CSV; use --view for a human-readable table. Output can be filtered " ++
            "and sorted to focus on specific packages or large instance counts.",
        .usage = "hunt histogram [file.hprof] [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the overview cache. Overrides the derived/default index directory." },
            .{ .flags = "-l, --limit", .argument = "<n>", .description = "Limit output to the top N rows.", .default_value = "15" },
            .{ .flags = "--view", .argument = null, .description = "Render a human-readable table instead of CSV." },
            .{ .flags = "-s, --sort-instances", .argument = null, .description = "Sort by instance count descending instead of shallow bytes." },
            .{ .flags = "--match", .argument = "<regex>", .description = "Include only class names matching the regex.", .example = "--match 'java\\.lang\\.String'" },
            .{ .flags = "--exclude", .argument = "<regex>", .description = "Omit class names matching the regex.", .example = "--exclude 'java\\.util\\..*'" },
            .{ .flags = "--min-bytes", .argument = "<n>", .description = "Include only rows with at least n shallow bytes." },
            .{ .flags = "--min-instances", .argument = "<n>", .description = "Include only rows with at least n instances." },
        },
        .examples = &.{
            "hunt histogram heapdump.hprof",
            "hunt histogram heapdump.hprof --view --match 'java.lang.String' -l 20",
            "hunt histogram --index-dir ./idx",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Histogram printed successfully." },
            .{ .code = 1, .description = "Invalid argument, bad regex, or missing overview cache." },
        },
        .see_also = &.{"classes", "objects", "info"},
    },
    .{
        .name = "classes",
        .description = "List loaded classes with names, superclasses, and instance sizes.",
        .long_description =
            "Lists loaded classes with their names, superclass names, and instance " ++
            "sizes. By default the output is CSV; use --view for a table. Regex " ++
            "filters can include or exclude packages.",
        .usage = "hunt classes [file.hprof] [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the overview cache. Overrides the derived/default index directory." },
            .{ .flags = "-l, --limit", .argument = "<n>", .description = "Limit output to the top N rows.", .default_value = "15" },
            .{ .flags = "--view", .argument = null, .description = "Render a human-readable table instead of CSV." },
            .{ .flags = "--match", .argument = "<regex>", .description = "Include only class names matching the regex." },
            .{ .flags = "--exclude", .argument = "<regex>", .description = "Omit class names matching the regex." },
            .{ .flags = "--min-instance-size", .argument = "<n>", .description = "Include only classes with at least n bytes per instance." },
        },
        .examples = &.{
            "hunt classes heapdump.hprof --view",
            "hunt classes heapdump.hprof --match 'com\\.example\\.' -l 50",
            "hunt classes --index-dir ./idx --view",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Class list printed successfully." },
            .{ .code = 1, .description = "Invalid argument, bad regex, or missing overview cache." },
        },
        .see_also = &.{"histogram", "objects"},
    },
    // NOTE: threads command is disabled until thread details are persisted in the index.
    // .{
    //     .name = "threads",
    //     .description = "List threads with IDs, names, and group information.",
    //     .long_description =
    //         "Lists threads discovered from the heap dump, including thread names, " ++
    //         "states, priorities, daemon flags, and stack frames. Requires the " ++
    //         "overview cache produced by overview.",
    //     .usage = "hunt threads [file.hprof] [options]",
    //     .options = &.{
    //         .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
    //         .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the overview cache. Overrides the derived/default index directory." },
    //     },
    //     .examples = &.{
    //         "hunt threads heapdump.hprof",
    //         "hunt threads --index-dir ./idx",
    //     },
    //     .exit_codes = &.{
    //         .{ .code = 0, .description = "Thread list printed successfully." },
    //         .{ .code = 1, .description = "Invalid argument or missing overview cache." },
    //     },
    //     .see_also = &.{"overview", "info"},
    // },
    .{
        .name = "objects",
        .description = "List object IDs whose class name matches a regex.",
        .long_description =
            "Queries the persistent index for objects whose class name matches the " ++
            "given regular expression and prints their raw object IDs as JSON. Use " ++
            "this to discover object IDs before decoding them with object or sample. " ++
            "Both Java dotted form (e.g. 'com\\.example\\.Foo') and JVM internal form " ++
            "(e.g. 'com/example/Foo') are accepted.",
        .usage = "hunt objects [file.hprof] <class-regex> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
            .{ .flags = "--limit", .argument = "<n>", .description = "Maximum number of objects to return.", .default_value = "100" },
            .{ .flags = "--offset", .argument = "<n>", .description = "Skip the first n matching objects.", .default_value = "0" },
            .{ .flags = "--reverse", .argument = null, .description = "Return results in descending ordinal order." },
        },
        .examples = &.{
            "hunt objects heapdump.hprof 'java\\.lang\\.String'",
            "hunt objects heapdump.hprof 'com\\.example\\.CacheEntry' --limit 10 --offset 20",
            "hunt objects 'java\\.lang\\.String' --index-dir ./idx",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Object list printed successfully." },
            .{ .code = 1, .description = "Invalid argument, bad regex, or missing index." },
        },
        .see_also = &.{"sample", "object", "refs-from"},
    },
    .{
        .name = "sample",
        .description = "Decode sample objects whose class name matches a regex.",
        .long_description =
            "Queries the persistent index for objects whose class name matches the " ++
            "given regular expression and prints a decoded JSON view of each object, " ++
            "including primitive and reference field values. Both Java dotted form " ++
            "(e.g. 'com\\.example\\.Foo') and JVM internal form (e.g. 'com/example/Foo') " ++
            "are accepted.",
        .usage = "hunt sample [file.hprof] <class-regex> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
            .{ .flags = "--limit", .argument = "<n>", .description = "Maximum number of objects to decode.", .default_value = "100" },
            .{ .flags = "--offset", .argument = "<n>", .description = "Skip the first n matching objects.", .default_value = "0" },
            .{ .flags = "--reverse", .argument = null, .description = "Decode results in descending ordinal order." },
        },
        .examples = &.{
            "hunt sample heapdump.hprof 'java\\.lang\\.String' --limit 5",
            "hunt sample 'java\\.lang\\.String' --index-dir ./idx --limit 5",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Sample objects decoded successfully." },
            .{ .code = 1, .description = "Invalid argument, bad regex, or missing index." },
        },
        .see_also = &.{"objects", "object"},
    },
    .{
        .name = "object",
        .description = "Decode a single object as JSON, including field values.",
        .long_description =
            "Looks up a single object by its raw ID and prints a JSON view of the " ++
            "object, including class information and field values. Reference fields " ++
            "are shown as raw object IDs.",
        .usage = "hunt object [file.hprof] <id> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
        },
        .examples = &.{
            "hunt object heapdump.hprof 0x3000",
            "hunt object 0x3000 --index-dir ./idx",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Object decoded successfully." },
            .{ .code = 1, .description = "Invalid argument, object not found, or missing index." },
        },
        .see_also = &.{"sample", "refs-from", "refs-to"},
    },
    .{
        .name = "refs-from",
        .description = "List outgoing references from an object as JSON.",
        .long_description =
            "Prints the outgoing (field or array element) references from the object " ++
            "with the given raw ID. Use --limit and --offset to page through large " ++
            "reference lists.",
        .usage = "hunt refs-from [file.hprof] <id> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
            .{ .flags = "--limit", .argument = "<n>", .description = "Maximum number of references to return.", .default_value = "all" },
            .{ .flags = "--offset", .argument = "<n>", .description = "Skip the first n references.", .default_value = "0" },
        },
        .examples = &.{
            "hunt refs-from heapdump.hprof 0x3000 --limit 10",
            "hunt refs-from 0x3000 --index-dir ./idx --limit 10",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "References printed successfully." },
            .{ .code = 1, .description = "Invalid argument, object not found, or missing index." },
        },
        .see_also = &.{"refs-to", "object", "roots"},
    },
    .{
        .name = "refs-to",
        .description = "List incoming references to an object as JSON.",
        .long_description =
            "Prints the incoming references to the object with the given raw ID. " ++
            "This is useful for understanding what keeps an object alive.",
        .usage = "hunt refs-to [file.hprof] <id> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
            .{ .flags = "--limit", .argument = "<n>", .description = "Maximum number of references to return.", .default_value = "all" },
            .{ .flags = "--offset", .argument = "<n>", .description = "Skip the first n references.", .default_value = "0" },
        },
        .examples = &.{
            "hunt refs-to heapdump.hprof 0x3000 --limit 10",
            "hunt refs-to 0x3000 --index-dir ./idx --limit 10",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "References printed successfully." },
            .{ .code = 1, .description = "Invalid argument, object not found, or missing index." },
        },
        .see_also = &.{"refs-from", "roots"},
    },
    .{
        .name = "roots",
        .description = "Find the shortest path from an object to a GC root as JSON.",
        .long_description =
            "Performs a breadth-first search from the object to the nearest GC root " ++
            "and prints the shortest path. Use --max-visited to limit the search " ++
            "space for very large heaps.",
        .usage = "hunt roots [file.hprof] <id> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
            .{ .flags = "--max-visited", .argument = "<n>", .description = "Maximum nodes to visit during the search." },
        },
        .examples = &.{
            "hunt roots heapdump.hprof 0x3000",
            "hunt roots 0x3000 --index-dir ./idx",
            "hunt roots 0x3000 --index-dir ./idx --max-visited 100000",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Root path printed successfully, or no path found within limits." },
            .{ .code = 1, .description = "Invalid argument, object not found, or missing index." },
        },
        .see_also = &.{"refs-to", "tree"},
    },
    .{
        .name = "tree",
        .description = "Perform a bounded tree expansion from an object as JSON.",
        .long_description =
            "Expands a tree starting from the given object, following outbound " ++
            "references by default or inbound references with --direction to. " ++
            "The expansion is bounded by --depth and --max-nodes to keep the " ++
            "output manageable.",
        .usage = "hunt tree [file.hprof] <id> [options]",
        .options = &.{
            .{ .flags = "<file.hprof>", .argument = null, .description = "Optional HPROF file; if given, the index directory is derived from config as <base>/<stem>.idx/." },
            .{ .flags = "--index-dir", .argument = "<dir>", .description = "Directory containing the heap index. Overrides the derived/default index directory." },
            .{ .flags = "--source", .argument = "<file.hprof>", .description = "Override the HPROF source path stored in the index." },
            .{ .flags = "--direction", .argument = "from|to", .description = "Traverse outbound ('from') or inbound ('to') references.", .default_value = "from" },
            .{ .flags = "--depth", .argument = "<n>", .description = "Maximum depth of the expansion." },
            .{ .flags = "--max-nodes", .argument = "<n>", .description = "Maximum nodes to include in the tree." },
        },
        .examples = &.{
            "hunt tree heapdump.hprof 0x3000",
            "hunt tree 0x3000 --index-dir ./idx",
            "hunt tree 0x3000 --index-dir ./idx --direction to --depth 5",
        },
        .exit_codes = &.{
            .{ .code = 0, .description = "Tree printed successfully." },
            .{ .code = 1, .description = "Invalid argument, object not found, or missing index." },
        },
        .see_also = &.{"refs-from", "roots"},
    },
};

pub fn findCommand(name: []const u8) ?Command {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn printGlobalHelp(writer: *Io.Writer) !void {
    try writeStyled(writer, Style.bold ++ Style.cyan, "hunt");
    try writer.writeAll(" - Java HPROF heap dump analyzer\n\n");

    try writeStyled(writer, Style.bold, "Usage:\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.cyan, "hunt");
    try writer.writeAll(" <command> [options]\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.cyan, "hunt");
    try writer.writeAll(" {-h|--help}\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.cyan, "hunt");
    try writer.writeAll(" {-v|--version}\n\n");
    try writeStyled(writer, Style.bold, "Overview commands:\n");
    try printCommandGroup(writer, &.{
        "overview", "info", "histogram", "classes" });

    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold, "Index commands:\n");
    try printCommandGroup(writer, &.{"index"});

    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold, "Query commands:\n");
    try printCommandGroup(writer, &.{ "objects", "sample", "object", "refs-from", "refs-to", "roots", "tree" });

    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold, "Global options:\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.yellow, "-h, --help");
    try writer.writeAll("         Show this help message\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.yellow, "-v, --version");
    try writer.writeAll("      Show version information\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.yellow, "--config <file>");
    try writer.writeAll("  Use the specified config file\n");

    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold, "Configuration:\n");
    try writer.writeAll("  Config is read from the platform-specific default location.\n");
    try writer.writeAll("  Use --config <file> to override.\n");

    try writer.writeAll("\n");
    try writeStyled(writer, Style.dim, "Run '");
    try writeStyled(writer, Style.cyan, "hunt <command> --help");
    try writeStyled(writer, Style.dim, "' for detailed help on a command.\n");
}

fn printCommandGroup(writer: *Io.Writer, names: []const []const u8) !void {
    var max_len: usize = 0;
    for (names) |name| {
        max_len = @max(max_len, name.len);
    }
    for (names) |name| {
        const cmd = findCommand(name) orelse continue;
        try writer.writeAll("  ");
        try writeStyled(writer, Style.cyan, cmd.name);
        try writeSpaces(writer, max_len - cmd.name.len + 2);
        try writer.writeAll(cmd.description);
        try writer.writeAll("\n");
    }
}

pub fn printCommandHelp(writer: *Io.Writer, name: []const u8) !void {
    const cmd = findCommand(name) orelse {
        try printError(writer, "unknown command: {s}", .{name});
        return;
    };

    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold, "NAME\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.cyan, cmd.name);
    try writer.writeAll(" - ");
    try writer.writeAll(cmd.description);
    try writer.writeAll("\n");

    try writer.writeAll("\n");
    try writeStyled(writer, Style.bold, "SYNOPSIS\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.green, cmd.usage);
    try writer.writeAll("\n");

    if (cmd.long_description.len > 0) {
        try writer.writeAll("\n");
        try writeStyled(writer, Style.bold, "DESCRIPTION\n");
        try writer.writeAll("  ");
        try writer.writeAll(cmd.long_description);
        try writer.writeAll("\n");
    }

    if (cmd.options.len > 0) {
        try writer.writeAll("\n");
        try writeStyled(writer, Style.bold, "OPTIONS\n");
        var max_len: usize = 0;
        for (cmd.options) |opt| {
            var len = opt.flags.len;
            if (opt.argument) |a| len += 1 + a.len;
            max_len = @max(max_len, len);
        }
        for (cmd.options) |opt| {
            try writer.writeAll("  ");
            var len = opt.flags.len;
            try writeStyled(writer, Style.yellow, opt.flags);
            if (opt.argument) |a| {
                try writer.writeAll(" ");
                try writeStyled(writer, Style.magenta, a);
                len += 1 + a.len;
            }
            try writeSpaces(writer, max_len - len + 2);
            try writer.writeAll(opt.description);
            if (opt.default_value) |dv| {
                try writer.writeAll(" (default: ");
                try writeStyled(writer, Style.cyan, dv);
                try writer.writeAll(")");
            }
            try writer.writeAll("\n");
            if (opt.example) |ex| {
                try writer.writeAll("    Example: ");
                try writeStyled(writer, Style.dim, ex);
                try writer.writeAll("\n");
            }
        }
    }

    if (cmd.examples.len > 0) {
        try writer.writeAll("\n");
        try writeStyled(writer, Style.bold, "EXAMPLES\n");
        for (cmd.examples) |ex| {
            try writer.writeAll("  ");
            try writeStyled(writer, Style.dim, "$ ");
            try writer.writeAll(ex);
            try writer.writeAll("\n");
        }
    }

    if (cmd.exit_codes.len > 0) {
        try writer.writeAll("\n");
        try writeStyled(writer, Style.bold, "EXIT STATUS\n");
        for (cmd.exit_codes) |ec| {
            try writer.writeAll("  ");
            try printStyled(writer, Style.yellow, "{d}", .{ec.code});
            try writer.print("  {s}\n", .{ec.description});
        }
    }

    if (cmd.see_also.len > 0) {
        try writer.writeAll("\n");
        try writeStyled(writer, Style.bold, "SEE ALSO\n");
        try writer.writeAll("  hunt ");
        for (cmd.see_also, 0..) |sa, i| {
            if (i > 0) try writer.writeAll(", hunt ");
            try writeStyled(writer, Style.cyan, sa);
        }
        try writer.writeAll("\n");
    }

    if (cmd.notes.len > 0) {
        try writer.writeAll("\n");
        try writeStyled(writer, Style.bold, "NOTES\n");
        try writer.writeAll("  ");
        try writer.writeAll(cmd.notes);
        try writer.writeAll("\n");
    }

    try writer.writeAll("\n");
}

pub fn printVersion(writer: *Io.Writer) !void {
    try writeStyled(writer, Style.bold ++ Style.cyan, "hunt");
    try writer.writeAll(" version ");
    try writeStyled(writer, Style.yellow, "0.1.0");
    try writer.writeAll("\n");
}

pub fn printMissingArgument(
    writer: *Io.Writer,
    command: []const u8,
    usage: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try printError(writer, fmt, args);
    try writer.writeAll("\n\n");
    try writeStyled(writer, Style.bold, "Usage:\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.green, usage);
    try writer.writeAll("\n\n");
    try writeStyled(writer, Style.dim, "Run '");
    try printStyled(writer, Style.cyan, "hunt {s} --help", .{command});
    try writeStyled(writer, Style.dim, "' for more information.\n");
}

pub fn printUnknownOption(
    writer: *Io.Writer,
    command: []const u8,
    usage: []const u8,
    option: []const u8,
) !void {
    try printError(writer, "unknown option '{s}' for command '{s}'", .{ option, command });
    try writer.writeAll("\n\n");
    try writeStyled(writer, Style.bold, "Usage:\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.green, usage);
    try writer.writeAll("\n\n");
    try writeStyled(writer, Style.dim, "Run '");
    try printStyled(writer, Style.cyan, "hunt {s} --help", .{command});
    try writeStyled(writer, Style.dim, "' for available options.\n");
}

pub fn printInvalidValue(
    writer: *Io.Writer,
    command: []const u8,
    usage: []const u8,
    option: []const u8,
    value: []const u8,
    expected: []const u8,
) !void {
    try printError(writer, "invalid value '{s}' for option '{s}': expected {s}", .{ value, option, expected });
    try writer.writeAll("\n\n");
    try writeStyled(writer, Style.bold, "Usage:\n");
    try writer.writeAll("  ");
    try writeStyled(writer, Style.green, usage);
    try writer.writeAll("\n\n");
    try writeStyled(writer, Style.dim, "Run '");
    try printStyled(writer, Style.cyan, "hunt {s} --help", .{command});
    try writeStyled(writer, Style.dim, "' for more information.\n");
}

/// Expect `args[i + 1]` to exist and return it. Otherwise prints a help-style
/// error message and returns `error.InvalidArgument`.
pub fn expectNextArg(
    writer: *Io.Writer,
    command: []const u8,
    usage: []const u8,
    option: []const u8,
    args: []const [:0]const u8,
    i: usize,
) ![]const u8 {
    if (i + 1 >= args.len) {
        try printMissingArgument(writer, command, usage, "missing value for option '{s}'", .{option});
        return error.InvalidArgument;
    }
    return args[i + 1];
}

/// Parse an unsigned integer for `option`. On failure prints a help-style error.
pub fn parseUnsigned(
    comptime T: type,
    writer: *Io.Writer,
    command: []const u8,
    usage: []const u8,
    option: []const u8,
    value: []const u8,
) !T {
    return std.fmt.parseInt(T, value, 10) catch {
        try printInvalidValue(writer, command, usage, option, value, "a non-negative integer");
        return error.InvalidArgument;
    };
}
