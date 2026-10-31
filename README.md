# video-review-tool

A PowerShell script that turns a rendered video, or a Remotion project, into a review pack an AI
can read without watching the video:

- **Frames**: a PNG at every scene change, one every 2 seconds and the last frame, numbered and
  named with their timestamps.
- **Audio findings**: length, loudness (LUFS), true and sample peaks, clipping, silences longer than
  1.5 seconds, and sudden clicks or pops, all with timestamps.
- **Narration**: the line being spoken at each frame, when the project has a narration script,
  recording table, `voiceover.json` or subtitle file the script can match to the audio.
- **report.md**: everything above in one file, linking each frame. Made for Claude Code, which can
  open the report and the frames together.
- **A PDF** to attach to a Claude chat: a cover page with the audio findings, then a contact sheet
  of 6 to 9 labelled frames per page, with the narration line under each frame. Kept under 20 MB.

## Requirements

- Windows PowerShell 5.1 (built into Windows 10 and 11) or PowerShell 7.
- **ffmpeg 5.1 or newer**, with ffprobe, on PATH. The script checks and stops if they are missing.
  To install:

  ```powershell
  winget install --id Gyan.FFmpeg -e
  ```

  (or `choco install ffmpeg`, or a build from <https://www.gyan.dev/ffmpeg/builds/> with its `bin`
  folder added to PATH). Open a new PowerShell window afterwards so PATH is reloaded, then check
  with `ffmpeg -version`.
- **Microsoft Edge or Google Chrome** for the PDF (Edge comes with Windows). Use `-NoPdf` to skip it.
- **Remotion projects only**: Node.js, and `npm install` already run in the project.

