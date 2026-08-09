const std = @import("std");
const api = @import("../api.zig");
const ast_dumper = @import("../core/ast_dumper.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const subcmd = args_iter.next() orelse {
        printUsage();
        std.process.exit(1);
    };

    if (std.mem.eql(u8, subcmd, "ast-dump")) {
        try executeAstDump(init, allocator, args_iter);
    } else {
        std.debug.print("Error: Unknown dev subcommand '{s}'\n\n", .{subcmd});
        printUsage();
        std.process.exit(1);
    }
}

fn executeAstDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        std.debug.print("Error: Missing file path for 'ast-dump'. Usage: kupcad dev ast-dump <file.kup>\n", .{});
        std.process.exit(1);
    };

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, file_path, allocator, .limited(MAX_FILE_SIZE)) catch |err| {
        std.debug.print("Error reading file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Fully parse the AST and resolve symbols/slots
    var doc = api.Document.parse(allocator, source) catch |err| {
        std.debug.print("Error parsing file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer doc.deinit();

    // Setup an allocating writer to buffer the tree dump
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try ast_dumper.dump(allocator, &doc, &out);

    // Construct output path and write file
    const out_path = try std.fmt.allocPrint(allocator, "{s}.dump", .{file_path});
    defer allocator.free(out_path);

    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    std.debug.print("Successfully dumped AST to {s}\n", .{out_path});
}

fn printUsage() void {
    std.debug.print(
        \\Usage: kupcad dev <subcommand> [options]
        \\
        \\Subcommands:
        \\  ast-dump <file>  Generate an AST tree dump (.dump) for compiler debugging
        \\
    , .{});
}
