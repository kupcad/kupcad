const std = @import("std");
const api = @import("../api.zig");
const ast_dumper = @import("../tools/dev/ast_dumper.zig");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub const DevError = error{
    MissingSubcommand,
    UnknownSubcommand,
    MissingFilePath,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const subcmd = args_iter.next() orelse {
        printUsage();
        return error.MissingSubcommand;
    };

    if (std.mem.eql(u8, subcmd, "ast-dump")) {
        try executeAstDump(init, allocator, args_iter);
    } else {
        std.log.err("Unknown dev subcommand '{s}'", .{subcmd});
        printUsage();
        return error.UnknownSubcommand;
    }
}

fn executeAstDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        std.log.err("Missing file path for 'ast-dump'. Usage: kupcad dev ast-dump <file.kup>", .{});
        return error.MissingFilePath;
    };

    // Use our new centralized file reader
    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        std.log.err("Error reading file '{s}': {}", .{ file_path, err });
        return err;
    };
    defer allocator.free(source);

    // Fully parse the AST and resolve symbols/slots
    var doc = api.Document.parse(allocator, source) catch |err| {
        std.log.err("Error parsing file '{s}': {}", .{ file_path, err });
        return err;
    };
    defer doc.deinit();

    // Setup an allocating writer to buffer the tree dump
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try ast_dumper.dump(allocator, &doc, &out);

    // Construct output path and write file
    const out_path = try std.fmt.allocPrint(allocator, "{s}.dump", .{file_path});
    defer allocator.free(out_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    std.log.info("Successfully dumped AST to {s}", .{out_path});
}

fn printUsage() void {
    std.log.info(
        \\Usage: kupcad dev <subcommand> [options]
        \\
        \\Subcommands:
        \\  ast-dump <file>  Generate an AST tree dump (.dump) for compiler debugging
        \\
    , .{});
}
