local insert = table.insert
local bnot = bit.bnot

local function ir_type(ir)
    return type(ir) == 'table' and ir[1] or ir
end

local function ir_record_bc(ir)
    assert(ir_type(ir) == 'RECORD')
    return ir[2]
end

local function ir_record_inames(ir)
    assert(ir_type(ir) == 'RECORD')
    return ir[3]
end

local function ir_record_i2o(ir)
    assert(ir_type(ir) == 'RECORD')
    return ir[4]
end

local function ir_record_onames(ir)
    assert(ir_type(ir) == 'RECORD')
    return ir[5]
end

-- ir_record_odefault(ir, o) -> schema?, val?
local function ir_record_odefault(ir, o)
    assert(ir_type(ir) == 'RECORD')
    local d = ir[6]
    if d then
        return d[bnot(o)], d[o]
    end
end

local function ir_record_ohidden(ir, o)
    assert(ir_type(ir) == 'RECORD')
    return ir[7] and ir[7][o]
end

local function ir_record_ioptional(ir, i)
    assert(ir_type(ir) == 'RECORD')
    return ir[4][i] == false
end

local ir_record_o2i_cache = setmetatable({}, { __mode = 'k' })

local function ir_record_o2i(ir)
    assert(ir_type(ir) == 'RECORD')
    local o2i = ir_record_o2i_cache[ir]
    if o2i then
        return o2i
    end
    o2i = {}
    local inames, i2o = ir[3], ir[4] 
    for i = 1, #inames do
        local o = i2o[i]
        if o then
            o2i[o] = i
        end
    end
    ir_record_o2i_cache[ir] = o2i
    return o2i
end

local function ir_fixed_size(ir)
    assert(ir_type(ir) == 'FIXED')
    return ir[2]
end

-----------------------------------------------------------------------
local schema2ilfunc = {
    null = 'putnulc', boolean = 'putboolc', int = 'putintc',
    long = 'putlongc', float = 'putfloatc', double = 'putdoublec',
    bytes = 'putbinc', string = 'putstrc'
}

local function prepare_default(il, schema, val)
    local ilfunc = schema2ilfunc[schema]
    if ilfunc then
        return il[ilfunc], val
    elseif schema.type == 'fixed' then
        return il.putstrc, val
    elseif schema.type == 'enum' then
        local symbols = schema.symbols
        for i = 1, #symbols do
            if symbols[i] == val then return il.putintc, i-1 end
        end
    end
    assert(false, 'NYI: complex default')
end

local function prepare_flat_default(il, schema, val)
    return prepare_default(il, schema, val) -- XXX
end

local prepare_flat_defaults_vec_helper
prepare_flat_defaults_vec_helper = function(il, schema, val, res, curcell)
    if     type(schema) == 'table' and schema.type == 'record' then
        local fields = schema.fields
        for i = 1, #fields do
            local field = fields[i]
            curcell = prepare_flat_defaults_vec_helper(
                il, field.type, val[field.name], res, curcell)
        end
        return curcell
    elseif type(schema) == 'table' and not schema.type then
        assert(false, 'NYI: union')
    else
        res[curcell * 2 - 1], res[curcell * 2] = prepare_flat_default(
            il, schema, val)
        return curcell + 1
    end
end
local function prepare_flat_defaults_vec(il, schema, val)
    local res = {}
    return prepare_flat_defaults_vec_helper(il, schema, val, res, 1) - 1, res
end

-----------------------------------------------------------------------

-- Emits code iterating a MAP or ARRAY at [$ipv + ipo].
-- Generated code assumes that object type (MAP/ARRAY) was already checked.
-- Handler emits the loop body; it receives the loop variable. 
-- The body is responsible for incrementing the loop variable.
-- Once the loop is complete, $ripv contains the position of
-- an element following MAP/ARRAY.
-- Nil $ripv or $ripv == $ipv are valid.
local function objforeach(il, ripv, ipv, ipo, handler)
    if ripv and ripv ~= ipv then
        return {
            {
                il.objforeach(ripv, ipv, ipo),
                (handler(ripv))
            },
            -- "loop variable has undefined value upon loop completion"
            il.skip(ripv, ipv, ipo)
        }
    else
        local lipv = il.id()
        return {
            il.beginvar(lipv),
            {
                il.objforeach(lipv, ipv, ipo),
                (handler(lipv))
            },
            -- "loop variable has undefined value upon loop completion"
            il.skip(ripv, ipv, ipo),
            il.endvar(lipv)
        }
    end
end

