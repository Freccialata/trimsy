# Converting trimsy to NLE/Compositor Plugins

## Architecture: Odin → C ABI

Odin compiles to native code and supports `export "c"` calling convention, so we can build a shared library (`.dylib`/`.dll`/`.so`) that exposes a C ABI. This is the standard way plugin SDKs work.

```
┌──────────────────────────────┐
│  trimsync core library       │  ← Pure Odin, C-ABI exported
│  (analyze, EDL, segment)     │
└──────────┬───────────────────┘
           │ C ABI (.dylib/.dll)
           ▼
┌──────────────────────────────┐
│  Host-specific plugin shim   │  ← C/C++/Python wrapper
│  (OFX, AE SDK, Resolve, etc)│
└──────────────────────────────┘
```

---

## Host-by-Host Breakdown

| Host | Plugin API | Language | Difficulty | Notes |
|------|-----------|----------|------------|-------|
| **Natron** | OFX (Open Effects) | C/C++ | ⭐⭐ Moderate | Best starting point. OFX is an open standard with C ABI. Write a thin C shim that calls the Odin library. |
| **Nuke** | OFX or NDK (C++) | C/C++ | ⭐⭐ Moderate | Also supports OFX, so same plugin works in both Natron and Nuke. NDK is more powerful but C++-only. |
| **DaVinci Resolve** | OFX (effects) or Fuse (Lua) | C/C++ or Lua | ⭐⭐ Moderate | OFX for video effects. But trimsy is more of an **editing** operation (modifying the timeline), not a per-frame effect — conceptual mismatch. Likely need the **Resolve Scripting API** (Python/Lua) which calls the C library to build timeline edits. |
| **Blender** | Python addon API | Python + C extension | ⭐⭐ Moderate | Write a Python addon that calls the Odin-compiled `.so`/`.dylib` via `ctypes` or a Python C extension. Blender's VSE (Video Sequence Editor) API lets you manipulate strips on the timeline. Good fit conceptually. |
| **After Effects** | AE SDK (C/C++) | C/C++ | ⭐⭐⭐ Hard | Adobe's SDK is heavy C++ with COM-like interfaces. The Odin library does analysis, but the AE plugin shim needs to be C++ and deal with AEGP suites, parameter UIs, etc. |
| **Premiere Pro** | Premiere SDK (C/C++) | C/C++ | ⭐⭐⭐ Hard | Similar difficulty to AE. The SDK for importers/exporters/effects is C++. However, Premiere also supports **CEP panels** (HTML/JS) and **UXP panels** that can shell out to the CLI tool — much easier. |

---

## The Conceptual Mismatch Problem

> **trimsy is a timeline/editorial tool, not a per-frame effect.**

Most plugin APIs (OFX, AE effects, etc.) operate on individual frames — "given frame N and these parameters, produce output frame N." That's great for color correction, blur, etc., but trimsy's job is to **rearrange and retime the timeline itself**.

This means for most hosts, there are **two strategies**:

### Strategy A: Scripting/Panel Integration (easier, better fit)

Write a script/panel that:
1. Calls the Odin C library to analyze audio and produce an EDL
2. Uses the host's scripting API to **modify the timeline** (split clips, set speed, delete segments)

**Best with:** DaVinci Resolve (Python/Lua scripting), Blender (Python addon), Premiere (CEP/UXP panel calling the CLI)

### Strategy B: OFX/Native Effect Plugin (harder, conceptual stretch)

Package it as an effect that takes a clip and outputs a retimed version. The effect would need to do frame-accurate time remapping internally (request different source frames depending on the EDL).

**Best with:** Natron/Nuke (OFX), After Effects (Time Remap via AEGP)

---

## Beyond Odin → C ABI: Other Options

