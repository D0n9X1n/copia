# Performance

[简体中文](Performance-zh-CN)

### Budgets

`copia-bench` seeds 1,000 clips (300 images) into a temporary store and fails when any budget is exceeded. CI runs it on every push.

| Metric | Budget |
|---|---|
| Idle CPU, strip hidden | < 0.1% average over 60 s |
| Idle memory (phys_footprint) | < 40 MB |
| Memory with the strip open | < 120 MB |
| ⌘Y to first frame | p95 < 100 ms over 50 opens |
| Hidden strip | card views and thumbnails released |

### Results

Measured with the default run (60 s idle, 50 opens) on an M3 Pro, macOS 27.2, release build, the strip on a 5848 × 2448 display:

| Metric | Result |
|---|---|
| Idle CPU | 0.029% |
| Idle memory | 33 MB |
| Strip open | 38 MB (53 MB after scrolling all 1,000 clips) |
| ⌘Y to first frame | p50 67 ms, p95 94 ms |

### What keeps it light

- **Polling only.** The only idle work is one `changeCount` read every 0.5 s on a tolerant timer.
- **Hide frees memory.** Closing the strip drops the card views and empties the thumbnail cache; the window and hosting view stay, so the next open is fast.
- **Small thumbnails, decoded off the main thread.** Thumbnails are decoded at 384 px (enough for a 192 pt card on a 2× display) in a background task, into a cache capped at 24 MB. Cards never keep their own copy.
- **One glass layer, system shadow.** The strip has a single glass backdrop; the window server draws the window shadow outside Copia's memory.
- **No `Canvas` behind images.** A SwiftUI `Canvas` checkerboard inside the glass strip cost about 110 MB of GPU buffers. A 16 × 16 tiled image replaces it.

### Run the benchmark

```sh
swift build -c release --product copia-bench
"$(swift build -c release --show-bin-path)/copia-bench" --json bench.json
```

Options: `--idle SECONDS` (default 60), `--opens N` (default 50), `--width POINTS` to place the strip in a narrower frame. Capture is paused during the run, so nothing you copy is read.

### Limits

- Open latency is measured in process: from the toggle to the first committed frame after the window is on screen. Measuring presented frames with ScreenCaptureKit needs Screen Recording permission and is not part of CI.
- There is no per-process GPU-time counter on macOS; "hidden" is checked by the panel being off screen with its cards and thumbnails released.