-- This table makes several functions below simple.
local ir2ilfuncs = {
    NUL      = { is = 'isnul',    put = 'putnulc' },
    BOOL     = { is = 'isbool',   put = 'putbool' },
    INT      = { is = 'isint',    put = 'putint' },
    LONG     = { is = 'islong',   put = 'putlong' },
    FLT      = { is = 'isfloat',  put = 'putfloat' },
    DBL      = { is = 'isdouble', put = 'putdouble' },
    BIN      = { is = 'isbin',    put = 'putbin' },
    STR      = { is = 'isstr',    put = 'putstr' },
    INT2LONG = { is = 'isint',    put = 'putint2long' },
    INT2FLT  = { is = 'isint',    put = 'putint2flt' },
    INT2DBL  = { is = 'isint',    put = 'putint2dbl' },
    LONG2FLT = { is = 'islong',   put = 'putlong2flt'},
    LONG2DBL = { is = 'islong',   put = 'putlong2dbl' },
    FLT2DBL  = { is = 'isfloat',  put = 'putflt2dbl' },
    BIN2STR  = { is = 'isbin',    put = 'putbin2str' },
    STR2BIN  = { is = 'isstr',    put = 'putstr2bin' }
}

-- Process an object at [$ipv + ipo] and store result at [$0 + opo].
-- Doesn't update $0. The function assumes that CHECKOBUF isn't necessary.
-- Stores next element's position in $ripv (if passed).
-- The only user is do_convert_record_flatten(); never used with complex types.
local function emit_patch(il, ir, ripv, ipv, ipo, opo)
    local irt = ir_type(ir)
    local ilfuncs = ir2ilfuncs[irt]
    if ilfuncs then
        return {
            il[ilfuncs.is]  (ipv, ipo),
            il[ilfuncs.put] (opo, ipv, ipo),
            il.move(ripv, ipv, ipo + 1)
        }
    elseif irt == 'FIXED' then
        return {
            il.isbin(ipv, ipo),
            il.lenis(ipv, ipo, ir_fixed_size(ir)),
            il.putbin(opo, ipv, ipo),
            il.move(ripv, ipv, ipo + 1)
        }
    elseif irt == 'ENUM' then
        return il.do_patch_enum(il, ir, ripv, ipv, ipo, opo)
    else
        assert(false, 'patch VLO') -- VLO, can't patch
    end
end

-- Check if an object's type at [$ipv + ipo] matches the IR.
-- This is a shallow check (
--   Ex: ir = {'ARRAY', ...}, check [$ipv + ipo] is an array, skip contents.)
-- Stores next element's position in $ripv (if passed).
local function emit_check(il, ir, ripv, ipv, ipo)
    local irt = ir_type(ir)
    local ilfuncs = ir2ilfuncs[irt]
    if ilfuncs then
        return {
            il[ilfuncs.is] (ipv, ipo),
            il.move(ripv, ipv, ipo + 1)
        }
    elseif irt == 'FIXED' then
        return {
            il.isbin(ipv, ipo),
            il.lenis(ipv, ipo, ir_fixed_size(ir)),
            il.move(ripv, ipv, ipo + 1)
        }
    elseif irt == 'ARRAY' then
        return {
            il.isarray(ipv, ipo),
            il.skip(ripv, ipv, ipo)
        }
    elseif irt == 'MAP' then
        return {
            il.ismap(ipv, ipo),
            il.skip(ripv, ipv, ipo)
        }
    elseif irt == 'UNION' then
        assert(false, 'NYI: union')
    elseif irt == 'RECORD' then
        assert(false, 'check record') -- should not happen
    elseif irt == 'ENUM' then
        return il.do_check_enum(il, ir, ripv, ipv, ipo)
    else
        assert(false)
    end
end

-- Unlike emit_check, performs deep validation (NYI).
-- The rules are the same.
local function emit_validate(il, ir, ripv, ipv, ipo)
    return emit_check(il, ir, ripv, ipv, ipo) -- XXX
end

