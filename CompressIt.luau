--!strict
--!native
--!optimize 2

local ENABLE_IMMEDIATE_INTS   = true
local ENABLE_IMMEDIATE_STR    = true
local ENABLE_SUBTYPE_NUMBERS  = true
local ENABLE_ZIGZAG_ENCODING  = true
local ENABLE_VARINT_ENCODING  = true
local ENABLE_STRING_INTERNING = true
local ENABLE_SPARSE_ARRAY     = true
local ENABLE_KEY_CACHE        = true

local FORMAT_VERSION: number = 0x01

-- Constants
local TAG_NIL        : number = 0x00
local TAG_FALSE      : number = 0x01
local TAG_TRUE       : number = 0x02
local TAG_ZERO       : number = 0x03
local TAG_IMM_INT_BASE : number = 0x10
local TAG_IMM_INT_MIN  : number = 0x10
local TAG_IMM_INT_MAX  : number = 0x4F  -- 0x10 + 63
local TAG_U8         : number = 0x50
local TAG_I16        : number = 0x51
local TAG_I32        : number = 0x52
local TAG_F64        : number = 0x53
local TAG_IMM_STR_BASE : number = 0x60
local TAG_IMM_STR_MIN  : number = 0x60
local TAG_IMM_STR_MAX  : number = 0x8F  -- 0x60 + 47
local TAG_STR_VAR    : number = 0x90   -- Varint-prefixed, not interned
local TAG_STR_NEW    : number = 0x91   -- First occurrence — intern it
local TAG_STR_REF    : number = 0x92   -- Back-reference by varint ID
local TAG_ARRAY      : number = 0xA0
local TAG_MAP        : number = 0xA1
local TAG_SPARSE     : number = 0xA2
local TAG_VEC2       : number = 0xB0
local TAG_VEC3       : number = 0xB1
local TAG_COLOR3     : number = 0xB2
local TAG_CFRAME     : number = 0xB3   -- pos(3×f32) + quat(4×f32) = 28 bytes
local TAG_BRICKCOLOR : number = 0xB4   -- u16 palette index
local TAG_UDIM       : number = 0xB5   -- scale(f32) + offset(i16) × 2
local TAG_UDIM2      : number = 0xB6   -- 2× UDim inlined
local TAG_ENUMITEM   : number = 0xB7   -- class(STR_NEW|STR_REF) + name(STR_NEW|STR_REF)
local TAG_RECT       : number = 0xB8   -- 4×f32
local TAG_NUMRANGE   : number = 0xB9   -- 2×f32
local TAG_DATETIME   : number = 0xBA   -- i64 (Unix epoch seconds)
local TAG_NUMSEQ     : number = 0xC0   -- u16 count + keypoints (t:f32, v:f32, w:f32)
local TAG_COLSEQ     : number = 0xC1   -- u16 count + keypoints (t:f32, r:f32, g:f32, b:f32, interp:u8)
local TAG_RAW_BUFFER : number = 0xF0
local MAX_DEPTH        : number = 64
local MAX_ITEMS        : number = 1_000_000
local IMM_INT_RANGE    : number = 64      -- 0..63 in ZigZag space → -32..31
local IMM_STR_MAX_LEN  : number = 47      -- 48 slots in opcode
local U8_MAX           : number = 255
local I16_MIN          : number = -32768
local I16_MAX          : number = 32767
local I32_MIN          : number = -2147483648
local I32_MAX          : number = 2147483647
local SPARSE_THRESHOLD : number = 0.5
local INTERN_MAX       : number = 65535   -- varint IDs stay ≤ 3 bytes in practice
local MAX_INTERN_LEN   : number = 255
-- Decision Stack sizing: each entry is 1 byte (tag) stored sequentially.
-- Worst case: every value is a decision. 1 M items cap → 1 MB stack.
local DECISION_POOL_INIT : number = 4096

local function VarintSize(n: number): number
    if n < 0x80 then return 1 end
    if n < 0x4000 then return 2 end
    if n < 0x200000 then return 3 end
    if n < 0x10000000 then return 4 end
    return 5
end

local function WriteVarint(buf: buffer, off: number, n: number): number
    while n >= 0x80 do
        buffer.writeu8(buf, off, bit32.bor(bit32.band(n, 0x7F), 0x80))
        off += 1
        n = bit32.rshift(n, 7)
    end
    buffer.writeu8(buf, off, n)
    return off + 1
end

local function ReadVarint(buf: buffer, off: number): (number, number)
    local result: number = 0
    local shift: number  = 0
    local bufLen: number = buffer.len(buf)
    while true do
        if off >= bufLen then
            error("CompressIt: varint truncated at offset " .. off)
        end
        local byte: number = buffer.readu8(buf, off)
        off += 1
        result = bit32.bor(result, bit32.lshift(bit32.band(byte, 0x7F), shift))
        if bit32.band(byte, 0x80) == 0 then
            break
        end
        shift += 7
        if shift > 35 then
            error("CompressIt: varint overflow (>5 bytes)")
        end
    end
    return result, off
end

