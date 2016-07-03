local ffi            = require('ffi')
local json           = require('json')
local msgpack        = require('msgpack')
local json_encode    = json and json.encode
local msgpack_decode = msgpack and msgpack.decode
local ffi_new        = ffi.new
local format, rep    = string.format, string.rep
local insert, remove = table.insert, table.remove
local concat         = table.concat

ffi.cdef([[
struct schema_il_Opcode {
    struct {
        uint16_t op;
        union {
            uint16_t scale;
            uint16_t step;
        };
    };
    union {
        uint32_t ripv;
        uint32_t offset;
        uint32_t name;
        uint32_t len;
    };
    union {
        struct {
            uint32_t ipv;
            uint32_t ipo;
        };
        int32_t  ci;
        int64_t  cl;
        double   cd;
    };

    // block
    static const int CALLFUNC    = 0xc0;
    static const int DECLFUNC    = 0xc1;
    static const int IBRANCH     = 0xc2;
    static const int SBRANCH     = 0xc3;
    static const int IFSET       = 0xc4;
    static const int IFNUL       = 0xc5;
    static const int INTSWITCH   = 0xc6;
    static const int STRSWITCH   = 0xc7;
    // ripv ipv ipo
    static const int OBJFOREACH  = 0xc8; // last block
    static const int MOVE        = 0xc9;
    static const int SKIP        = 0xca;
    static const int PSKIP       = 0xcb;

    static const int PUTBOOLC    = 0xcc;
    static const int PUTINTC     = 0xcd;
    static const int PUTLONGC    = 0xce;
    static const int PUTFLOATC   = 0xcf;
    static const int PUTDOUBLEC  = 0xd0;
    static const int PUTSTRC     = 0xd1;
    static const int PUTBINC     = 0xd2;
    static const int PUTARRAYC   = 0xd3;
    static const int PUTMAPC     = 0xd4;
    static const int PUTXC       = 0xd5;
    static const int PUTNULC     = 0xd6;

    static const int PUTBOOL     = 0xd7;
    static const int PUTINT      = 0xd8;
    static const int PUTLONG     = 0xd9;
    static const int PUTFLOAT    = 0xda;
    static const int PUTDOUBLE   = 0xdb;
    static const int PUTSTR      = 0xdc;
    static const int PUTBIN      = 0xdd;
    static const int PUTARRAY    = 0xde;
    static const int PUTMAP      = 0xdf;
    static const int PUTINT2LONG = 0xe0;
    static const int PUTINT2FLT  = 0xe1;
    static const int PUTINT2DBL  = 0xe2;
    static const int PUTLONG2FLT = 0xe3;
    static const int PUTLONG2DBL = 0xe4;
    static const int PUTFLT2DBL  = 0xe5;
    static const int PUTSTR2BIN  = 0xe6;
    static const int PUTBIN2STR  = 0xe7;

    static const int PUTENUMI2S  = 0xe8;
    static const int PUTENUMS2I  = 0xe9;

    /* rt.err_type depends on these values */
    static const int ISBOOL      = 0xea;
    static const int ISINT       = 0xeb;
    static const int ISFLOAT     = 0xec;
    static const int ISDOUBLE    = 0xed;
    static const int ISLONG      = 0xee;
    static const int ISSTR       = 0xef;
    static const int ISBIN       = 0xf0;
    static const int ISARRAY     = 0xf1;
    static const int ISMAP       = 0xf2;
    static const int ISNUL       = 0xf3;
    static const int ISNULORMAP  = 0xf4;

    static const int LENIS       = 0xf5;

    static const int ISSET       = 0xf6;
    static const int ISNOTSET    = 0xf7;
    static const int BEGINVAR    = 0xf8;
    static const int ENDVAR      = 0xf9;

    static const int CHECKOBUF   = 0xfa;

    static const int ERRVALUEV   = 0xfb;

    static const unsigned NILREG  = 0xffffffff;
};

struct schema_il_V {
    union {
        uint64_t     raw;
        struct {
            uint32_t gen    :30;
            uint32_t islocal:1;
            uint32_t isdead :1;
            uint32_t inc;
        };
    };
};

]])

local opcode = ffi_new('struct schema_il_Opcode')