-- Process an object at [$ipv + ipo] and store result at [$0].
-- Update $0. CHECKOBUF is necessary.
-- Stores next element's position in $ripv (if passed).
local emit_convert
emit_convert = function(il, ir, ripv, ipv, ipo, nowrap)
    local irt = ir_type(ir)
    local ilfuncs = ir2ilfuncs[irt]
    if ilfuncs then
        return {
            il[ilfuncs.is]  (ipv, ipo),
            il.checkobuf(1),
            il[ilfuncs.put] (0, ipv, ipo),
            il.move(0, 0, 1),
            il.move(ripv, ipv, ipo + 1)
        }
    elseif irt == 'FIXED' then
        return {
            { il.isbin(ipv, ipo), il.lenis(ipv, ipo, ir_fixed_size(ir)) },
            il.checkobuf(1),
            il.putbin(0, ipv, ipo),
            il.move(0, 0, 1),
            il.move(ripv, ipv, ipo + 1)
        }
    elseif irt == 'ARRAY' then
        return {
            il.isarray(ipv, ipo),
            il.checkobuf(1),
            il.putarray(0, ipv, ipo),
            il.move(0, 0, 1),
            objforeach(il, ripv, ipv, ipo, function(xipv)
                return emit_convert(il, ir[2], xipv, xipv, 0)
            end)
        }
    elseif irt == 'MAP' then
        return {
            il.ismap(ipv, ipo),
            il.checkobuf(1),
            il.putmap(0, ipv, ipo),
            il.move(0, 0, 1),
            objforeach(il, ripv, ipv, ipo, function(xipv)
                return {
                    il.isstr(xipv, 0),
                    il.checkobuf(1),
                    il.putstr(0, xipv, 0),
                    il.move(0, 0, 1),
                    emit_convert(il, ir[2], xipv, xipv, 1)
                }
            end)
        }
    elseif irt == 'UNION' then
        assert(false, 'NYI: union')
    elseif irt == 'RECORD' then
        return il.do_convert_record(il, ir, ripv, ipv, ipo, nowrap)
    elseif irt == 'ENUM' then
        return il.do_convert_enum(il, ir, ripv, ipv, ipo)
    else
        assert(false)
    end
end

-- Like emit_convert(), but may omit some checks since the element
-- was already checked (the check was shallow).
local function emit_convert_unchecked(il, ir, ripv, ipv, ipo, nowrap)
    local res = emit_convert(il, ir, ripv, ipv, ipo, nowrap)
    -- get rid of checks - emit_convert must cooperate
    -- also exploited by emit_rec_xflatten_pass2
    res[1] = il.nop()
    return res
end

-----------------------------------------------------------------------
-- RECORD, flatten

local do_convert_record_flatten_pass1
local do_convert_record_flatten_pass2
local do_convert_record_flatten_pass3
local function do_convert_record_flatten(il, ir, ripv, ipv, ipo, nowrap)
    assert(ir_type(ir) == 'RECORD')
    if nowrap ~= 'nowrap' then
        local code = emit_convert(il, ir, ripv, ipv, ipo, 'nowrap')
        return {
            il.checkobuf(0),
            il.putarrayc(0, il.ir_width[ir]),
            il.move(0, 0, 1),
            code
        }
    end
    local var_block, defaults = {}, {}
    local context = {
        il = il,
        defaults = defaults,   -- [celli * 2 - 1] il_put* func,
                               -- [celli * 2]     argument
        var_block = var_block, -- variable declarations
        vlocell = nil          -- first cell with a VLO
    }
    -- a shadow tree (keyed by o)
    -- used for inter-pass sharing
    -- after 1st pass contains 'direct write' cell indices,
    -- after 2nd - stores input vars
    -- (either directly or in [0] of a nested table)
    local tree = {}
    do_convert_record_flatten_pass1(context, ir, tree, 1)
    local init_block = {}
    for i = 1, context.vlocell - 1 do
        local ilfunc = defaults[i * 2 - 1]
        if ilfunc then
            insert(init_block, ilfunc(i - 1, defaults[i * 2]))
        end
    end
    local parser_block = do_convert_record_flatten_pass2(context, ir, tree,
                                                nil, ipv, ipo)
    local generator_block = do_convert_record_flatten_pass3(context, ir, tree, 1,
                                                   ipv, ipo)
    local vlocell = context.vlocell
    local maxcell = context.maxcell
    if vlocell == maxcell then -- update $0
        insert(generator_block, il.move(0, 0, vlocell - 1))
    end
    il.ir_width[ir] = maxcell - 1
    return {
        var_block,
        il.checkobuf(vlocell),
        init_block,
        parser_block,
        generator_block,
        il.skip(ripv, ipv, ipo)
    }
end

