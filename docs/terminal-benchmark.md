# Terminal performance measurements

Run the same script **inside each terminal**, with the same visible grid, font,
font size, display/refresh rate, power mode and scrollback settings:

```sh
./benchmark.sh --label ghostty
./benchmark.sh --label anymacs
./benchmark.sh --label ghostel
```

Each invocation runs three trials and prints medians. Results, individual samples,
terminal environment, script checksum and grid dimensions are saved in
`build/benchmarks/*.json`. Use `--notes 'font, refresh rate, power mode, workload'`
to record the other comparison settings.
Python 3 is the only dependency for the default suite. Nothing is downloaded.
Keep the window visible, do not type during a run, and use Ctrl-C to stop. Resizing
invalidates a run and stops it. Run terminals sequentially, with other benchmarks
stopped, and alternate their order across repeated comparisons.

## What the numbers mean

| Metric | Interpretation |
| --- | --- |
| ASCII / truecolor / Unicode MiB/s | Bytes written and then acknowledged by a cursor-position reply; higher is better. Includes PTY, parser and terminal work up to that reply. |
| Idle reply p50 / p95 / p99 | Protocol round-trip time in milliseconds; lower is better. Includes the benchmark, OS scheduling, and terminal reply path. |
| Loaded batch reply p50 / p95 / p99 | Time to submit about 64 KiB of colored output and receive a subsequent reply; includes the burst's write time. A repeatable backlog test, **not keyboard latency**. |
| Frame supply FPS | Full-grid updates submitted and parser-acknowledged per second. The default target is 60. **Not displayed FPS.** |
| Frame service p95 | Time to submit one prepared frame and receive its reply, excluding pacing sleeps. Shows tail stalls; it is not GPU frame time. |
| Missed supply slots | Producer could not keep its requested schedule. Does not count frames skipped by the renderer. |
| Optional CPU / sampled peak RSS | Host process CPU over the suite, as a percentage of one core, and maximum RSS sampled every 0.5 seconds. For Anymacs this includes all of Emacs. |

Payloads and animation frames are prepared before timing. Writes handle partial
completion and time out. Cursor-position replies fence each trial so the script
does not merely time filling the PTY buffer. They **do not fence GPU presentation**.
Warm-up operations are excluded. Latency percentiles and per-trial data are in the
JSON; the console summarizes the median of the trials' p50/p95 values.

The default uses the alternate screen and restores the previous screen afterward.
Its scrolling test excludes scrollback accumulation. To include your configured
scrollback storage, run this separately in both terminals:

```sh
./benchmark.sh --label anymacs-scrollback --mode throughput --scrollback
```

This writes into the main screen and leaves benchmark output in scrollback. Do not
compare it against an alternate-screen run. CJK uses repeated warmed glyphs; this
does not measure the cold glyph cache or complex emoji shaping. Multiplexers such
as tmux can answer protocol queries themselves; benchmark without them first.

## FPS benchmarks found online

- [Fortio `fps`](https://github.com/fortio/fps) supplies an animated FPS stress test
  with frame-time statistics. Its [measurement loop](https://github.com/fortio/fps/blob/main/fps.go)
  draws and waits for cursor-position replies. This measures application/terminal
  round trips, not confirmed display presentation. Optional independent check:
  `brew install fortio/tap/fps`, then `fps -fire -n 600 -json 60`.
- [DOOM-fire-zig](https://github.com/const-void/DOOM-fire-zig) is a visually demanding
  FPS demo. Its authors explicitly call the comparisons unscientific and report
  terminals looking choppy despite higher reported FPS. Useful for spotting
  stutter, not proof that every generated frame reached the display.
- [kitty's benchmark](https://sw.kovidgoyal.net/kitty/performance/),
  `kitten __benchmark__`, measures several parsing workloads. Rendering is normally
  suppressed; `--render` enables it, but the docs explicitly warn that asynchronous
  rendering prevents those results from measuring rendering performance properly.
- [vtebench](https://github.com/alacritty/vtebench) provides a broader collection of
  PTY workloads. Its own disclaimer says it does not measure frame rate or latency.

## Measure displayed frames on macOS

Use Apple's [Game Performance / Metal Instruments workflow](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/)
to inspect frame duration, presentation and missed vsync intervals. In the embedded
case, attach to **Emacs**, since Ghostty's renderer lives in that process.
`M-: (emacs-pid)` gives the PID. For standalone Ghostty, find its app PID in Activity
Monitor; do not use the shell's PID.

```sh
./benchmark.sh --label anymacs-trace --mode frames --seconds 15 --runs 1 \
  --target-fps 120 --pid 12345 --trace
```

Replace `12345`. This starts `xctrace` with the Game Performance template, waits for
recording to start, runs the workload, and saves a `.trace` beside the JSON. It
requires full Xcode and existing profiling access; failures are reported in the
adjacent `.trace.log`. Open the trace in Instruments and inspect the **Display**
track and CPU/GPU scheduling over the workload's timestamps. Display-wide vsync
and surface-swap totals include other apps: identify the terminal's presentation
activity instead of calling those totals terminal FPS. Also inspect Core
Animation presentation when the embedding uses IOSurface-backed layers; counting
GPU submissions alone is not proof of a visible update. Profiling adds overhead,
so compare equally instrumented runs separately from the normal suite.

For a 60 Hz display, use `--target-fps 60`; for 120 Hz, use 120. An uncapped supply
test (`--target-fps 0`) measures update-processing capacity and can exceed the
display's refresh rate. No displayed FPS is fabricated: JSON `displayed_fps` stays
null unless a separate presentation measurement is made.

## Measure the “snappy” feeling

The most relevant measurement is **key-to-visible-pixel latency**, both idle and
under output/Emacs load. [Typometer](https://github.com/pavelfatin/typometer) injects
OS keys and detects the resulting pixels; it supports macOS but is an older Java
tool, so verify it on your OS and calibrate capture overhead. A high-speed camera
filming the key action and screen is another independent end-to-end method. Report
median and tail latency, not only an average. Protocol reply times cannot replace
this measurement because they omit the real input and display paths.

For the embedded terminal, compare quiet Emacs with realistic redisplay/GC/Lisp activity
in a second pane while the native terminal stays visible. Record that workload
and its duration so it can be repeated. Run resource sampling separately too:

```sh
./benchmark.sh --label anymacs-resources --pid 12345
```

Match the exact Ghostty engine/configuration where possible: the embedded wrapper
and an installed Ghostty release may contain different engine revisions. A single
throughput score or composite “winner” hides these differences.

Research checked 2026-09-18. Verified execution in standalone Ghostty and native
Anymacs, including an Instruments capture. These smoke runs used different grids
and are not a comparative performance result. Local harness verification:
`python3 -B -m unittest discover -s test -p 'test_benchmark.py'`.
