# Marker Import for grandMA3

Import a list of markers into a grandMA3 timecode show. For every marker the plugin
creates a **Cue** in a Sequence you choose, and a **Timecode event** that fires that cue
at the marker's time.

Tag your track once in whatever audio tool you already use, export the markers, run the
plugin — and the timecode show is built. No web converter, no XML round-trip, no upload
of your show data to anyone.

```
   Audacity / Reaper / any CSV                 grandMA3
  ┌────────────────────────────┐          ┌──────────────────────────┐
  │  0.0    Intro              │          │  Sequence "Markers"      │
  │  64.0   Build              │  ──────► │    Cue 1  Intro          │
  │  84.5   Drop               │  plugin  │    Cue 2  Build          │
  │  132.0  Breakdown          │          │    Cue 3  Drop      ...  │
  └────────────────────────────┘          │                          │
                                          │  Timecode "Show"         │
                                          │    00:00:00.000 → Cue 1  │
                                          │    00:01:04.000 → Cue 2  │
                                          │    00:01:24.500 → Cue 3  │
                                          └──────────────────────────┘
```

## Install

1. Copy the `MarkerImport` folder into your grandMA3 plugin library:

   ```
   <your gma3 library>/datapools/plugins/MarkerImport/
   ```

   On a console that is the USB stick or the internal library; with onPC it is typically
   `~/MALightingTechnology/gma3_library/datapools/plugins/` (macOS/Linux) or
   `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\` (Windows).

2. In grandMA3, import it into the Plugin pool (or run `ReloadAllPlugins` if you dropped
   it in while the software was running).

## Use

Two things must exist **before** you run it — the plugin deliberately does not create
pools on your behalf:

- a **Timecode selected in the Timecode pool** (yellow frame). It may be empty.
- a **Sequence** with the name you are going to type. It may be empty.

Then run the plugin and answer two prompts:

| prompt | what to type |
|---|---|
| Sequence name | the name of that existing sequence, e.g. `Markers` |
| Full path of the marker file | e.g. `/Users/me/markers.csv` |

When it finishes you get a summary box with the number of markers imported. Open the
Timecode window and the Sequence pool — the cues and events are there.

Existing cues in the sequence are never overwritten: numbering continues above the
highest cue already present.

## Input formats

The plugin looks at each line and works out the format on its own, so you do not have to
declare anything. Lines it cannot read (headers, comments, blanks) are skipped silently.

**1 — Simple CSV** `Name,Start,End` (the end column is optional and ignored)

```csv
Name,Start,End
Drop,84.5,86.0
"Big, loud drop",132.0,134.0
```

**2 — Audacity label track** (File ▸ Export ▸ Export Labels), tab separated

```
84.500000	86.000000	Drop
```

**3 — Reaper marker export** (Region/Marker Manager ▸ Export)

```csv
#,Name,Start,End,Length
M1,Drop,1:24.500,,
```

Times may be written as `84.5`, `1:24.5` (m:s) or `0:01:24.5` (h:m:s).

> **SMPTE `hh:mm:ss:ff` is deliberately rejected.** Without knowing the frame rate the
> plugin would have to guess, and a wrong guess puts every marker at the wrong time
> without telling you. Convert to seconds first.

See [`examples/`](examples/) for one file in each format — all three describe the same
six markers.

## What is tested, and what is not

Honesty matters more than a tidy feature list, so:

- **The grandMA3 half is field-tested.** Creating the cues, the track and the timecode
  events has been run on a real grandMA3 with a real show file, and it worked. That logic
  is unchanged in this release.
- **The file parsing is covered by tests** you can run yourself without a console:
  `lua tests/test_parser.lua` (51 checks). This is where a silent mistake would be worst —
  a marker landing at the wrong time — so every format and time notation is asserted.
- **Not tested:** every grandMA3 version, network sessions, very large marker lists
  (a few hundred is fine; thousands is untried), and non-Latin characters in marker names.

If something breaks, open an issue with the first few lines of your marker file and what
the Command Line printed — the plugin logs every marker it imports.

## Limitations

- Cue numbers are integers starting above the highest existing cue; there is no way to
  choose the range yet.
- One sequence per run. Import twice into two sequences if you need two tracks.
- Marker *ends* are ignored — each marker becomes one "go to cue" event, not a range.

## Who wrote this

**The code was written by Claude, Anthropic's Claude Code.** It was commissioned,
directed and tested on real grandMA3 hardware by [Tozsers](https://github.com/Tozsers),
who works in show lighting and needed this for his own shows. Saying so seems more useful
than pretending otherwise — judge the code on whether it works, and the tests are there
so you can check.

Built on the object-tree approach used by the grandMA3 plugin community; thanks in
particular to the open-source plugins that documented how timecode tracks are structured.

## License

MIT — see [LICENSE](LICENSE). Do what you like with it, no warranty. It writes into your
show file, so try it on a copy first.