| Approach | Pro | Con |
|----------|-----|-----|
| **Odin → C ABI shared library** | Direct, fast, no runtime dependencies | Need a C/C++ shim per host |
| **Keep it as a CLI tool** | Works everywhere, zero SDK headaches | Less "integrated" UX — but Resolve/Premiere/Blender can all call CLIs from scripts |
| **Odin → WASM** | Portable, sandboxed | No NLE supports WASM plugins (yet) |
| **Rewrite core in C** | Maximum compatibility with every SDK | Loses Odin ergonomics, probably not worth it since Odin C ABI is clean |
| **Zig or Rust → C ABI** | Same idea as Odin, different language | Only relevant if switching languages |
| **Python binding (cffi/ctypes)** | Easiest integration with Resolve, Blender, Nuke | Extra layer, but very practical |

---

## Recommended Path

### Step 1: Factor `trimsync` into a C-ABI Library

The `trimsync` package is already separate. Expose key functions with `export "c"`:

```odin
@(export, link_name="trimsy_analyze")
trimsy_analyze :: proc "c" (input_path: cstring, threshold: f32, ...) -> ^C_EDL { ... }
```

### Step 2: Python Binding via `ctypes`

Build a Python binding that loads the `.dylib`/`.dll`. This instantly enables integration with:
- **DaVinci Resolve** (via its Python scripting API)
- **Blender** (via Python addon)
- **Nuke** (via Python panels)

### Step 3: OFX Plugin (optional)

For Natron/Nuke, write a thin C shim (~200–300 lines) wrapping the OFX API and delegating to the Odin library.

### Step 4: Premiere/AE (optional)

The lowest-friction approach is a **CEP panel** (HTML/JS) that shells out to the `trimsy` CLI and then applies edits via ExtendScript — no C++ SDK wrestling required.

---

## Package Separation: Isolating FFmpeg from Core

The current codebase is **almost** cleanly separated already. Only one file in `trimsync/` imports FFmpeg — `decoder.odin`. The analyzer is pure computation (no I/O, no external deps).

### Current Structure

```
trimsync/                  ← core library (BUT decoder.odin couples it to FFmpeg)
├── types.odin             │  Config, Chunk, EDL, Decoded_Audio — NO ffmpeg
├── analyzer.odin          │  analyze_silence() — NO ffmpeg, pure algorithm
├── trimsync.odin          │  entry point: calls decode_audio() then analyze_silence()
├── decoder.odin           │  ⚠️ ALL the ffmpeg calls live here
└── ffmpeg/                │  raw ffmpeg C bindings (avcodec, avformat, avutil)
    ├── avcodec.odin
    ├── avformat.odin
    └── avutil.odin

ffmpeg_runner.odin         ← (root package) CLI ffmpeg subprocess for output
main.odin                  ← CLI entry point
```

### Proposed Structure

```
trimsync/                  ← PURE core: types + analysis. Zero external deps.
├── types.odin             │  Config, Chunk, Edit_Decision_List, Decoded_Audio
├── analyzer.odin          │  analyze_silence() — takes samples, returns EDL
└── trimsync.odin          │  convenience procs, edl_print_summary

ffmpeg/                    ← FFmpeg bindings + decoder. Standalone package.
├── avcodec.odin           │  raw C bindings
├── avformat.odin          │
├── avutil.odin            │
└── decoder.odin           │  decode_audio() → Decoded_Audio

main.odin                  ← CLI: uses both trimsync + ffmpeg
ffmpeg_runner.odin         ← CLI: subprocess ffmpeg for output
```

### What Changes

The refactor is minimal — essentially moving one file and adjusting two imports:

1. **Move `decoder.odin`** from `trimsync/` to `ffmpeg/`
2. **Move `ffmpeg/`** from `trimsync/ffmpeg/` to top-level `ffmpeg/`
3. **Update `trimsync.odin`** — the `analyze()` convenience proc either moves to `main.odin` or takes a `Decoded_Audio` directly instead of a file path
4. The `Decoded_Audio` struct stays in `trimsync/types.odin` (it's just a data container, no FFmpeg dependency)

### Result

| Consumer | Imports | FFmpeg needed? |
|----------|---------|---------------|
| OFX plugin | `trimsync` only | ❌ Host provides audio samples |
| Python binding | `trimsync` only | ❌ Host provides audio samples |
| Blender addon | `trimsync` only | ❌ Host provides audio samples |
| CLI standalone | `trimsync` + `ffmpeg` | ✅ FFmpeg decodes audio + produces output |

---

## Does Being a Plugin Eliminate the FFmpeg Dependency?

**Yes, completely.** Right now trimsy uses FFmpeg for two things, and both are replaced by the host's built-in media engine:

| Current FFmpeg use | As a plugin, replaced by… |
|----|---|
| **Audio decoding** (extracting samples for silence analysis) | The host already has the audio decoded — OFX/AE SDK/Blender API all give you direct access to audio sample buffers |
| **Video re-encoding** (producing the output with speed changes) | The host handles all rendering and export — you just tell it which frames to use and at what speed |

Inside any host, the media engine that ships with the app (Resolve's, Nuke's, Blender's, etc.) replaces FFmpeg entirely. The core library becomes **pure analysis** — take audio samples in, produce an EDL/segment list out. No I/O, no codecs, no FFmpeg.

> **The standalone CLI mode would still use FFmpeg** for users who don't have any NLE/compositor installed. So FFmpeg goes from a hard dependency to an optional one (CLI-only).

---

## Is a Plugin Cross-Program?

**It depends on the plugin standard:**

| Plugin Format | Cross-program? | Hosts |
|---|---|---|
| **OFX (OpenFX)** | ✅ **Yes** — that's the whole point of the standard | Natron, Nuke, DaVinci Resolve, Vegas, Flame, Fusion, Scratch, Baselight |
| **AE SDK** | ❌ After Effects only | After Effects |
| **Premiere SDK** | ❌ Premiere only | Premiere Pro |
| **Blender addon** | ❌ Blender only | Blender |
| **Resolve Script API** | ❌ Resolve only | DaVinci Resolve |

**OFX is the one-plugin-many-hosts answer.** A single `.ofx.bundle` compiled once runs in Natron, Nuke, Resolve, and several others. It's the closest thing to "write once, run everywhere" in the NLE/compositor world.

### The Catch with OFX

OFX gives cross-program portability, **but** it's designed for per-frame effects. For trimsy's use case (timeline retiming), it would be implemented as a **retiming effect**: the plugin receives the full clip, analyzes audio, then for each output frame, requests the appropriate source frame based on the EDL. It works, but it's a slightly unusual use of the API — doing time-domain manipulation inside a spatial-domain framework.

### Best of Both Worlds

All three distribution modes can coexist, sharing the same core Odin library compiled with C ABI:

```
                    ┌─────────────────────────┐
                    │  trimsync core (Odin)   │
                    │  pure analysis, no I/O  │
                    └────┬─────┬─────┬────────┘
                         │     │     │
              ┌──────────┘     │     └──────────┐
              ▼                ▼                ▼
     ┌────────────────┐ ┌───────────┐ ┌─────────────────┐
     │  OFX plugin    │ │  Python   │ │  CLI + FFmpeg   │
     │  (C shim)      │ │  binding  │ │  (standalone)   │
     │                │ │  (ctypes) │ │                 │
     │ Cross-program: │ │           │ │ No host needed, │
     │ Natron, Nuke,  │ │ Blender,  │ │ FFmpeg required │
     │ Resolve, etc.  │ │ Resolve,  │ │                 │
     │                │ │ Nuke      │ │                 │
     │ No FFmpeg ✓    │ │ No FFmpeg │ │ FFmpeg needed   │
     └────────────────┘ └───────────┘ └─────────────────┘
```

---

## Summary

- **Odin → C ABI** is the right core strategy — Odin has first-class `"c"` calling convention support
- **As a plugin, FFmpeg is not needed** — the host app provides all media decoding and encoding
- **OFX is the only cross-program plugin standard** — one build runs in Natron, Nuke, Resolve, and more
- **Natron/Nuke (OFX)** and **Blender (Python addon)** are the easiest plugin targets
- **DaVinci Resolve** is best approached via its Python/Lua scripting API + C library, or via OFX
- **Premiere/AE** are harder as native plugins but easily doable via panel + CLI
- **The standalone CLI keeps FFmpeg** as an optional fallback for users without NLE apps
- No need to rewrite anything in C — Odin's C ABI export is sufficient
