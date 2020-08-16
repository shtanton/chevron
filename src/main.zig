const std = @import("std");

const CompileTemplateError = error {
    MissingCloseBracket,
    MissingCloseTerm,
    OutOfMemory,
};

const RunTemplateError = error {
    UnknownValue,
    InvalidJsonStructure,
    OutOfMemory,
} || std.os.WriteError;

const UsageError = error {
    InvalidUsage,
};

fn readWholeFile(allocator: *std.mem.Allocator, file: std.fs.File) ![]u8 {
    var contents: []u8 = try allocator.alloc(u8, 1024);
    var total_read: usize = 0;
    read_loop: while (true) {
        if (total_read == contents.len) {
            contents = try allocator.realloc(contents, contents.len * 2);
        }
        const read = try file.read(contents[total_read..]);
        if (read == 0) {
            break :read_loop;
        }
        total_read += read;
    }
    return contents[0..total_read];
}

const Section = union(enum) {
    Text: []u8,
    Substitution: []u8,
    HashBlock: struct {
        identifier: []u8,
        contents: Template,
    },
};

const Template = struct {
    sections: []Section,
};

fn findString(query: []const u8, string: []const u8) ?usize {
    var i: u32 = 0;
    while (i <= string.len - query.len) {
        if (std.mem.eql(u8, query, string[i..i+query.len])) {
            return i;
        }
        i += 1;
    }
    return null;
}

fn compileInput(allocator: *std.mem.Allocator, input: []u8) CompileTemplateError!Template {
    var current_block_start: usize = 0;
    var current_block_end: usize = 0;
    var sections = std.ArrayList(Section).init(allocator);
    while (current_block_end < input.len) {
        if (input[current_block_end] == '{') {
            var query = input[current_block_end..];
            current_block_end += 1;
            if (input[current_block_end] == '#') {
                input[current_block_end] = '/';
                current_block_end += 1;
                current_block_start = current_block_end;
                while (current_block_end < input.len and input[current_block_end] != '}') {
                    current_block_end += 1;
                }
                if (current_block_end == input.len) {
                    return CompileTemplateError.MissingCloseBracket;
                }
                const identifier = input[current_block_start..current_block_end];
                current_block_end += 1;
                current_block_start = current_block_end;
                query = query[0..identifier.len+3];
                current_block_end = current_block_end + (findString(query, input[current_block_end..]) orelse return CompileTemplateError.MissingCloseTerm);
                const contents = try compileInput(allocator, input[current_block_start..current_block_end]);
                current_block_end += query.len;
                current_block_start = current_block_end;
                try sections.append(Section{.HashBlock = .{.identifier = identifier, .contents = contents}});
            } else {
                current_block_start = current_block_end;
                while (current_block_end < input.len and input[current_block_end] != '}') {
                    current_block_end += 1;
                }
                if (current_block_end == input.len) {
                    return CompileTemplateError.MissingCloseBracket;
                }
                try sections.append(Section{.Substitution = input[current_block_start..current_block_end]});
                current_block_end += 1;
                current_block_start = current_block_end;
            }
        } else {
            while (current_block_end < input.len and input[current_block_end] != '{') {
                current_block_end += 1;
            }
            try sections.append(Section{.Text = input[current_block_start..current_block_end]});
        }
    }
    return Template {
        .sections = sections.items,
    };
}

const DataAncestry = struct {
    data: *const std.json.ObjectMap,
    parent: ?*const DataAncestry,
    fn init(data: *const std.json.ObjectMap) DataAncestry {
        return DataAncestry {
            .data = data,
            .parent = null,
        };
    }
    fn getValue(self: *const DataAncestry, key: []const u8) ?std.json.Value {
        var current: ?*const DataAncestry = self;
        while (current) |ancestry| {
            if (ancestry.data.getValue(key)) |value| {
                return value;
            } else {
                current = ancestry.parent;
            }
        }
        return null;
    }
    fn initChild(self: *const DataAncestry, data: *const std.json.ObjectMap) DataAncestry {
        return DataAncestry {
            .data = data,
            .parent = self,
        };
    }
};

fn executeTemplate(json: DataAncestry, template: Template, output: std.fs.File) RunTemplateError!void {
    for (template.sections) |section| {
        switch (section) {
            .Text => |text| {
                try output.writeAll(text);
            },
            .Substitution => |variable| {
                const value = json.getValue(variable) orelse return RunTemplateError.UnknownValue;
                switch (value) {
                    .String => |v| try output.writeAll(v),
                    .Integer => |v| try std.fmt.formatInt(v, 10, false, std.fmt.FormatOptions {}, output),
                    else => unreachable,
                }
            },
            .HashBlock => |block| {
                const value = json.getValue(block.identifier) orelse return RunTemplateError.UnknownValue;
                switch (value) {
                    .Array => |arr| {
                        for (arr.items) |item| {
                            var item_map = switch (item) {
                                .Object => |item_map| item_map,
                                else => return RunTemplateError.InvalidJsonStructure,
                            };
                            try executeTemplate(json.initChild(&item_map), block.contents, output);
                        }
                    },
                    else => return RunTemplateError.InvalidJsonStructure,
                }
            },
        }
    }
}

fn invalidUsage() UsageError {
    std.debug.warn("Usage: chevron template_file output_file\n\tProvide JSON on stdin", .{});
    return UsageError.InvalidUsage;
}

pub fn main() anyerror!void {
    const stdin = std.io.getStdIn();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const json_string = try readWholeFile(&arena.allocator, stdin);

    var parser = std.json.Parser.init(&arena.allocator, false);
    const tree = try parser.parse(json_string);

    var arg_iterator = std.process.args();
    _ = arg_iterator.skip();
    const template_relative_path = if (arg_iterator.next(&arena.allocator)) |arg| try arg else {
        return invalidUsage();
    };
    const output_relative_path = if (arg_iterator.next(&arena.allocator)) |arg| try arg else {
        return invalidUsage();
    };

    const cwd = std.fs.cwd();
    const template_file = try cwd.openFile(template_relative_path, .{.read = true, .write = false, .lock = std.fs.File.Lock.Shared});
    const output_file = try cwd.createFile(output_relative_path, .{.lock = std.fs.File.Lock.Shared});

    const template_string = try readWholeFile(&arena.allocator, template_file);
    const template = try compileInput(&arena.allocator, template_string);
    const map = switch (tree.root) {
        .Object => |value| value,
        else => return RunTemplateError.InvalidJsonStructure,
    };
    try executeTemplate(DataAncestry.init(&map), template, output_file);
}
