const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const MAX_CASES = @import("./root.zig").MAX_CASES;
const CASE_INDEX = @import("./root.zig").CASE_INDEX;

const SelectOperation = @import("./root.zig").SelectOperation;

pub fn initResultType(
    Result: type,
    value: anytype,
    comptime case_idx: CASE_INDEX,
) Result {
    const result_type_info: std.builtin.Type.Union = @typeInfo(Result).@"union";
    return @unionInit(
        Result,
        result_type_info.fields[case_idx].name,
        value,
    );
}

pub fn selectName(Cases: type) []const u8 {
    return comptime blk: {
        const case_count = caseCount(Cases);
        var name_buf: [:0]const u8 = &("select(".*);
        for (0..case_count) |case_idx| {
            const case = getCase(Cases, case_idx);
            const data_type = getDataType(case);
            const name = @typeName(data_type);
            const op_name = @tagName(getOperation(case));
            name_buf = name_buf ++ "(" ++ op_name ++ ", " ++ name ++ ")";
            if (case_idx != case_count - 1) {
                name_buf = name_buf ++ ", ";
            }
        }
        name_buf = name_buf ++ ")";
        break :blk name_buf;
    };
}

fn getCase(Cases: type, comptime index: CASE_INDEX) type {
    const cases_type_info = @typeInfo(Cases);
    assert(cases_type_info == .@"struct");
    assert(cases_type_info.@"struct".is_tuple);
    const args_as_struct = cases_type_info.@"struct";
    return args_as_struct.fields[index].type;
}

fn getOperation(Case: type) SelectOperation {
    const case_info: std.builtin.Type.Struct = @typeInfo(Case).@"struct";
    assert(case_info.is_tuple);
    return switch (case_info.fields.len) {
        2 => SelectOperation.receive,
        3 => SelectOperation.send,
        else => unreachable,
    };
}

fn getDataType(Case: type) type {
    const case_info: std.builtin.Type.Struct = @typeInfo(Case).@"struct";
    assert(case_info.is_tuple);
    const case_operation = @typeInfo(case_info.fields[0].type);
    assert(case_operation == .enum_literal);
    const chan_ptr = case_info.fields[1].type;
    const chan_ptr_info: std.builtin.Type.Pointer = @typeInfo(chan_ptr).pointer;
    const chan = chan_ptr_info.child;
    return chan.ValueType;
}

pub fn SelectResultType(Cases: type) type {
    const cases_type_info = @typeInfo(Cases);
    assert(cases_type_info == .@"struct");
    assert(cases_type_info.@"struct".is_tuple);
    const args_as_struct = cases_type_info.@"struct";

    if (args_as_struct.fields.len != 2) {
        @compileError("TODO");
    }

    const op_a = args_as_struct.fields[0].type;
    const op_b = args_as_struct.fields[1].type;

    const op_a_info: std.builtin.Type.Struct = @typeInfo(op_a).@"struct";
    const op_b_info: std.builtin.Type.Struct = @typeInfo(op_b).@"struct";
    assert(op_a_info.is_tuple);
    assert(op_b_info.is_tuple);

    const op_a_operation = @typeInfo(op_a_info.fields[0].type);
    assert(op_a_operation == .enum_literal);

    const op_b_operation = @typeInfo(op_b_info.fields[0].type);
    assert(op_b_operation == .enum_literal);

    const chan_a_ptr = op_a_info.fields[1].type;
    const chan_b_ptr = op_b_info.fields[1].type;

    const chan_a_ptr_info: std.builtin.Type.Pointer = @typeInfo(chan_a_ptr).pointer;
    const chan_b_ptr_info: std.builtin.Type.Pointer = @typeInfo(chan_b_ptr).pointer;

    const chan_a = chan_a_ptr_info.child;
    const chan_b = chan_b_ptr_info.child;

    const ResultTypeA = chan_a.ValueType;
    const ResultTypeB = chan_b.ValueType;

    const OptionalA = @Type(std.builtin.Type{ .optional = .{ .child = ResultTypeA } });
    const OptionalB = @Type(std.builtin.Type{ .optional = .{ .child = ResultTypeB } });

    const union_tag_type_info: std.builtin.Type = .{ .@"enum" = .{
        .tag_type = u2,
        .fields = &[_]std.builtin.Type.EnumField{
            .{ .name = "0", .value = 0 },
            .{ .name = "1", .value = 1 },
        },
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_exhaustive = true,
    } };

    const UnionTagType = @Type(union_tag_type_info);

    const union_type_info: std.builtin.Type = .{
        .@"union" = .{
            .layout = .auto,
            .tag_type = UnionTagType,
            .fields = &[_]std.builtin.Type.UnionField{
                .{
                    .name = "0",
                    .type = OptionalA,
                    .alignment = @alignOf(ResultTypeA),
                },
                .{
                    .name = "1",
                    .type = OptionalB,
                    .alignment = @alignOf(ResultTypeB),
                },
            },
            .decls = &[_]std.builtin.Type.Declaration{},
        },
    };

    comptime assert(@intFromEnum(UnionTagType.@"0") == 0);
    const UnionType = @Type(union_type_info);
    return UnionType;
}

fn ChannelFromCase(Case: type) type {
    const case_type_info: std.builtin.Type.Struct = @typeInfo(Case).@"struct";
    assert(case_type_info.is_tuple);
    const fields = case_type_info.fields;
    // TODO: support send
    assert(fields.len == 2);
    assert(std.mem.eql(u8, fields[1].name, "1"));
    return case_type_info.fields[1].type;
}

pub fn channelFromCase(case: anytype) ChannelFromCase(@TypeOf(case)) {
    return case[1];
}

fn validateCases(cases: anytype) void {
    const Cases = @TypeOf(cases);
    @setEvalBranchQuota(MAX_CASES);
    const case_count = caseCount(Cases);
    comptime var case_idx: CASE_INDEX = 0;
    inline while (case_idx < case_count) : (case_idx += 1) {
        const case = cases[case_idx];
        if (case[0] != .receive) {
            std.debug.panic("unsupported operation: {s}", .{@tagName(case[0])});
        }
    }
}

pub fn caseCount(Cases: type) CASE_INDEX {
    const cases_type_info = @typeInfo(Cases);
    const case_count = cases_type_info.@"struct".fields.len;
    return case_count;
}
