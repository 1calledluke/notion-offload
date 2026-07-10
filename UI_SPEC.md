# Task: Polish the DIT Media Ingest UI

App at `~/dit-ingest-app`. Build: `./build.sh install`. Only touch `Sources/DITIngest/SetupView.swift`.
Do NOT change any logic in SetupModel, Engine, or AppDelegate. All @Published properties and methods
stay identical. Only the SwiftUI view layer changes.

The goal: make this feel like a polished, professional macOS app — not a developer prototype.
Think Final Cut Pro / Logic / native Apple pro apps. Clean, calm, confident.

---

## Window

- Size: **540 wide × 600 tall** (slightly wider for breathing room)
- No visible padding "box" — content flows naturally
- Background: default window material (`.windowBackground` / standard NSWindow)

---

## Header (top of window, always visible)

A compact two-line header, NOT a toolbar — just content at the top of the VStack:

```
[icon]  DIT Media Ingest                          [card chip]
        Ingest from card to project
```

- Left: `Image(systemName: "externaldrive.fill.badge.plus")` in accent color (`.accentColor`),
  font size ~22pt, sitting beside a VStack of title + subtitle
- Title: "DIT Media Ingest", `.title3`, `.bold()`
- Subtitle: "Ingest media from card to project", `.caption`, `.secondary`
- Right: a small pill/chip showing the card volume name — rounded rectangle background
  (`.fill(.quaternary)`), padding 4h×2v, `.caption`, `.secondary`. Use `model.sourceURL.lastPathComponent`.
- Separate header from content with a `Divider()` below it.
- Padding: 16pt horizontal, 14pt top, 8pt bottom before divider.

---

## Form view (idle state)

### Section: Project

Label: "PROJECT" in `.caption2`, `.secondary`, uppercased — used as a section header above each group.

```
PROJECT
[ Filter projects…                    ] [↺]
┌──────────────────────────────────────────┐
│ • Hope Church Christmas              │
│   Startup Brand Film                 │
│   …                                  │
└──────────────────────────────────────────┘
```

- Section header "PROJECT" + refresh button on same row (refresh button: SF Symbol `arrow.clockwise`,
  `.buttonStyle(.plain)`, icon only with `.help("Refresh from Notion")`)
- If `model.isLoadingProjects`: show a `ProgressView().controlSize(.mini)` inline after the label
- Filter field: `.textFieldStyle(.roundedBorder)`, placeholder "Filter projects…"
- List: `List(model.filteredProjects, id: \.self, selection: $model.selectedProject)` — height 150,
  `.listStyle(.inset)` with alternating row backgrounds (default macOS behavior), `.border(.separator)`

### Section: Destinations

Label: "DESTINATIONS" section header.

Three folder rows — each is a compact HStack:
```
Dump location *      [ /Volumes/SSD_Storage/...        ] [Browse]
Backup 1 (optional)  [ /Volumes/Hope Church 2/...      ] [Browse]
Backup 2 (optional)  [ /Volumes/Macintosh HD/...       ] [Browse]
```

- Row label: fixed-width (~130pt), `.font(.callout)`, `.foregroundStyle(.secondary)`
- Asterisk on "Dump location" label only to hint it's required
- TextField: `.textFieldStyle(.roundedBorder)`, fills remaining space
- Browse button: `.buttonStyle(.bordered)`, `.controlSize(.small)`, title "Browse…"
- Rows have 6pt vertical spacing between them

### Bottom bar

A footer HStack pinned to the bottom, separated by a Divider():

```
[error or hint text, secondary]          [Cancel]  [Begin Ingest ▶]
```

- If `model.goBlockReason != nil`: show reason text in `.callout`, `.secondary`
- If `model.errorMessage != nil`: show error in `.callout`, red
- Cancel: `.buttonStyle(.plain)`
- "Begin Ingest" button: `.buttonStyle(.borderedProminent)`, `.controlSize(.regular)`,
  keyboardShortcut `.defaultAction`, disabled when `!model.canGo()`

---

## Running view

Replace the plain running view with a more structured layout:

### Dump phase (activeBackups is empty):

```
┌─────────────────────────────────────────┐
│  ⬇  Dumping to SSD                     │
│                                         │
│  01_SonyA7IV_26.06.26                   │
│  207 of 441 files                       │
│                                         │
│  [████████████░░░░░░░░░░░░]  47%        │
│                                         │
│  84.3 MB/s                              │
│  DCIM/100MSDCF/C0207.MP4               │
└─────────────────────────────────────────┘
```

Implementation:
- Phase icon + label: `Image(systemName: "arrow.down.circle.fill")` accent color, `.title2`,
  beside `Text("Dumping to SSD").font(.headline)`
- Card name: extract from `model.progressText` (it's "\(cardName): \(i)/\(total) — \(name)")
  or just show `model.progressText` in `.callout`, `.secondary`, limited to 2 lines
- `ProgressView(value: model.progressFraction)` — full width, `.controlSize(.large)` if available,
  else default
- Speed on its own line: `Text(model.speedText).font(.title3).bold().monospacedDigit()`
- Current file: last component of progressText, `.caption`, `.secondary`, 1 line, truncated

### Backup phase (activeBackups not empty):

```
┌─────────────────────────────────────────┐
│  ⇪  Backing up                          │
│  01_SonyA7IV_26.06.26                   │
│                                         │
│  ▪ Hope Church 2          149 MB/s  ████│ 62%
│  ▪ Macintosh HD           279 MB/s  ████│ 81%
│                                         │
│  [██████████████████░░░░░]  71% overall │
└─────────────────────────────────────────┘
```

Implementation:
- Phase header: `Image(systemName: "arrow.up.circle.fill")` accent color + "Backing Up"
- Card name: `Text(model.currentCardName).font(.headline)`
- For each backup in `model.activeBackups.values.sorted(by: { $0.label < $1.label })`:
  - HStack: drive icon (externaldrive.fill, .secondary), label (bold, fills space),
    speed (monospacedDigit, bold), percentage (secondary)
  - ProgressView(value: backup.progressFraction) .controlSize(.small)
  - 6pt spacing between drives
- Overall progress bar at bottom with "X% overall" label

---

## Result view

```
        ✅
   01_SonyA7IV_26.06.26
   Dumped and backed up to 2 locations.

              [ Done ]
```

- Checkmark: `Image(systemName: "checkmark.circle.fill")`, 56pt, `.green`
- For error: `xmark.circle.fill`, `.red`
- Message text: `.title3`, `.semibold`, centered
- "Done" button: `.buttonStyle(.borderedProminent)`, `.keyboardShortcut(.defaultAction)`
- Generous vertical spacing, all centered

---

## Style constants / polish notes

- Use `.monospacedDigit()` on all speed and percentage numbers so they don't jump around
- Respect system dark/light mode — use semantic colors only (`.primary`, `.secondary`,
  `.accentColor`, `.red`, `.green`), no hardcoded hex
- All section headers: `.font(.caption2).foregroundStyle(.secondary)` uppercased text
- Inter-section spacing: 16pt
- The window should NOT be resizable: set in SetupWindowController (don't change that file —
  note it for future reference only)
- Smooth transitions between form/running/result states:
  ```swift
  .animation(.easeInOut(duration: 0.2), value: model.isRunning)
  .animation(.easeInOut(duration: 0.2), value: model.finishedMessage != nil)
  ```

---

## Done criteria

- `./build.sh install` compiles clean.
- All three states render correctly: form → running (dump) → running (backup) → result.
- No logic changes — only SetupView struct and its sub-views.
- Dark mode looks good (test mentally — semantic colors only).
- The window feels like a real, shipping macOS pro app.