local op2str = {
    [opcode.CALLFUNC   ] = 'CALLFUNC   ',   [opcode.DECLFUNC   ] = 'DECLFUNC   ',
    [opcode.IBRANCH    ] = 'IBRANCH    ',   [opcode.SBRANCH    ] = 'SBRANCH    ',
    [opcode.IFSET      ] = 'IFSET      ',   [opcode.IFNUL      ] = 'IFNUL      ',
    [opcode.INTSWITCH  ] = 'INTSWITCH  ',   [opcode.STRSWITCH  ] = 'STRSWITCH  ',
    [opcode.OBJFOREACH ] = 'OBJFOREACH ',   [opcode.MOVE       ] = 'MOVE       ',
    [opcode.SKIP       ] = 'SKIP       ',   [opcode.PSKIP      ] = 'PSKIP      ',
    [opcode.PUTBOOLC   ] = 'PUTBOOLC   ',   [opcode.PUTINTC    ] = 'PUTINTC    ',
    [opcode.PUTLONGC   ] = 'PUTLONGC   ',   [opcode.PUTFLOATC  ] = 'PUTFLOATC  ',
    [opcode.PUTDOUBLEC ] = 'PUTDOUBLEC ',   [opcode.PUTSTRC    ] = 'PUTSTRC    ',
    [opcode.PUTBINC    ] = 'PUTBINC    ',   [opcode.PUTARRAYC  ] = 'PUTARRAYC  ',
    [opcode.PUTMAPC    ] = 'PUTMAPC    ',   [opcode.PUTXC      ] = 'PUTXC      ',
    [opcode.PUTNULC    ] = 'PUTNULC    ',   [opcode.PUTBOOL    ] = 'PUTBOOL    ',
    [opcode.PUTINT     ] = 'PUTINT     ',   [opcode.PUTLONG    ] = 'PUTLONG    ',
    [opcode.PUTFLOAT   ] = 'PUTFLOAT   ',   [opcode.PUTDOUBLE  ] = 'PUTDOUBLE  ',
    [opcode.PUTSTR     ] = 'PUTSTR     ',   [opcode.PUTBIN     ] = 'PUTBIN     ',
    [opcode.PUTARRAY   ] = 'PUTARRAY   ',   [opcode.PUTMAP     ] = 'PUTMAP     ',
    [opcode.PUTINT2LONG] = 'PUTINT2LONG',   [opcode.PUTINT2FLT ] = 'PUTINT2FLT ',
    [opcode.PUTINT2DBL ] = 'PUTINT2DBL ',   [opcode.PUTLONG2FLT] = 'PUTLONG2FLT',
    [opcode.PUTLONG2DBL] = 'PUTLONG2DBL',   [opcode.PUTFLT2DBL ] = 'PUTFLT2DBL ',
    [opcode.PUTSTR2BIN ] = 'PUTSTR2BIN ',   [opcode.PUTBIN2STR ] = 'PUTBIN2STR ',
    [opcode.PUTENUMI2S ] = 'PUTENUMI2S ',   [opcode.PUTENUMS2I ] = 'PUTENUMS2I ',
    [opcode.ISBOOL     ] = 'ISBOOL     ',   [opcode.ISINT      ] = 'ISINT      ',
    [opcode.ISLONG     ] = 'ISLONG     ',   [opcode.ISFLOAT    ] = 'ISFLOAT    ',
    [opcode.ISDOUBLE   ] = 'ISDOUBLE   ',   [opcode.ISSTR      ] = 'ISSTR      ',
    [opcode.ISBIN      ] = 'ISBIN      ',   [opcode.ISARRAY    ] = 'ISARRAY    ',
    [opcode.ISMAP      ] = 'ISMAP      ',   [opcode.ISNUL      ] = 'ISNUL      ',
    [opcode.ISNULORMAP ] = 'ISNULORMAP ',   [opcode.LENIS      ] = 'LENIS      ',
    [opcode.ISSET      ] = 'ISSET      ',   [opcode.ISNOTSET   ] = 'ISNOTSET   ',
    [opcode.BEGINVAR   ] = 'BEGINVAR   ',   [opcode.ENDVAR     ] = 'ENDVAR     ',
    [opcode.CHECKOBUF  ] = 'CHECKOBUF  ',   [opcode.ERRVALUEV  ] = 'ERRVALUEV  '
}

local function opcode_new(op)
    local o = ffi_new('struct schema_il_Opcode')
    if op then o.op = op end
    return o
end

local opcode_NOP = opcode_new(opcode.MOVE); opcode_NOP.ripv = opcode.NILREG

local function opcode_ctor_ipv(op)
    return function(ipv)
        local o = ffi_new('struct schema_il_Opcode')
        o.op = op; o.ipv = ipv
        return o
    end
end

local function opcode_ctor_ipv_ipo(op)
    return function(ipv, ipo)
        local o = ffi_new('struct schema_il_Opcode')
        o.op = op; o.ipv = ipv; o.ipo = ipo
        return o
    end
end

local function opcode_ctor_ripv_ipv_ipo(op)
    return function(ripv, ipv, ipo)
        local o = ffi_new('struct schema_il_Opcode')
        o.op = op; o.ripv = ripv or opcode.NILREG
        o.ipv = ipv; o.ipo = ipo
        return o
    end
end

local function opcode_ctor_offset_ipv_ipo(op)
    return function(offset, ipv, ipo)
        local o = ffi_new('struct schema_il_Opcode')
        o.op = op; o.offset = offset; o.ipv = ipv; o.ipo = ipo
        return o
    end
end

local function opcode_ctor_offset_ci(op)
    return function(offset, ci)
        local o = ffi_new('struct schema_il_Opcode')
        o.op = op; o.offset = offset; o.ci = ci or 42
        return o
    end
end