-- A subset of cells in the resulting flattened record
-- are at fixed offsets. Compute offsets allowing the parser
-- to store a value immediately instead of postponing until
-- the generation phase (important for optional fields -
-- eliminates one IF). Stop once we hit a VLO, like array.
--
-- Also compute default values to store in cells beforehand.
-- Computes context.vlocell - the index of the first cell hosting
-- a VLO.
do_convert_record_flatten_pass1 = function(context, ir, tree, curcell)
    local o2i, onames = ir_record_o2i(ir), ir_record_onames(ir)
    local bc = ir_record_bc(ir)
    local defaults = context.defaults
    for o = 1, #onames do
        local ds, dv = ir_record_odefault(ir, o)
        local dcells
        if ds then
            -- default value attached; it may expand into
            -- several cells (e.g. a nested record); it is
            -- also possible that there is no associated IR
            -- so we are going to increase curcell based on
            -- defaults alone (that's why we have dcells);
            -- finally if there is an IR it may define
            -- a different default value, overriding defaults
            -- we're preparing now
            local ddata
            dcells, ddata = prepare_flat_defaults_vec(context.il, ds, dv)
            for i = 1, dcells do
                defaults[ (curcell + i)*2 - 3 ] = ddata[ i * 2 - 1 ]
                defaults[ (curcell + i)*2 - 2 ] = ddata[ i * 2 ]
            end
        end
        local fieldir = bc[o2i[o]]
        if not fieldir then
            assert(dcells)
            curcell = curcell + dcells
        else
            local fieldirt
::restart::
            fieldirt = ir_type(fieldir)
            if type(fieldir) ~= 'table' or fieldirt == 'FIXED' or fieldirt == 'ENUM' then
                tree[o] = curcell - 1
                curcell = curcell + 1
            elseif fieldirt == 'RECORD' then
                local childtree = {}
                tree[o] = childtree
                if do_convert_record_flatten_pass1(context, fieldir,
                                          childtree, curcell) then
                    return true
                end
                curcell = context.vlocell
            elseif fieldirt == 'UNION' then
                assert(false, 'NYI')
                if ir_union_osimple(fieldir) then
                    -- union in source schema mapped to a simple type in target
                    fieldir = nil -- XXX
                    goto restart
                else
                    -- consider it VLO for simplicity (XXX simple optional fields?)
                    context.vlocell = curcell
                    return true
                end
            else
                -- ARRAY or MAP, it's a VLO
                context.vlocell = curcell
                return true
            end
        end
    end
    context.vlocell = curcell
    return false
end

-- Emit a parser code, uses offsets computed during pass1.
-- Allocates a variable to store position of each input field value.
-- Puts variable names in tree, replacing offsets (which are no longer needed).
do_convert_record_flatten_pass2 = function(context, ir, tree, ripv, ipv, ipo)
    local il = context.il
    local inames, i2o = ir_record_inames(ir), ir_record_i2o(ir)
    local code = {
        il.ismap(ipv, ipo),
        il.nop() -- the function passed to objforeach() below appends to code
    }
    code[2] = objforeach(il, ripv, ipv, ipo, function(xipv)
            local bc = ir_record_bc(ir)
            local var_block = context.var_block
            local switch = { il.strswitch(xipv, 0) }
            for i = 1, #inames do
                local fieldir = bc[i]
                local fieldirt = ir_type(fieldir)
                local o = i2o[i]
                local fieldvar = il.id()
                local targetcell = tree[o]
                insert(var_block, il.beginvar(fieldvar))
                local branch = {
                    il.sbranch(inames[i]),
                    il.isnotset(fieldvar),
                    il.move(fieldvar, xipv, 1)
                }
                if fieldirt == 'RECORD' and o then
                    local childtree = tree[o]
                    if not childtree then
                        childtree = {}
                        tree[o] = childtree
                    end
                    childtree[0] = fieldvar
                    insert(branch,
                           do_convert_record_flatten_pass2(context, fieldir, childtree,
                                                           xipv, xipv, 1))
                elseif fieldirt == 'UNION' then
                    assert(false, 'NYI')
                elseif targetcell then
                    tree[o] = fieldvar
                    insert(branch, emit_patch(il, fieldir, xipv, xipv, 1,
                                              targetcell))
                elseif o then
                    tree[o] = fieldvar
                    insert(branch, emit_check(il, fieldir, xipv, xipv, 1))
                else
                    insert(branch, emit_validate(il, fieldir, xipv, xipv, 1))
                    if not ir_record_ioptional(ir, i) then
                        -- we aren't going to see this var during pass3
                        insert(code, il.isset(fieldvar, ipv, ipo, inames[i]))
                        insert(code, il.endvar(fieldvar))
                    end
                end
                switch[i + 1] = branch
            end -- for i = 1, #inames do
            return { il.isstr(xipv, 0), switch }
    end)
    return code
end

-- Emit code generating the (flattened) output record.
-- Note: a subset of cells until the first VLO are already
-- filled at this point (defaults and/or values stored by the parser),
-- however $0 wasn't incremented yet.
-- Computes context.maxcell - total number of cells, plus 1.
do_convert_record_flatten_pass3 = function(context, ir, tree, curcell, ipv, ipo)
    local o2i, onames = ir_record_o2i(ir), ir_record_onames(ir)
    local bc = ir_record_bc(ir)
    local defaults = context.defaults
    local vlocell = context.vlocell
    local il = context.il
    local code = {}
    for o = 1, #onames do
        local ds, dv = ir_record_odefault(ir, o)
        local dcells
        local fieldvar = tree[o]
        if type(fieldvar) == 'table' then
            fieldvar = fieldvar[0]
        end
        local tbranch, fbranch
        if not fieldvar then
            fbranch = code
        elseif not ds then -- it's mandatory
            tbranch = {}
            insert(code, {
                il.isset(fieldvar, ipv, ipo, onames[o]),
                tbranch,
                il.endvar(fieldvar)
            })
        else
            tbranch = { il.ibranch(1) }
            fbranch = { il.ibranch(0) }
            insert(code, { il.ifset(fieldvar), tbranch, fbranch })
            insert(code, il.endvar(fieldvar))
        end
        -- fbranch - if field was missing from the input
        if ds then
            local ddata, didcross
            dcells, ddata = prepare_flat_defaults_vec(context.il, ds, dv)

            local dsplit -- a spliting point (before/after vlocell)
            if     curcell > vlocell then
                dsplit = 0
            elseif curcell + dcells <= vlocell then
                dsplit = dcells
            else
                dsplit = vlocell - curcell
                didcross = true
            end

            -- before vlocell; patch (unless the same value already stored)
            for i = 1, dsplit do
                local dcurcell = curcell + i - 1
                local ilfunc, arg = ddata[ i * 2 - 1 ], ddata[ i * 2 ]

                if ilfunc ~= defaults[ dcurcell * 2 - 1 ] or
                       arg ~= defaults[ dcurcell * 2 ] then

                    insert(fbranch, ilfunc(dcurcell - 1, arg))
                end
            end

            if dsplit ~= dcells then -- after vlocell; append
                if didcross then -- update $0
                    insert(fbranch, il.move(0, 0, vlocell - 1))
                end
                insert(fbranch, il.checkobuf(dcells - dsplit))
                for i = dsplit + 1, dcells do
                    local ilfunc, arg = ddata[ i * 2 - 1 ], ddata[ i * 2 ]
                    insert(fbranch, ilfunc(i - dsplit - 1, arg))
                end
                insert(fbranch, il.move(0, 0, dcells - dsplit))
            end
        end
        -- tbranch - if field was present in the input
        local fieldir = bc[o2i[o]]
        if not fieldir then
            curcell = curcell + dcells
        else
            local fieldirt
            fieldirt = ir_type(fieldir)
            if fieldirt == 'RECORD' then
                insert(tbranch, do_convert_record_flatten_pass3(context, fieldir,
                                                       tree[o], curcell,
                                                       fieldvar, 0))
                curcell = context.maxcell
            elseif fieldirt == 'UNION' then
                assert(false, 'NYI: union')
            elseif curcell >= vlocell then -- append
                if curcell == vlocell then -- update $0
                    insert(tbranch, il.move(0, 0, vlocell - 1))
                end
                insert(tbranch, emit_convert_unchecked(il, fieldir,
                                                       nil, fieldvar, 0))
                curcell = curcell + 1
            else -- curcell < vlocell, value already *patch*-ed in
                curcell = curcell + 1
            end
        end
    end
    context.maxcell = curcell
    return code
end

-----------------------------------------------------------------------
-- RECORD, unflatten

local do_convert_record_unflatten_pass1
local do_convert_record_unflatten_pass2
local do_convert_record_unflatten_pass3
local function do_convert_record_unflatten(il, ir, ripv, ipv, ipo, nowrap)
    assert(ir_type(ir) == 'RECORD')
    if nowrap ~= 'nowrap' then
        local code = emit_convert(il, ir, ripv, ipv, ipo+1, 'nowrap')
        return {
            il.isarray(ipv, ipo),
            il.lenis(ipv, ipo, il.ir_width[ir]),
            code
        }
    end
    if not ripv then
        ripv = il.id()
        return {
            il.beginvar(ripv),
            do_convert_record_unflatten(il, ir, ripv, ipv, ipo, 'nowrap'),
            il.endvar(ripv)
        }
    end
    local context = {
        il = il,
        ipv = ripv,
        fieldv = {},
        fieldo = {},
        lastref = {}
    }
    local tree = {}
    local code = {
        il.move(ripv, ipv, ipo),
        do_convert_record_unflatten_pass1(context, ir, tree, 1, false),
        do_convert_record_unflatten_pass2(context, ir, tree) and
            do_convert_record_unflatten_pass3(context, ir, tree)
    }
    il.ir_width[ir] = context.maxcell - 1
    return code
end

-- Pass1 generates code to check types in the input *flat* record.
-- The code also allocates variables to save positions of some
-- elements in the input. If there's a run of fixed size elements,
-- we save only the first element's postion (base); later ones
-- are accessed via base + offset. Variable names and offsets are
-- stored in ctx.fieldv/ctx.fieldo.
--
-- Both are keyed by *cellid* - i.e. the element's index in the flat
-- record. The routine also build a *tree* — a mapping from I (element's
-- IR index) to cellid.
--
-- Sometimes a field is *hidden*, i.e. excluded from the output.
-- In that case a slightly different logic applies (and often
-- fewer variables are needed).
do_convert_record_unflatten_pass1 = function(context, ir, tree, curcell, hidden)
    local bc, inames = ir_record_bc(ir), ir_record_inames(ir)
    local i2o = ir_record_i2o(ir)
    local il, ipv = context.il, context.ipv
    local fieldv, fieldo = context.fieldv, context.fieldo
    local code = {}
    for i = 1, #inames do
        local o = i2o[i]
        local fieldir = bc[i]
        local fieldirt = ir_type(fieldir)
        if fieldirt == 'RECORD' then
            local childtree = {}
            tree[i] = childtree
            insert(code,
                   do_convert_record_unflatten_pass1(context, fieldir,
                                                     childtree, curcell,
                                                     hidden or ir_record_ohidden(ir, o)))
            curcell = context.maxcell
        elseif fieldirt == 'UNION' then
            assert(false, 'NYI: union')
        elseif o and not hidden and not ir_record_ohidden(ir, o) then
            tree[i] = curcell
            local lastcell = context.lastcell
            if lastcell then
                fieldv[curcell] = fieldv[lastcell]
                fieldo[curcell] = curcell - lastcell
            else
                local fieldvar = il.id()
                insert(code, il.beginvar(fieldvar))
                insert(code, il.move(fieldvar, ipv, 0))
                fieldv[curcell] = fieldvar
                fieldo[curcell] = 0
                context.lastcell = curcell
            end
            insert(code, emit_check(context.il, fieldir,
                                    ipv, ipv, 0))
            curcell = curcell + 1
            if not ir2ilfuncs[fieldirt] then
                context.lastcell = nil -- VLO
            end
        else
            insert(code, emit_validate(context.il, fieldir,
                                       ipv, ipv, 0))
            curcell = curcell + 1 -- XXX union
            if not ir2ilfuncs[fieldirt] then -- XXX enum, fixed
                context.lastcell = nil -- VLO
            end
        end
    end
    context.maxcell = curcell
    return code
end

-- Walk the *tree* in the output order and fill *lastref*.
-- Lastref is the last cell that needs a variable. Once it's reached,
-- we ENDVAR the variable.
-- Note: we assume that if an elements is hidden, the fieldv/tree
-- entry is missing, hence it's unnecessary to check if it's hidden here.
do_convert_record_unflatten_pass2 = function(context, ir, tree)
    if not tree then return end
    local bc, onames = ir_record_bc(ir), ir_record_onames(ir)
    local o2i = ir_record_o2i(ir)
    local fieldv = context.fieldv
    local lastref = context.lastref
    for o = 1, #onames do
        local i = o2i[o]
        if i then
            local fieldir = bc[i]
            if ir_type(fieldir) == 'RECORD' then
                do_convert_record_unflatten_pass2(context, fieldir, tree[i])
            else
                local curcell = tree[i]
                local fieldvar = fieldv[curcell]
                if fieldvar then
                    lastref[fieldvar] = curcell
                end
            end
        end
    end
    return true
end

-- Emit the code producing the result. Straightforward.
do_convert_record_unflatten_pass3 = function(context, ir, tree)
    local bc, onames = ir_record_bc(ir), ir_record_onames(ir)
    local o2i = ir_record_o2i(ir)
    local il, fieldv, fieldo = context.il, context.fieldv, context.fieldo
    local lastref = context.lastref
    local maplen = 0
    local code = { il.checkobuf(1), il.nop(), il.move(0, 0, 1) }
    for o = 1, #onames do
        local i = o2i[o]
        if ir_record_ohidden(ir, o) then
            -- skip it
        elseif not i then
            -- put defaults
            local schema, val = ir_record_odefault(ir, o)
            local ilfunc, arg = prepare_default(il, schema, val)
            insert(code, {
                il.checkobuf(2),
                il.putstrc(0, onames[o]),
                ilfunc(1, arg),
                il.move(0, 0, 2)
            })
            maplen = maplen + 1
        else
            local fieldir = bc[i]
            local fieldirt = ir_type(fieldir)
            insert(code, {
                il.checkobuf(1),
                il.putstrc(0, onames[o]),
                il.move(0, 0, 1)
            })
            if fieldirt == 'RECORD' then
                insert(code, do_convert_record_unflatten_pass3(context, fieldir, tree[i]))
            elseif fieldirt == 'UNION' then
                assert(false, 'NYI: union')
            else
                local curcell = tree[i]
                local fieldvar = fieldv[curcell]
                insert(code, emit_convert_unchecked(il, fieldir, nil,
                                                    fieldvar,
                                                    fieldo[curcell]))
                if lastref[fieldvar] == curcell then
                    insert(code, il.endvar(fieldvar))
                end
            end
            maplen = maplen + 1
        end
    end
    code[2] = il.putmapc(0, maplen)
    return code
end

-----------------------------------------------------------------------
-- ENUM, flatten

-- Prepare a mapping table for PUTENUMS2I.
-- Do it once for each IR node, hence the cache.
local enum_flatten_cache = setmetatable({}, {__mode = 'k' })
local function enum_flatten_cache_get(ir)
    local tab = enum_flatten_cache[ir]
    if not tab then
        tab = {}
        local inames, i2o = ir[3], ir[4]
        for i = 1, #inames do
            tab[inames[i]] = (i2o[i] or 0) - 1
        end
        enum_flatten_cache[ir] = tab
    end
    return tab
end

local function do_patch_enum_flatten(il, ir, ripv, ipv, ipo, opo)
    return {
        il.isstr(ipv, ipo),
        il.putenums2i(opo, ipv, ipo, enum_flatten_cache_get(ir)),
        il.move(ripv, ipv, ipo + 1)
    }
end

local function do_check_enum_flatten(il, ir, ripv, ipv, ipo)
    return {
        il.isstr(ipv, ipo),
        il.move(ripv, ipv, ipo + 1)
    }
end

local function do_convert_enum_flatten(il, ir, ripv, ipv, ipo)
    return {
        il.isstr(ipv, ipo), -- MUST be #1, see emit_convert_unchecked()
        il.checkobuf(1),
        il.putenums2i(0, ipv, ipo, enum_flatten_cache_get(ir)),
        il.move(0, 0, 1),
        il.move(ripv, ipv, ipo + 1)
    }
end

-----------------------------------------------------------------------
-- ENUM, unflatten

-- Prepare a mapping table for PUTENUMI2S.
-- Do it once for each IR node, hence the cache.
local enum_unflatten_cache = setmetatable({}, {__mode = 'k' })
local function enum_unflatten_cache_get(ir)
    local tab = enum_unflatten_cache[ir]
    if not tab then
        tab = {}
        local n, i2o, onames = #ir[3], ir[4], ir[5]
        for i = 1, n do
            local o = i2o[i]
            tab[i] = o and onames[o] or ''
        end
        enum_unflatten_cache[ir] = tab
    end
    return tab
end

local function do_patch_enum_unflatten(il, ir, ripv, ipv, ipo, opo)
    return {
        il.isint(ipv, ipo),
        il.putenumi2s(opo, ipv, ipo, enum_unflatten_cache_get()),
        il.move(ripv, ipv, ipo + 1)
    }
end

local function do_check_enum_unflatten(il, ir, ripv, ipv, ipo)
    return {
        il.isint(ipv, ipo),
        il.move(ripv, ipv, ipo + 1)
    }
end

local function do_convert_enum_unflatten(il, ir, ripv, ipv, ipo)
    return {
        il.isint(ipv, ipo), -- MUST be #1, see emit_convert_unchecked()
        il.checkobuf(1),
        il.putenumi2s(0, ipv, ipo, enum_unflatten_cache_get(ir)),
        il.move(0, 0, 1),
        il.move(ripv, ipv, ipo + 1)
    }
end

-----------------------------------------------------------------------

local emit_rec_xflatten_pass1
local emit_rec_xflatten_pass2

local function emit_rec_xflatten(il, ir, n_svc_fields, ipv)
    assert(ir_type(ir) == 'RECORD')
    local counter = il.id()
    local var_block = {}
    local context = {
        il = il,
        n_svc_fields = n_svc_fields,
        var_block = var_block,
        counter = counter
    }
    local tree = {}
    emit_rec_xflatten_pass1(context, ir, tree, 1)
    return {
        il.beginvar(counter),
        var_block,
        emit_rec_xflatten_pass2(context, ir, tree, nil, ipv, 0),
        il.move(ipv, counter, 0)
    }
end

-- Creates the *tree*. Each node is keyed by the field number in
-- the output schema. For each key, a node stores the ID for UPDATE
-- or a nested node.
emit_rec_xflatten_pass1 = function(context, ir, tree, curcell)
    local o2i, onames = ir_record_o2i(ir), ir_record_onames(ir)
    local bc = ir_record_bc(ir)
    local n_svc_fields = context.n_svc_fields
    for o = 1, #onames do
        local fieldir = bc[o2i[o]]
        if not fieldir then
            local ds, dv = ir_record_odefault(ir, o)
            curcell = curcell + prepare_flat_defaults_vec(context.il, ds, dv)
        else
            local fieldirt
            tree[o] = curcell + n_svc_fields
            fieldirt = ir_type(fieldir)
            if     fieldirt == 'RECORD' then
                local ctree = {}
                tree[o] = ctree
                curcell = emit_rec_xflatten_pass1(context, fieldir,
                                                  ctree, curcell)
            elseif fieldirt == 'UNION' then
                assert(false, 'NYI: union')
            else
                curcell = curcell + 1
            end
        end
    end
    return curcell
end

-- Process input; output parts of the UPDATE statement immediately
-- after we encouter an object attribute (i.e. no reordering).
-- Fetches ID-s for UPDATE from the tree.
emit_rec_xflatten_pass2 = function(context, ir, tree, ripv, ipv, ipo)
    local il = context.il
    return {
        il.ismap(ipv, ipo),
        objforeach(il, ripv, ipv, ipo, function(xipv)
            local inames, bc = ir_record_inames(ir), ir_record_bc(ir)
            local i2o = ir_record_i2o(ir)
            local var_block = context.var_block
            local counter = context.counter
            local switch = { il.strswitch(xipv, 0) }
            for i = 1, #inames do
                local fieldir = bc[i]
                local fieldirt = ir_type(fieldir)
                local o = i2o[i]
                local fieldvar = il.id()
                local targetcell = tree[o]
                insert(var_block, il.beginvar(fieldvar))
                local branch = {
                    il.sbranch(inames[i]),
                    il.isnotset(fieldvar),
                    il.move(fieldvar, xipv, 1)
                }
                if fieldirt == 'RECORD' and o then
                    insert(branch, emit_rec_xflatten_pass2(context, fieldir,
                                                           tree and tree[o],
                                                           xipv, fieldvar, 0))
                elseif fieldirt == 'UNION' then
                    assert(false, 'NYI')
                elseif o then
                    -- Note: this code motion is harmless
                    -- (see emit_conver/emit_convert_unchecked);
                    -- allows to keep CHECKOBUF optimiser simple
                    -- (CHECKOBUF can't move past typecheck.)
                    local convert = emit_convert(il, fieldir, xipv, xipv, 1)
                    local typecheck = convert[1]
                    convert[1] = il.nop()
                    insert(branch, {
                        typecheck,
                        il.checkobuf(3),
                        il.putarrayc(0, 3),
                        il.putstrc(1, '='),
                        il.putintc(2, tree[o]),
                        il.move(counter, counter, 1),
                        il.move(0, 0, 3),
                        convert
                    })
                else
                    insert(branch, emit_validate(il, fieldir, xipv, xipv, 1))
                end
                switch[i + 1] = branch
            end -- for i = 1, #inames do
            return { il.isstr(xipv, 0), switch }
        end)
    }
end

local function emit_code(il, ir, n_svc_fields)
    local flatten = { il.declfunc(1, 1) }
    local unflatten = { il.declfunc(2, 1) }
    local xflatten = { il.declfunc(3,1) }
    local il_funcs = { flatten, unflatten, xflatten } -- backends expect this
                                                      -- particular order
    il.il_funcs = il_funcs
    -- configure for unflatten
    local ir_width_unflatten = {}
    il.ir_width = ir_width_unflatten
    il.do_convert_record = do_convert_record_unflatten
    il.do_patch_enum = do_patch_enum_unflatten
    il.do_check_enum = do_check_enum_unflatten
    il.do_convert_enum = do_convert_enum_unflatten
    unflatten[2] = emit_convert(il, ir, 1, 1, 0, 'nowrap')
    -- configure for flatten / xflatten
    local ir_width_flatten = {}
    il.ir_width = ir_width_flatten
    il.do_convert_record = do_convert_record_flatten
    il.do_patch_enum = do_patch_enum_flatten
    il.do_check_enum = do_check_enum_flatten
    il.do_convert_enum = do_convert_enum_flatten
    flatten[2] = emit_convert(il, ir, nil, 1, 0, 'nowrap')
    if ir_type(ir) == 'RECORD' then
        xflatten[2] = emit_rec_xflatten(il, ir, n_svc_fields, 1)
    end
    -- remove cruft
    il.il_funcs = nil
    il.ir_width = nil
    il.do_convert_record = nil
    il.do_patch_enum = nil
    il.do_check_enum = nil
    il.do_convert_enum = nil

    return il.cleanup(il_funcs),
           ir_width_unflatten[ir] or 1,
           ir_width_flatten[ir] or 1
end

-----------------------------------------------------------------------
return {
    emit_code          = emit_code, 
    do_convert_record_flatten   = do_convert_record_flatten,
    do_convert_record_unflatten = do_convert_record_unflatten,
    emit_rec_xflatten  = emit_rec_xflatten
}
