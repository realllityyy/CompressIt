# CompressIt — Universal Binary Serializer for Roblox

[![Version](https://img.shields.io/badge/version-2.0-blue.svg)](https://github.com)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Roblox](https://img.shields.io/badge/platform-Roblox-red.svg)](https://create.roblox.com)

CompressIt is a **high-performance, single-file binary serializer** for Luau. It packs Lua values — including the full Roblox type universe — into compact `buffer` payloads with a single allocation, and decodes them back with zero-logic overhead via a jump-table dispatcher.

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [API](#api)
- [Architecture](#architecture)
- [Supported Types](#supported-types)
- [Usage Examples](#usage-examples)
- [Wire Format](#wire-format)
- [Benchmarks](#benchmarks)
- [Benchmark Script](#benchmark-script)
- [Notes](#notes)
- [Updates](#updates)

---

## Features

| Feature | Description |
|---|---|
| **Single Allocation** | The exact buffer size is calculated before any writing begins — one `buffer.create`, zero resizes |
| **Decision Stack** | A two-phase pipeline separates analysis from writing, eliminating split-brain bugs and redundant iteration |
| **Numeric Narrowing** | Integers are automatically stored as `u8`, `i16`, `i32`, or `f64` — whichever is smallest |
| **Immediate Values** | Small integers (`-32` to `31`) and short strings (`0`–`47` bytes) are encoded directly in the tag byte — zero payload |
| **ZigZag Encoding** | Signed integers are mapped to unsigned before varint compression, so negative numbers are just as compact as positive |
| **LEB128 Varints** | All lengths and IDs use unsigned LEB128 — 1 byte for values under 128, never a wasted fixed `u32` |
| **String Interning** | Repeated strings are written once and back-referenced by a varint ID for the rest of the payload |
| **Quaternion CFrames** | CFrames are stored as position + quaternion (28 bytes) instead of a full rotation matrix (48 bytes) |
| **Sparse Array Detection** | Tables with density below 50% are encoded as key-value pairs instead of a holey sequence |
| **Full Roblox Types** | Native support for 14 Roblox types including `NumberSequence`, `ColorSequence`, `EnumItem`, and `DateTime` |
| **Jump-Table Decoder** | A 256-slot function table gives O(1) tag dispatch — no `if/elseif` chains in the decode path |
| **SharedTable Support** | Parallel Luau `SharedTable` values are snapshotted and serialized transparently |
| **Raw Buffer Embed** | `buffer` values are copied directly with `buffer.copy` — zero re-encoding |

---

## Installation

1. Place `CompressIt.lua` as a `ModuleScript` anywhere accessible to your scripts (e.g. `ReplicatedStorage`).
2. Require it:

```lua
local CompressIt = require(game.ReplicatedStorage.CompressIt)
```

---

## API

CompressIt exports two functions and one metadata field.

| Member | Signature | Description |
|---|---|---|
| `Compress` | `(data: any) → buffer` | Serializes `data` into a compact binary buffer. Throws on unsupported types. |
| `Decompress` | `(buf: buffer) → any` | Deserializes a buffer produced by `Compress`. Validates the version header and all bounds. Throws on corruption or version mismatch. |
| `VERSION` | `number` | The current format version (`2`). Buffers from a different version will error on decompress. |

### Compress

```lua
local packed: buffer = CompressIt.Compress(data)
```

Serializes any supported value. Tables are analyzed automatically — arrays, maps, and sparse arrays are each encoded with the optimal layout. Roblox types are detected via `typeof()` and written in their native binary form. Strings that appear more than once in the payload are interned: written once, referenced by ID afterwards.

**Throws** if `data` contains an `Instance`, `function`, `thread`, or any other unsupported type.

### Decompress

```lua
local data: any = CompressIt.Decompress(packed)
```

Reconstructs the original value from a buffer. Validates the format version byte at offset 0 and performs bounds checks on every read. Interned strings are reconstructed into the same identity for the lifetime of the call.

**Throws** on version mismatch, truncated data, unknown tags, or invalid intern references.

---

## Architecture

CompressIt uses a strict three-phase pipeline. No phase does the work of another.

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1 — Smart Probe  ("The Brain")                           │
│                                                                 │
│   Traverses the data exactly once.                              │
│   • Calculates the exact byte size of the output.               │
│   • Records every structural decision into a Decision Stack     │
│     (pre-allocated buffer, reused across calls — zero GC).      │
│   • Performs all heavy logic: table classification, numeric     │
│     narrowing, string interning, ZigZag + varint sizing.        │
│   • Enforces MAX_DEPTH (64) and MAX_ITEMS (1,000,000).          │
└───────────────────────────────┬─────────────────────────────────┘
                                │  Decision Stack
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Phase 2 — Linear Encoder  ("The Muscle")                       │
│                                                                 │
│   Allocates the result buffer exactly once.                     │
│   Traverses the data a second time but performs zero logic.     │
│   Pops the next instruction from the Decision Stack and         │
│   writes the bytes blindly.                                     │
│                                                                 │
│   Guarantees O(1) per-value encoding and perfect consistency    │
│   between the calculated size and the actual write.             │
└───────────────────────────────┬─────────────────────────────────┘
                                │  Packed buffer
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Phase 3 — Jump-Table Decoder                                   │
│                                                                 │
│   256-slot function table indexed by tag byte → O(1) dispatch.  │
│   Immediate integer and string decoders are baked at            │
│   module-load time (value captured in closure).                  │
│   Strict bounds validation on every read.                       │
└─────────────────────────────────────────────────────────────────┘
```

### Why the Decision Stack?

A naive serializer iterates the data once to measure sizes, then again to write. If any logic runs differently the second time — a string that was "new" during measurement is "already interned" during writing — the size and the actual bytes diverge. This is a **split-brain bug**.

The Decision Stack solves it by recording every classification decision during the Probe. The Encoder never classifies anything — it only reads back what the Probe already decided. The two phases are guaranteed to agree.

---

## Supported Types

### Primitives

| Type | Encoding |
|---|---|
| `nil` | Single tag byte (`0x00`) |
| `boolean` | Single tag byte (`true` = `0x02`, `false` = `0x01`) |
| `number` | Narrowed automatically — see table below |
| `string` | Immediate (≤ 47 bytes in tag) or varint-prefixed; interned on repeat |
| `buffer` | Varint length + raw `buffer.copy` |

### Number Narrowing

| Range | Stored As | Bytes (tag + payload) |
|---|---|---|
| `0` | Zero tag | 1 |
| `-32` to `31` | Immediate integer (ZigZag in tag) | 1 |
| `0` to `255` | `u8` | 2 |
| `-32768` to `32767` | `i16` | 3 |
| `-2147483648` to `2147483647` | `i32` | 5 |
| Everything else | `f64` | 9 |

### Tables

| Layout | When | Encoding |
|---|---|---|
| Array | All keys are contiguous integers `1..n` | Tag + varint length + sequential values |
| Sparse Array | All keys are integers but density < 50% | Tag + varint count + key/value pairs |
| Map | Any non-integer key, or mixed | Tag + varint count + key/value pairs |

### Roblox Types

| Type | Encoding | Size |
|---|---|---|
| `Vector2` | 2 × `f32` | 9 bytes |
| `Vector3` | 3 × `f32` | 13 bytes |
| `CFrame` | Position (3 × `f32`) + Quaternion (4 × `f32`) | 29 bytes |
| `Color3` | 3 × `f32` (R, G, B) | 13 bytes |
| `BrickColor` | `u16` palette index | 3 bytes |
| `UDim` | `f32` scale + `i32` offset | 9 bytes |
| `UDim2` | 2 × UDim inlined | 17 bytes |
| `EnumItem` | Class name + enum name (both interned strings) | variable |
| `Rect` | Min + Max (4 × `f32`) | 17 bytes |
| `NumberRange` | Min + Max (2 × `f32`) | 9 bytes |
| `NumberSequence` | `u16` count + keypoints (3 × `f32` each) | variable |
| `ColorSequence` | `u16` count + keypoints (3 × `f32` + `u8` interp each) | variable |
| `DateTime` | Unix epoch as `i64` | 9 bytes |
| `SharedTable` | Snapshotted, then encoded as a Map | variable |

### Hard Errors

These types **cannot** be serialized and will throw immediately:

| Type | Reason |
|---|---|
| `Instance` | Not portable — references live objects in the scene tree |
| `function` | Not serializable |
| `thread` | Not serializable |
| Unknown userdata | No known encoding |

---

## Usage Examples

### Basic round-trip

```lua
local CompressIt = require(game.ReplicatedStorage.CompressIt)

local original = {
    name    = "Alice",
    health  = 100,
    pos     = Vector3.new(10, 0, 20),
    active  = true,
}

local packed = CompressIt.Compress(original)
print("Packed size:", buffer.len(packed), "bytes")  -- compact!

local restored = CompressIt.Decompress(packed)
print(restored.name, restored.health, restored.pos)
-- Alice    100    10, 0, 20
```

### Sending over the network

```lua
-- Server
local CompressIt = require(game.ReplicatedStorage.CompressIt)
local event = game.ReplicatedStorage.RemoteEvents.GameState

local state = {
    round   = 7,
    scores  = { Alice = 120, Bob = 95, Charlie = 110 },
    time    = 42.5,
}

-- Compress once, fire the raw buffer — no double-encoding
event:FireAllClients(CompressIt.Compress(state))
```

```lua
-- Client
local CompressIt = require(game.ReplicatedStorage.CompressIt)
local event = game.ReplicatedStorage.RemoteEvents.GameState

event.OnClientInvoke = function(packed)
    local state = CompressIt.Decompress(packed)
    print("Round:", state.round, "My score:", state.scores[LocalPlayer.Name])
end
```

### Roblox types

```lua
local CompressIt = require(game.ReplicatedStorage.CompressIt)

local data = {
    cframe   = workspace.Part.CFrame,
    color    = Color3.fromRGB(255, 128, 0),
    brick    = BrickColor.new("Bright red"),
    size     = UDim2.new(1, -20, 0, 50),
    range    = NumberRange.new(10, 100),
    sequence = NumberSequence.new({ 0, 0.5, 1 }, { 0, 1, 0 }),
    when     = DateTime.now(),
    item     = Enum.Material.Concrete,
}

local packed   = CompressIt.Compress(data)
local restored = CompressIt.Decompress(packed)

print(restored.cframe)   -- CFrame reconstructed from quaternion
print(restored.item)     -- Enum.Material.Concrete
```

### Error handling

```lua
local CompressIt = require(game.ReplicatedStorage.CompressIt)

-- This will throw — functions can't be serialized
local ok, err = pcall(CompressIt.Compress, { callback = print })
print(ok, err)
-- false    CompressIt: cannot serialize functions

-- This will throw — Instances can't be serialized
local ok2, err2 = pcall(CompressIt.Compress, { part = workspace.Baseplate })
print(ok2, err2)
-- false    CompressIt: cannot serialize Instance objects. Wrap needed data in a table.
```

---

## Wire Format

Every serialized payload starts with a single **version byte** (`0x02`), followed by the encoded value.

### Tag Map

| Range | Meaning |
|---|---|
| `0x00`–`0x0F` | Constants: `nil`, `false`, `true`, `zero` |
| `0x10`–`0x4F` | Immediate integers — ZigZag value embedded in tag (64 slots → `-32` to `31`) |
| `0x50`–`0x5F` | Numeric subtypes: `u8`, `i16`, `i32`, `f64` |
| `0x60`–`0x8F` | Immediate strings — length embedded in tag (48 slots → `0` to `47` bytes) |
| `0x90`–`0x9F` | String subtypes: `STR_VAR`, `STR_NEW` (intern), `STR_REF` (back-reference) |
| `0xA0`–`0xAF` | Tables: `ARRAY`, `MAP`, `SPARSE_ARRAY` |
| `0xB0`–`0xBF` | Roblox types: `Vector2` through `DateTime` |
| `0xC0`–`0xDF` | Sequences: `NumberSequence`, `ColorSequence` |
| `0xF0`–`0xFF` | Raw: `RAW_BUFFER` |

### Key Encodings

**Varint (LEB128)** — All lengths and intern IDs. Each byte carries 7 bits of data; the high bit indicates continuation.

```
Value 127  →  [0x7F]              (1 byte)
Value 128  →  [0x80, 0x01]        (2 bytes)
Value 300  →  [0xAC, 0x02]        (2 bytes)
```

**ZigZag** — Signed integers mapped to unsigned before varint encoding.

```
 0  →  0
-1  →  1
 1  →  2
-2  →  3
 2  →  4
```

**String Interning** — First occurrence of a string writes `STR_NEW` + varint length + bytes, and assigns it an ID. Every subsequent occurrence writes `STR_REF` + varint ID. For payloads with repeated keys (the common case in tables of records), this often cuts string storage by 80–95%.

---

## Benchmarks

All benchmarks run at **10,000 iterations**, no warmup, on Roblox Studio (server context). Times are per-call averages in microseconds.

| Suite | Size | Compress | Decompress | Round-Trip |
|---|---|---|---|---|
| Single Bool | 2 B | 0.18 µs | 0.10 µs | **0.28 µs** |
| Single Number | 10 B | 0.19 µs | 0.12 µs | **0.31 µs** |
| Empty Table | 3 B | 0.28 µs | 0.17 µs | **0.45 µs** |
| Single String | 14 B | 0.30 µs | 0.19 µs | **0.49 µs** |
| Sparse Array | 23 B | 1.58 µs | 1.47 µs | **3.05 µs** |
| Flat Small | 45 B | 2.49 µs | 1.73 µs | **4.22 µs** |
| Mixed Deep | 101 B | 6.39 µs | 4.99 µs | **11.38 µs** |
| Flat Large | 164 B | 7.02 µs | 5.10 µs | **12.11 µs** |
| Nested | 176 B | 9.95 µs | 7.10 µs | **17.04 µs** |
| Numbers Only | 2,108 B | 27.63 µs | 18.96 µs | **46.59 µs** |
| Repeated Strings | 2,398 B | 204.42 µs | 147.81 µs | **352.23 µs** |

> Primitives and small tables are consistently under **1 µs** round-trip. A 64-entry table with 7 repeated string keys per entry (the `Repeated Strings` suite — 448 total string writes) completes in **352 µs**, with string interning collapsing most of that repeated data.

---

## Benchmark Script

Place this as a `Script` in `ServerScriptService`, alongside `CompressIt` as a sibling `ModuleScript`. No warmup — results print immediately.

```lua
-- BenchmarkCompressIt.lua (Server Script)
-- Place in ServerScriptService. CompressIt must be a sibling ModuleScript.

local CompressIt = require(script.Parent.CompressIt)

local ITERATIONS = 10_000

--------------------------------------------------------------------------------
-- TEST PAYLOADS
--------------------------------------------------------------------------------

local Payloads: { [string]: any } = {
	["Flat Small"] = {
		name = "Player",
		health = 100,
		score = 42,
		active = true,
	},

	["Flat Large"] = {
		name = "LongPlayerNameHere",
		health = 73,
		score = 99999,
		x = 512.5,
		y = 128.0,
		z = -256.75,
		active = true,
		team = "Blue",
		rank = 14,
		streak = 7,
		deaths = 3,
		joined = 1000,
		level = 22,
		xp = 45000,
		coins = 8200,
	},

	["Nested"] = {
		player = {
			name = "Alice",
			stats = { hp = 100, mp = 50, str = 12 },
			inventory = { "sword", "shield", "potion", "potion", "potion" },
			position = { x = 100, y = 0, z = 200 },
		},
		settings = {
			graphics = "high",
			fov = 70,
			sensitivity = 0.4,
		},
	},

	["Repeated Strings"] = (function()
		local t: { [string]: any } = {}
		local keys = { "name", "type", "value", "active", "owner", "target", "source" }
		for i = 1, 64 do
			local entry: { [string]: any } = {}
			for _, k in ipairs(keys) do
				entry[k] = "item_" .. i
			end
			t[i] = entry
		end
		return t
	end)(),

	["Sparse Array"] = (function()
		local t: { [number]: number } = {}
		t[1]    = 1
		t[10]   = 10
		t[100]  = 100
		t[1000] = 1000
		t[5000] = 5000
		return t
	end)(),

	["Numbers Only"] = (function()
		local t: { number } = table.create(256)
		for i = 1, 256 do
			t[i] = i * 0.1 - 12.8
		end
		return t
	end)(),

	["Mixed Deep"] = {
		level1 = {
			level2 = {
				level3 = {
					level4 = {
						value = "deep",
						nums = { 1, 2, 3, 4, 5 },
					},
				},
			},
		},
		flags = { true, false, true, true, false },
		nil_test = { 1, nil, 3, nil, 5 },  -- becomes sparse
	},

	["Single Nil"]     = nil,
	["Single Bool"]    = true,
	["Single Number"]  = 3.14159265358979,
	["Single String"]  = "hello world",
	["Empty Table"]    = {},
}

--------------------------------------------------------------------------------
-- BENCHMARK RUNNER
--------------------------------------------------------------------------------

local function benchmark(label: string, payload: any)
	-- Compress timing
	local t0 = os.clock()
	local lastBuf: buffer = buffer.create(0)
	for _ = 1, ITERATIONS do
		lastBuf = CompressIt.Compress(payload)
	end
	local compressTime = os.clock() - t0

	-- Decompress timing
	local t1 = os.clock()
	local lastVal: any = nil
	for _ = 1, ITERATIONS do
		lastVal = CompressIt.Decompress(lastBuf)
	end
	local decompressTime = os.clock() - t1

	local byteSize = buffer.len(lastBuf)
	local compressUs  = (compressTime  / ITERATIONS) * 1_000_000
	local decompressUs = (decompressTime / ITERATIONS) * 1_000_000
	local totalUs     = compressUs + decompressUs

	print(string.format(
		"%-22s | %6d B | C: %7.2f µs | D: %7.2f µs | RT: %7.2f µs",
		label, byteSize, compressUs, decompressUs, totalUs
	))

	return lastVal  -- keep alive so GC doesn't interfere
end

--------------------------------------------------------------------------------
-- MAIN
--------------------------------------------------------------------------------

print(string.rep("-", 82))
print(string.format("  CompressIt Benchmark — %d iterations per suite", ITERATIONS))
print(string.rep("-", 82))
print(string.format(
	"%-22s | %8s | %16s | %16s | %16s",
	"Suite", "Size", "Compress", "Decompress", "Round-Trip"
))
print(string.rep("-", 82))

local _keep: { any } = {}  -- prevent GC of results during run

for label, payload in pairs(Payloads) do
	_keep[#_keep + 1] = benchmark(label, payload)
end

print(string.rep("-", 82))
print("Done.")
```

---

## Notes

- **Production-safe.** All decode paths validate bounds before reading. Version mismatches, truncated buffers, and unknown tags all throw clear errors.
- **Zero GC in the hot path.** The Decision Stack is a module-level `buffer` that doubles on overflow and is reused across every `Compress` call. The decoder key cache is a weak-value table that survives across `Decompress` calls.
- **CFrame precision.** Quaternion encoding introduces a small floating-point delta vs the original rotation matrix (typically < 1e-6). For physics-critical applications, verify this is acceptable.
- **Format is versioned.** The first byte of every buffer is the format version. `Decompress` rejects buffers from a different version immediately, so the wire format can evolve without silent corruption.
- **`SharedTable` is snapshotted.** The table is locked and copied before serialization. Changes made after `Compress` is called are not reflected.
- **Thread-safety.** `Compress` and `Decompress` are not safe to call concurrently from multiple threads — they share module-level state (Decision Stack, intern table). Each thread needs its own call sequence.

---

## Updates

| Version | Notes |
|---|---|
| v2.0 | Full Roblox type universe (14 types). Quaternion CFrames. Jump-table decoder. Decision Stack resource pool. SharedTable support. Strict bounds validation. |
| v1.0 | Initial release. Core primitives, tables, Vector3, Color3, CFrame (matrix). |
