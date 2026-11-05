# Expected results for the sample

What a review of `cutproof-sample.mp4` (made by `make-sample.ps1`) should report. Taken from a real
run of `review-video.ps1` on Windows 11 with ffmpeg 9.0. Exact frame times can shift slightly with
another ffmpeg version, but the findings shouldn't.

## The two deliberate problems

| Problem | Where | What Cutproof reports |
|---|---|---|
| Typo on screen: "sampel" | Slide 1, 0-3 s | **Possible spelling mistakes:** `sampel`, suggestions `sample, simple, sampled`, on frames #1-#3 |
| Number that doesn't match the narration | Slide 2, 3-6 s | **Numbers in the narration:** line 2 at 00:03.00 says `35%`; **35%** is missing on screen, which shows `25%` (frames #3-#5) |

## Everything else in the report

- **Warning:** "The video has no audio track." That's expected: the sample has no audio, so the
  audio checks (loudness, clipping, clicks, silences) are skipped.
- **Narration:** 2 of 2 lines placed, from `cutproof-sample.srt`, with timings from the file.
- **Reading time:** 0 of 2 slides too quick (5 and 4 new words, each shown for 3 s).
- **Shorts safe areas:** not checked, because the sample isn't a vertical 9:16 video.
- **Frames:** 5 (every 2 s, the end of slide 1, the scene change and the last frame).
- The final lines of the tool's output:

```
  Narration: 2 of 2 lines placed (cutproof-sample.srt)
  Text:   1 possible spelling mistake(s), 0 slide(s) too quick to read, 1 line(s) with a spoken number not on screen
  1 warning(s); see the top of report.md.
```

Claude's own review should name both problems with their timestamps, and say there's no audio to check.