-- zigzag doggy mommy
local function ZigZagEncode(n: number): number
    -- Maps: 0→0, -1→1, 1→2, -2→3, 2→4, ...
    if n >= 0 then
        return n * 2
    else
        return (-n) * 2 - 1
    end
end

local function ZigZagDecode(z: number): number
    if bit32.band(z, 1) == 0 then
        return bit32.rshift(z, 1)
    else
        return -bit32.rshift(z + 1, 1)
    end
end

local function MatrixToQuat(
    r00: number, r01: number, r02: number,
    r10: number, r11: number, r12: number,
    r20: number, r21: number, r22: number
): (number, number, number, number)
    local trace: number = r00 + r11 + r22

    local qw: number, qx: number, qy: number, qz: number

    if trace > 0 then
        local s: number = 0.5 / math.sqrt(trace + 1.0)
        qw = 0.25 / s
        qx = (r21 - r12) * s
        qy = (r02 - r20) * s
        qz = (r10 - r01) * s
    elseif r00 > r11 and r00 > r22 then
        local s = 2.0 * math.sqrt(1.0 + r00 - r11 - r22)
        qw = (r21 - r12) / s
        qx = 0.25 * s
        qy = (r01 + r10) / s
        qz = (r02 + r20) / s
    elseif r11 > r22 then
        local s = 2.0 * math.sqrt(1.0 + r11 - r00 - r22)
        qw = (r02 - r20) / s
        qx = (r01 + r10) / s
        qy = 0.25 * s
        qz = (r12 + r21) / s
    else
        local s = 2.0 * math.sqrt(1.0 + r22 - r00 - r11)
        qw = (r10 - r01) / s
        qx = (r02 + r20) / s
        qy = (r12 + r21) / s
        qz = 0.25 * s
    end

    return qw, qx, qy, qz
end

local function QuatToCFrame(px: number, py: number, pz: number,
    qw: number, qx: number, qy: number, qz: number): CFrame
    local inv: number = 1.0 / math.sqrt(qw*qw + qx*qx + qy*qy + qz*qz)
    qw *= inv; qx *= inv; qy *= inv; qz *= inv

    local xx = qx*qx; local yy = qy*qy; local zz = qz*qz
    local xy = qx*qy; local xz = qx*qz; local yz = qy*qz
    local wx = qw*qx; local wy = qw*qy; local wz = qw*qz

    return CFrame.new(
        px, py, pz,
        1 - 2*(yy+zz),  2*(xy-wz),      2*(xz+wy),
        2*(xy+wz),       1 - 2*(xx+zz),  2*(yz-wx),
        2*(xz-wy),       2*(yz+wx),      1 - 2*(xx+yy)
    )
end

local function BrickColorToIndex(bc: BrickColor): number
    return (bc :: any).Number :: number
end


local ds_buf   : buffer  = buffer.create(DECISION_POOL_INIT)
local ds_cap   : number  = DECISION_POOL_INIT
local ds_write : number  = 0   -- write head (Probe)
local ds_read  : number  = 0   -- read head  (Encoder)

local function ds_reset(): void
    ds_write = 0
    ds_read  = 0
end

local function ds_push(tag: number): void
    if ds_write >= ds_cap then
        local newCap: number = ds_cap * 2
        local newBuf: buffer = buffer.create(newCap)
        buffer.copy(newBuf, 0, ds_buf, 0, ds_cap)
        ds_buf = newBuf
        ds_cap = newCap
    end
    buffer.writeu8(ds_buf, ds_write, tag)
    ds_write += 1
end

local function ds_pop(): number
    local tag: number = buffer.readu8(ds_buf, ds_read)
    ds_read += 1
    return tag
end

local function ds_pushU32(v: number): void

    if ds_write + 4 > ds_cap then
        local newCap: number = math.max(ds_cap * 2, ds_write + 4)
        local newBuf: buffer = buffer.create(newCap)
        buffer.copy(newBuf, 0, ds_buf, 0, ds_cap)
        ds_buf = newBuf
        ds_cap = newCap
    end
    buffer.writeu32(ds_buf, ds_write, v)
    ds_write += 4
end

local function ds_popU32(): number
    local v: number = buffer.readu32(ds_buf, ds_read)
    ds_read += 4
    return v
end


local intern_map   : {[string]: number} = {}
local intern_count : number             = 0

local function intern_reset(): void
    intern_map   = {}
    intern_count = 0
end


local key_cache     : {[string]: string} = {}
local key_cache_size: number             = 0
local KEY_CACHE_MAX : number             = 512

do
    if ENABLE_KEY_CACHE then
        setmetatable(key_cache, { __mode = "v" } :: any)
    end
end



local _typeof = typeof  -- cache global

local function classifyRblxType(val: any): string
    return _typeof(val) :: string
end


