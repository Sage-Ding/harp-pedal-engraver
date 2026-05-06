# Harp Pedal Engraver by Sage Ding @ Northwestern University

I wrote this because I got tired of marking pedal changes by hand.

I'm a harpist, pianist, flutist, and violinist, and I compose and arrange a lot of harp music. Every time I write a new piece or arrangement I have to sit down and work out which pedals change where, then manually place each marking in the score. MuseScore 4 has a pedal diagram tool but it still makes me place every single change myself, one by one. That gets old fast when you're just trying to check if a passage is even playable.

So I built a plugin that reads the whole score and figures it out automatically.

It places an opening pedal diagram at bar 1 and then marks every subsequent change throughout the piece, with ⚠ warnings on any spot where the string might still be ringing when the pedal needs to move. It ignores all other instruments and only looks at the harp staves, and if you have multiple harps in the score it handles each one independently.

I'm an incoming student at Northwestern studying Applied Mathematics and Harp Performance, which is basically why this ended up being more algorithmic than it probably needed to be. The placement logic uses a scoring function that weighs advance notice, rest texture, string activity, and note density to find the best spot for each label rather than just dumping everything on the deadline note.

It's still a work in progress. The look-ahead placement is the next thing I want to fix: right now labels land at the exact moment the new note arrives instead of a measure or two beforehand, which is the whole point of pedal markings in professional scores. That's the main open issue.

---

**Credit:** This plugin builds on [harp_pedal_diagram](https://github.com/Jojo-Schmitz/harp_pedal_diagram), the reference implementation for harp diagrams in MuseScore. The Bravura font glyph codes and diagram format come from that project. The original authors are iancboswell (2012), Karen Zita Haigh (2015), Nicolas Froment (2017), Joachim Schmitz (2019, 2023), Trudy Firestone (2021), and Marc Sabatella (2023). This project is a complete rewrite of the automation layer on top of their work, licensed under GPL v2.

---

## What it does

A concert harp has 7 foot pedals, one for each pitch class (D C B on the left foot, E F G A on the right). Each pedal has three positions: flat, natural, or sharp. When the music changes key or uses accidentals, the harpist has to physically move the relevant pedals, ideally before the note arrives and ideally when that string isn't still vibrating.

The plugin produces:

- An opening diagram showing all 7 starting positions in the standard Bravura notation (the little notch symbols)
- Mid-score text labels like `C♯` or `F♮, G♯` at the best available moment before each change is needed
- A ⚠ prefix on any label where moving the pedal might cause an audible buzz because the string is still ringing

## Requirements

MuseScore 3.3 or later. The plugin uses `rewindToTick()` which was introduced in 3.3 — older builds fall back to a linear walk that's less reliable on scores with irregular rhythms or grace notes.

## Installation

Download `HarpPedalEngraver.qml` and put it in your MuseScore plugins folder:

- macOS: `~/Documents/MuseScore3/Plugins/`
- Windows: `%HOMEPATH%\Documents\MuseScore3\Plugins\`
- Linux: `~/Documents/MuseScore3/Plugins/`

Then go to Plugins > Plugin Manager in MuseScore, find Harp Pedal Engraver in the list, and enable it. After that it shows up under Plugins > Harp Pedal Engraver.

## Usage

Open a score that has a harp part, then run the plugin. It processes the whole score and places all the markings at once. The operation is fully undoable with Ctrl+Z.

If the plugin can't find a harp, it logs all the part names to the Plugin Console (Help > Plugin Console) so you can see what it's looking for. It recognizes "Harp", "Hrp.", "竖琴", "ハープ", "harpe", and "arpa" — if your score uses something else, you can add it to the `isHarp()` function in the source.

Running the plugin a second time clears all previous markings before re-placing them, so you can run it as many times as you want as you edit the score.

## Adjustable parameters

At the top of the file there are a few things you can change:

```
safetyBeats     default 2    how many quarter notes of ring-out to allow after a pluck
lookaheadBeats  default 8    how far before the deadline to search for a placement spot
diagramOffsetY  default -3.5 vertical position of the opening diagram (negative = up)
normalLeftY     default 5.5  position of left-foot change labels
warnLeftY       default 7.0  position of left-foot warning labels
normalRightY    default 8.5  position of right-foot change labels
warnRightY      default 10.0 position of right-foot warning labels
```

## How the algorithm works

There are three passes.

**Pass 1** walks every measure and segment in the score using the raw linked-list structure rather than a MuseScore cursor. This matters because `cursor.next()` skips segments where the cursor's own track has nothing — so if the flute holds a half note on beat 1, a naive cursor walk jumps straight to beat 3 and misses any harp accidentals on beat 2. The segment walk doesn't have this problem.

**Pass 1b** scans the collected events to figure out the optimal starting pedal state. Instead of setting everything to natural and marking every accidental as a change, it looks at the first occurrence of each pitch class and uses that as the starting position. For a piece in D major this means the opening diagram already shows F♯ and C♯, and the first F or C in the score doesn't need a change label at all.

**Pass 2** simulates playing through the score event by event. It keeps track of the current pedal state and when each string was last plucked. When it finds a note that requires a different pedal position than what's currently set, it calls `computeBestSlot()` to find the best moment to place the label and queues it as a pending change. Changes are flushed when their best slot is reached or when the deadline arrives.

`computeBestSlot()` scores each candidate tick on a 100-point scale:

- up to 50 points for advance notice (further before the deadline = better)
- 20 points if the string has finished ringing by then
- 30 points if there are no harp notes at all (pure rest)
- 15 points if other strings are playing but this one is silent
- up to 15 points for textural sparsity (fewer simultaneous notes)
- 5 points for being at a barline
- 20 point penalty for slots after the deadline

The loop ordering within Pass 2 matters: detection and placement happen before `lastS` is updated for the current tick. If you update `lastS` first, the safety buffer ends up anchored to the deadline note's own tick, which blocks all the earlier candidate slots and generates false buzz warnings.

## Known issues

**Labels land at the deadline, not before it.** The scoring function works correctly but the search window currently starts at the detection tick, which equals the deadline tick. The fix is a pre-scan pass that builds a complete change schedule before Pass 2 starts, so `detectionTick` can be set to a moment earlier than `deadlineTick`. This is the most important open issue and the thing I'm working on next.

**No enharmonic conflict detection.** If the score has both G♯ and A♭ within the same passage, the plugin will try to set the G pedal and the A pedal independently without flagging that those two demands are physically contradictory on a harp.

**No glissando handling.** Before a glissando, all 7 pedals need to be set to match the required scale before the gliss starts. The plugin doesn't detect glissandos or give them higher-priority placement.

## License

## Development notes
A few parts of the code in this project were written and formatted with AI assistance (Claude by Anthropic).
The algorithm design, musical domain knowledge, debugging, and testing were completely my own.
