# Cutproof (video-review-tool)

Proofread a video without watching it.

Cutproof checks your finished video the way an editor would, before you publish. It lines up your narration (from your script or subtitles) with what's on screen, then flags typos, numbers that don't match the voiceover, text that vanishes before anyone can read it, and audio problems, with timestamps. It runs entirely on your Windows PC and makes no network requests of its own.

Under the hood, it's a PowerShell script that turns a rendered video, or a Remotion project, into a review pack an AI
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

An AI can work from the text summaries alone for a quick review, or look at a mix of text, audio
findings and frame images for a more detailed one.

It comes as a Claude Code plugin called **Cutproof** (see
[Install it as a Claude Code plugin](#install-it-as-a-claude-code-plugin)), and its skill can also
be installed on its own (see [Using it with your AI](#using-it-with-your-ai)).

## Example prompts

Copy one of these into Claude Code and change the path:

1. "Do a full review of C:\path\to\video.mp4"
2. "Skim C:\path\to\video.mp4 with Sonnet and write a timeline file, then give me your overall opinion from the timeline"
3. "Make a timeline file and a key-frames PDF for C:\path\to\video.mp4, so I can attach both to a chat"

[How to ask](#how-to-ask) has more, and explains what each kind of review costs.

## Try it with the sample

The `samples` folder lets you try Cutproof on a 6-second test video before using your own. The
video itself isn't stored in the repo, because Anthropic's plugin directory accepts only text and
image files, so make it first. From this repo's folder (it needs ffmpeg):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\samples\make-sample.ps1
```

That writes `samples\cutproof-sample.mp4` (about 16 KB): two slides of white text that ffmpeg
draws from scratch from `samples\cutproof-sample-slides.ass`, with no audio. It needs an ffmpeg
build with libass, which the builds in [Requirements](#requirements) include. Its narration is `samples\cutproof-sample.srt`, which Cutproof
finds because it has the same name. Two problems are planted: the first slide says "sampel", and
the second shows 25% while the narration says 35%.

Then, in Claude Code in this folder, try the three example prompts on it:

1. "Do a full review of samples\cutproof-sample.mp4"
2. "Skim samples\cutproof-sample.mp4 with Sonnet and write a timeline file, then give me your overall opinion from the timeline"
3. "Make a timeline file and a key-frames PDF for samples\cutproof-sample.mp4, so I can attach both to a chat"

Each should name both problems with their timestamps and say there's no audio to check.
[samples/expected-results.md](samples/expected-results.md) lists what the report should contain.
The review pack goes in `samples\cutproof-sample-review\`; delete it and the video when you're done.

## Where it works

Cutproof runs only in Claude Code on Windows. In Claude chat or Cowork you can still ask Claude to
write you a ready-to-paste Claude Code prompt for reviewing your video, then run it in Claude Code.

- **Claude Code on Windows:** yes, with ffmpeg installed (see [Requirements](#requirements)).
  Install it as a plugin or as a skill folder.
- **Chat in claude.ai and the Claude apps:** no. If you add Cutproof from the plugin directory, its
  skill also loads in chat, but there it would have to run in Claude's code execution sandbox,
  which can't run Windows PowerShell or ffmpeg on your computer or see your video files. Run the
  tool yourself and attach the PDF it makes instead (see
  [Getting a PDF to attach to a chat](#getting-a-pdf-to-attach-to-a-chat)).
- **Cowork:** the skill loads there too, but the tool only works where it can run Windows
  PowerShell and ffmpeg on your own Windows computer, with access to the video. It hasn't been
  tested in Cowork.
- **macOS and Linux:** not supported. The tool relies on Windows PowerShell and the OCR and spell
  checker built into Windows.

A plugin you add to your claude.ai account also appears in Claude Code as a synced plugin at the
next session start, so you don't need to install it there separately.

## What this plugin runs, sends and fetches

Everything runs on your computer. The plugin adds one skill and no hooks, commands or servers.

- **The command Claude runs.** `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill folder>/review-video.ps1"`
  with the video or project path and the options. The skill pre-approves nothing, so Claude Code
  shows you the command and asks before each run, unless your own permission settings already
  allow it. `-ExecutionPolicy Bypass` lets the tool's unsigned scripts run even where Windows'
  script policy would block them. It applies to that one PowerShell process only and doesn't
  change your system's policy.
- **The programs the tool starts:**
  - `ffmpeg` and `ffprobe` from your PATH, to take frames, find scene changes and measure the audio.
  - Windows PowerShell 5.1 (`powershell.exe`), as a separate process running `windows-text.ps1`,
    which uses the OCR and spell checker built into Windows.
  - Microsoft Edge or Google Chrome in headless mode, with a throwaway profile in the work folder,
    to print the PDF from a local HTML page.
  - `AudioScan.cs`, the bundled C# source, which PowerShell compiles in memory with `Add-Type` on
    each run. It starts ffmpeg to decode the audio.
  - **Remotion projects only:** the project's own Remotion CLI (`node_modules\@remotion\cli`),
    run with Node.js, to bundle the project and render stills and the audio. That runs the
    project's own code, so only review projects you trust; Claude asks first if you didn't make
    the project. The tool never runs `npx` and never installs or downloads packages: if Remotion
    isn't installed in the project, it stops. Remotion itself may download its own headless
    Chrome the first time it renders, as it does in any Remotion project.
- **The sample maker** (`samples\make-sample.ps1`) runs only if you run it. It runs one fixed
  ffmpeg command: ffmpeg's built-in colour source, with the slides' text from
  `samples\cutproof-sample-slides.ass` drawn in the Arial font Windows already has. It writes one
  MP4 next to itself and reads nothing else. See [Try it with the sample](#try-it-with-the-sample).
- **What it reads:** the video or Remotion project you name, and in that project folder the
  narration files, audio clips and `review-words.txt` it looks for (see [Narration](#narration));
  files you pass with `-Narration`, `-WordList` or `-CompareWith`; and the previous review kept in
  `previous\`.
- **What it writes:**
  - The review pack: `<video name>-review\` next to the video, `out\<composition>-review\` inside
    a Remotion project, or the folder you give with `-OutDir`. Each run moves the last run's files
    into `previous\`, replacing the run kept there before. Only files the tool wrote are moved or
    deleted, so other files in that folder are left alone.
  - A work folder, `%TEMP%\video-review-<id>`, deleted at the end unless you add `-KeepWork`.
- **What it sends and fetches:** nothing. The tool makes no network requests (see the Remotion
  note above). Frames and the report reach Anthropic only the way anything in your conversation
  does: when Claude opens them, or when you attach the PDF to a chat.

## Privacy

Cutproof collects nothing. There is no telemetry, no account and no server.

- **Read:** the video or Remotion project you point it at; in its project folder, the narration
  files, audio clips and `review-words.txt` it looks for; files you pass with `-Narration`,
  `-WordList` or `-CompareWith`; and the previous review kept in `previous\`. Nothing else.
- **Written:** only the review pack and a temporary work folder, both on your computer (see
  [What it writes](#what-this-plugin-runs-sends-and-fetches)).
- **Sent:** nothing, by the tool. Claude sees frames and the report only when it opens them in
  your conversation, and a chat AI sees the PDF only if you attach it.

Questions, bugs and security reports:
[GitHub issues](https://github.com/Ablation-Lab/video-review-tool/issues).

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
  runs the project's own Remotion CLI with Node (never `npx`, so nothing is downloaded), which runs
  the project's own code (its Remotion config and components), so only review Remotion projects
  you trust.
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
| `key-frames.ps1` | Builds `key-frames.pdf` for `-KeyFramesPdf` (loaded by the tool). |
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
run into `previous\` (replacing the one before) and compares with it. Only the files the script
wrote are moved or deleted, so it's safe to point `-OutDir` at a folder that holds other files.

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

### Install it as a Claude Code plugin

The repo is also a Claude Code plugin, and its own plugin marketplace, so you can install the
skill without copying files and update it with one command. In Claude Code 2.1.275 or later:

```text
/plugin install cutproof --marketplace Ablation-Lab/video-review-tool
```

On older versions, run `/plugin marketplace add Ablation-Lab/video-review-tool`, then
`/plugin install cutproof@cutproof`. To update it later, run
`claude plugin update cutproof@cutproof`.

If you installed it earlier under its old name, `video-review-skill`, remove that first with
`/plugin uninstall video-review-skill@video-review-skill` and
`/plugin marketplace remove video-review-skill`, then install Cutproof as above.

The plugin is called Cutproof and contains the same skill folder, so it works the same way. Ask in
plain words as above, or type `/cutproof:video-review-skill C:\path\to\video.mp4`. Use either the plugin or a
copied skill folder, not both, or Claude Code loads the skill twice.

### claude.ai

You can upload the skill to claude.ai (Customize > Skills), but it only does its work in Claude
Code on Windows. It runs PowerShell, ffmpeg and Windows' own OCR and spell checker on your
computer. Skills in claude.ai run in Claude's code execution sandbox instead, where the tool can't
run and can't see your video files. If you want Claude in claude.ai to look at a video, run the
tool yourself and attach the PDF it makes (see
[Getting a PDF to attach to a chat](#getting-a-pdf-to-attach-to-a-chat)).

What uploading does give you: a skill turned on in claude.ai also loads in Claude Code 2.1.273 or
later when you're signed in with the same account, as `anthropic-skills:video-review-skill`
(see [Anthropic's skills docs](https://code.claude.com/docs/en/skills)). Then you don't need a
local copy, and you shouldn't keep one, or Claude Code loads the skill twice.

To follow claude.ai's rules, the upload must be a zip with the `video-review-skill` folder at its
root, holding all six files, not just `SKILL.md`. Its `SKILL.md` can only use the
[Agent Skills spec](https://agentskills.io/specification) fields (`name`, `description`,
`license`, `compatibility`, `metadata`, `allowed-tools`), and an upload with any other field
fails. So leave out the `argument-hint` line, which only adds a hint to Claude Code's `/` menu.
From PowerShell, in this repo:

```powershell
$tmp = Join-Path $env:TEMP 'video-review-skill-upload'
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
New-Item -ItemType Directory $tmp | Out-Null
Copy-Item -Recurse .\skills\video-review-skill $tmp
$root = Join-Path $tmp 'video-review-skill'
$skill = Join-Path $root 'SKILL.md'
[IO.File]::WriteAllLines($skill, [string[]](Get-Content -Encoding UTF8 $skill | Where-Object { $_ -notmatch '^argument-hint:' }))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = "$env:TEMP\video-review-skill.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
Get-ChildItem $root -File -Recurse | ForEach-Object {
    $name = 'video-review-skill/' + $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $name) | Out-Null
}
$archive.Dispose()
```

Don't use `Compress-Archive` or another zip tool that stores paths with `\` (Windows
PowerShell 5.1's does): claude.ai rejects that zip with "Zip file contains path with invalid
characters". The snippet above names each file with `/`.

Then upload `video-review-skill.zip` from your temp folder (type `%TEMP%` in File Explorer's
address bar to find it). After you update this repo, build and upload it again.

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
- **Remotion projects**: the project is bundled once with its own Remotion CLI, each frame is
  rendered with `remotion still`, and unless `-NoAudio` is given the audio is rendered alone with
  `remotion render --codec=wav`, which is quick because no video frames are rendered.

### Limits

- Frame selection assumes a constant frame rate. A variable-rate video may miss some requested
  frames; the script lists them as a warning.
- Narration matching needs the narration to be clearly audible. Loud music under the voice
  lowers the match scores.
- OCR, spelling and the safe-area figures have the limits described in
  [On-screen text checks](#on-screen-text-checks). The OCR passes add about 10 to 15 s per 100 frames.
- The PDF is printed by Edge or Chrome in headless mode. If neither is installed, use `-NoPdf`.

## Maintainers: tests

Two PowerShell test scripts need no ffmpeg, network or Pester. Each exits with code 0 when every
check passes:

- `tests\Move-PreviousReview.Tests.ps1` checks that each run keeps the last review in
  `previous\` and never moves or deletes files the tool didn't write.
- `tests\Remotion-Cli.Tests.ps1` checks, with a fake `@remotion/cli` package, that a Remotion
  project's own CLI is run with Node and never through `npx` (it needs Node.js).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Move-PreviousReview.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Remotion-Cli.Tests.ps1
```

## Maintainers: privacy check

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