local function ProbeValue(val: any, depth: number): number
    if depth > MAX_DEPTH then
        error("CompressIt: max nesting depth (" .. MAX_DEPTH .. ") exceeded")
    end

    local t: string = type(val)

    -- nil 
    if t == "nil" then
        ds_push(TAG_NIL)
        return 1

        -- boolean
    elseif t == "boolean" then
        ds_push(val and TAG_TRUE or TAG_FALSE)
        return 1

        -- number
    elseif t == "number" then
        if ENABLE_SUBTYPE_NUMBERS then
            if val == 0 then
                ds_push(TAG_ZERO)
                return 1
            end

            local floor: number = math.floor(val)
            if val == floor then
                -- Integer path
                if ENABLE_ZIGZAG_ENCODING and ENABLE_IMMEDIATE_INTS then
                    local zz: number = ZigZagEncode(val)
                    if zz < IMM_INT_RANGE then
                        ds_push(TAG_IMM_INT_BASE + zz)
                        return 1  -- tag only, no payload
                    end
                end

                if val >= 0 and val <= U8_MAX then
                    ds_push(TAG_U8)
                    return 1 + 1  -- tag + 1 byte
                elseif val >= I16_MIN and val <= I16_MAX then
                    ds_push(TAG_I16)
                    return 1 + 2
                elseif val >= I32_MIN and val <= I32_MAX then
                    ds_push(TAG_I32)
                    return 1 + 4
                end
            end
        end

        -- Default: f64
        ds_push(TAG_F64)
        return 1 + 8

        -- string
    elseif t == "string" then
        local len: number = #val

        if ENABLE_STRING_INTERNING and len > 0 and len <= MAX_INTERN_LEN then
            local existingId: number? = intern_map[val]
            if existingId then
                -- Back
                ds_push(TAG_STR_REF)
                ds_pushU32(existingId)
                return 1 + VarintSize(existingId)
            else

                if intern_count < INTERN_MAX then
                    local id: number = intern_count
                    intern_map[val] = id
                    intern_count += 1

                    ds_push(TAG_STR_NEW)
                    ds_pushU32(len)  -- encoder will read this back
                    return 1 + VarintSize(len) + len
                end
            end
        end

        if ENABLE_IMMEDIATE_STR and len <= IMM_STR_MAX_LEN then
            ds_push(TAG_IMM_STR_BASE + len)
            return 1 + len  -- tag encodes length; payload is raw bytes
        else
            ds_push(TAG_STR_VAR)
            return 1 + VarintSize(len) + len
        end

        -- vector3
    elseif t == "vector" then
        ds_push(TAG_VEC3)
        return 1 + 12  -- 3×f32

        -- buffer
    elseif t == "buffer" then
        local len: number = buffer.len(val)
        ds_push(TAG_RAW_BUFFER)
        return 1 + VarintSize(len) + len

        -- table
    elseif t == "table" then
        local rtype: string = _typeof(val)

        if rtype == "Vector2" then
            ds_push(TAG_VEC2)
            return 1 + 8  -- 2×f32

        elseif rtype == "Vector3" then
            ds_push(TAG_VEC3)
            return 1 + 12

        elseif rtype == "Color3" then
            ds_push(TAG_COLOR3)
            return 1 + 12 

        elseif rtype == "CFrame" then
            ds_push(TAG_CFRAME)
            return 1 + 28

        elseif rtype == "BrickColor" then
            ds_push(TAG_BRICKCOLOR)
            return 1 + 2  

        elseif rtype == "UDim" then
            ds_push(TAG_UDIM)
            return 1 + 8

        elseif rtype == "UDim2" then
            ds_push(TAG_UDIM2)
            return 1 + 16

        elseif rtype == "EnumItem" then

            ds_push(TAG_ENUMITEM)
            local className: string = (val :: any).Class :: string
            local enumName:  string = (val :: any).Name  :: string
            local size: number = 1  -- tag only
            size += ProbeValue(className, depth + 1)
            size += ProbeValue(enumName, depth + 1)
            return size

        elseif rtype == "Rect" then
            ds_push(TAG_RECT)
            return 1 + 16 

        elseif rtype == "NumberRange" then
            ds_push(TAG_NUMRANGE)
            return 1 + 8 

        elseif rtype == "NumberSequence" then
            local kps: {NumberSequenceKeypoint} = (val :: any).Keypoints :: {NumberSequenceKeypoint}
            local n: number = #kps
            ds_push(TAG_NUMSEQ)
            ds_pushU32(n)
            return 1 + 2 + (n * 12)  -- tag + u16 count + keypoints

        elseif rtype == "ColorSequence" then
            local kps: {ColorSequenceKeypoint} = (val :: any).Keypoints :: {ColorSequenceKeypoint}
            local n: number = #kps
            ds_push(TAG_COLSEQ)
            ds_pushU32(n)
            return 1 + 2 + (n * 17)

        elseif rtype == "DateTime" then
            ds_push(TAG_DATETIME)
            return 1 + 8  -- i64 epoch seconds

        elseif rtype == "SharedTable" then

            SharedTable.lock(val :: SharedTable)
            local snap: {[any]: any} = SharedTable.snapshot(val :: SharedTable)
            return ProbeValue(snap, depth)  -- will hit the table branch below

        elseif rtype == "Instance" then
            error("CompressIt: cannot serialize Instance objects. Wrap needed data in a table.")

        elseif rtype ~= "table" then
            error("CompressIt: unsupported Roblox type '" .. rtype .. "'")
        end

        --plain table
        local count: number    = 0
        local maxIdx: number   = 0
        local hasNonSeq: boolean = false
        local itemCount: number  = 0

        local k: any = next(val)
        while k ~= nil do
            count += 1
            itemCount += 1
            if itemCount > MAX_ITEMS then
                error("CompressIt: table exceeds MAX_ITEMS (" .. MAX_ITEMS .. ")")
            end

            if type(k) == "number" then
                local fk: number = math.floor(k)
                if k == fk and fk >= 1 then
                    if fk > maxIdx then maxIdx = fk end
                else
                    hasNonSeq = true
                end
            else
                hasNonSeq = true
            end

            k = next(val, k)
        end

        local tableType: number = 1  -- default MAP
        local seqLen: number    = count

        if not hasNonSeq then
            if maxIdx == 0 then

                tableType = 0
                seqLen    = 0
            else
                local density: number = count / maxIdx
                if ENABLE_SPARSE_ARRAY and density < SPARSE_THRESHOLD then
                    tableType = 2  -- SPARSE
                    seqLen    = count
                else
                    -- Verify full contiguity
                    local contiguous: boolean = true
                    for i = 1, maxIdx do
                        if val[i] == nil then
                            contiguous = false
                            break
                        end
                    end
                    if contiguous then
                        tableType = 0  -- ARRAY
                        seqLen    = maxIdx
                    elseif ENABLE_SPARSE_ARRAY then
                        tableType = 2
                        seqLen    = count
                    end
                    -- else stays MAP
                end
            end
        end

        ds_push(0xD0 + tableType)  -- 0xD0=ARRAY, 0xD1=MAP, 0xD2=SPARSE
        ds_pushU32(seqLen)

        local size: number = 1 + VarintSize(seqLen)  -- tag + varint length

        if tableType == 0 then
            for i = 1, seqLen do
                size += ProbeValue(val[i], depth + 1)
            end
        elseif tableType == 2 then
            local sk: any = next(val)
            while sk ~= nil do
                size += ProbeValue(sk, depth + 1)
                size += ProbeValue(val[sk], depth + 1)
                sk = next(val, sk)
            end
        else
            local mk: any = next(val)
            while mk ~= nil do
                size += ProbeValue(mk, depth + 1)
                size += ProbeValue(val[mk], depth + 1)
                mk = next(val, mk)
            end
        end

        return size

        -- errors - some people just be dumb fr
    elseif t == "function" then
        error("CompressIt: cannot serialize functions")
    elseif t == "thread" then
        error("CompressIt: cannot serialize threads (coroutines)")
    else
        error("CompressIt: unsupported type '" .. t .. "'")
    end
