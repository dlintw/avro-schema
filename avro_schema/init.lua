local digest      = require('digest')
local front       = require('avro_schema.frontend')
local c           = require('avro_schema.compiler')
local il          = require('avro_schema.il')
local backend_lua = require('avro_schema.backend')
local rt          = require('avro_schema.runtime')

local format, find, sub = string.format, string.find, string.sub
local insert, remove, concat = table.insert, table.remove, table.concat

local base64_encode       = digest.base64_encode
local f_create_schema     = front.create_schema
local f_validate_data     = front.validate_data
local f_create_ir         = front.create_ir
local c_emit_code         = c.emit_code
local il_create           = il.il_create
local rt_msgpack_encode   = rt.msgpack_encode
local rt_msgpack_decode   = rt.msgpack_decode
local rt_lua_encode       = rt.lua_encode
local rt_universal_decode = rt.universal_decode
local install_lua_backend = backend_lua.install

-- We give away a handle but we never expose schema data.
local schema_by_handle = setmetatable( {}, { __mode = 'k' } )

local function get_schema(handle)
    local schema = schema_by_handle[handle]
    if not schema then
        error(format('Not a schema: %s', handle), 0)
    end
    return schema
end

local function is_schema(schema_handle)
    return not not schema_by_handle[schema_handle]
end

-- IR-s are cached
local ir_by_key        = setmetatable( {}, { __mode = 'v' } )

local function get_ir(from_schema, to_schema, inverse)
    local k = format('%s%p.%p', inverse and '-' or '', from_schema, to_schema)
    local ir = ir_by_key[k]
    if ir then
        if type(ir) == 'table' and ir[1] == 'ERR' then
            return false, ir[2]
        else
            return true, ir
        end
    else
        local err
        ir, err = f_create_ir(from_schema, to_schema, inverse)
        if not ir then
            ir_by_key[k] = { 'ERR', err }
            return false, err
        else
            ir_by_key[k] = ir
            return true, ir
        end
    end
end

local function schema_to_string(handle)
    local schema = schema_by_handle[handle]
    return format('Schema (%s)',
                  handle[1] or (type(schema) ~= 'table' and schema) or
                  schema.name or schema.type or 'union')
end

local schema_handle_mt = {
    __tostring  = schema_to_string,
    __serialize = schema_to_string
}

local augment_defaults
augment_defaults = function(schema, visited)
    if type(schema) == 'string' or visited[schema] then return end
    visited[schema] = true
    local t = schema.type
    if t == nil then
        for _, branch in ipairs(schema) do
            augment_defaults(branch, visited)
        end
    elseif t == 'array' then
        augment_defaults(schema.items, visited)
    elseif t == 'map' then
        augment_defaults(schema.values, visited)
    elseif t == 'record' then
        for _, field in ipairs(schema.fields) do
            local fieldt = field.type
            augment_defaults(fieldt, visited)
            if field.default == nil then
                local fieldtk = fieldt.type or fieldt
                if type(fieldtk) == 'table' then
                    fieldt = fieldt[1]
                    fieldtk =  fieldt.type or fieldt
                end
                if fieldtk == 'boolean' then
                    field.default = false
                elseif fieldtk == 'int' or fieldtk == 'long' or
                       fieldtk == 'float' or fieldtk == 'double' then
                    field.default = 0
                elseif fieldtk == 'bytes' or fieldtk == 'string' then
                    field.default = ''
                elseif fieldtk == 'array' or fieldtk == 'map' then
                    field.default = {}
                elseif fieldtk == 'enum' then
                    field.default = fieldt.symbols[1]
                elseif fieldtk == 'record' then
                    local dr = {}
                    for _, xfield in ipairs(fieldt.fields) do
                        dr[xfield.name] = xfield.default
                    end
                    field.default = dr
                end
            end
        end
    end
end

local function create(raw_schema, options)
    local ok, schema = pcall(f_create_schema, raw_schema)
    if not ok then
        return false, schema
    end
    if type(options) == 'table' and options.defaults == 'auto' then
        augment_defaults(schema, {})
    end
    local schema_handle = setmetatable({}, schema_handle_mt)
    schema_by_handle[schema_handle] = schema
    return true, schema_handle