local il_methods = {
    nop = function() return opcode_NOP end,
    ----------------------------------------------------------------
    declfunc = function(name, ipv)
        local o = opcode_new(opcode.DECLFUNC)
        o.name = name; o.ipv = ipv
        return o
    end,
    ibranch = function(ci)
        local o = opcode_new(opcode.IBRANCH)
        o.ci = ci
        return o
    end,
    ifset       = opcode_ctor_ipv         (opcode.IFSET),
    ifnul       = opcode_ctor_ipv_ipo     (opcode.IFNUL),
    intswitch   = opcode_ctor_ipv_ipo     (opcode.INTSWITCH),
    strswitch   = opcode_ctor_ipv_ipo     (opcode.STRSWITCH),
    objforeach  = opcode_ctor_ripv_ipv_ipo(opcode.OBJFOREACH),
    ----------------------------------------------------------------
    move        = opcode_ctor_ripv_ipv_ipo(opcode.MOVE),
    skip        = opcode_ctor_ripv_ipv_ipo(opcode.SKIP),
    pskip       = opcode_ctor_ripv_ipv_ipo(opcode.PSKIP),
    ----------------------------------------------------------------
    putboolc    = function(offset, cb)
        local o = opcode_new(opcode.PUTBOOLC)
        o.offset = offset; o.ci = cb and 1 or 0
        return o
    end,
    putintc     = opcode_ctor_offset_ci(opcode.PUTINTC),
    putlongc = function(offset, cl)
        local o = opcode_new(opcode.PUTLONGC)
        o.offset = offset; o.cl = cl
        return o
    end,
    putfloatc   = function(offset, cf)
        local o = opcode_new(opcode.PUTFLOATC)
        o.offset = offset; o.cd = cf
        return o
    end,
    putdoublec  = function(offset, cd)
        local o = opcode_new(opcode.PUTDOUBLEC)
        o.offset = offset; o.cd = cd
        return o
    end,
    putarrayc   = opcode_ctor_offset_ci(opcode.PUTARRAYC),
    putmapc     = opcode_ctor_offset_ci(opcode.PUTMAPC),
    putnulc = function(offset)
        local o = opcode_new(opcode.PUTNULC)
        o.offset = offset
        return o
    end,
    ----------------------------------------------------------------
    putbool     = opcode_ctor_offset_ipv_ipo(opcode.PUTBOOL),
    putint      = opcode_ctor_offset_ipv_ipo(opcode.PUTINT),
    putlong     = opcode_ctor_offset_ipv_ipo(opcode.PUTLONG),
    putfloat    = opcode_ctor_offset_ipv_ipo(opcode.PUTFLOAT),
    putdouble   = opcode_ctor_offset_ipv_ipo(opcode.PUTDOUBLE),
    putstr      = opcode_ctor_offset_ipv_ipo(opcode.PUTSTR),
    putbin      = opcode_ctor_offset_ipv_ipo(opcode.PUTBIN),
    putarray    = opcode_ctor_offset_ipv_ipo(opcode.PUTARRAY),
    putmap      = opcode_ctor_offset_ipv_ipo(opcode.PUTMAP),
    putint2long = opcode_ctor_offset_ipv_ipo(opcode.PUTINT2LONG),
    putint2flt  = opcode_ctor_offset_ipv_ipo(opcode.PUTINT2FLT),
    putint2dbl  = opcode_ctor_offset_ipv_ipo(opcode.PUTINT2DBL),
    putlong2flt = opcode_ctor_offset_ipv_ipo(opcode.PUTLONG2FLT),
    putlong2dbl = opcode_ctor_offset_ipv_ipo(opcode.PUTLONG2DBL),
    putflt2dbl  = opcode_ctor_offset_ipv_ipo(opcode.PUTFLT2DBL),
    putstr2bin  = opcode_ctor_offset_ipv_ipo(opcode.PUTSTR2BIN),
    putbin2str  = opcode_ctor_offset_ipv_ipo(opcode.PUTBIN2STR),
    ----------------------------------------------------------------
    isbool      = opcode_ctor_ipv_ipo(opcode.ISBOOL),
    isint       = opcode_ctor_ipv_ipo(opcode.ISINT),
    islong      = opcode_ctor_ipv_ipo(opcode.ISLONG),
    isfloat     = opcode_ctor_ipv_ipo(opcode.ISFLOAT),
    isdouble    = opcode_ctor_ipv_ipo(opcode.ISDOUBLE),
    isstr       = opcode_ctor_ipv_ipo(opcode.ISSTR),
    isbin       = opcode_ctor_ipv_ipo(opcode.ISBIN),
    isarray     = opcode_ctor_ipv_ipo(opcode.ISARRAY),
    ismap       = opcode_ctor_ipv_ipo(opcode.ISMAP),
    isnul       = opcode_ctor_ipv_ipo(opcode.ISNUL),
    isnulormap  = opcode_ctor_ipv_ipo(opcode.ISNULORMAP),
    ----------------------------------------------------------------
    lenis = function(ipv, ipo, len)
        local o = opcode_new(opcode.LENIS)
        o.ipv = ipv; o.ipo = ipo; o.len = len
        return o
    end,
    ----------------------------------------------------------------
    isnotset    = opcode_ctor_ipv(opcode.ISNOTSET),
    beginvar    = opcode_ctor_ipv(opcode.BEGINVAR),
    endvar      = opcode_ctor_ipv(opcode.ENDVAR),
    ----------------------------------------------------------------
    checkobuf = function(offset, ipv, ipo, scale)
        local o = opcode_new(opcode.CHECKOBUF)
        o.offset = offset; o.ipv = ipv or opcode.NILREG
        o.ipo = ipo or 0; o.scale = scale or 1
        return o
    end,
    errvaluev  = opcode_ctor_ipv_ipo(opcode.ERRVALUEV)
    ----------------------------------------------------------------
    -- callfunc, sbranch, putstrc, putbinc, putxc and isset
    -- are instance methods
}