end

local function EncodeValue(buf: buffer, off: number, val: any, depth: number): number
    local decision: number = ds_pop()

    -- constants
    if decision == TAG_NIL then
        buffer.writeu8(buf, off, TAG_NIL)
        return off + 1

    elseif decision == TAG_FALSE then
        buffer.writeu8(buf, off, TAG_FALSE)
        return off + 1

    elseif decision == TAG_TRUE then
        buffer.writeu8(buf, off, TAG_TRUE)
        return off + 1

    elseif decision == TAG_ZERO then
        buffer.writeu8(buf, off, TAG_ZERO)
        return off + 1

        -- int
    elseif decision >= TAG_IMM_INT_MIN and decision <= TAG_IMM_INT_MAX then
        buffer.writeu8(buf, off, decision)
        return off + 1

        -- num
    elseif decision == TAG_U8 then
        buffer.writeu8(buf, off, TAG_U8)
        buffer.writeu8(buf, off + 1, val :: number)
        return off + 2

    elseif decision == TAG_I16 then
        buffer.writeu8(buf, off, TAG_I16)
        buffer.writei16(buf, off + 1, val :: number)
        return off + 3

    elseif decision == TAG_I32 then
        buffer.writeu8(buf, off, TAG_I32)
        buffer.writei32(buf, off + 1, val :: number)
        return off + 5

    elseif decision == TAG_F64 then
        buffer.writeu8(buf, off, TAG_F64)
        buffer.writef64(buf, off + 1, val :: number)
        return off + 9

        -- strings
    elseif decision >= TAG_IMM_STR_MIN and decision <= TAG_IMM_STR_MAX then
        buffer.writeu8(buf, off, decision)
        off += 1
        local len: number = decision - TAG_IMM_STR_BASE
        if len > 0 then
            buffer.writestring(buf, off, val :: string)
            off += len
        end
        return off
    elseif decision == TAG_STR_VAR then
        buffer.writeu8(buf, off, TAG_STR_VAR)
        off += 1
        local len: number = #(val :: string)
        off = WriteVarint(buf, off, len)
        if len > 0 then
            buffer.writestring(buf, off, val :: string)
            off += len
        end
        return off

    elseif decision == TAG_STR_NEW then
        local len: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_STR_NEW)
        off += 1
        off = WriteVarint(buf, off, len)
        if len > 0 then
            buffer.writestring(buf, off, val :: string)
            off += len
        end
        return off

    elseif decision == TAG_STR_REF then
        local id: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_STR_REF)
        off += 1
        off = WriteVarint(buf, off, id)
        return off

        -- vector3
    elseif decision == TAG_VEC3 then
        buffer.writeu8(buf, off, TAG_VEC3)
        off += 1
        local v: vector = val :: vector
        buffer.writef32(buf, off,     v.X)
        buffer.writef32(buf, off + 4, v.Y)
        buffer.writef32(buf, off + 8, v.Z)
        return off + 12

        -- raw buffer
    elseif decision == TAG_RAW_BUFFER then
        buffer.writeu8(buf, off, TAG_RAW_BUFFER)
        off += 1
        local src: buffer = val :: buffer
        local len: number = buffer.len(src)
        off = WriteVarint(buf, off, len)
        buffer.copy(buf, off, src, 0, len)
        return off + len

        -- roblox types
    elseif decision == TAG_VEC2 then
        buffer.writeu8(buf, off, TAG_VEC2)
        off += 1
        local v: any = val
        buffer.writef32(buf, off,     (v.X :: number))
        buffer.writef32(buf, off + 4, (v.Y :: number))
        return off + 8

    elseif decision == TAG_COLOR3 then
        buffer.writeu8(buf, off, TAG_COLOR3)
        off += 1
        local c: any = val
        buffer.writef32(buf, off,     (c.R :: number))
        buffer.writef32(buf, off + 4, (c.G :: number))
        buffer.writef32(buf, off + 8, (c.B :: number))
        return off + 12

    elseif decision == TAG_CFRAME then
        buffer.writeu8(buf, off, TAG_CFRAME)
        off += 1
        local cf: any = val
        local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
            (cf :: CFrame):GetComponents()
        -- Position
        buffer.writef32(buf, off,     x)
        buffer.writef32(buf, off + 4, y)
        buffer.writef32(buf, off + 8, z)
        -- Quaternion
        local qw, qx, qy, qz = MatrixToQuat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
        buffer.writef32(buf, off + 12, qw)
        buffer.writef32(buf, off + 16, qx)
        buffer.writef32(buf, off + 20, qy)
        buffer.writef32(buf, off + 24, qz)
        return off + 28

    elseif decision == TAG_BRICKCOLOR then
        buffer.writeu8(buf, off, TAG_BRICKCOLOR)
        off += 1
        local idx: number = BrickColorToIndex(val :: BrickColor)
        buffer.writeu16(buf, off, idx)
        return off + 2

    elseif decision == TAG_UDIM then
        buffer.writeu8(buf, off, TAG_UDIM)
        off += 1
        local u: any = val
        buffer.writef32(buf, off,     (u.Scale  :: number))
        buffer.writei32(buf, off + 4, (u.Offset :: number))
        return off + 8

    elseif decision == TAG_UDIM2 then
        buffer.writeu8(buf, off, TAG_UDIM2)
        off += 1
        local u: any = val
        local ux: any = u.X
        local uy: any = u.Y
        buffer.writef32(buf, off,      (ux.Scale  :: number))
        buffer.writei32(buf, off + 4,  (ux.Offset :: number))
        buffer.writef32(buf, off + 8,  (uy.Scale  :: number))
        buffer.writei32(buf, off + 12, (uy.Offset :: number))
        return off + 16

    elseif decision == TAG_ENUMITEM then
        buffer.writeu8(buf, off, TAG_ENUMITEM)
        off += 1
        local e: any = val
        off = EncodeValue(buf, off, (e.Class :: string), depth + 1)
        off = EncodeValue(buf, off, (e.Name  :: string), depth + 1)
        return off

    elseif decision == TAG_RECT then
        buffer.writeu8(buf, off, TAG_RECT)
        off += 1
        local r: any = val
        local mn: any = r.Min
        local mx: any = r.Max
        buffer.writef32(buf, off,      (mn.X :: number))
        buffer.writef32(buf, off + 4,  (mn.Y :: number))
        buffer.writef32(buf, off + 8,  (mx.X :: number))
        buffer.writef32(buf, off + 12, (mx.Y :: number))
        return off + 16

    elseif decision == TAG_NUMRANGE then
        buffer.writeu8(buf, off, TAG_NUMRANGE)
        off += 1
        local nr: any = val
        buffer.writef32(buf, off,     (nr.Min :: number))
        buffer.writef32(buf, off + 4, (nr.Max :: number))
        return off + 8

    elseif decision == TAG_DATETIME then
        buffer.writeu8(buf, off, TAG_DATETIME)
        off += 1
        local dt: any = val
        local epoch: number = (dt :: DateTime).UnixTimestamp :: number
        local lo: number = bit32.band(epoch, 0xFFFFFFFF)
        local hi: number = 0 
        if epoch > 0xFFFFFFFF then
            hi = math.floor(epoch / 4294967296)
            lo = epoch - hi * 4294967296
        elseif epoch < 0 then
            hi = -1
            lo = bit32.band(epoch, 0xFFFFFFFF)
        end
        buffer.writeu32(buf, off, lo)
        buffer.writeu32(buf, off + 4, hi)
        return off + 8

    elseif decision == TAG_NUMSEQ then
        local n: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_NUMSEQ)
        off += 1
        buffer.writeu16(buf, off, n)
        off += 2
        local kps: {NumberSequenceKeypoint} = ((val :: any).Keypoints :: {NumberSequenceKeypoint})
        for i = 1, n do
            local kp: NumberSequenceKeypoint = kps[i]
            buffer.writef32(buf, off,     kp.Time)
            buffer.writef32(buf, off + 4, kp.Value)
            buffer.writef32(buf, off + 8, kp.Weight)
            off += 12
        end
        return off

    elseif decision == TAG_COLSEQ then
        local n: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_COLSEQ)
        off += 1
        buffer.writeu16(buf, off, n)
        off += 2
        local kps: {ColorSequenceKeypoint} = ((val :: any).Keypoints :: {ColorSequenceKeypoint})
        for i = 1, n do
            local kp: ColorSequenceKeypoint = kps[i]
            local c: Color3 = kp.Color
            buffer.writef32(buf, off,      kp.Time)
            buffer.writef32(buf, off + 4,  c.R)
            buffer.writef32(buf, off + 8,  c.G)
            buffer.writef32(buf, off + 12, c.B)
            buffer.writeu8(buf,  off + 16, (kp.Interpolation :: any).Value :: number)
            off += 17
        end
        return off

    elseif decision == 0xD0 then
        local seqLen: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_ARRAY)
        off += 1
        off = WriteVarint(buf, off, seqLen)
        local arr: {[any]: any} = val :: {[any]: any}
        for i = 1, seqLen do
            off = EncodeValue(buf, off, arr[i], depth + 1)
        end
        return off

    elseif decision == 0xD1 then
        local count: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_MAP)
        off += 1
        off = WriteVarint(buf, off, count)
        local map: {[any]: any} = val :: {[any]: any}
        local mk: any = next(map)
        while mk ~= nil do
            off = EncodeValue(buf, off, mk, depth + 1)
            off = EncodeValue(buf, off, map[mk], depth + 1)
            mk = next(map, mk)
        end
        return off

    elseif decision == 0xD2 then
        local count: number = ds_popU32()
        buffer.writeu8(buf, off, TAG_SPARSE)
        off += 1
        off = WriteVarint(buf, off, count)
        local sp: {[any]: any} = val :: {[any]: any}
        local sk: any = next(sp)
        while sk ~= nil do
            off = EncodeValue(buf, off, sk, depth + 1)
            off = EncodeValue(buf, off, sp[sk], depth + 1)
            sk = next(sp, sk)
        end
        return off
    end

    error("CompressIt: encoder hit unexpected decision byte 0x" .. string.format("%02X", decision))
