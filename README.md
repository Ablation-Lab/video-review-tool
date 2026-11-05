# video-review-tool

A PowerShell script that turns a rendered video, or a Remotion project, into a review pack an AI
can analyze without watching the video:

- **Frames:** grabs a frame at every scene change and every 2 seconds, so a reviewer can see the video without watching it.
- **Key frames:** picks one fully built slide per scene, plus any flagged moments, for a small PDF you can attach to a chat.
- **Audio checks:** measures loudness, and flags clipping, clicks and long silences.
- **Narration matching:** lines up each recorded voice clip with where it plays in the video.
- **On-screen text:** reads all the text in the frames and flags possible spelling mistakes.
- **Number matching:** checks that numbers in the narration match the ones on screen.
- **Reading time:** flags text that disappears before anyone could read it.
- **Changes since last render:** shows only what's different from the previous version.
- **Shorts safe areas:** warns when text sits where YouTube's buttons would cover it.
- **Reports:** writes a report file, a text timeline for long videos, and a PDF for chats.
- **Claude Code skill:** you just ask in plain English. It skims by default, with optional full or every-frame reviews and limits to keep usage down.

Agents can rely on reading text summaries only for quick reviews or they can look at a mix of text, audio information and frame screenshots for a more detailed analysis.

You can copy/paste the pre made instructions i.e :  "Do a full review of C:\path\to\video.mp4"

or 'Skim C:\path\to\video.mp4 with Sonnet and write a timeline file, then give me your overall opinion from the timeline'

Or for chat  AI : 'Make a timeline file and a key-frames PDF for C:\path\to\video.mp4, so I can attach both to a chat'

