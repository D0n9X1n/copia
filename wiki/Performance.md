# Performance

[简体中文](Performance-zh-CN)

### Budgets

`copia-bench` seeds 1,000 clips (300 images) into a temporary store and fails when any budget is exceeded. CI runs one unprofiled gate per PR or main push: no retries or best-of selection. A profile after failure is diagnostic only. The release links the exact main push’s benchmark report and states whether 120 Hz checks actually gated.

| Metric | Budget | Where it runs |
|---|---|---|
| Idle CPU, strip hidden | < 0.15% average over 60 s | CI and local |
| Idle memory (phys_footprint) | < 40 MB | CI and local |
| Memory with the strip open | < 120 MB | CI and local |
| ⌘Y to first frame, in process | p95 < 100 ms over 50 opens, strip 1512 pt wide | CI and local |
| ⌘Y to first presented frame | p95 < 100 ms over 50 opens | Local, gated on a 120 Hz main display |
| Hidden strip | no body evaluations, layer displays or display-link ticks, no window on screen, card views and thumbnails released | CI and local |
| Scroll smoothness | ≥ 95% of frames show new card-row content and ≥ 95% of frame intervals are ≤ 1.5 × the refresh interval | Local, gated on a 120 Hz main display |
| Motion settle | open, close, lens, delete and undo, with and without Reduce Motion: ≤ the analytic settle time + 20 ms | Local, gated on a 120 Hz main display |

The default reference width is 1512 pt, capped to the screen's available width; `--width` overrides the reference but not that cap. The panel then takes an 8 pt inset on each side. Read `stripWidthPoints` and `backingScale` before comparing runs: local runs used a 1496 pt panel, while the current CI display produced 1008 pt at 1×. Presented-frame checks gate only when the main display runs at 120 Hz or faster. On a slower display they are measured and listed under `reportedOnly` with the refresh rate, because one 60 Hz refresh (16.7 ms) is most of the 20 ms settle margin. The frozen-row and hidden-render controls gate at any refresh.

The idle CPU budget was previously revised from <0.1% to <0.15%. That change did not alter any other limit. Historical runs keep their original verdicts; current CI uses the native-refresh recording method described below.

### Two paths

The bench picks its path at launch and writes it to the report as `path`:

- **`screenCaptureKit`** runs when the terminal has Screen Recording permission (`CGPreflightScreenCaptureAccess()`) and `--no-sck` is not passed. It records the bench's own windows for the presented-frame checks, then runs the in-process ⌘Y measure as well.
- **`proxy`** runs otherwise. CI may use either path: the current `xcode-27` image grants Screen Recording, so inspect the report rather than assuming a proxy run. ⌘Y is measured in process, and the recorded checks (scroll smoothness and every motion settle) are skipped, not failed. Each skipped check is listed with its reason under `skipped` in the JSON.

### How each budget is measured

- **Idle CPU and memory.** After one warm-up open and close, the strip stays hidden for the idle window. CPU is `getrusage` time over wall time, and memory is `phys_footprint`. Open memory is read after stepping the selection through every card, pausing a frame every four cards so the row scrolls and realises each one, before any recording starts.
- **⌘Y to first presented frame.** The time from the toggle call to the first captured frame whose first-card header (its top 16 pt, at least 8 pt of it visible) matches the settled open frame. Before each open, the first clip is selected, so the first card sits at the leading edge.
- **⌘Y to first frame, in process.** The time from the toggle call until the panel is on screen and visible, its cards are mounted, a layer with committed contents lies in the row's leading card slot, and one more transaction has completed.
- **Pointer selection.** `dispatchMs` measures selection on mouse-down; `transactionFlushMs` measures the layout/transaction flush. Only `presentedTargetRingMs` measures when the target ring appears in a captured frame. Do not report dispatch as presentation. At 120 Hz the benchmark requires all five clicks to select on mouse-down, a detected target ring for every click, and a median presented latency of at most 100 ms. All samples, including the slowest, are reported.
- **Hidden strip.** `Diagnostics` counts SwiftUI body evaluations (StripView and ClipCard), displays and draws of the panel's counting root layer, and display-link ticks. Copia owns no display link, so that counter stays at 0 by construction. All three must stay at 0 over the idle window, with no Copia window visible. A positive control then forces a redraw while the strip is hidden (it changes a value the strip's body reads, lays out, and displays the root layer). Both the body and layer counters must rise, or the bench fails.
- **Scroll smoothness.** A display link owned by the bench scrolls the row at 4,000 pt/s for 5 s, about 90 cards, so new cards and thumbnails are realised during the scroll. Each presented frame's entire card row is hashed during conversion to luma; an interrupted scroll or one that falls more than one refresh short of 20,000 pt cannot pass. The `drive` and `frozenControlDrive` fields retain actual distance, elapsed time, capture count and any invalidation reason; an incomplete or empty negative control is not evidence of a frozen row. A frame is new when its hash differs from the previous frame's, and the window's edges count as frame intervals, so a stall at either end is caught. The same scroll at 0 pt/s is the frozen-row control and must fail the check.
- **Motion settle.** Each motion is recorded three times with Reduce Motion forced off and three times with it forced on. The settle time runs from one refresh before the first visibly changed frame to the first frame after which the motion stays within 1% of its final frame, and the median must be ≤ the analytic settle time + 20 ms. Delete and Undo must also show changed, intermediate pixels after the trigger. Delete separately requires two distinct intermediate states inside the outgoing card before reflow starts, so an instant disappearance followed by moving neighbours cannot pass. "Within 1%" uses the measure that fits each motion. Open, delete and undo track how far the moving content is from its final position, as a fraction of its travel. The lens tracks the ring's position between two cards. Fades and crossfades track the luma distance to the final frame, as a fraction of the largest distance in the trial. The analytic time comes from the original published budget curves (`Motion.settleCeiling`), not from the shorter playback used for open, close, keyboard selection, undo and the movement of neighbouring cards after deletion: the time each curve last sits more than 1% from its target, and for a delete, the full fade duration plus the settle time of the reflow started by its completion. The report also gives each time measured from the Animator call (`fromTriggerMs`), which adds the compositor's latency to the screen. Neighbouring text clips have one to four sentences, so a card that slides one slot never matches its neighbour's slot.