end

type DecodeFunc = (buf: buffer, off: number) -> (any, number)

local JumpTable: {[number]: DecodeFunc} = table.create(256)

local function _chk(buf: buffer, off: number, need: number): void
    if off + need > buffer.len(buf) then
        error("CompressIt: buffer underrun at offset " .. off .. " (need " .. need .. " bytes, have " .. (buffer.len(buf) - off) .. ")")
    end
end

local dec_interns     : {[number]: string} = table.create(256)
local dec_intern_count: number             = 0

local DecodeValue: (buf: buffer, off: number) -> (any, number)

JumpTable[TAG_NIL] = function(buf: buffer, off: number): (any, number)
    return nil, off
end

JumpTable[TAG_FALSE] = function(buf: buffer, off: number): (any, number)
    return false, off
end

JumpTable[TAG_TRUE] = function(buf: buffer, off: number): (any, number)
    return true, off
end

JumpTable[TAG_ZERO] = function(buf: buffer, off: number): (any, number)
    return 0, off
end

do
    local function decImmInt(tag: number): DecodeFunc
        local zigzag: number = tag - TAG_IMM_INT_BASE
        local val: number = ZigZagDecode(zigzag)
        return function(_buf: buffer, off: number): (any, number)
            return val, off  -- value is baked at table-build time
        end
    end
    for tag = TAG_IMM_INT_MIN, TAG_IMM_INT_MAX do
        JumpTable[tag] = decImmInt(tag)
    end
