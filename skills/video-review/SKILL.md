---
name: video-review
description: Review a rendered video or a Remotion project without watching it. Runs review-video.ps1 (Windows, ffmpeg) to extract timestamped frames at scene changes and every 2 s, check the audio (LUFS loudness, peaks, clipping, silences over 1.5 s, clicks and pops) and match narration lines to frames, then writes report.md and a PDF contact sheet. Use whenever the user asks to review, check, look at, QA or proofread a video, a render, an MP4 or other video file, a Short or explainer, or a Remotion project or composition; asks whether slides or on-screen text match the narration or voiceover; asks about a video's audio (too loud, clipping, clicks, gaps); or wants a PDF of a video to attach to a chat.
argument-hint: <video file or Remotion project folder> [options]
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/review-video.ps1" *) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/review-video.ps1" *)
---

# Video review

The tool turns a video file or a Remotion project into a review pack you can read: frames as PNGs,
audio findings and the narration line at each frame, all listed in `report.md`. Your job is to run
it, then review the video from the pack.

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
| `-SceneThreshold 0.3` | For camera footage (the default 0.02 suits slides with fades). |
| `-NoPdf` | Skip the PDF when the user only wants your review. |
| `-NoAudio` | Remotion: skip the audio render. |

Long videos take a while: about 30 s for 8 minutes of video, and about 4 s per Remotion still. Use
a timeout of 10 minutes. The last lines of the output give the paths of `report.md`, the frames
folder and the PDF. The pack goes in `<video name>-review\` next to the video, or in
`out\<composition>-review\` inside a Remotion project, unless `-OutDir` was given.

If the output ends with `FAILED:`, stop and tell the user the reason. If ffmpeg is missing, the
fix is `winget install --id Gyan.FFmpeg -e`, then a new terminal. Lines starting with `WARNING:`
also appear at the top of the report. Pass them on.

## 2. Review the video

1. Read `report.md`. It has warnings, a summary, the audio findings, the narration timeline (each
   line with its start, end and match score), then a table of every frame with its time, why it
   was taken, its file in `frames/` and the narration at that moment. "(pause; last line)" means
   no one is speaking and the line shown was the one just spoken.
2. Open the frames with the Read tool and compare each slide with its narration line. Look at the
   frames marked `end of scene` first (each is a finished slide just before it changes) and
   `scene change` (each is the next slide once it has settled), then the regular frames wherever
   the narration line changes or something builds up on screen. For a long video, sample the
   regular frames rather than opening them all.
3. Check for:
   - on-screen text, numbers, names or labels that disagree with the narration, or a slide that
     shows something before or after it is said;
   - typos, cut-off or overlapping text, text too small or low-contrast to read, empty or black
     frames, and placeholder or leftover content;
   - narration lines marked "not found", which may be missing from the render or changed since
     recording;
   - audio problems in the report: clipping, true peak above -1 dBTP, clicks or pops (give their
     times), silences in the middle of the video, and loudness far from about -14 LUFS.
4. Report back briefly: the problems first, each with the frame number and timestamp (for example
   `#14 00:22.00`) and what is wrong, then the audio findings, then anything the tool couldn't
   check (no narration found, or lines not matched). Say plainly if everything matches. Don't
   change the project unless the user asks.

## The PDF

`<name>-review.pdf` is in the same folder: a cover page with the audio findings, then 6 to 9
frames a page, each labelled with its timestamp and narration line. It is kept under 20 MB. When
the user wants something to attach to a Claude chat or send to someone, give them its full path.
Use `-MaxPdfMB <n>` for a smaller limit.