-- visualize register
local function rvis(reg, inc)
    if reg == opcode.NILREG then
        return '_'
    elseif not inc or inc == 0 then
        return '$'..reg
    else
        return format('$%d+%d', reg, inc)
    end
end

-- visualize constant
local function cvis(o, extra, decode)
    if extra then
        local c = extra[o]
        if c then
            local ok, res = true, c
            if decode then
                ok, res = pcall(decode, c)
            end
            if ok then
                ok, res = pcall(json_encode, res)
            end
            if ok then
                return res
            end
        end
    end
    return format('#%p', o)
end

-- visualize opcode
local function opcode_vis(o, extra)
    local opname = op2str[o.op]
    if o == opcode_NOP then
        return 'NOP'
    elseif o.op == opcode.CALLFUNC then
        return format('%s %s,\t%s,\tFUNC<%s>', opname,
                      rvis(o.ripv), rvis(o.ipv, o.ipo), extra[o])
    elseif o.op == opcode.DECLFUNC then
        return format('%s %d,\t%s', opname, o.name, rvis(o.ipv))
    elseif o.op == opcode.IBRANCH then
        return format('%s %d', opname, o.ci)
    elseif o.op == opcode.SBRANCH then
        return format('%s %s', opname, cvis(o, extra))
    elseif o.op == opcode.IFSET or (
           o.op >= opcode.ISNOTSET and o.op <= opcode.ENDVAR) then
        return format('%s %s', opname, rvis(o.ipv))
    elseif (o.op >= opcode.IFNUL and o.op <= opcode.STRSWITCH) or
           (o.op >= opcode.ISBOOL and o.op <= opcode.ISNULORMAP) or
           o.op == opcode.ERRVALUEV then
        return format('%s [%s]', opname, rvis(o.ipv, o.ipo))
    elseif o.op == opcode.OBJFOREACH then
        return format('%s %s,\t[%s],\t%d', opname, rvis(o.ripv), rvis(o.ipv, o.ipo), o.step)
    elseif o.op == opcode.MOVE then
        return format('%s %s,\t%s', opname, rvis(o.ripv), rvis(o.ipv, o.ipo))
    elseif o.op == opcode.ISSET then
        return format('%s %s,\t%s,\t%s', opname, rvis(o.ripv), rvis(o.ipv, o.ipo), cvis(o, extra))
    elseif o.op == opcode.SKIP or o.op == opcode.PSKIP then
        return format('%s %s,\t[%s]', opname, rvis(o.ripv), rvis(o.ipv, o.ipo))
    elseif o.op == opcode.PUTBOOLC or o.op == opcode.PUTINTC or
           o.op == opcode.PUTARRAYC or o.op == opcode.PUTMAPC then
        return format('%s [%s],\t%d', opname, rvis(0, o.offset), o.ci)
    elseif o.op == opcode.PUTLONGC then
        return format('%s [%s],\t%s', opname, rvis(0, o.offset), o.cl)
    elseif o.op == opcode.PUTFLOATC or o.op == opcode.PUTDOUBLEC then
        return format('%s [%s],\t%f', opname, rvis(0, o.offset), o.cd)
    elseif o.op == opcode.PUTNULC then
        return format('%s [%s]', opname, rvis(0, o.offset))
    elseif o.op == opcode.PUTSTRC or o.op == opcode.PUTBINC then
        return format('%s [%s],\t%s', opname, rvis(0, o.offset), cvis(o, extra))
    elseif o.op == opcode.PUTXC then
        return format('%s [%s],\t%s', opname, rvis(0, o.offset), cvis(o, extra, msgpack_decode))
    elseif o.op >= opcode.PUTBOOL and o.op <= opcode.PUTBIN2STR then
        return format('%s [%s],\t[%s]', opname, rvis(0, o.offset), rvis(o.ipv, o.ipo))
    elseif o.op == opcode.PUTENUMI2S or o.op == opcode.PUTENUMS2I then
        return format('%s [%s],\t[%s],\t%s', opname,
                      rvis(0, o.offset), rvis(o.ipv, o.ipo), cvis(o, extra))
    elseif o.op == opcode.LENIS then
        return format('%s [%s],\t%d', opname, rvis(o.ipv, o.ipo), o.len)
    elseif o.op == opcode.CHECKOBUF then
        return format('%s %s,\t[%s],\t%d', opname, rvis(0, o.offset), rvis(o.ipv, o.ipo), o.scale)
    else
        return format('<opcode: %d>', o.op)
    end
end

-- visualize IL code
local il_vis_helper
il_vis_helper = function(res, il, indentcache, level, object)
    if not object then -- pass
    elseif type(object) == 'table' then
        local start = 1
        if level ~= 0 or type(object[1]) ~= 'table' then
            il_vis_helper(res, il, indentcache, level, object[1])
            start = 2
            level = level + 1
        end
        for i = start, #object do
            il_vis_helper(res, il, indentcache, level, object[i])
        end
    else
        local indent = indentcache[level]
        if not indent then
            indent = '\n'..rep('  ', level)
            indentcache[level] = indent
        end
        insert(res, indent)
        insert(res, il.opcode_vis(object))
    end
end
local function il_vis(il, root)
    local res = {}
    il_vis_helper(res, il, {}, 0, root)
    if res[1] == '\n' then res[1] = '' end
    insert(res, '\n')
    return concat(res)
end