end

JumpTable[TAG_U8] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 1)
    return buffer.readu8(buf, off), off + 1
end

JumpTable[TAG_I16] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 2)
    return buffer.readi16(buf, off), off + 2
end

JumpTable[TAG_I32] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 4)
    return buffer.readi32(buf, off), off + 4
end


JumpTable[TAG_F64] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 8)
    return buffer.readf64(buf, off), off + 8
end

do
    local function decImmStr(len: number): DecodeFunc
        if len == 0 then
            return function(_buf: buffer, off: number): (any, number)
                return "", off
            end
        end
        return function(buf: buffer, off: number): (any, number)
            _chk(buf, off, len)
            return buffer.readstring(buf, off, len), off + len
        end
    end
    for tag = TAG_IMM_STR_MIN, TAG_IMM_STR_MAX do
        JumpTable[tag] = decImmStr(tag - TAG_IMM_STR_BASE)
    end
end

JumpTable[TAG_STR_VAR] = function(buf: buffer, off: number): (any, number)
    local len: number
    len, off = ReadVarint(buf, off)
    if len == 0 then return "", off end
    _chk(buf, off, len)
    return buffer.readstring(buf, off, len), off + len
end


JumpTable[TAG_STR_NEW] = function(buf: buffer, off: number): (any, number)
    local len: number
    len, off = ReadVarint(buf, off)
    local s: string = ""
    if len > 0 then
        _chk(buf, off, len)
        s = buffer.readstring(buf, off, len)
        off += len
    end
    dec_intern_count += 1
    dec_interns[dec_intern_count] = s
    return s, off
