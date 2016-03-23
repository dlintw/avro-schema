#!/usr/bin/env tarantool
local tap = require('tap')
-- use alt entry point (exposes internals)
local avro = package.loadlib(
    os.getenv('BINARY_DIR')..'/avro/avro.so', 'luaopen_avrotest') ()

local create_schema = avro.create_schema
local flatten       = avro.flatten
local unflatten     = avro.unflatten
local is_compatible = avro.schema_is_compatible
local get_schema_names = avro.get_schema_names
local get_schema_types = avro.get_schema_types

local test = tap.test('Avro module')
box.cfg{}
test:plan(10)

-- hook GC methods to produce log
local gc_log
local function wrap_gc(orig_gc)
    return function(arg)
        if gc_log then 
            table.insert(gc_log, tostring(arg))
        end
        orig_gc(arg)
    end
end
for _,M in pairs({ avro._get_metatables() }) do
    M.__gc = wrap_gc(M.__gc)
end

-- a few stock schema prototypes
local int_schema_p          = { type = "int" }
local long_schema_p         = { type = "long" }
local float_schema_p        = { type = "float" }
local double_schema_p       = { type = "double" }
local string_schema_p       = { type = "string" }
local int_array_schema_p    = { type = "array", items = "int" }
local string_array_schema_p = { type = "array", items = "string" }
local frob_v1_schema_p      = {
    type = "record",
    name = "X.Frob",
    fields = {
        { name = "A", type = "int" },
        { name = "B", type = "int" },
        { name = "C", type = "int" }
    }
}
local frob_v2_schema_p    = {
    type = "record",
    name = "X.Frob",
    fields = {
        { name = "A", type = "int" },
        { name = "B", type = "int" },
        { name = "C", type = "int" },
        { name = "D", type = "string" }
    }
}
local frob_v1_array_schema_p = { type = "array", items = frob_v1_schema_p }
local complex_schema_p = {
    type = "record",
    name = "X.Complex",
    fields = {
        { name = "A", type = "int" },
        { name = "B", type = "int" },
        { name = "C", type = "int" },
        { name = "D", type = {
            type = "record",
            name = "X.Nested",
            fields = {
                { name = "E", type = "int" },
                { name = "F", type = "int" },
                { name = "G", type = "int" }
            }
        }}
    }
}
local enum_schema_p = {
   type = "enum",
   name = "Suit",
   symbols = {"SPADES", "HEARTS", "DIAMONDS", "CLUBS"}
}