-- cleanup IL:
--  (*) fix incorrect lists nesting
--  (*) remove NOPS and MOVEs assigning to NILREG
--  (*) remove redundant IFs
local il_cleanup_helper
il_cleanup_helper = function(res, object)
    if type(object) == 'table' then
        local head = object[1]
        if type(head) == 'cdata' and
           head.op >= opcode.DECLFUNC and head.op <= opcode.OBJFOREACH then
            local nested = { head }
            for i = 2, #object do
                il_cleanup_helper(nested, object[i])
            end
            if nested[2] or head.op == opcode.DECLFUNC then
                insert(res, nested) -- keep nested block IFF it's not empty
            end
        else
            for i = 1, #object do
                il_cleanup_helper(res, object[i])
            end
        end
    elseif object.op < opcode.MOVE and object.op > opcode.PSKIP or
           object.ripv ~= opcode.NILREG then
        insert(res, object) -- elide NOPs (NOP is MOVE to NILREG)
    end
end
local function il_cleanup(object)
    local res = {}
    il_cleanup_helper(res, object)
    return res
end

-- === Basic optimization engine in less than 450 LOC. ===
--
-- Elide some MOVE $reg, $reg+offset instructions.
-- Combine COBs (CHECKOBUFs) and hoist them out of loops.
--
-- We track variable state in a 'scope' data structure.
-- A scope is a dict keyed by a variable name. Scopes are chained
-- via 'parent' key. The lookup starts with the outter-most scope
-- and walks the chain until the entry is found.
--
-- The root scope is created upon entering DECLFUNC. When optimiser
-- encounters a nested block, it adds another scope on top of the chain
-- and invokes itself recursively. Once the block is done, the child
-- scope is removed.
--
-- When a variable value is updated in a program (e.g. assignment),
-- the updated entry is created in the outter-most scope, shadowing
-- any entry in parent scopes. Once a block is complete, the outermost
-- scope has all variable changes captured. These changes are merged
-- with the parent scope.
--
-- Variable state is <gen, inc, islocal, isdead> tuple. Variables are
-- scoped lexically; if a variable is marked local it is skipped when
-- merging with the parent scope. Codegen may explicitly shorten variable
-- lifetime with a ENDVAR instruction. Once a variable is dead its value
-- is no longer relevant. Valid code MUST never reference a dead variable.
--
-- Note: ENDVAR affects the code following the instruction (in a depth-first
--       tree walk order.) E.g. if the first branch in a conditional
--       declares a variable dead, it affects subsequent branches as well.
--
-- Concerning gen and inc.
--
-- Gen is a generation counter. If a variable X is updated
-- in such a way that new(X) = old(X) + C, the instruction is elided
-- and C is added to inc while gen is unchanged. Those we call 'dirty'
-- variables. If a variable is updated in a different fashion, including
-- but not limited to copying another variable's value, i.e. X = Y, we
-- declare that a new value is unrelated to the old one. Gen is assigned
-- a new unique id, and inc is set to 0.
--
-- Surprisingly, this simple framework is powerful enough to determine
-- if a loop proceeds in fixed increments (capture variable state
-- at the begining of the loop body and at the end and compare gen-s.)

local function vlookup(scope, vid)
    if not scope then
        assert(false, format('$%d not found', vid)) -- assume correct code
    end
    local res = scope[vid]
    if res then
        if res.isdead == 1 then
            assert(false, format('$%d is dead', vid)) -- assume correct code
        end
        return res
    end
    return vlookup(scope.parent, vid)
end

local function vcreate(scope, vid)
    local v = scope[vid]
    if not v then
        v = ffi_new('struct schema_il_V')
        scope[vid] = v
    end
    return v
end

local function vsnapshot(scope, vid)
    local v = scope[vid]
    if v then
        local copy = ffi_new('struct schema_il_V')
        copy.raw = v.raw
        return copy
    else -- in outter scope, virtually immutable
        return vlookup(scope.parent, vid)
    end
end

-- 'execute' an instruction and update scope
local function vexecute(il, scope, o, res)
    assert(type(o)=='cdata')
    if o.op == opcode.MOVE and o.ripv == o.ipv then
       local vinfo = vlookup(scope, o.ipv)
       local vnewinfo = vcreate(scope, o.ipv)
       vnewinfo.gen = vinfo.gen
       vnewinfo.inc = vinfo.inc + o.ipo
       return
    end
    if o.op == opcode.BEGINVAR then
        local vinfo = vcreate(scope, o.ipv)
        vinfo.islocal = 1
        insert(res, o)
        return
    end
    if o.op == opcode.ENDVAR then
        local vinfo = vcreate(scope, o.ipv)
        vinfo.isdead = 1
        insert(res, o)
        return
    end
    local fixipo = 0
    if (o.op == opcode.CALLFUNC or
        o.op >= opcode.IFNUL and o.op <= opcode.PSKIP or
        o.op >= opcode.PUTBOOL and o.op <= opcode.ISSET or
        o.op == opcode.CHECKOBUF or o.op == opcode.ERRVALUEV) and
       o.ipv ~= opcode.NILREG then

        local vinfo = vlookup(scope, o.ipv)
        fixipo = vinfo.inc
    end
    local fixoffset = 0
    if o.op >= opcode.PUTBOOLC and o.op <= opcode.PUTENUMS2I or
       o.op == opcode.CHECKOBUF then

        local vinfo = vlookup(scope, 0)
        fixoffset = vinfo.inc
    end
    -- spill $0
    if o.op == opcode.CALLFUNC then
        local vinfo = vlookup(scope, 0)
        if vinfo.inc > 0 then
            insert(res, il.move(0, 0, vinfo.inc))
        end
        vinfo = vcreate(scope, 0)
        vinfo.gen = il.id()
        vinfo.inc = 0
    end
    -- apply fixes
    o.ipo = o.ipo + fixipo
    o.offset = o.offset + fixoffset
    insert(res, o)
    if (o.op == opcode.CALLFUNC or
        o.op >= opcode.OBJFOREACH and o.op <= opcode.PSKIP) and
       o.ripv ~= opcode.NILREG then
        local vinfo = vcreate(scope, o.ripv)
        vinfo.gen = il.id()
        vinfo.inc = 0
    end