end


JumpTable[TAG_STR_REF] = function(buf: buffer, off: number): (any, number)
    local id: number
    id, off = ReadVarint(buf, off)
    local idx: number = id + 1  -- intern IDs are 0-based, list is 1-based
    if idx < 1 or idx > dec_intern_count then
        error("CompressIt: STR_REF id " .. id .. " out of range (intern count = " .. dec_intern_count .. ")")
    end
    return dec_interns[idx], off
end


JumpTable[TAG_VEC2] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 8)
    local x: number = buffer.readf32(buf, off)
    local y: number = buffer.readf32(buf, off + 4)
    return Vector2.new(x, y), off + 8
end


JumpTable[TAG_VEC3] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 12)
    local x: number = buffer.readf32(buf, off)
    local y: number = buffer.readf32(buf, off + 4)
    local z: number = buffer.readf32(buf, off + 8)
    return Vector3.new(x, y, z), off + 12
end


JumpTable[TAG_COLOR3] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 12)
    local r: number = buffer.readf32(buf, off)
    local g: number = buffer.readf32(buf, off + 4)
    local b: number = buffer.readf32(buf, off + 8)
    return Color3.new(r, g, b), off + 12
end


JumpTable[TAG_CFRAME] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 28)
    local px: number  = buffer.readf32(buf, off)
    local py: number  = buffer.readf32(buf, off + 4)
    local pz: number  = buffer.readf32(buf, off + 8)
    local qw: number  = buffer.readf32(buf, off + 12)
    local qx: number  = buffer.readf32(buf, off + 16)
    local qy: number  = buffer.readf32(buf, off + 20)
    local qz: number  = buffer.readf32(buf, off + 24)
    return QuatToCFrame(px, py, pz, qw, qx, qy, qz), off + 28
end


JumpTable[TAG_BRICKCOLOR] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 2)
    local idx: number = buffer.readu16(buf, off)
    return BrickColor.new(idx), off + 2
end


JumpTable[TAG_UDIM] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 8)
    local scale:  number = buffer.readf32(buf, off)
    local offset: number = buffer.readi32(buf, off + 4)
    return UDim.new(scale, offset), off + 8
end


JumpTable[TAG_UDIM2] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 16)
    local xs: number = buffer.readf32(buf, off)
    local xo: number = buffer.readi32(buf, off + 4)
    local ys: number = buffer.readf32(buf, off + 8)
    local yo: number = buffer.readi32(buf, off + 12)
    return UDim2.new(xs, xo, ys, yo), off + 16
end


JumpTable[TAG_ENUMITEM] = function(buf: buffer, off: number): (any, number)
    local className: any
    local enumName:  any
    className, off = DecodeValue(buf, off)
    enumName,  off = DecodeValue(buf, off)
    local enumClass: any = (Enum :: any)[className :: string]
    if not enumClass then
        error("CompressIt: unknown Enum class '" .. (className :: string) .. "'")
    end
    local item: any = enumClass[enumName :: string]
    if not item then
        error("CompressIt: unknown EnumItem '" .. (className :: string) .. "." .. (enumName :: string) .. "'")
    end
    return item, off
end

JumpTable[TAG_RECT] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 16)
    local minX: number = buffer.readf32(buf, off)
    local minY: number = buffer.readf32(buf, off + 4)
    local maxX: number = buffer.readf32(buf, off + 8)
    local maxY: number = buffer.readf32(buf, off + 12)
    return Rect.new(Vector2.new(minX, minY), Vector2.new(maxX, maxY)), off + 16
end

JumpTable[TAG_NUMRANGE] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 8)
    local mn: number = buffer.readf32(buf, off)
    local mx: number = buffer.readf32(buf, off + 4)
    return NumberRange.new(mn, mx), off + 8
end

JumpTable[TAG_DATETIME] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 8)
    local lo: number = buffer.readu32(buf, off)
    local hi: number = buffer.readu32(buf, off + 4)
    local epoch: number
    if hi == 0 then
        epoch = lo
    elseif hi == 0xFFFFFFFF then
        epoch = lo - 4294967296
    else
        epoch = hi * 4294967296 + lo
    end
    return DateTime.fromUnixTime(epoch), off + 8
end


JumpTable[TAG_NUMSEQ] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 2)
    local n: number = buffer.readu16(buf, off)
    off += 2
    _chk(buf, off, n * 12)
    local kps: {NumberSequenceKeypoint} = table.create(n)
    for i = 1, n do
        local t: number = buffer.readf32(buf, off)
        local v: number = buffer.readf32(buf, off + 4)
        local w: number = buffer.readf32(buf, off + 8)
        kps[i] = NumberSequenceKeypoint.new(t, v, w)
        off += 12
    end
    return NumberSequence.new(kps), off
