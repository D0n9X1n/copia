# Performance

[简体中文](Performance-zh-CN)

### Budgets

`copia-bench` seeds 1,000 clips (300 images) into a temporary store and fails when any budget is exceeded. CI runs it on every push.

| Metric | Budget | Where it runs |
|---|---|---|
| Idle CPU, strip hidden | < 0.1% average over 60 s | CI and local |
| Idle memory (phys_footprint) | < 40 MB | CI and local |
| Memory with the strip open | < 120 MB | CI and local |
| ⌘Y to first frame | p95 < 100 ms over 50 opens | CI (proxy) and local (recorded) |
| Hidden strip | no body evaluations, layer displays or display-link ticks, no window on screen, card views and thumbnails released | CI and local |
| Scroll smoothness | ≥ 95% of frames show new card-row content and ≥ 95% of frame intervals are ≤ 1.5 × the refresh interval | Local only |
| Motion settle | open, close, lens, delete and undo, with and without Reduce Motion: ≤ the analytic settle time + 20 ms | Local only |

### Two paths

The bench picks its path at launch and writes it to the report as `path`:

- **`screenCaptureKit`** runs when the terminal has Screen Recording permission (`CGPreflightScreenCaptureAccess()`) and `--no-sck` is not passed. It records the bench's own windows and runs every check.
- **`proxy`** runs otherwise, which includes CI because the hosted runner has no Screen Recording. ⌘Y is measured in process, and the recorded checks (scroll smoothness and every motion settle) are skipped, not failed. Each skipped check is listed with its reason under `skipped` in the JSON.

### How each budget is measured

- **Idle CPU and memory.** After one warm-up open and close, the strip stays hidden for the idle window. CPU is `getrusage` time over wall time, and memory is `phys_footprint`. Open memory is read after scrolling through every card once, before any recording starts.
- **⌘Y to first frame, recorded.** The time from the toggle call to the first captured frame whose first-card header (its top 16 pt, at least 8 pt of it visible) matches the settled open frame. Before each open, the first clip is selected, so the first card sits at the leading edge.
- **⌘Y to first frame, proxy.** The time from the toggle call until the panel is on screen and visible, its cards are mounted, a layer with committed contents lies in the row's leading card slot, and one more transaction has completed.
- **Hidden strip.** `Diagnostics` counts SwiftUI body evaluations (StripView and ClipCard), displays and draws of the panel's counting root layer, and display-link ticks. Copia owns no display link, so that counter stays at 0 by construction. All three must stay at 0 over the idle window, with no Copia window visible. A positive control then forces a redraw while the strip is hidden (it changes a value the strip's body reads, lays out, and displays the root layer). Both the body and layer counters must rise, or the bench fails.
- **Scroll smoothness.** A display link owned by the bench scrolls the row at 4,000 pt/s for 5 s, about 90 cards, so new cards and thumbnails are realised during the scroll. Each presented frame's card row is hashed. A frame is new when its hash differs from the previous frame's, and the window's edges count as frame intervals, so a stall at either end is caught. The same scroll at 0 pt/s is the frozen-row control and must fail the check.
- **Motion settle.** Each motion is recorded three times with Reduce Motion forced off and three times with it forced on. The settle time runs from one refresh before the first visibly changed frame to the first frame after which the motion stays within 1% of its final frame, and the median must be ≤ the analytic settle time + 20 ms. "Within 1%" uses the measure that fits each motion. Open, delete and undo track how far the moving content is from its final position, as a fraction of its travel. The lens tracks the ring's position between two cards. Fades and crossfades track the luma distance to the final frame, as a fraction of the largest distance in the trial. The analytic time comes from the `Motion` table: the time each curve last sits more than 1% from its target, and for a delete, the fade plus the reflow it starts. The report also gives each time measured from the Animator call (`fromTriggerMs`), which adds the compositor's latency to the screen.

### Recording scope