--
-- load-good-schema
--
test:test('load-good-schema', function(test)

    local tests = {
        {'load-int-schema',           int_schema_p,           'Avro schema (int)'},
        {'load-long-schema',          long_schema_p,          'Avro schema (long)'},
        {'load-float-schema',         float_schema_p,         'Avro schema (float)'},
        {'load-double-schema',        double_schema_p,        'Avro schema (double)'},
        {'load-string-schema',        string_schema_p,        'Avro schema (string)'},
        {'load-int-array-schema',     int_array_schema_p,     'Avro schema (array)'},
        {'load-string-array-schema',  string_array_schema_p,  'Avro schema (array)'},
        {'load-frob-v1-schema',       frob_v1_schema_p,       'Avro schema (X.Frob)'},
        {'load-frob-v2-schema',       frob_v2_schema_p,       'Avro schema (X.Frob)'},
        {'load-frob-v1-array-schema', frob_v1_array_schema_p, 'Avro schema (array)'},
        {'load-complex-schema',       complex_schema_p,       'Avro schema (X.Complex)'},
        {'load-enum-schema',          enum_schema_p,          'Avro schema (Suit)'},
        {'load-union-value',          {'int', 'string'},      'Avro schema (union)'}
    }
 
    test:plan(#tests)

    for _,v in pairs(tests) do
        local ok, schema = create_schema(v[2])
        test:is_deeply({ok, tostring(schema)}, {true, v[3]}, v[1])
    end
end)

--
-- load-bad-schema
--
test:test('load-bad-schema', function(test)

    test:plan(7)

    test:is_deeply({create_schema('')}, {false, 'Error parsing JSON: unexpected token near end of file'}, 'bad1')
    test:is_deeply({create_schema({})}, {false, 'Union type must have at least one branch'}, 'bad2')
    test:is_deeply({create_schema({ type = 'broccoli' })}, {false, 'Unknown Avro "type": broccoli'}, 'bad3')
    test:is_deeply({create_schema({ type = 'array' })}, {false, 'Array type must have "items"'}, 'bad4')
    test:is_deeply({create_schema({ type = 'record' })}, {false, 'Record type must have a "name"'}, 'bad5')
    test:is_deeply({create_schema({ type = 'record', name = 'X' })}, {false, 'Record type must have "fields"'}, 'bad6')
    test:is_deeply(
        { create_schema({ type = 'record', name = 'X', fields = {}}) },
        { false, 'Record type must have at least one field' },
        'bad7')
end)

--
-- resolver cache
--
test:test('resolver-cache', function(test)
    local _, frob_v1_schema = create_schema(frob_v1_schema_p)
    local _, frob_v2_schema = create_schema(frob_v2_schema_p)
    local cache = avro._get_resolver_cache()

    test:plan(5)
    test:is_deeply(cache, {}, 'resolver-cache-initially-empty')
    test:is_deeply(avro._create_resolver(frob_v2_schema, frob_v1_schema), nil, 'resolver-created')
    test:istable(cache[frob_v2_schema], 'resolver-was-cached-1')
    test:is(tostring(cache[frob_v2_schema][frob_v1_schema]), 'Avro schema resolver', 'resolver-was-cached-2')

    frob_v1_schema = nil
    frob_v2_schema = nil
    collectgarbage()
    collectgarbage()
    test:is_deeply(cache, {}, 'resolver-cache-auto-pruned')
end)

--
-- objects properly GC-ed
--
test:test('gc', function(test)

    local _, frob_v1_schema = create_schema(frob_v1_schema_p)
    collectgarbage()
    test:plan(6)

    gc_log = {}
    create_schema(frob_v1_schema_p)
    collectgarbage()
    test:is_deeply(gc_log, {'Avro schema (X.Frob)'}, 'gc-schema')

    gc_log = {}
    do
        local _, frob_v1_schema = create_schema(frob_v1_schema_p)
        local _, frob_v2_schema = create_schema(frob_v2_schema_p)
        avro._create_resolver(frob_v2_schema, frob_v1_schema)
    end
    collectgarbage()
    collectgarbage()
    collectgarbage()
    table.sort(gc_log)
    test:is_deeply(gc_log, {'Avro schema (X.Frob)', 'Avro schema (X.Frob)', 'Avro schema resolver'}, 'gc-resolver')

    gc_log = {}
    flatten({ A = 1, B = 2, C = 3 }, frob_v1_schema)
    collectgarbage()
    test:is_deeply(gc_log, {'Avro xform ctx'}, 'gc-flatten-xform-ctx')

    gc_log = {}
    flatten({ A = '', B = 2, C = 3 }, frob_v1_schema)
    collectgarbage()
    test:is_deeply(gc_log, {'Avro xform ctx'}, 'gc-flatten-error-xform-ctx')

    gc_log = {}
    unflatten({ 1, 2, 3 }, frob_v1_schema)
    collectgarbage()
    test:is_deeply(gc_log, {'Avro xform ctx'}, 'gc-unflatten-xform-ctx')

    gc_log = {}
    unflatten({ '', 2, 3 }, frob_v1_schema)
    collectgarbage()
    test:is_deeply(gc_log, {'Avro xform ctx'}, 'gc-unflatten-error-xform-ctx')

    gc_log = nil
end)

--
-- flatten
--
test:test('flatten', function(test)
    local _, frob_v1_schema = create_schema(frob_v1_schema_p)
    local _, frob_v2_schema = create_schema(frob_v2_schema_p)
    local _, frob_v1_array_schema = create_schema(frob_v1_array_schema_p)
    local _, complex_schema = create_schema(complex_schema_p)
    local ABC = { A = 1, B = 2, C = 3 }
    local flat_ABC = { 1, 2, 3 }
    local ABCD = { A = 1, B = 2, C = 3, D = 'test' }
    local flat_ABCD = { 1, 2, 3, 'test' }
    local ABCDEFG = { A = 1, B = 2, C = 3, D = { E = 4, F = 5, G = 6 } }
    local flat_ABCDEFG = { 1, 2, 3, 4, 5, 6 }

    test:plan(7)

    test:is_deeply(
        { flatten(ABC, frob_v1_schema) },
        { true, flat_ABC },
        'flatten-frob-v1')

    test:is_deeply(
        { flatten({ ABC, ABC, ABC }, frob_v1_array_schema) },
        { true, { flat_ABC, flat_ABC, flat_ABC } },
        'flatten-frob-v1-array')

    test:is_deeply(
        { flatten(ABCD, frob_v2_schema) },
        { true, flat_ABCD },
        'flatten-frob-v2')

    test:is_deeply(
        { flatten(ABCD, frob_v2_schema, frob_v1_schema) },
        { true, flat_ABC },
        'flatten-frob-v2-as-frob-v1')

    test:is_deeply(
        { flatten(ABCDEFG, complex_schema) },
        { true, flat_ABCDEFG },
        'flatten-complex')

    test:is_deeply(
        { flatten({ A = '', B = 2, C = 3 }, frob_v1_schema) },
        { false, 'type mismatch' },
        'flatten-error-type-mismatch')

    local T = {}
    T[1] = T
    test:is_deeply(
        { flatten(T, frob_v1_array_schema) },
        { false, 'circular ref' },
        'flatten-error-circular-ref')
end)

--
-- unflatten
--
test:test('unflatten', function(test)
    local _, frob_v1_schema = create_schema(frob_v1_schema_p)
    local _, frob_v2_schema = create_schema(frob_v2_schema_p)
    local _, frob_v1_array_schema = create_schema(frob_v1_array_schema_p)
    local _, complex_schema = create_schema(complex_schema_p)
    local ABC = { A = 1, B = 2, C = 3 }
    local flat_ABC = { 1, 2, 3 }
    local ABCD = { A = 1, B = 2, C = 3, D = 'test' }
    local flat_ABCD = { 1, 2, 3, 'test' }
    local ABCDEFG = { A = 1, B = 2, C = 3, D = { E = 4, F = 5, G = 6 } }
    local flat_ABCDEFG = { 1, 2, 3, 4, 5, 6 }
    local tnew = box.tuple.new

    test:plan(12)

    test:is_deeply(
        { unflatten(flat_ABC, frob_v1_schema) },
        { true, ABC },
        'unflatten-frob-v1')

    test:is_deeply(
        { unflatten({ flat_ABC, flat_ABC, flat_ABC }, frob_v1_array_schema) },
        { true, { ABC, ABC, ABC } },
        'unflatten-frob-v1-array')

    test:is_deeply(
        { unflatten(flat_ABCD, frob_v2_schema) },
        { true, ABCD },
        'unflatten-frob-v2')

    test:is_deeply(
        { unflatten(flat_ABCD, frob_v2_schema, frob_v1_schema) },
        { true, ABC },
        'unflatten-frob-v2-as-frob-v1')

    test:is_deeply(
        { unflatten(flat_ABCDEFG, complex_schema) },
        { true, ABCDEFG },
        'unflatten-complex')

    test:is_deeply(
        { unflatten(tnew(flat_ABC), frob_v1_schema) },
        { true, ABC },
        'unflatten-frob-v1 (tuple)')

    test:is_deeply(
        { unflatten(tnew({ flat_ABC, flat_ABC, flat_ABC }), frob_v1_array_schema) },
        { true, { ABC, ABC, ABC } },
        'unflatten-frob-v1-array (tuple)')

    test:is_deeply(
        { unflatten(tnew(flat_ABCD), frob_v2_schema) },
        { true, ABCD },
        'unflatten-frob-v2 (tuple)')

    test:is_deeply(
        { unflatten(tnew(flat_ABCD), frob_v2_schema, frob_v1_schema) },
        { true, ABC },
        'unflatten-frob-v2-as-frob-v1 (tuple)')

    test:is_deeply(
        { unflatten(tnew(flat_ABCDEFG), complex_schema) },
        { true, ABCDEFG },
        'unflatten-complex (tuple)')

    test:is_deeply(
        { unflatten({ '', 2, 3 }, frob_v1_schema) },
        { false, 'type mismatch' },
        'flatten-error-type-mismatch')

    local T = {}
    T[1] = T
    test:is_deeply(
        { unflatten(T, frob_v1_array_schema) },
        { false, 'circular ref' },
        'flatten-error-circular-ref')
end)

--
-- schema compatibility
--
test:test('is-compatible', function(test)
    local _, frob_v1_schema = create_schema(frob_v1_schema_p)
    local _, frob_v2_schema = create_schema(frob_v2_schema_p)

    test:plan(2)

    test:is_deeply(
        { is_compatible(frob_v1_schema, frob_v2_schema) },
        { false, 'Reader field D doesn\'t appear in writer' },
        'upgrade')

    test:is_deeply(
        { is_compatible(frob_v2_schema, frob_v1_schema) },
        { true },
        'downgrade')

end)

--
-- enum
--
test:test('enum', function(test)
    local _, enum_schema = create_schema(enum_schema_p)
    local symbols = enum_schema_p.symbols

    test:plan(2 * #symbols + 4)

    for i,k in pairs(symbols) do
        test:is_deeply(
            { flatten(k, enum_schema) },
            { true, i - 1 },
            'flatten-'..k)
    end

    for i,k in pairs(symbols) do
        test:is_deeply(
            { unflatten(i - 1, enum_schema) },
            { true, k },
            string.format('unflatten-%d', i - 1))
    end

    test:is_deeply(
        { flatten('INVALID', enum_schema) },
        { false, 'name unknown' },
        'flatten-INVALID')

    test:is_deeply(
        { unflatten(-1, enum_schema) },
        { false, 'name unknown' },
        'unflatten-minus-1')

    test:is_deeply(
        { unflatten(4, enum_schema) },
        { false, 'name unknown' },
        'unflatten-4')

    test:is_deeply(
        { unflatten(100, enum_schema) },
        { false, 'name unknown' },
        'unflatten-100')
end)

--
-- union
--
test:test('union', function(test)
    local _, simple_schema = create_schema({ 'int', 'string' })
    local _, record_schema = create_schema({
        type = 'record',
        name = 'X.Union',
        fields = {
            { name = 'A', type = 'int' },
            { name = 'B', type = { 'int', 'string' } },
            { name = 'C', type = 'int' }
        }
    })
    local simple1, simple2 = { 'int', 42 }, { 'string', 'Hello, world!'}
    local simple1_flat, simple2_flat = { 0, 42 }, { 1, 'Hello, world!'}
    local record1 = { A = 1, B = simple1, C = 3}
    local record2 = { A = 1, B = simple2, C = 3}
    local record1_flat = { 1, 0, 42, 3 }
    local record2_flat = { 1, 1, 'Hello, world!', 3 }

    local valid_cases = {
        { simple_schema, simple1, simple1_flat },
        { simple_schema, simple2, simple2_flat },
        { record_schema, record1, record1_flat },
        { record_schema, record2, record2_flat }
    }

    test:plan(2 * #valid_cases + 6)
    for i, case in pairs(valid_cases) do
        test:is_deeply(
            { flatten(case[2], case[1]) },
            { true, case[3] },
            string.format('flatten-%d', i)
        )
    end
    for i, case in pairs(valid_cases) do
        test:is_deeply(
            { unflatten(case[3], case[1]) },
            { true, case[2] },
            string.format('unflatten-%d', i)
        )
    end

    test:is_deeply(
        { flatten({ 'brokkoli', 42 }, simple_schema ) },
        { false, "name unknown" },
        'invalid-1')

    test:is_deeply(
        { flatten({ 'int', {} }, simple_schema ) },
        { false, "type mismatch" },
        'invalid-2')

    test:is_deeply(
        { flatten({ 'string', {} }, simple_schema ) },
        { false, "type mismatch" },
        'invalid-3')

    test:is_deeply(
        { unflatten({ -1, 42 }, simple_schema) },
        { false, "name unknown"},
        'invalid-4')

    test:is_deeply(
        { unflatten({ 2, 42 }, simple_schema) },
        { false, "name unknown"},
        'invalid-4')

    test:is_deeply(
        { unflatten({ 100, 42 }, simple_schema) },
        { false, "name unknown"},
        'invalid-4')

end)

test:test('schema-query', function(test)
    local _, int_schema = create_schema(int_schema_p)
    local _, frob_schema = create_schema(frob_v2_schema_p)
    local _, complex_schema = create_schema(complex_schema_p)

    test:plan(6)

    test:is_deeply(
        get_schema_names(int_schema),
        {},
        'not-a-record-names')

    test:is_deeply(
        get_schema_types(int_schema),
        {},
        'not-a-record-types')

    test:is_deeply(
        get_schema_names(frob_schema),
        { 'A', 'B', 'C', 'D' },
        'frob-names')

    test:is_deeply(
        get_schema_types(frob_schema),
        { 'int', 'int', 'int', 'string' },
        'frob-types')

    test:is_deeply(
        get_schema_names(complex_schema),
        { 'A', 'B', 'C', 'D.E', 'D.F', 'D.G' },
        'complex-names')

    test:is_deeply(
        get_schema_types(complex_schema),
        { 'int', 'int', 'int', 'int', 'int', 'int' },
        'complex-types')

end)

test:check()

os.exit(test.planned == test.total and test.failed == 0 and 0 or -1)