Can also be installed on its own as a Claude Code skill (see [Using it with your AI](#using-it-with-your-ai))

You can copy/paste the pre made instructions i.e :  "Do a full review of C:\path\to\video.mp4"
or 'Skim C:\path\to\video.mp4 with Sonnet and write a timeline file, then give me your overall opinion from the timeline'
Or if you are only using a chat AI you can use:  'Make a timeline file and a key-frames PDF for C:\path\to\video.mp4, so I can attach both to a chat'

## Cost: skim versus full review

Running the tool costs nothing in AI usage. Having an AI open the frames is what costs: every
frame opened is an image it has to read. A full review of a 15-minute video, with six Opus
subagents opening every frame, used up a whole usage session.

- **Skim** (the default, and the one to use for long videos): the AI works from `report.md`, the
  OCR'd on-screen text and the scene-change frames (`end of scene` and `scene change`), and opens
  a frame image where something looks wrong: a flagged check, a narration line that doesn't fit
  the text on screen, a changed frame, an audio problem at that moment.
- **Always some real frames**: even a skim or a text-only review opens a small sample of key
  frames, about one fully built slide per scene, so the AI judges the visual style (layout,
  overlaps, contrast, empty frames) and not just the words. It says at the end how many frames it
  opened.
- **Full review**: only when you ask for one. Use a cheaper model for any subagents (Sonnet, unless
  you ask for Opus), run at most two at a time, and cap how many frames get opened in total (100
  unless you say otherwise). For a long video, a larger `-Interval` cuts the frame count before the
  review starts.

Rough guide to how many frames the tool makes:

| `-Interval` | Regular frames per minute | 5-minute video | 15-minute video |
| --- | --- | --- | --- |
| `1` | 60 | 300 | 900 |
| `2` (default) | 30 | 150 | 450 |
| `4` | 15 | 75 | 225 |
| `5` | 12 | 60 | 180 |
| `10` | 6 | 30 | 90 |

Add up to two frames per scene change (the end of one slide and the start of the next), so a
slide video with a new slide every 10 seconds adds up to about 12 a minute. The summary at the top
of `report.md` gives the exact count.

## How to ask

With the [skill installed](#install-it-as-a-claude-code-skill), copy one of these into Claude Code
and change the path.

**Skim** (the default): report, on-screen text and scene changes; frames opened only where
something looks wrong.

```text
Review C:\path\to\video.mp4
```

**Full review, capped**: opens up to 100 frames by default. On a video over 5 minutes, Claude
asks before it starts.

```text
Do a full review of C:\path\to\video.mp4
```

**Every frame**: no cap. On a long video this can use a whole usage session.

```text
Do a full review of C:\path\to\video.mp4, every frame, no cap
```

**Choosing the model** for the subagents: add one of these to a full review. Sonnet is
recommended; Opus uses much more usage.

```text
Do a full review of C:\path\to\video.mp4, use Sonnet subagents
```

```text
Do a full review of C:\path\to\video.mp4, use Opus
```

**Big-picture verdict, cheaply**: a Sonnet subagent skims the video and writes `timeline.md`, a
scene-by-scene timeline, and Claude gives its opinion of the whole video from that file without
opening frames itself.

```text
Skim C:\path\to\video.mp4 with Sonnet and write a timeline file, then give me your overall opinion from the timeline
```

**Just the PDF**: runs the tool and gives you the PDF's path, with no review.

```text
Make the review PDF for C:\path\to\video.mp4 so I can attach it to a chat
```

**Sharing with a chat AI**: for a long video, attach a text timeline file plus a small key-frames
PDF (about 15 to 20 frames), not the full contact sheet. `-KeyFramesPdf` makes `key-frames.pdf`:
one fully built frame per scene (the end-of-scene frame, once everything has appeared) plus any
frames flagged as findings, each page labelled with its timestamp, scene name and the finding. Ask:

```text
Make a timeline file and a key-frames PDF for C:\path\to\video.mp4, so I can attach both to a chat
```

The key-frames PDF is the one to attach for long videos. The full contact-sheet PDF is best for
short videos such as Shorts, or for just the changed frames (`-ChangesPdf`).

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
- **Remotion projects only**: Node.js, and `npm install` already run in the project. The tool
  runs `npx remotion` in that project, which runs the project's own code (its Remotion config and
  components), so only review Remotion projects you trust.
- **On-screen text checks**: nothing to install. They use the OCR and spell checker built into
  Windows 10 and 11, through Windows PowerShell 5.1 (also built in). OCR needs a recognizer for your
  language; English is normally there already. If it isn't, the script stops and says how to add
  it (Settings > Time & language > Language & region). Use `-NoOcr` to skip these checks.

The tool lives in `skills/video-review-skill/`, so that folder can be installed on its own as a Claude
Code skill (see [Using it with your AI](#using-it-with-your-ai)). Keep its files together:

| File | Does |
| --- | --- |
| `review-video.ps1` | The tool. |
| `review-checks.ps1` | The on-screen text checks and the comparison with the last review (loaded by the tool). |
| `windows-text.ps1` | Calls Windows' OCR and spell checker (started by the tool). |
| `AudioScan.cs` | Sample-level audio checks, narration matching and frame comparison (compiled by the tool on each run). |
| `SKILL.md` | Instructions for Claude Code. |

The `review-video.ps1` at the root of the repo is a shortcut to the tool.

## Getting it

```powershell
git clone https://github.com/Ablation-Lab/video-review-tool.git
cd video-review-tool
```

Then run it from that folder (below), or install it as a Claude Code skill (see
[Using it with your AI](#using-it-with-your-ai)).

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
  report.md                 changes, audio, narration, on-screen text checks and the frame list
  explainer-review.pdf      cover page and contact sheet, for a Claude chat
  explainer-changes.pdf     only with -ChangesPdf: the frames that changed since the last review
  key-frames.pdf            only with -KeyFramesPdf: about 15 to 20 key frames, for a chat
  review.json               frame data the next run compares with
  frames\
    0001_00-00-00.000_interval.png
    0006_00-00-08.733_end.png       finished slide just before a scene change
    0007_00-00-10.000_scene.png     new scene after the change has settled
    ...
  previous\                 the last run, kept for the comparison (report, frames, PDFs)
```

Frame names are `<number>_<hh-mm-ss.mmm>_<reason>.png`. Running the script again moves the last
run into `previous\` (replacing the one before) and compares with it.

## Using it with your AI

### Install it as a Claude Code skill

The `skills/video-review-skill` folder is a complete Claude Code skill: the instructions Claude
follows (`SKILL.md`) and the tool itself. The folder has the same name as the skill, as the
[Agent Skills spec](https://agentskills.io/specification) requires. Copy it into your personal
skills folder (`~/.claude/skills/`) and every Claude Code session on your computer can use it.
From PowerShell, in this repo:

```powershell
New-Item -ItemType Directory -Force "$HOME\.claude\skills\video-review-skill" | Out-Null
Copy-Item -Recurse -Force .\skills\video-review-skill\* "$HOME\.claude\skills\video-review-skill\"
```

That gives you `~/.claude/skills/video-review-skill/SKILL.md` (on Windows,
`<your home folder>\.claude\skills\video-review-skill\SKILL.md`). Claude Code picks
the skill up without a restart (if the `skills` folder didn't exist when the session started, type
`/reload-skills`). Run the same two lines again after you update this repo.

Earlier versions installed the skill in a `video-review` folder. If you have one, remove it so
Claude Code doesn't load the skill twice:

```powershell
Remove-Item -Recurse -Force "$HOME\.claude\skills\video-review" -ErrorAction SilentlyContinue
```

Then ask in plain words, for example:

> Review C:\path\to\video.mp4

> Check the slides in C:\path\to\remotion-project against the narration.

> What changed in C:\path\to\video.mp4 since the last review?

or type `/video-review-skill C:\path\to\video.mp4`. Claude runs the tool, opens `report.md` and the
frames, checks each slide against its narration line, goes through the on-screen text checks and
reports problems with frame numbers and timestamps.

To use the skill in one project only, copy the files into a `video-review-skill` folder inside
that project's `.claude\skills\` folder instead.

### claude.ai

The skill can't do its work in claude.ai. It runs PowerShell, ffmpeg and Windows' own OCR and
spell checker on your computer, and skills uploaded to claude.ai run in Anthropic's Linux sandbox,
which has none of these and can't see your video files. Use it in Claude Code on Windows. If you
want Claude in claude.ai to look at a video, run the tool yourself and attach the PDF it makes
(see [Getting a PDF to attach to a chat](#getting-a-pdf-to-attach-to-a-chat)).

So don't upload it to claude.ai. Anthropic's docs say claude.ai rejects skills that use Claude
Code-only fields such as this skill's `argument-hint`. And a skill you do turn on in claude.ai
also loads in Claude Code 2.1.273 or later when you're signed in with the same account (as
`anthropic-skills:video-review-skill`), so with a local copy installed too, Claude Code would
load it twice.

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

For a long video, attach the small key-frames PDF (about 15 to 20 frames, one per scene plus the
flagged ones, under 10 MB) and a text timeline:

> Run the video review tool on C:\path\to\video.mp4 with -KeyFramesPdf and give me the path to key-frames.pdf.

If the review folder already holds a complete review, `-KeyFramesPdf` builds the PDF from those
frames and changes nothing else; otherwise it runs the review first. Scenes are found from the
numbered footer badge on slide videos (`03 / SIZE DEPENDS ON THE TASK`); with no clear scenes, it
picks frames spread evenly over the video. Findings are the frames the review flagged (spelling,
reading time, spoken numbers not on screen, safe areas, frames with no text).

For a short video, the full contact sheet is fine. Ask:

> Run the video review tool on C:\path\to\video.mp4 and give me the path to the PDF, so I can
> attach it to a Claude chat.

For a re-render, ask for just the changes:

> Run the video review tool on C:\path\to\video.mp4 with -ChangesPdf and give me the changes PDF.

(Or run the tool yourself: the PDF is `<video name>-review\<video name>-review.pdf`.) Then attach
the PDF to a chat and ask, for example:

> This PDF is a review sheet for my video. The first pages have the audio findings and automatic
> checks; then each frame is shown with its timestamp, any problems found (red), the narration line
> at that moment and the on-screen text read by OCR (blue). Check every frame against its narration
> line and list anything that doesn't match, with the frame number and timestamp.

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
| `-NoOcr` | off | Skip the on-screen text and its checks (spelling, reading time, numbers, safe areas). |
| `-OcrLanguage <tag>` | your Windows language | Language for OCR and spelling, e.g. `en-US`. |
| `-WordList <file>` | none | Extra words the spelling check accepts, one per line. `review-words.txt` in the project folder is read automatically. |
| `-WordsPerSecond <n>` | `3` | Reading speed for the reading-time check. |
| `-NumberWordsFrom <n>` | `10` | Numbers spoken as words are checked from this value up ("five" is often said without being shown). Numbers written as digits in the narration are always checked. |
| `-SafeMargins t,r,b,l` | `288,192,672,48` | Shorts safe-area margins in pixels at 1080x1920 (top, right, bottom, left). |
| `-CompareWith <folder>` | the last run | A previous review folder to compare with, e.g. the review of an older file name. |
| `-ChangesPdf` | off | Also make a PDF of only the frames that changed since the previous review. |
| `-KeyFramesPdf` | off | Also make `key-frames.pdf`: about 15 to 20 frames (one fully built frame per scene plus flagged frames), each labelled with timestamp, scene and finding. Built from the existing frames if the output folder already holds a review. |
| `-KeyFramesMaxMB <MB>` | `10` | Size limit for `key-frames.pdf`. Frames are made smaller until it fits. |
| `-KeepWork` | off | Keep the temporary work folder, for debugging. |

`Get-Help .\skills\video-review-skill\review-video.ps1 -Full` shows the same descriptions.

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

## On-screen text checks

Every frame is read three times with Windows OCR and the readings are merged: as it is (best for
small text), with its colours inverted, and inverted at half size. Windows OCR reads dark text on a
light background best; on dark slides it can miss big headline numbers at full size and read them
fine once inverted and halved. The text of each frame is in the report's frame table and under
each frame in the PDF.

- **Spelling**: words the Windows spell checker (in your Windows language) rejects. To keep OCR
  misreads out, a word is listed only when the original frame and an inverted copy both read it the
  same way; words read only one way are listed separately as probable misreads. It also skips
  words under 4 letters, words with digits, short all-caps words (acronyms), camelCase names,
  words that appear in the narration, part-words from text being typed on (the start of a longer
  word seen in another frame) and words in `review-words.txt` in the project folder (one per line).
- **Reading time**: slides run from one scene change to the next. Text carried over from the
  previous slide (headers, footers) doesn't count, and bare numbers don't count as words. Each new
  line counts from when it first appears; a slide is flagged if, from any of those moments, the
  words still to read need more than 0.5 s longer than is left, at `-WordsPerSecond` (3 by
  default). The 0.5 s allows for frames being sampled every 2 s. Video files only, since it needs
  the scene changes.
- **Numbers**: each narration line with a number in it (digits such as 97, 3.7M, $2, 48%, 1,200, and
  number words from `-NumberWordsFrom` up, such as "seventeen" or "three point seven million") is
  checked against the text on screen from 0.5 s before the line to 1 s after it. A number that
  doesn't appear is flagged, with the numbers that were on screen. "3.7 million" matches "3.7M" or
  "3.7"; "48 percent" matches "48%". Needs narration placed in time.
- **Shorts safe areas**: for vertical 9:16 videos, any text inside the margins YouTube Shorts
  covers. YouTube publishes no official figure for organic Shorts. The default comes from Google's
  *Universal Video Ad Safe Zones* sheet for vertical video (1080x1920): 288 px top, 192 px right,
  672 px bottom, 48 px left. It is the only first-party guide and the most cautious one; third-party
  estimates for ordinary Shorts are smaller (some use about 180 top, 120 right, 390 bottom, 60 left)
  and disagree with each other. Use `-SafeMargins 180,120,390,60` or similar for a looser check.

OCR is good on clear slide text but not perfect: it can misread small, faint or monospaced text (an
I read as 1, "R1" as "RI"), so every flag is something to look at, not a verdict. When OCR misses a
number entirely, the number check flags it as missing.

## Changes since the last render

Each run saves `review.json` (every frame's text and a small greyscale copy of its picture). The
next run of the same video (same output folder) moves the last run into `previous\` and compares:
a frame counts as changed when no frame of the previous review looks the same, so frames that only
moved in time aren't listed. A "Changes since the last review (changes only)" section at the top of
the report lists the changed frames, each with a link to the previous frame nearest in time and the
words added and removed on screen. The report also counts previous frames that no longer appear.

- To compare with the review of a different file (say `video-v2.mp4` against `video-v1.mp4`), add
  `-CompareWith C:\path\to\video-v1-review`.
- Add `-ChangesPdf` for `<name>-changes.pdf`: a cover listing the changes, then only the changed
  frames, ready to attach to a chat.

Re-encoding alone doesn't count as a change: in testing, re-encoded copies with a few planted
edits showed exactly the edited frames as changed.

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
- OCR, spelling and the safe-area figures have the limits described in
  [On-screen text checks](#on-screen-text-checks). The OCR passes add about 10 to 15 s per 100 frames.
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

## Credits and licence

Built with [Claude Code](https://claude.com/claude-code).

Released under the MIT licence; see [LICENSE](LICENSE). This is an unofficial community project
from Ablation Lab. It isn't made, endorsed or supported by Anthropic.
