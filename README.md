# TrimSync (trimsy)

**TrimSync** (`trimsy`) is a command-line video speed editor written in the [Odin](https://odin-lang.org/) programming language. It analyzes a video's audio track to automatically detect silent segments and can speed them up (or remove them entirely via jump-cuts), saving you time in post-production.

## Features

- **Silence Detection**: Automatically identifies quiet parts in your audio track.
- **Speed Adjustment**: Set distinct speeds for sounded segments vs. silent segments (e.g., normal speed for speaking, 5x speed for pauses).
- **Jump Cuts**: Completely skip/remove silence for tight editing.
- **Safety Margins**: Add padding around spoken segments to ensure words aren't abruptly cut off.
- **Presets**: Comes with built-in presets for lectures, podcasts (gentle), aggressive saving, and raw jump cuts.
- **Analysis Mode**: Check timing breakdowns and get suggestions on configurations without having to wait for the video to re-render.

## Prerequisites

- [Odin compiler](https://odin-lang.org/) (for building from source)
- [FFmpeg](https://ffmpeg.org/) installed and accessible in your system's `PATH`.

## Building

To build the executable, simply run:

```bash
odin build . -out:trimsy -o:speed
```

## Usage

```bash
trimsy <input_file> [options]
```

### Options

```text
  -o, --output <file>          Output file (default: input_trimmed.ext)
  -t, --threshold <0.03>       Silent threshold (0.0–1.0)
  -s, --sounded-speed <1.0>    Speed multiplier for sounded segments
  -ss, --silent-speed <5.0>    Speed multiplier for silent segments
  --skip, --jumpcut            Remove silent segments entirely (jump cut)
  -m, --margin <1>             Frames of safety margin around speech
  -p, --preset <name>          Use a preset (see below)
  --analyze                    Analyze only — show timing breakdown, no output
  --help, -h                   Show help
```

### Built-in Presets

| Name       | Description |
| ---------- | ----------- |
| `lecture`  | Optimized for recorded lectures / talking heads. Low threshold, generous margin, sped-up silence. |
| `jumpcut`  | Removes all silence completely (hard jump cuts). |
| `gentle`   | Light touch — silence sped up 2×. Good for podcasts and interviews. |
| `aggressive` | Hard cuts + sounded segments at 1.5× speed. Maximum time savings. |

### Examples

**Process a video with default settings:**
```bash
./trimsy lecture.mp4
```

**Use a preset:**
```bash
./trimsy tutorial.mp4 -p jumpcut
```

**Test threshold behavior (Analysis mode):**
```bash
./trimsy interview.mov --analyze -t 0.05
```

**Custom speed overrides:**
```bash
./trimsy meeting.mp4 -ss 8 -s 1.25 -m 2
```

## Inspiration

jumpcutter by [carykh](https://github.com/carykh/jumpcutter)

YT video: [Automatic on-the-fly video editing tool!](https://www.youtube.com/watch?v=DQ8orIurGxw)
