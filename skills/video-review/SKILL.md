---
name: video-review
description: Review a rendered video or a Remotion project without watching it. Runs review-video.ps1 (Windows, ffmpeg) to extract timestamped frames at scene changes and every 2 s, check the audio (LUFS, peaks, clipping, silences, clicks), match narration lines to frames, read the on-screen text with Windows OCR (spelling, reading time, spoken numbers missing from the screen, YouTube Shorts safe areas) and list what changed since the last review, then writes report.md and a PDF contact sheet. Use whenever the user asks to review, check, look at, QA or proofread a video, a render, an MP4, a Short or explainer, or a Remotion project or composition; asks whether slides or on-screen text match the narration; asks about typos, text that is too fast to read, numbers, safe areas or a video's audio; asks what changed since the last render; or wants a PDF of a video to attach to a chat.
argument-hint: <video file or Remotion project folder> [options]
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/review-video.ps1" *) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/review-video.ps1" *)
---

# Video review

The tool turns a video file or a Remotion project into a review pack you can read: frames as PNGs,
audio findings, the narration line and the OCR'd on-screen text at each frame, automatic checks,
and what changed since the last review, all in `report.md`. Your job is to run it, then review the
video from the pack.

## 1. Run the tool

Run it with this exact command (it works from both the Bash and the PowerShell tool), using the
user's path in quotes:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/review-video.ps1" "<video file or Remotion project folder>" [options]
```

- **Video file** (MP4, MOV and so on): frames every 2 s, around each scene change and at the end.
- **Remotion project folder**: stills rendered with `npx remotion still` (no full render needed)
  and the audio rendered on its own. It uses the first composition unless `-Composition <id>` is
  given; the output lists the others. It needs `npm install` already run in the project.

Useful options (all optional):

| Option | Use |
| --- | --- |
| `-Composition <id>` | Remotion: which composition to render. |
| `-Frames 0,90,450` | Remotion: render only these frame numbers. |
| `-Interval <s>` | Seconds between regular frames (default 2). Use 4 or more for long videos. |
| `-Narration <file>` | Narration source if it isn't found automatically: `.srt`, `.vtt`, `.csv`, `.md` recording table or `voiceover.json`. |
| `-Project <folder>` | Folder to search for narration when the video sits outside its project. |
| `-OutDir <folder>` | Where to write the pack. |
| `-CompareWith <folder>` | Compare with an older review folder (e.g. of a previous file name). By default each run compares with the last run of the same video. |
| `-ChangesPdf` | Also make a PDF of only the changed frames, when the user wants just the changes. |
| `-WordsPerSecond <n>` | Reading speed for the reading-time check (default 3). |
| `-NumberWordsFrom <n>` | Spoken number words are checked from this value up (default 10). |
| `-SafeMargins t,r,b,l` | Shorts safe-area margins at 1080x1920 (default 288,192,672,48, Google's cautious figures). |
| `-WordList <file>` | Extra words the spelling check accepts. |
| `-SceneThreshold 0.3` | For camera footage (the default 0.02 suits slides with fades). |
| `-NoOcr` | Skip the on-screen text checks. |
| `-NoPdf` | Skip the PDF when the user only wants your review. |
| `-NoAudio` | Remotion: skip the audio render. |

Long videos take a while: about 2 minutes for 8 minutes of video, and about 4 s per Remotion
still. Use a timeout of 10 minutes. The last lines of the output give the paths of `report.md`, the
frames folder and the PDFs, plus one-line totals for the audio, text checks and changes. The pack
goes in `<video name>-review\` next to the video, or in `out\<composition>-review\` inside a
Remotion project, unless `-OutDir` was given. Each run keeps the previous one in `previous\`.

If the output ends with `FAILED:`, stop and tell the user the reason. If ffmpeg is missing, the
fix is `winget install --id Gyan.FFmpeg -e`, then a new terminal. Lines starting with `WARNING:`
also appear at the top of the report. Pass them on.

## 2. Review the video

1. Read `report.md`. In order: warnings; **changes since the last review** (only when there was a
   previous run: the changed frames, with a link to the old frame and the words added and
   removed); a summary; audio findings; the narration timeline (each line with its start, end and
   match score); the **on-screen text checks** (spelling, reading time, numbers, Shorts safe
   areas); then a table of every frame with its time, why it was taken, its file in `frames/`, the
   narration at that moment, its OCR text and its flags. "(pause; last line)" means no one is
   speaking and the line shown was the one just spoken.
2. If the user asked what changed, or a changes section is present, start with the changed frames:
   open each one next to its previous frame and say what changed.
3. Open the frames with the Read tool and compare each slide with its narration line. Look at the
   frames marked `end of scene` first (each is a finished slide just before it changes) and
   `scene change` (each is the next slide once it has settled), then the regular frames wherever
   the narration line changes or something builds up on screen, and every flagged frame. For a
   long video, sample the regular frames rather than opening them all.
4. Treat the automatic checks as leads, not verdicts, and confirm each one in the frame image:
   - **Spelling**: OCR can misread small, faint or monospaced text, and some flagged words are
     deliberate (names, misheard words shown on purpose). Report only the ones the image confirms.
   - **Reading time**: flagged slides have more new words than fit their time at the given words
     per second. Narrated diagrams with many labels trip it easily; say which slides really need
     more time.
   - **Numbers**: a spoken number not found on screen is either a real mismatch (the slide shows a
     different figure) or a number OCR missed, often big headline digits. Check the frame.
   - **Safe areas**: text inside YouTube's overlay margins on vertical videos. The default margins
     are the most cautious published ones, so prioritise text near the bottom and right edges.
5. Also check by eye for on-screen text, numbers, names or labels that disagree with the narration,
   cut-off or overlapping text, low contrast, empty or black frames, and placeholder or leftover
   content; narration lines marked "not found"; and audio problems in the report (clipping, true
   peak above -1 dBTP, clicks or pops, silences mid-video, loudness far from about -14 LUFS).
6. Report back briefly: the problems first, each with the frame number and timestamp (for example
   `#14 00:22.00`) and what is wrong, then the audio findings, then anything the tool couldn't
   check. Say plainly if everything matches. Don't change the project unless the user asks; if a
   flagged word is correct, you can suggest adding it to `review-words.txt` in the project folder.

## The PDFs

`<name>-review.pdf` is in the same folder: a cover page with the audio findings, the checks and any
changes, then 6 to 9 frames a page, each labelled with its timestamp, any problems found (red), the
narration line and the OCR text (blue, misspellings underlined). It is kept under 20 MB. With
`-ChangesPdf` there is also `<name>-changes.pdf` with only the changed frames. When the user wants
something to attach to a Claude chat or send to someone, give them the full path. Use
`-MaxPdfMB <n>` for a smaller limit.
