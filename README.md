# DIT Media Ingest

A macOS menu-bar app for verified camera-card offloads, built for a working
video production studio. Card in → verified dump → parallel-safe backups →
Finder previews → Notion project sync — with crash recovery at every step.

<!-- screenshot: docs/screenshot.png -->

## What it does

- **Auto-detects inserted cards** and offers to ingest; detects the camera
  (Sony, Blackmagic BRAW via the Blackmagic RAW SDK, BWF audio recorders) and
  names folders accordingly: `Client/yy.mm_Project_JobCode/Video/01_Camera_date/`
- **Verified copies** — every file is MD5-hashed during the copy and verified
  at the destination; a manifest receipt is written next to each card folder
- **Crash-safe by design** — atomic writes (`.partial` → rename), per-drive
  write locking, and a resume system that detects interrupted backups from the
  log and offers one-click retry in a Pending Backups panel
- **Backups that respect fragile filesystems** — sequential per drive, safe
  for ExFAT/NTFS archive disks; folder names are sanitized for them too
- **BRAW Finder previews** — macOS dropped legacy Quick Look plugins, so the
  app stamps each .braw's first frame onto the file as its Finder icon using
  a small bundled tool built on the Blackmagic RAW SDK (footage bytes untouched;
  checksums stay valid)
- **A thumbnail file browser** with real BRAW previews for hand-picking clips,
  or "Dump full card"
- **Notion integration** — projects and job codes pull from a Notion database;
  each ingest posts a receipt comment to the project page
- **Auto-transcription hand-off** — optionally triggers
  [Notion Transcribe](https://github.com/1calledluke) on interview folders the
  moment a dump verifies
- **Self-updating** from this repo's releases

## Requirements

- macOS 14+, Apple Silicon
- [exiftool](https://exiftool.org) (`brew install exiftool`) for camera detection
- [Blackmagic RAW](https://www.blackmagicdesign.com/products/blackmagicraw)
  (or DaVinci Resolve) for BRAW thumbnails/previews — optional; everything
  else works without it
- A Notion integration token (Settings… → paste) for project sync — optional

## Install

Grab the zip from [Releases](../../releases), unzip into `/Applications`,
launch. The app lives in the menu bar and registers itself as a login item.

## Build from source

```bash
swift build            # debug
./build.sh install     # release bundle -> /Applications
./.build/debug/DITIngest --selftest   # engine + resume-detector test suite
```

The BRAW tool builds separately against the Blackmagic RAW SDK:

```bash
clang++ -std=c++17 -O2 tools/brawthumb.cpp \
  "$SDK/Include/BlackmagicRawAPIDispatch.cpp" -I "$SDK/Include" \
  -framework CoreFoundation -framework CoreGraphics -framework ImageIO \
  -framework CoreServices -o tools/brawthumb
```

## Configuration

`~/Library/Application Support/DITIngest/config.json` — created on first run;
the Notion token and database IDs are set via the Settings window, never
stored in this repo.

---

Built by [Index Video Production](https://indexvideoproduction.com) with
Claude Code.