The tool lives in `skills/video-review/`: `review-video.ps1`, `AudioScan.cs` (compiled by the
script on each run, so keep it next to it) and `SKILL.md`. That way the folder can be installed on
its own as a Claude Code skill (see [Using it with your AI](#using-it-with-your-ai)). The
`review-video.ps1` at the root of the repo is a shortcut to it.

## Running it

From PowerShell, in this folder:

```powershell
# A rendered video
.\review-video.ps1 C:\path\to\video.mp4

# A Remotion project: stills every 2 s plus the last frame, from the first composition
.\review-video.ps1 C:\path\to\remotion-project

# A Remotion project: chosen frames of a chosen composition
.\review-video.ps1 C:\path\to\remotion-project -Composition Main -Frames 0,90,450
```

If Windows blocks the script ("running scripts is disabled on this system"), run it this way
instead, or run `Get-ChildItem -Recurse *.ps1 | Unblock-File` once in this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\review-video.ps1 C:\path\to\video.mp4
```

The script prints each step, then where the report, frames and PDF are. If anything fails, it
stops with `FAILED:` and the reason, and exits with code 1. Problems that don't stop it (for
example, narration lines it could not find in the audio) are printed as `WARNING:` and listed at
the top of the report and the PDF.

### Output

By default the pack goes in `<video name>-review\` next to the video, or in
`out\<composition>-review\` inside a Remotion project. Use `-OutDir` to put it elsewhere.

```
explainer-review\
  report.md                 audio findings, narration timeline and the frame list
  explainer-review.pdf      cover page and contact sheet, for a Claude chat
  frames\
    0001_00-00-00.000_interval.png
    0006_00-00-08.733_end.png       finished slide just before a scene change
    0007_00-00-10.000_scene.png     new scene after the change has settled
    ...
```

Frame names are `<number>_<hh-mm-ss.mmm>_<reason>.png`. Running the script again replaces the
frames from the previous run.

## Using it with your AI

### Install it as a Claude Code skill

The `skills/video-review` folder is a complete Claude Code skill: the instructions Claude follows
(`SKILL.md`) and the tool itself. Copy it into your personal skills folder and every Claude Code
session on your computer can use it. From PowerShell, in this repo:

```powershell
New-Item -ItemType Directory -Force "$HOME\.claude\skills" | Out-Null
Copy-Item -Recurse -Force .\skills\video-review "$HOME\.claude\skills\"
```

That gives you `<your home folder>\.claude\skills\video-review\SKILL.md`. Claude Code picks the
skill up without a restart (if the `skills` folder didn't exist when the session started, type
`/reload-skills`). Run the same two lines again after you update this repo.

Then ask in plain words, for example:

> Review C:\path\to\video.mp4

> Check the slides in C:\path\to\remotion-project against the narration.

or type `/video-review C:\path\to\video.mp4`. Claude runs the tool, opens `report.md` and the
frames, checks each slide against its narration line and reports problems with frame numbers and
timestamps.

To use the skill in one project only, copy the folder into that project's `.claude\skills\`
folder instead.

### Without skills

Paste a prompt like this into a fresh session of Claude Code (or another AI assistant that can run
commands on your computer):

> Read the README at C:\path\to\video-review-tool\README.md. Then run the tool on
> C:\path\to\video.mp4, open report.md and the frames it makes, and check every slide against its
> narration line. List anything that doesn't match, with the frame number and timestamp, then any
> audio problems from the report.

For a Remotion project, name the folder and composition instead: *"run the tool on the Remotion
project in C:\path\to\remotion-project, composition Main"*.

### Getting a PDF to attach to a chat

Ask:

> Run the video review tool on C:\path\to\video.mp4 and give me the path to the PDF, so I can
> attach it to a Claude chat.

(Or run the tool yourself: the PDF is `<video name>-review\<video name>-review.pdf`.) Then attach
the PDF to a chat and ask, for example:

> This PDF is a review sheet for my video. The first page has the audio findings; then each frame
> is shown with its timestamp and the narration line at that moment. Check every frame against its
> narration line and list anything that doesn't match, with the frame number and timestamp.

## Options

| Option | Default | What it does |
| --- | --- | --- |
| `-OutDir <folder>` | see above | Where the review pack goes. |
| `-Interval <s>` | `2` | Seconds between regular frames. |
| `-SceneThreshold <n>` | `0.02` | Scene-change sensitivity. The default suits slides and motion graphics with fades; use about `0.3` for camera footage. |
| `-SilenceDb <dB>` | `-50` | Audio below this level counts as silence. |
| `-MinSilence <s>` | `1.5` | Shortest silence to report. |
| `-ClickRatio <n>` | `20` | How many times a jump must exceed the signal around it to count as a click. Lower it to catch quieter clicks (and get more false alarms). |
| `-ClickMinDb <dB>` | `-45` | Quietest jump that can count as a click. |
| `-ClipDb <dB>` | `-0.1` | Samples at or above this level count as clipped. |
| `-Narration <file>` | found automatically | Narration source to use (see below). |
| `-Project <folder>` | found automatically | Folder to search for narration when reviewing a video file. |
| `-Composition <id>` | first listed | Remotion only: the composition to render. |
| `-Frames 0,90,450` | every `-Interval` s | Remotion only: frame numbers to render. |
| `-NoAudio` | off | Remotion only: skip rendering the audio (no audio checks or narration). |
| `-MaxPdfMB <MB>` | `20` | PDF size limit. Frames are made smaller until it fits. |
| `-NoPdf` | off | Skip the PDF. |
| `-KeepWork` | off | Keep the temporary work folder, for debugging. |

`Get-Help .\skills\video-review\review-video.ps1 -Full` shows the same descriptions.

## Narration

The script looks for narration in this order:

1. The file given with `-Narration`.
2. A subtitle file next to the video with the same name (`video.srt` or `video.vtt`).
3. The project folder: the Remotion project, or the nearest folder above the video that has
   `package.json`, `script.md` or `src\voiceover.json` (or the folder given with `-Project`). It
   reads:
   - Markdown tables in the top-level `.md` files with a file column (`File`, `Clip`, `Audio`) and
     a text column (`Line`, `Text`, `Narration`): a **recording table**, one audio clip per line.
   - `voiceover.json` files: `{ "id": { "file": "audio/x.mp3", "seconds": 7.5, "words": [ { "text", "startMs", "endMs" } ] } }`.
     Clips are split into sentences using the word timings.
   - `.srt` and `.vtt` files, and tables with a `Start` or `Time` column, used with their own timings.
   - Quoted `> ` lines in the top-level `.md` files: listed in the report, but with no timings they
     can't be placed under frames.

Recording tables and `voiceover.json` don't say when each line plays in the finished video, so the
script finds out: it measures the loudness of each clip in 10 ms steps and finds where that pattern
best matches the video's audio, in order, line by line. Each line in the report has a match score
from 0 to 1. Lines below 0.7 are reported as not found and not used. When there are several
candidates (one table per Short, say), the one with the most matched lines is used, and the report
lists the others with their counts.

Clip files are found from the path in the table or JSON, then in `public\`, `public\audio\` and
`audio\`, then anywhere in the project by name.

## How the checks work

- **Scene changes**: ffmpeg compares frames 0.25 s apart (motion-graphics fades are too gradual to
  show up between neighbouring frames). For each change there are two frames: the finished slide
  just before it ("end of scene") and the new scene 0.5 s after it settles ("scene change"). The
  second is merged into a regular frame when one falls within 0.75 s.
- **Loudness and peaks**: ffmpeg's `ebur128` filter (integrated loudness, loudness range, true peak).
  The loudest moments and the sample peak come from the sample scan.
- **Silences**: ffmpeg's `silencedetect`, with `-SilenceDb` and `-MinSilence`.
- **Clicks and pops**: `AudioScan.cs` reads the decoded samples and looks for jumps in the
  waveform's second difference that are much larger than the signal in the 2 ms around them. That
  catches clicks, digital pops, and audio that starts or stops without a fade. Speech, including
  plosives, stays well below the default threshold. A quiet click under loud speech can be missed.
- **Clipping**: samples at or above `-ClipDb`.
- **Remotion projects**: the project is bundled once, each frame is rendered with
  `npx remotion still`, and unless `-NoAudio` is given the audio is rendered alone with
  `npx remotion render --codec=wav`, which is quick because no video frames are rendered.

### Limits

- Frame selection assumes a constant frame rate. A variable-rate video may miss some requested
  frames; the script lists them as a warning.
- Narration matching needs the narration to be clearly audible. Loud music under the voice
  lowers the match scores.
- The PDF is printed by Edge or Chrome in headless mode. If neither is installed, use `-NoPdf`.

## Privacy check

This repo uses the same fail-loudly privacy check as the other Ablation Lab repos.
`scripts/privacy-check.sh` scans the staged files for personal emails, keys and tokens, local
paths, hardware terms and a private list of terms. It runs from the pre-commit hook and blocks the
commit if anything matches (exit 1) or if the check itself can't run properly (exit 2).

- Turn the hook on once per clone: `git config core.hooksPath .githooks`
- Run it by hand: `bash scripts/privacy-check.sh` (staged files) or
  `bash scripts/privacy-check.sh --worktree` (all files, including untracked ones).
- The private list lives in `.privacy/patterns.txt`, one extended regex per line. It is git-ignored
  (`.privacy/.gitignore` contains `*`) and must never be committed; the check refuses to run if it
  is missing, empty or tracked.
- A known-safe line can be allowed by adding its hash to `.privacy-allow`:
  `bash scripts/privacy-check.sh --hash <path> <line number>`.