end

JumpTable[TAG_COLSEQ] = function(buf: buffer, off: number): (any, number)
    _chk(buf, off, 2)
    local n: number = buffer.readu16(buf, off)
    off += 2
    _chk(buf, off, n * 17)
    local kps: {ColorSequenceKeypoint} = table.create(n)


    local interpMap: {[number]: EnumItem} = {
        [0] = Enum.KeypointInterpolationMode.Linear,
        [1] = Enum.KeypointInterpolationMode.Constant,
        [2] = Enum.KeypointInterpolationMode.Cubic,
    }

    for i = 1, n do
        local t: number = buffer.readf32(buf, off)
        local r: number = buffer.readf32(buf, off + 4)
        local g: number = buffer.readf32(buf, off + 8)
        local b: number = buffer.readf32(buf, off + 12)
        local interpVal: number = buffer.readu8(buf, off + 16)
        local interp: EnumItem = interpMap[interpVal] or Enum.KeypointInterpolationMode.Linear
        kps[i] = ColorSequenceKeypoint.new(t, Color3.new(r, g, b), interp)
        off += 17
    end
    return ColorSequence.new(kps), off
end


JumpTable[TAG_ARRAY] = function(buf: buffer, off: number): (any, number)
    local len: number
    len, off = ReadVarint(buf, off)
    local arr: {[any]: any} = table.create(len)
    for i = 1, len do
        local v: any
        v, off = DecodeValue(buf, off)
        arr[i] = v
    end
    return arr, off
end


JumpTable[TAG_MAP] = function(buf: buffer, off: number): (any, number)
    local count: number
    count, off = ReadVarint(buf, off)
    local map: {[any]: any} = {}
    for _ = 1, count do
        local k: any, v: any
        k, off = DecodeValue(buf, off)
        v, off = DecodeValue(buf, off)


        if ENABLE_KEY_CACHE and type(k) == "string" then
            local cached: string? = key_cache[k :: string]
            if cached then
                k = cached
            else
                if key_cache_size < KEY_CACHE_MAX then
                    key_cache[k :: string] = k :: string
                    key_cache_size += 1
                end
            end
        end

        map[k] = v
    end
    return map, off
end

JumpTable[TAG_SPARSE] = function(buf: buffer, off: number): (any, number)
    local count: number
    count, off = ReadVarint(buf, off)
    local arr: {[any]: any} = {}
    for _ = 1, count do
        local k: any, v: any
        k, off = DecodeValue(buf, off)
        v, off = DecodeValue(buf, off)
        arr[k] = v
    end
    return arr, off
end


JumpTable[TAG_RAW_BUFFER] = function(buf: buffer, off: number): (any, number)
    local len: number
    len, off = ReadVarint(buf, off)
    _chk(buf, off, len)
    local result: buffer = buffer.create(len)
    buffer.copy(result, 0, buf, off, len)
    return result, off + len
end


DecodeValue = function(buf: buffer, off: number): (any, number)
    if off >= buffer.len(buf) then
        error("CompressIt: unexpected end of buffer at offset " .. off)
    end
    local tag: number = buffer.readu8(buf, off)
    off += 1

    local fn: DecodeFunc? = JumpTable[tag]
    if not fn then
        error("CompressIt: unknown tag 0x" .. string.format("%02X", tag) .. " at offset " .. (off - 1))
    end
    return fn(buf, off)
end


-- PUBLIC API


--[[ Compress(data: any) -> buffer
     Serialises `data` into a compact binary buffer.
     Supported types: nil, boolean, number, string, buffer, table,
     Vector2, Vector3, CFrame, Color3, BrickColor, UDim, UDim2,
     EnumItem, Rect, NumberRange, NumberSequence, ColorSequence,
     DateTime, SharedTable.
     Throws on: Instance, function, thread, unknown userdata.
]]
local function Compress(data: any): buffer
    -- Reset all mutable state
    ds_reset()
    intern_reset()

    local payloadSize: number = ProbeValue(data, 0)
    local totalSize:   number = 1 + payloadSize  -- version byte + payload


    local buf: buffer = buffer.create(totalSize)


    buffer.writeu8(buf, 0, FORMAT_VERSION)

    EncodeValue(buf, 1, data, 0)

    return buf
end

--[[ Decompress(buf: buffer) -> any
     Deserialises a buffer produced by Compress().
     Validates the format version header.
     Throws on version mismatch, truncated data, or unknown tags.
]]
local function Decompress(buf: buffer): any
    if buffer.len(buf) < 1 then
        error("CompressIt: buffer is empty")
    end


    dec_intern_count = 0


    local version: number = buffer.readu8(buf, 0)
    if version ~= FORMAT_VERSION then
        error("CompressIt: format version mismatch — expected " .. FORMAT_VERSION .. ", got " .. version)
    end


    local val: any, _: number = DecodeValue(buf, 1)
    return val
end



return {
    Compress   = Compress,
    Decompress = Decompress,

    -- Metadata
    VERSION = FORMAT_VERSION,
}