end

local function validate(schema_handle, data)
    return f_validate_data(get_schema(schema_handle), data)
end

local function are_compatible(schema_h1, schema_h2, opt_mode)
    local ok, extra = get_ir(get_schema(schema_h1), get_schema(schema_h2),
                             opt_mode == 'downgrade')
    if ok then
        return true -- never leak IR
    else
        return false, extra
    end
end

-----------------------------------------------------------------------
-- codegen

-- "template often contains ${variables}"
local function compile_template(template)
    local code = {}
    local n, p = 0, 0
    while p do
        local a, b = find(template, '${[^}]+}', p + 1)
        n = n + 2
        code[n - 1] = sub(template, p + 1, (a or #template + 1) - 1)
        code[n] = a and sub(template, a + 2, b - 1)
        p = b
    end
    return function(dict)
        local res = {}
        for i = 1, n, 2 do
            insert(res, code[i])
            local v = dict[code[i+1]]
            insert(res, type(v) == 'table' and concat(v, '\n') or v)
        end
        return concat(res)
    end
end

-- yields ", a1, ... aN"
local function param_list(n, class)
    if n == 0 then return '' end
    class = class or 'a'
    local res = { '' }
    for i = 1, n do
        insert(res, class..i)
    end
    return concat(res, ', ')
end

local function gen_store_service_fields(service_fields)
    local code, pos = {}, 1
    for i, field in ipairs(service_fields) do
        if field == 'boolean' then
            insert(code, format('r.ot[%d] = 3-ffi_cast("int", not a%d)', pos, i))
            pos = pos + 1
        elseif field == 'int' or field == 'long' then
            insert(code, format('r.ov[%d].ival = a%d', pos, pos, i))
            pos = pos + 1
        elseif field == 'float' or field == 'double' then
            insert(code, format('r.ov[%d].dval = a%d',
                                pos, i))
            pos = pos + 1
        elseif field == 'string' or field == 'bytes' then
            insert(code, format([[
r.ov[%d].xlen = #a%d; r.ov[%d].xoff = 0xffffffff
r.ov[%d].p = ffi_cast("void *", a%d)]],
                                pos, i, pos, pos+1, i))
            pos = pos + 2
        else
            assert(false)
        end
    end
    return code
end

local function gen_fetch_service_fields(service_fields)
    local code = {}
    for i, field in ipairs(service_fields) do
        if field == 'boolean' then
            insert(code, format('x%d = r.t[%d] == 3', i, i))
        elseif field == 'int' then
            insert(code, format('x%d = tonumber(r.v[%d].ival)', i, i))
        elseif field == 'long' then
            insert(code, format('x%d = r.v[%d].ival', i, i))
        elseif field == 'float' or field == 'double' then
            insert(code, format('x%d = r.v[%d].dval', i, i))
        elseif field == 'string' or field == 'bytes' then
            insert(code, format([[
x%d = ffi_string(r.b1-r.v[%d].xoff, r.v[%d].xlen)]], i, i, i))
        else
            assert(false)
        end
    end
    return code
end

local expand_lua_template
local function gen_lua_code(args, il, il_code, service_fields)
    install_lua_backend(il, args)
    expand_lua_template = expand_lua_template or compile_template([=[
-- v2.1
local ffi        = require('ffi')
local bit        = require('bit')
local digest     = require('digest')
local rt         = require('avro_schema.runtime')
local pcall      = pcall
local bor, band  = bit.bor, bit.band
local lshift     = bit.lshift
local ffi_cast   = ffi.cast
local ffi_string = ffi.string
local rt_C       = ffi.load(rt.C_path)
local rt_regs          = rt.regs
local rt_buf_grow      = rt.buf_grow
local rt_err_type      = rt.err_type
local rt_err_length    = rt.err_length
local rt_err_missing   = rt.err_missing
local rt_err_duplicate = rt.err_duplicate
local rt_err_value     = rt.err_value
local cpool      = digest.base64_decode([[
${cpool_data}
]])
${outter_protos}
${outter_decls}
local function linker(decode_proc, encode_proc)
    decode_proc = decode_proc or rt.msgpack_decode
    encode_proc = encode_proc or rt.msgpack_encode
${inner_decls}
    return {
        flatten  = function(data${extra_params})
            return pcall(flatten, data${extra_params})
        end,
        unflatten  = function(data)
            return pcall(unflatten, data)
        end,
        xflatten  = function(data)
            return pcall(xflatten, data)
        end
    }
end
return linker
]=])
    local outter_protos = {}
    local outter_decls = {}
    local inner_decls = {}
    local n = #service_fields

    -- flatten
    local f_complete = gen_store_service_fields(service_fields)
    insert(f_complete, 'v0 = encode_proc(r, v0)')

    il.emit_lua_func(il_code[1], inner_decls, {
        func_decl = format('local function flatten(data%s)', param_list(n)),
        func_locals = 'local r, v0, v1',
        conversion_init = [[
        r = rt_regs; v1 = 0; v0 = 0
        decode_proc(r, data)
        r.b2 = ffi_cast("const uint8_t *", cpool) + #cpool]],
        conversion_complete = concat(f_complete, '\n'),
        func_return = 'return v0'
    })

    -- unflatten
    local u_complete = gen_fetch_service_fields(service_fields)
    insert(u_complete, 'v0 = encode_proc(r, v0)')

    il.emit_lua_func(il_code[2], inner_decls, {
        func_decl = 'local function unflatten(data)',
        func_locals = 'local r, v0, v1',
        nlocals_min = n,
        conversion_init = [[
r = rt_regs; v0 = 0; v1 = 0
decode_proc(r, data)
r.b2 = ffi_cast("const uint8_t *", cpool) + #cpool]],
        conversion_complete = concat(u_complete, '\n'),
        func_return = 'return v0' .. param_list(n, 'x'),
        iter_prolog = 'if _ < 16 then goto continue end' -- artificially bump iter count
    })

    -- xflatten
    il.emit_lua_func(il_code[3], inner_decls, {
        func_decl = 'local function xflatten(data)',
        func_locals = 'local r, v0, v1',
        conversion_init = format([[
r = rt_regs
decode_proc(r, data)
r.b2 = ffi_cast("const uint8_t *", cpool) + #cpool
r.k = %d; v0 = 0; v1 = 0]], n + 1),
        conversion_complete = [[
rt_C.schema_rt_xflatten_done(r, v0)
v0 = encode_proc(r, v0)]],
        func_return = 'return v0'
    })

    -- helper functions (if any)
    for i = 4, #il_code do
        local func = il_code[i]
        insert(outter_protos, format('local f%d', func[1].name))
        il.emit_lua_func(func, outter_decls)
    end

    return expand_lua_template({
        cpool_data = base64_encode(il.cpool_get_data()),
        extra_params = param_list(n),
        outter_protos = outter_protos,
        outter_decls = outter_decls,
        inner_decls = inner_decls
    })
end

-- service fields, a subset of AVRO types
local valid_service_field = {
    boolean = 1, int =    1, long =  1, float = 1,
    double =  1, string = 1, bytes = 1
}

-- compile(schema)
-- compile(schema1, schema2)
-- compile({schema1, schema2, downgrade = true, service_fields = { ... }})
local function compile(...)
    local n = select('#', ...)
    local args = { ... }
    local ok, ir
    if n == 1 and not is_schema(args[1]) then
        if type(args[1]) ~= 'table' then
            error('Expecting a schema or a table', 0)
        end
        n = select('#', unpack(args[1]))
        args = args[1]
    end
    local service_fields = args.service_fields or {}
    if type(service_fields) ~= 'table' then
        error('service_fields: Expecting a table', 0)
    end
    for i, field in ipairs(service_fields) do
        if not valid_service_field[field] then
            error(format('service_fields[%d]: Invalid type: %s', i, field), 0)
        end
    end
    local list = {}
    for i = 1, n do
        insert(list, get_schema(args[i]))
    end
    if #list == 0 then
        error('Expecting a schema', 0)
    elseif #list == 1 then
        ok, ir = get_ir(list[1], list[1])
    elseif #list == 2 then
        ok, ir = get_ir(list[1], list[2], args.downgrade)
    else
        assert(false, 'NYI: chain')
    end
    if not ok then
        return false, ir
    else
        local il = il_create()
        local debug = args.debug
        local ok, il_code = pcall(c_emit_code, il, ir, service_fields)
        if not ok then return false, il_code end
        if not debug then
            il_code = il.optimize(il_code)
        end
        local dump_il = args.dump_il
        if dump_il then
            local file = io.open(dump_il, 'w+')
            file:write(il.vis(il_code))
            file:close()
        end
        local lua_code, lua_args = gen_lua_code(args, il, il_code, service_fields)
        local dump_src = args.dump_src
        if dump_src then
            local file = io.open(dump_src, 'w+')
            file:write(lua_code)
            file:close()
        end
        local module, err     = loadstring(lua_code, '@<schema-jit>')
        if not module then error(err, 0) end
        local linker          = module(lua_args)
        local process_msgpack = linker(rt_universal_decode, rt_msgpack_encode)
        local process_lua     = linker(rt_universal_decode, rt_lua_encode)
        return true, {
            flatten           = process_lua.flatten,
            unflatten         = process_lua.unflatten,
            xflatten          = process_lua.xflatten,
            flatten_msgpack   = process_msgpack.flatten,
            unflatten_msgpack = process_msgpack.unflatten,
            xflatten_msgpack  = process_msgpack.xflatten
        }
    end
end

-----------------------------------------------------------------------
-- misc
local get_names_helper
get_names_helper = function(res, pos, names, rec)
    local fields = rec.fields
    for i = 1, #fields do
        local ftype = fields[i].type
        insert(names, fields[i].name)
        if type(ftype) == 'string' then
            res[pos] = concat(names, '.')
            pos = pos + 1
        elseif ftype.type == 'record' then
            pos = get_names_helper(res, pos, names, ftype)
        elseif not ftype.type then -- union
            local path = concat(names, '.')
            res[pos] = path .. '.$type$'
            res[pos + 1] = path
            pos = pos + 2
        else
            res[pos] = concat(names, '.')
            pos = pos + 1
        end
        remove(names)
    end
    return pos
end

local function get_names(schema_h)
    local schema = get_schema(schema_h)
    if type(schema) == 'table' and schema.type == 'record' then
        local res = {}
        local names = {}
        get_names_helper(res, 1, names, schema)
        return res
    else
        return {}
    end
end

local get_types_helper
get_types_helper = function(res, pos, rec)
    local fields = rec.fields
    for i = 1, #fields do
        local ftype = fields[i].type
        if type(ftype) == 'string' then
            res[pos] = ftype
            pos = pos + 1
        elseif ftype.type == 'record' then
            pos = get_types_helper(res, pos, ftype)
        elseif not ftype.type then -- union
            pos = pos + 2
        else
            res[pos] = ftype.name or ftype.type
            pos = pos + 1
        end
    end
    return pos
end

local function get_types(schema_h)
    local schema = get_schema(schema_h)
    if type(schema) == 'table' and schema.type == 'record' then
        local res = {}
        get_types_helper(res, 1, schema)
        return res
    else
        return {}
    end
end

local export_helper
export_helper = function(node, already_built)
    if type(node) ~= 'table' then
        return node
    elseif already_built[node] then
        return node.name
    else
        already_built[node] = true
        local res = {}
        for k, v in pairs(node) do
            res[k] = k == 'default' and v or export_helper(v, already_built)
        end
        return res
    end
end
local function export(schema_h)
    return export_helper(get_schema(schema_h), {})
end

return {
    are_compatible = are_compatible,
    create         = create,
    compile        = compile,
    get_names      = get_names,
    get_types      = get_types,
    is             = is_schema,
    validate       = validate,
    export         = export
}