end

-- Merge branches (conditional or switch);
-- if branches had diverged irt $r, spill $r
-- (e.g. one did $1 = $1 + 2 while another didn't touch $1 at all)
-- Note: bscopes[1]/bblocks[1] are unused, indices start with 2.
local function vmergebranches(il, bscopes, bblocks)
    local parent = bscopes[2].parent
    local skip = { parent = true } -- vids to skip: dead or diverged
    local maybediverged = {}
    local diverged = {}
    local counters = {} -- how many branches have it, if < #total then diverged
    local nscopes = #bscopes
    for i = 2, nscopes do
        for vid, vinfo in pairs(bscopes[i]) do
            counters[vid] = (counters[vid] or 1) + 1
            if vinfo.islocal == 0 and not skip[vid] then
                local vother = maybediverged[vid]
                if vinfo.isdead == 1 then
                    skip[vid] = true
                    diverged[vid] = nil
                    maybediverged[vid] = nil
                    vcreate(parent, vid).isdead = 1 
                elseif not vother then
                    maybediverged[vid] = vinfo
                elseif vother.raw ~= vinfo.raw then
                    skip[vid] = true
                    maybediverged[vid] = nil
                    diverged[vid] = true
                end
            end
        end
    end
    for vid, vinfo in pairs(maybediverged) do
        if counters[vid] ~= nscopes then
            diverged[vid] = true
        else
            local vpinfo = vcreate(parent, vid)
            vpinfo.gen = vinfo.gen
            vpinfo.inc = vinfo.inc
        end
    end
    for vid, _ in pairs(diverged) do
        local vpinfo = vcreate(parent, vid)
        vpinfo.gen = il.id()
        vpinfo.inc = 0
        for i = 2, nscopes do
            local vinfo = bscopes[i][vid]
            if vinfo and vinfo.inc > 0 then
                insert(bblocks[i], il.move(vid, vid, vinfo.inc))
            end
        end
    end
    return diverged
end

-- Collect variables modified by the given code block.
local vvarschanged_cache = setmetatable({}, { __mode = 'k' })
local vvarschanged
vvarschanged = function(block)
    local res = vvarschanged_cache[block]
    if res then return res end
    assert(type(block) == 'table')
    res = {}
    local locals = {}
    for i = 1, #block do
        local item = block[i]
        if type(item) == 'table' then
            local nested = vvarschanged(item)
            for vid, _ in pairs(nested) do
                res[vid] = true
            end
        elseif item.op == opcode.CALLFUNC then
            res[0] = true
        elseif item.op >= opcode.OBJFOREACH and item.op <= opcode.PSKIP then
            res[item.ripv] = true
        elseif item.op == opcode.BEGINVAR then
            locals[item.ipv] = true
        end
    end
    for vid, _ in pairs(locals) do
        res[vid] = nil
    end
    vvarschanged_cache[block] = res
    return res
end

-- Spill 'dirty' variables that are modified in a loop body
-- before entering the loop.
local function vprepareloop(il, scope, lblock, block)
    local changed = vvarschanged(lblock)
    for vid, _ in pairs(changed) do
        local vinfo = vlookup(scope, vid)
        if vinfo.inc > 0 then
            insert(block, il.move(vid, vid, vinfo.inc))
            local info = vcreate(scope, vid)
            info.gen = il.id()
            info.inc = 0
        end
    end
end

-- Spill 'dirty' variables at the end of a loop body.
local function vmergeloop(il, lscope, lblock)
    local parent = lscope.parent
    for vid, vinfo in pairs(lscope) do
        if vinfo ~= parent and vinfo.islocal == 0 then
            local vpinfo = vcreate(parent, vid)
            vpinfo.gen = il.id()
            vpinfo.inc = 0
            if vinfo.inc > 0 then
                insert(lblock, il.move(vid, vid, vinfo.inc))
            end
        end
    end
end

-- Whether or not it is valid to move a COB across the specified
-- code range. If start is non-nil block[start] is assumed to be
-- another COB we are attempting to merge with.
local vcobmotionvalid
vcobmotionvalid = function(block, cob, start, stop)
    if cob.ipv == opcode.NILREG then
        return true
    else
        local t = block[start]
        if t and t.ipv ~= opcode.NILREG then
            return false -- they won't merge
        end
    end
    for i = start or 1, stop or #block do
        local o = block[i]
        if type(o) == 'table' then
            if not vcobmotionvalid(o, cob) then
                return false
            end
        elseif o.op == opcode.ISMAP or o.op == opcode.ISARRAY then
            -- we lack alias analysis; it's unsafe to move past ANY typecheck
            return false
        elseif o.op >= opcode.OBJFOREACH and o.op <= opcode.PSKIP and
               o.ripv == cob.ipv then
            -- it modifies the variable
            return false
        end
    end
    return true
end

-- Merge 2 COBs, update a.
local function vcobmerge(a, b)
    if a.offset < b.offset then
        a.offset = b.offset
    end
    if b.ipv ~= opcode.NILREG then
        assert(a.ipv == opcode.NILREG)
        a.ipv = b.ipv
        a.ipo = b.ipo
        a.scale = b.scale
    end
end

-- Here be dragons.
local voptimizeblock
voptimizeblock = function(il, scope, block, res)
    -- COB hoisting state
    local entryv0sn = vsnapshot(scope, 0) -- $0 at block start
    local firstcobpos, firstcobv0sn -- first COB (if any), will attempt
                                    -- to pop it into the parent
    local cobpos, cobv0sn, cobfixup -- 'active' COB, when we encounter
                                    -- another COB, we attempt to merge

    for i = 2, #block do -- foreach item in the current block, excl. head
        local o = block[i]
        if type(o) == 'cdata' then -- Opcode
            vexecute(il, scope, o, res)
            if o.op == opcode.CHECKOBUF then
                local v0info = vlookup(scope, 0)
                if not cobv0sn or v0info.gen ~= cobv0sn.gen or
                   not vcobmotionvalid(res, o, cobpos) then
                    -- no active COB or merge imposible: activate current COB
                    cobpos = #res
                    cobv0sn = vsnapshot(scope, 0)
                    if not firstcobpos then
                        firstcobpos = cobpos
                        firstcobv0sn = cobv0sn 
                    end
                    cobfixup = 0
                else
                    -- update active COB and drop the current one
                    o.offset = o.offset + cobfixup
                    vcobmerge(o, res[cobpos])
                    res[cobpos] = o
                    remove(res)
                end
            end
        else
            local head = o[1]
            if head.op >= opcode.IFSET and head.op <= opcode.STRSWITCH then
                -- branchy things: conditions and switches
                local bscopes = {0}
                local bblocks = {head}
                local cobhoistable, cobmaxoffset = 0, 0
                for i = 2, #o do
                    local branch = o[i]
                    local bscope = { parent = scope }
                    local bblock = { branch[1] }
                    voptimizeblock(il, bscope, branch, bblock)
                    bscopes[i] = bscope
                    bblocks[i] = bblock
                    -- update hoistable COBs counter
                    local cob = bblock[0]
                    if cob and cob.ipv == opcode.NILREG then
                        cobhoistable = cobhoistable + 1
                        if cob.offset > cobmaxoffset then
                            cobmaxoffset = cob.offset
                        end
                    end
                end
                -- a condition has 2 branches, though empty ones are omitted;
                -- if it's the case temporary restore the second branch
                -- for the vmergebranches() to consider this execution path
                if #o == 2 and (head.op == opcode.IFSET or
                                head.op == opcode.IFNUL) then
                    bscopes[3] = { parent = scope }
                end
                vmergebranches(il, bscopes, bblocks)
                insert(res, bblocks)
                -- hoist COBs but only if at least half of the branches will
                -- benefit
                if cobhoistable >= #bblocks/2 then
                    for i = 2, #bblocks do
                        local bblock = bblocks[i]
                        local pos = bblock[-1]
                        if pos and bblock[0].ipv == opcode.NILREG then
                            remove(bblock, pos)
                        end
                    end
                    local o = il.checkobuf(cobmaxoffset)
                    local v0info = vlookup(scope, 0)
                    if not cobv0sn or v0info.gen ~= cobv0sn.gen or
                       not vcobmotionvalid(res, o, cobpos) then
                        -- no active COB or merge imposible: activate current
                        cobpos = #res
                        cobv0sn = vsnapshot(scope, 0)
                        if not firstcobpos then
                            firstcobpos = cobpos
                            firstcobv0sn = cobv0sn 
                        end
                        cobfixup = 0
                        insert(res, cobpos, o)
                    else
                        -- update active COB and drop the current one
                        o.offset = o.offset + cobfixup
                        vcobmerge(o, res[cobpos])
                        res[cobpos] = o
                    end
                end
            elseif head.op == opcode.OBJFOREACH then
                -- loops
                local v0bsn = vsnapshot(scope, 0) -- used by COB hoisting
                vprepareloop(il, scope, o, res)
                local v0asn = vsnapshot(scope, 0) -- used by COB hoisting
                local lscope = { parent = scope }
                local lblock = {}
                vexecute(il, lscope, head, lblock)
                local ivinfo = lscope[head.ripv]
                local ivgen = ivinfo.gen
                voptimizeblock(il, lscope, o, lblock)
                if ivinfo.gen == ivgen then
                    -- loop variable incremented in fixed steps
                    head.step = ivinfo.inc
                    lscope[head.ripv] = nil
                    local vinfo = vcreate(scope, head.ripv)
                    vinfo.gen = il.id()
                    vinfo.inc = 0
                end
                vmergeloop(il, lscope, lblock)
                insert(res, lblock)
                local cob = lblock[0]
                if cob then -- attempt COB hoisting
                    local v0info = vlookup(lscope, 0)
                    if v0info.gen ~= v0asn.gen or
                       v0info.inc == v0asn.inc then
                        -- hoisting failed: $0 is non-linear or
                        -- doesn't change at all
                    else
                        remove(lblock, lblock[-1])
                        cob.offset = 0
                        cob.ipv = head.ipv
                        cob.ipo = head.ipo
                        cob.scale = v0info.inc --[[ - v0asn.inc
                            but the later == 0, vprepareloop() spilled it ]]
                        if not cobv0sn or v0bsn.gen ~= cobv0sn.gen or
                           not vcobmotionvalid(res, cob, cobpos) then
                            -- no active COB or merge imposible:
                            -- activate current one
                            cobfixup = 0
                            cobpos = #res
                            cobv0sn = vsnapshot(scope, 0)
                            if not firstcobpos then
                                firstcobpos = cobpos
                                firstcobv0sn = cobv0sn
                            end
                            insert(res, cobpos, cob)
                        else
                            -- update active COB and drop the current one;
                            -- changing cobv0sn here is a hack
                            -- enabling to move COBs across (some) loops.
                            -- Basically when moving COB we must compensate
                            -- for $0 changing. Due to limitations in the
                            -- variable state tracking, it looks as if $0
                            -- value before and after the loop are unrelated.
                            -- In fact, after($0) = before($0) + k*x.
                            cobfixup = v0bsn.inc - cobv0sn.inc
                            cob.offset = cobfixup
                            vcobmerge(cob, res[cobpos])
                            cobv0sn = vsnapshot(scope, 0)
                            res[cobpos] = cob
                        end
                    end
                end
            else
                assert(false)
            end
        end
    end
    -- Add missing ENDVARs.
    for vid, vinfo in pairs(scope) do
        if vid ~= 'parent' and vinfo.islocal == 1 and vinfo.isdead == 0 then
            insert(res, il.endvar(vid))
        end
    end
    -- Attempt to pop the very first COB into the parent.
    if firstcobpos and firstcobv0sn.gen == entryv0sn.gen and
       vcobmotionvalid(res, res[firstcobpos], nil, firstcobpos) then
        -- There was a COB and the code motion was valid.
        -- Create a copy of the COB with adjusted offset and save it in res[0].
        -- If the parent decides to accept, it has to remove a now redundant
        -- COB at firstcobpos.
        local o = res[firstcobpos]
        res[0] = il.checkobuf(o.offset + firstcobv0sn.inc - entryv0sn.inc,
                               o.ipv, o.ipo, o.scale)
        res[-1] = firstcobpos
    end