### Recording scope

- Only windows the bench process owns are recorded: the `SCContentFilter` is built from the bench's panel and its wallpaper window, never from a whole display, and the stream is cropped to the panel's frame.
- For the whole recording, an opaque, bench-owned gradient window sits directly behind the panel at the next lower window level, so the glass samples only that wallpaper. The gradient runs left to right only, so a vertical slide stays a pure translation.
- Frames stay in memory as 8-bit luma planes, or as hashes during the scroll. Nothing is written to disk.
- The watcher stays active on a private pasteboard; `privateBoardPolls` counts idle polls. The system clipboard is never read. The panel ignores the mouse while recording, but it still takes key focus when it opens. Clicking another app during a recorded run closes the strip and spoils that trial. The JSON lists affected one-based `interruptedRounds`; those samples fail rather than reopening the panel or being retried.

### Results

The first 120 Hz v0.0.2 candidate failed: 84.9% of scroll intervals were on time; open, reduced-motion close and the keyboard lens exceeded their settling limits. The five actual pointer-to-ring samples had a median of 20.3 ms and a 158.1 ms maximum. A separate Metal control showed that capping ScreenCaptureKit at exactly 120 fps missed real presentations; the recorder now uses native refresh (`minimumFrameInterval = .zero`). This correction does not turn that failed run into a pass. Release evidence uses a fresh run on changed code, with the same limits.

Measured with the default run (60 s idle, 50 opens, 3 motion rounds) on an M3 Pro, macOS 27.2, release build, the strip 1496 pt wide (1512 pt less the panel inset) on a 60 Hz display. There were two recorded runs and two proxy runs (`--no-sck`), and every gated check passed.

| Metric | Proxy, run 1 | Proxy, run 2 | Recorded, run 1 | Recorded, run 2 |
|---|---|---|---|---|
| Idle CPU | 0.054% | 0.056% | 0.052% | 0.053% |
| Idle memory | 30.7 MB | 30.8 MB | 30.8 MB | 30.5 MB |
| Strip open, before scrolling | 34 MB | 34 MB | 34 MB | 34 MB |
| Strip open, after scrolling all 1,000 cards | 92 MB in a later run (the earlier runs above stepped the selection without letting the row scroll) | | | |
| ⌘Y to first frame, in process | p50 79.0 ms, p95 91.8 ms | p50 80.6 ms, p95 91.5 ms | p50 76.7 ms, p95 90.7 ms | p50 77.8 ms, p95 92.7 ms |
| Hidden strip: bodies, layer displays, display-link ticks | 0, 0, 0; control rose | 0, 0, 0; control rose | 0, 0, 0; control rose | 0, 0, 0; control rose |
| Frozen-row control | skipped | skipped | fails, as required | fails, as required |

Presented frames, reported at 60 Hz (gated only at 120 Hz):

| Metric | Budget | Recorded, run 1 | Recorded, run 2 |
|---|---|---|---|
| ⌘Y to first presented frame | p95 < 100 ms | p50 102.9 ms, p95 120.3 ms | p50 105.2 ms, p95 124.9 ms |
| Scroll: new content, on-time intervals | ≥ 95%, ≥ 95% | 86.2%, 94.3% | 89.0%, 94.3% |
| Open, normal / Reduce Motion | 253.6 / 168.5 ms | 250.0 / 150.0 | 250.0 / 150.0 |
| Close | 198.9 / 168.5 ms | 216.7 / 200.0 | 200.0 / 200.0 |
| Lens | 199.6 / 20.0 ms | 216.7 / 16.7 | 200.0 / 16.7 |
| Delete (full fade plus reflow) | 464.9 / 318.5 ms | 300.0 / 183.3 | 300.0 / 183.3 |
| Undo | 205.7 / 168.5 ms | 216.7 / 183.3 | 216.7 / 183.3 |

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

Options: `--idle SECONDS` (default 60), `--opens N` (default 50), `--width POINTS` (default 1512) to set the strip's width, `--no-sck` to run the proxy path even with Screen Recording, and `--motion-rounds N` (default 3). The active watcher polls a private pasteboard, so nothing you copy is read.

### Limits

- macOS has no per-process GPU-time counter. "Hidden" is checked with the rendering counters and the panel being off screen.
- The in-process ⌘Y measure cannot see presented frames. The presented time adds the window server's commit-to-screen pipeline (about three refreshes at 60 Hz) and the slide until the first card's top is visible.
- Settle times are quantised to the display's refresh interval, 16.7 ms at 60 Hz, so a 20 ms margin leaves room for about one frame. That is why presented-frame checks gate at 120 Hz.
- At 60 Hz, presented ⌘Y is over 100 ms, close, lens and undo settle one or two refreshes late, and about 5% of scroll frame intervals run long. Those 60 Hz figures are historical, not 120 Hz release evidence.
- Recorded checks run wherever Screen Recording is granted; otherwise the report lists them under `skipped`. The CI image can grant recording access.
- Delete schedules reflow from the fade's completion. The recorded delete finishes sooner than the full scheduled sequence; the cause is not established. The budget follows the scheduled sequence, not an assumption of overlap.