- Only windows the bench process owns are recorded: the `SCContentFilter` is built from the bench's panel and its wallpaper window, never from a whole display, and the stream is cropped to the panel's frame.
- For the whole recording, an opaque, bench-owned gradient window sits directly behind the panel at the next lower window level, so the glass samples only that wallpaper. The gradient runs left to right only, so a vertical slide stays a pure translation.
- Frames stay in memory as 8-bit luma planes, or as hashes during the scroll. Nothing is written to disk.
- Capture stays paused for the whole run, so the system clipboard is never read. The panel ignores the mouse while recording, but it still takes key focus when it opens. Clicking another app during a recorded run closes the strip and spoils that trial.

### Results

Measured with the default run (60 s idle, 50 opens, 3 motion rounds) on an M3 Pro, macOS 27.2, release build, the strip 2908 pt wide on a 60 Hz 5848 × 2448 display. One proxy run (`--no-sck`) and two recorded runs; "over" marks a missed budget:

| Metric | Proxy | Recorded, run 1 | Recorded, run 2 |
|---|---|---|---|
| Idle CPU | 0.039% | 0.037% | 0.044% |
| Idle memory | 32.5 MB | 32.5 MB | 33.2 MB |
| Strip open, after scrolling all 1,000 clips | 54.2 MB | 49.2 MB | 49.3 MB |
| ⌘Y to first frame | p50 60.9 ms, p95 93.6 ms | p50 111.1 ms, p95 136.1 ms (over) | p50 104.9 ms, p95 140.5 ms (over) |
| Hidden strip: bodies, layer displays, display-link ticks | 0, 0, 0; control rose | 0, 0, 0; control rose | 0, 0, 0; control rose |
| Scroll: new content, on-time intervals | skipped | 75.3%, 93.2% (over) | 95.4%, 94.0% (over) |
| Frozen-row control | skipped | 0%, 74.5% (fails, as required) | 5.0%, 14.3% (fails, as required) |

Motion settle, median of three, in ms:

| Motion | Limit | Run 1 | Run 2 |
|---|---|---|---|
| Open | 253.6 | 250.0 | 266.7 (over) |
| Open, Reduce Motion | 168.5 | 166.7 | 150.0 |
| Close | 198.9 | 216.7 (over) | 216.7 (over) |
| Close, Reduce Motion | 168.5 | 200.0 (over) | 200.0 (over) |
| Lens | 199.6 | 200.0 (over) | 216.7 (over) |
| Lens, Reduce Motion | 20.0 | 16.7 | 16.7 |
| Delete | 464.9 | 283.3 | 300.0 |
| Delete, Reduce Motion | 318.5 | 166.7 | 166.7 |
| Undo | 205.7 | 200.0 | 200.0 |
| Undo, Reduce Motion | 168.5 | 166.7 | 183.3 (over) |

On the same machine, the proxy before it also waited for the first card's committed contents measured p50 83.3 ms and p95 99.4 ms, so the proxy is not slower.

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

Options: `--idle SECONDS` (default 60), `--opens N` (default 50), `--width POINTS` to place the strip in a narrower frame, `--no-sck` to run the proxy path even with Screen Recording, and `--motion-rounds N` (default 3). Capture is paused during the run, so nothing you copy is read.

### Limits

- macOS has no per-process GPU-time counter. "Hidden" is checked with the rendering counters and the panel being off screen.
- The proxy cannot see presented frames. On the same machine it reads lower than the recorded ⌘Y time, which includes the window server's first composite and the slide until the first card is visible.
- Settle times are quantised to the display's refresh interval, 16.7 ms at 60 Hz, so a 20 ms margin leaves room for about one frame.
- The recorded checks run only locally; CI lists them under `skipped`.
- The recorded ⌘Y time is over budget at 60 Hz: the panel's first composite reaches the screen 85–135 ms after the toggle, and the slide must bring the first card's top into view. The proxy cannot see this.
- In the scroll, some presented frames repeat the previous card row (5–25%), and about 6% of frame intervals are longer than 1.5 refreshes.
- Close settles one to two frames late in both modes, and the lens zero to one frame over a limit just under 200 ms.
- Delete, in both modes, settles well under its analytic time. The cards beside the deleted one are near-identical text, so the reflow changes few pixels, and the measure may call it settled early. Treat the delete result as unverified.
- An open's first visible frame comes after its animation has started, so the open settle time can read short, most visibly with Reduce Motion.