end

local function voptimizefunc(il, func)
    local head, scope = func[1], {}
    local res = { head }
    local r0 = vcreate(scope, 0)
    local r1 = vcreate(scope, head.ipv)
    voptimizeblock(il, scope, func, res)
    if r0.inc > 0 then
        insert(res, il.move(0, 0, r0.inc))
    end
    if r1.inc > 0 then
        insert(res, il.move(head.ipv, head.ipv, r1.inc))
    end
    return res
end

local function voptimize(il, code)
    local res = {}
    for i = 1, #code do
        res[i] = voptimizefunc(il, code[i])
    end
    return res
end

local function il_create()

    local extra = {}
    local id = 10 -- low ids are reserved

    local il
    il = setmetatable({
        callfunc = function(ripv, ipv, ipo, func)
            local o = opcode_new(opcode.CALLFUNC)
            o.ripv = ripv; o.ipv = ipv; o.ipo = ipo
            extra[o] = func
            return o
        end,
        ----------------------------------------------------------------
        sbranch = function(cs)
            local o = opcode_new(opcode.SBRANCH)
            extra[o] = cs
            return o
        end,
        putstrc = function(offset, cs)
            local o = opcode_new(opcode.PUTSTRC)
            o.offset = offset; extra[o] = cs
            return o
        end,
        putbinc = function(offset, cb)
            local o = opcode_new(opcode.PUTBINC)
            o.offset = offset; extra[o] = cb
            return o
        end,
        putxc = function(offset, cx)
            local o = opcode_new(opcode.PUTXC)
            o.offset = offset; extra[o] = cx
            return o
        end,
        putenums2i = function(offset, ipv, ipo, tab)
            local o = opcode_new(opcode.PUTENUMS2I)
            o.offset = offset; o.ipv = ipv; o.ipo = ipo
            extra[o] = tab
            return o
        end,
        putenumi2s = function(offset, ipv, ipo, tab)
            local o = opcode_new(opcode.PUTENUMI2S)
            o.offset = offset; o.ipv = ipv; o.ipo = ipo
            extra[o] = tab
            return o
        end,
        isset = function(ripv, ipv, ipo, cs)
            local o = opcode_new(opcode.ISSET)
            o.ripv = ripv; o.ipv = ipv
            o.ipo = ipo; extra[o] = cs
            return o
        end,
    ----------------------------------------------------------------
        id = function() id = id + 1; return id end,
        get_extra = function(o)
            return extra[o]
        end,
        vis = function(code) return il_vis(il, code) end,
        opcode_vis = function(o)
            return opcode_vis(o, extra)
        end,
        cleanup = il_cleanup,
        optimize = function(code) return voptimize(il, code) end,
    }, { __index = il_methods })
    return il
end

return {
    il_create = il_create
}
