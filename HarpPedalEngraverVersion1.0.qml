// =============================================================================
//  MuseScore
//  Music Composition & Notation
//
//  Harp Pedal Engraver
//  Automatic pedal change markings for harp parts
//
//  Copyright (C) 2012 iancboswell
//  Copyright (C) 2015 Karen Zita Haigh
//  Copyright (C) 2017 Karen Zita Haigh, Nicolas Froment
//  Copyright (C) 2019 Joachim Schmitz
//  Copyright (C) 2021 Trudy Firestone
//  Copyright (C) 2023 Joachim Schmitz, Marc Sabatella
//  Copyright (C) 2025 Sage Ding
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License version 2
//  as published by the Free Software Foundation and appearing in
//  the file LICENCE.GPL
// 
// History
// Version 1 by iancboswell September 2012. Contains Harpfont.tff
// Version 2 by kzh October 2015. Code is a complete rewrite of the plugin.
// Version 3 by Nicolas Froment 2017, use Bravura text, no external font
// Version 4 by Joachim Schmitz 2019, port to MuseScore 3
// Version 5 by Trudy Firestone 2021, support updating an existing pedal diagram
// Version 5.1 by Joachim Schmitz & Marc Sabatella 2023, port to MuseScore 4
// Harp Pedal Engraver v1.0 by Sage Ding 2025
//   complete rewrite as an automation engine — reads the whole score,
//   computes every pedal change, and places all markings automatically
//   built
//
// What this plugin does
//   reads the whole score, figures out every pedal change needed, and places
//   all markings automatically — opening diagram plus mid-score change labels
//   works for any number of harps, ignores all other instruments
//
// Output
//   1. opening pedal diagram at bar 1 in standard Bravura notch-mark notation
//   2. change labels like "C#" or "Fn, G#" at the best available moment
//   3. a warning prefix on labels where the string might still be ringing
//
// Algorithm (three passes)
//   Pass 1 - walk every segment and collect harp note events into a flat list
//   Pass 1b - determine the best starting pedal state from first occurrences
//   Pass 2 - simulate playback, detect every change, score placement spots
//
// For non-harpists
//   a concert harp has 7 foot pedals (D C B on the left, E F G A on the right)
//   each pedal has three positions: flat, natural, or sharp
//   when the music needs an accidental the harpist moves the relevant pedal,
//   ideally before the note arrives and while that string is not still vibrating
//   "tick" is MuseScore's time unit: 480 ticks = one quarter note
//   "TPC" (Tonal Pitch Class) encodes spelling not just pitch — G# and Ab
//   sound identical on a piano but require completely different pedal positions
//   "safety buffer" is the ring-out time after a pluck: moving the pedal
//   during this window causes an audible buzz
//   "deadline" is the tick of the note that requires the new pedal position

import QtQuick 2.9
import MuseScore 3.0

MuseScore {
    menuPath: "Plugins.Harp Pedal Engraver"
    description: "Automatic harp pedal change markings"
    version: "1.0"
    requiresScore: true
    pluginType: "run" 

    // how many quarter-note beats of ring-out to allow after a string is plucked
    // before it's safe to move that pedal without buzzing
    // 2 = half note of ring-out, increase for more cautious placement
    property int safetyBeats: 2

    // how many beats before the deadline to search for a placement spot
    // 8 = two measures of 4/4, increase for denser scores
    property int lookaheadBeats: 8

    // vertical position of the opening diagram in staff spaces, negative = up
    // -3.5 places it just above the treble clef, increase magnitude if it
    // overlaps your key signature
    property real diagramOffsetY: -3.5

    // vertical positions of the four label rows in staff spaces, positive = down
    // these stack in the gap between treble and bass staves
    property real normalLeftY:  5.5   // D C B changes, no buzz risk
    property real warnLeftY:    7.0   // D C B changes, warning
    property real normalRightY: 8.5   // E F G A changes, no buzz risk
    property real warnRightY:   10.0  // E F G A changes, warning


    // returns true if this Part is a harp
    // checks both long name and short name, case-insensitive
    // add more variants here if your score uses a different instrument name
    function isHarp(part) {
        var name = (part.longName + " " + part.shortName).toLowerCase()
        return name.indexOf("harp")  >= 0 ||
               name.indexOf("harpe") >= 0 ||
               name.indexOf("arpa")  >= 0 ||
               name.indexOf("竖琴")  >= 0 ||
               name.indexOf("ハープ") >= 0
    }


    // converts a TPC value to { name: "C", state: 1 } etc
    //
    // TPC encodes spelling, not just pitch. G# (TPC 22) and Ab (TPC 11) are
    // the same piano key but require different pedal positions on a harp.
    // MuseScore bakes key-signature accidentals into the TPC value, so a C
    // written in D major arrives here as TPC 21 (C#) not TPC 14 (Cn). We
    // never need to look up the key signature separately.
    //
    // TPC layout follows the circle of fifths:
    //   F=13  C=14  G=15  D=16  A=17  E=18  B=19  (naturals)
    //   flat = natural - 7,  sharp = natural + 7
    //
    // returns null for double accidentals which the harp can't produce
    function getPedalState(tpc) {
        var base = { C:14, D:16, E:18, F:13, G:15, A:17, B:19 }
        for (var n in base) {
            if (tpc === base[n] - 7) return { name: n, state: -1 }
            if (tpc === base[n]    ) return { name: n, state:  0 }
            if (tpc === base[n] + 7) return { name: n, state:  1 }
        }
        return null
    }


    // D, C, B are controlled by the left foot
    // E, F, G, A are controlled by the right foot
    // we separate them into different label rows so the performer can read
    // each foot's instructions independently
    function isLeftFoot(name) {
        return name === "D" || name === "C" || name === "B"
    }


    function sym(state) {
        if (state === -1) return "\u266D"  // b flat
        if (state ===  1) return "\u266F"  // # sharp
        return "\u266E" // n natural
    }


    // turns [{name:"C", state:1}, {name:"F", state:1}] into "C#, F#"
    // multiple changes at the same moment get combined into one label
    function groupLabel(arr) {
        var parts = []
        for (var i = 0; i < arr.length; i++)
            parts.push(arr[i].name + sym(arr[i].state))
        return parts.join(", ")
    }


    // builds the 8-character Bravura Text string for the opening pedal diagram
    // order is D C B | E F G A where | is the divider between left and right foot
    //
    // Bravura SMuFL glyphs:
    //   U+E680 flat position   (pedal forward, string shortened)
    //   U+E681 natural position (pedal middle)
    //   U+E682 sharp position  (pedal back, string tightened)
    //   U+E683 vertical divider between D-C-B and E-F-G-A
    function diagramText(p) {
        var s = { "-1":"\uE680", "0":"\uE681", "1":"\uE682" }
        return s[p.D] + s[p.C] + s[p.B] + "\uE683" +
               s[p.E] + s[p.F] + s[p.G] + s[p.A]
    }


    function makeInitDiagram(p) {
        var el       = newElement(Element.STAFF_TEXT)
        el.text      = diagramText(p)
        el.fontFace  = "Bravura Text"
        el.fontSize  = 20
        el.autoplace = false
        el.offsetY   = diagramOffsetY
        return el
    }


    function makeChangeLabel(txt, yOff, isWarn) {
        var el       = newElement(Element.STAFF_TEXT)
        el.text      = isWarn ? ("\u26A0 " + txt) : txt
        el.fontSize  = 9
        el.italic    = true
        el.autoplace = false
        el.offsetY   = yOff
        return el
    }


    // insertion sort on {name, state} arrays
    // QML's Array.sort() doesn't reliably accept inline comparators, so we
    // do it manually, fine for 7 items max (one per pedal)
    function sortByName(arr) {
        for (var a = 1; a < arr.length; a++) {
            var key = arr[a]
            var b   = a - 1
            while (b >= 0 && arr[b].name > key.name) {
                arr[b + 1] = arr[b]
                b--
            }
            arr[b + 1] = key
        }
        return arr
    }


    // moves a cursor to (staffIdx, tick) so we can insert a label there
    // uses rewindToTick() on MS 3.3+, falls back to linear walk on older builds
    function seekCursor(cur, staffIdx, tick) {
        if (typeof cur.rewindToTick === "function") {
            cur.staffIdx = staffIdx
            cur.rewindToTick(tick)
        } else {
            cur.rewind(0)
            cur.staffIdx = staffIdx
            while (cur.segment && cur.tick < tick)
                cur.next()
        }
    }


    // finds the best tick to place a pedal change label
    //
    // searches forward from detectionTick to deadlineTick + lookaheadBeats
    // we go past the deadline because a rest just after the deadline is still
    // a better placement than a busy beat before it — the late penalty handles
    // the scoring
    //
    // scoring (max 100 points):
    //   0-50  advance notice: further before deadline = higher score
    //     20  safety bonus: string has finished ringing by this tick
    //     30  rest bonus: no harp notes at all
    //     15  string-idle bonus: this string is silent (others may be playing)
    //   0-15  sparsity bonus: fewer simultaneous notes = more foot bandwidth
    //      5  barline bonus: measure boundaries are natural places for changes
    //    -20  late penalty: for ticks after the deadline (min score stays at 1)
    //
    // returns deadlineTick as fallback if nothing scores better
    function computeBestSlot(events, name, detectionTick, deadlineTick, lastS, div) {
        var winEnd = deadlineTick + lookaheadBeats * div
        var bTick  = deadlineTick
        var bScore = -1

        for (var xi = 0; xi < events.length; xi++) {
            var xev = events[xi]
            if (xev.tick < detectionTick) continue
            if (xev.tick > winEnd) break

            var isLate = (xev.tick > deadlineTick)
            var ahead  = deadlineTick - xev.tick
            var xs     = Math.round(50.0 *
                             Math.min(Math.max(ahead, 0) / (lookaheadBeats * div), 1.0))

            var rEnd = lastS[name] + safetyBeats * div
            if (xev.tick >= rEnd) xs += 20

            if (!xev.hasNote) {
                xs += 30
            } else {
                var active = false
                for (var xd = 0; xd < xev.demands.length; xd++) {
                    if (xev.demands[xd].name === name) { active = true; break }
                }
                if (!active) xs += 15
                xs += Math.max(0, Math.round(15.0 * (1.0 - xev.noteDensity / 8.0)))
            }

            if (isLate)        xs = Math.max(xs - 20, 1)
            if (xev.atBarline) xs += 5
            if (xs > 100) xs = 100
            if (xs > bScore) { bScore = xs; bTick = xev.tick }
        }
        return bTick
    }


    // main pipeline — runs once per harp in the score
    //
    // harpTracks  - all track indices for this harp (2 staves x 4 voices = 8 tracks)
    // topStaffIdx - staff index of the treble clef staff, where labels get placed
    function processHarp(harpTracks, topStaffIdx) {
        var div = curScore.division  // ticks per quarter note, usually 480

        // pre-pass: remove any labels from a previous run
        //
        // we identify our labels by their properties:
        //   opening diagram: fontFace === "Bravura Text"
        //   change labels:   fontSize === 9 and italic === true
        //
        // we check ann.track to avoid touching labels on other instruments
        // track = staffIdx * 4 + voice, so Math.floor(track / 4) gives staffIdx
        //
        // iterating backwards because removing an element shifts later indices
        var clM = curScore.firstMeasure
        while (clM) {
            var clS = clM.firstSegment
            while (clS) {
                for (var ai = clS.annotations.length - 1; ai >= 0; ai--) {
                    var ann      = clS.annotations[ai]
                    if (ann.type !== Element.STAFF_TEXT) continue
                    if (Math.floor(ann.track / 4) !== topStaffIdx) continue
                    if (ann.fontFace === "Bravura Text" ||
                       (ann.fontSize === 9 && ann.italic === true))
                        curScore.remove(ann)
                }
                clS = clS.next
            }
            clM = clM.nextMeasure
        }
        console.log("Harp[" + topStaffIdx + "] pre-pass clear done")

        // pass 1: build the events list
        //
        // each event is a moment where the harp plays notes or rests, with:
        //   tick - position in MuseScore ticks
        //   demands - which pedal states the notes here require
        //   hasNote - true if any chord is present
        //   hasRest - true if any rest is present
        //   noteDensity - total simultaneous notes (used for sparsity scoring)
        //   atBarline - true for the first event in each measure
        //
        // we walk measure->segment directly instead of using a cursor because
        // cursor.next() calls nextInTrack() internally, which skips segments
        // where the cursor's own track has nothing. if the flute holds a half
        // note on beat 1, a cursor walk jumps to beat 3 and misses harp
        // accidentals on beat 2. the segment walk doesn't have this problem.
        //
        // in MS3, measure.nextMeasure can walk into a second staff's measure
        // chain and traverse the whole score twice. we detect this by watching
        // for backward tick jumps and stop when we see one.
        var events = []
        var measure = curScore.firstMeasure
        var lastMeasureTick = -1

        while (measure) {
            var mFirstTick = measure.firstSegment ? measure.firstSegment.tick : -1
            if (mFirstTick >= 0 && mFirstTick < lastMeasureTick) break
            if (mFirstTick >= 0) lastMeasureTick = mFirstTick

            var measureFirstEventTick = -1
            var seg = measure.firstSegment

            while (seg) {
                var tick = seg.tick
                var demanded = {}
                var hasNote = false
                var hasRest = false
                var noteCount = 0

                for (var ti = 0; ti < harpTracks.length; ti++) {
                    var el = seg.elementAt(harpTracks[ti])
                    if (!el) continue

                    if (el.type === Element.REST) {
                        hasRest = true
                    } else if (el.type === Element.CHORD) {
                        hasNote   = true
                        noteCount += el.notes.length
                        for (var ni = 0; ni < el.notes.length; ni++) {
                            var r = getPedalState(el.notes[ni].tpc)
                            if (r) demanded[r.name] = r.state
                        }
                    }
                }

                if (hasNote || hasRest) {
                    var atBarline = (measureFirstEventTick < 0)
                    if (atBarline) measureFirstEventTick = tick

                    var dList = []
                    for (var nn in demanded)
                        dList.push({ name: nn, state: demanded[nn] })

                    events.push({
                        tick:        tick,
                        demands:     dList,
                        hasNote:     hasNote,
                        hasRest:     hasRest,
                        noteDensity: noteCount,
                        atBarline:   atBarline
                    })
                }
                seg = seg.next
            }
            measure = measure.nextMeasure
        }

        console.log("Harp[" + topStaffIdx + "] Pass 1: " + events.length + " events")

        // log first and last ticks so we can spot wrap-around in the console
        var diagFirst = [], diagLast = []
        for (var dx = 0; dx < Math.min(5, events.length); dx++)
            diagFirst.push(events[dx].tick)
        for (var dx = Math.max(0, events.length - 5); dx < events.length; dx++)
            diagLast.push(events[dx].tick)
        console.log("  first 5 ticks: " + diagFirst.join(", "))
        console.log("  last  5 ticks: " + diagLast.join(", "))

        // safety net in case the break above didn't catch the wrap
        for (var dx = 1; dx < events.length; dx++) {
            if (events[dx].tick < events[dx-1].tick) {
                console.log("  WRAP at index " + dx + ": trimming")
                events = events.slice(0, dx)
                break
            }
        }

        if (events.length === 0) {
            console.log("Harp[" + topStaffIdx + "]: no events, skipping")
            return
        }

        // pass 1b: find the best starting pedal state
        //
        // instead of starting everything at natural and marking every
        // accidental as a change, we look at the first occurrence of each
        // pitch class and use that as the starting position. for a piece in
        // D major this means the opening diagram already shows F# and C#,
        // and no change label is needed for the first F or C in the score.
        var initP = { D:0, C:0, B:0, E:0, F:0, G:0, A:0 }
        var seen  = { D:false, C:false, B:false, E:false, F:false, G:false, A:false }

        for (var ei1 = 0; ei1 < events.length; ei1++) {
            var dd1 = events[ei1].demands
            for (var di1 = 0; di1 < dd1.length; di1++) {
                if (!seen[dd1[di1].name]) {
                    initP[dd1[di1].name] = dd1[di1].state
                    seen[dd1[di1].name]  = true
                }
            }
            var allSeen = true
            for (var kk in seen) { if (!seen[kk]) { allSeen = false; break } }
            if (allSeen) break
        }
        console.log("Harp[" + topStaffIdx + "] initP: " + JSON.stringify(initP))

        // pass 2: simulate playback and place change labels
        //
        // we walk through events keeping curP (current pedal state) and lastS
        // (last tick each string was plucked). when a note needs a different
        // pedal state than curP has, we call computeBestSlot() and queue the
        // change as pending. changes are flushed when their best slot arrives
        // or when the deadline is reached.
        //
        // the loop ordering is important — detection and flush both happen
        // before lastS is updated for the current tick. if you update lastS
        // first, the safety buffer gets anchored to the deadline note's own
        // tick and blocks all earlier candidate slots.
        //
        // example of why order matters:
        //   G natural last plucked at tick 0, G# needed at tick 2000
        //   wrong order: lastS.G = 2000 first, rEnd = 2960, all candidates
        //                before 2960 are blocked, forced placement with warning
        //   right order: lastS.G still 0, rEnd = 960, rest at tick 1920
        //                scores 80 points, placed two beats early, no warning
        var curP  = { D:initP.D, C:initP.C, B:initP.B,
                      E:initP.E, F:initP.F, G:initP.G, A:initP.A }
        var lastS = { D:-999999, C:-999999, B:-999999,
                      E:-999999, F:-999999, G:-999999, A:-999999 }
        var pending = []
        var placed  = {}

        var ic = curScore.newCursor()
        seekCursor(ic, topStaffIdx, events[0].tick)
        if (ic.segment) {
            ic.add(makeInitDiagram(initP))
            console.log("Harp[" + topStaffIdx + "] initial diagram @ tick " + events[0].tick)
        }

        for (var ei2 = 0; ei2 < events.length; ei2++) {
            var ev = events[ei2]

            // step 1: detect changes needed at this tick
            for (var di2 = 0; di2 < ev.demands.length; di2++) {
                var d = ev.demands[di2]
                if (curP[d.name] === d.state) continue

                var found = false
                for (var pi1 = 0; pi1 < pending.length; pi1++) {
                    if (pending[pi1].name === d.name) {
                        // tighten the deadline if this occurrence is earlier
                        if (ev.tick < pending[pi1].deadlineTick) {
                            pending[pi1].deadlineTick = ev.tick
                            pending[pi1].newState     = d.state
                            pending[pi1].bestSlotTick =
                                computeBestSlot(events, d.name,
                                                pending[pi1].detectionTick,
                                                ev.tick, lastS, div)
                        }
                        found = true
                        break
                    }
                }

                if (!found) {
                    var bTick = computeBestSlot(events, d.name,
                                                ev.tick, ev.tick, lastS, div)
                    pending.push({
                        name:          d.name,
                        newState:      d.state,
                        detectionTick: ev.tick,
                        deadlineTick:  ev.tick,
                        bestSlotTick:  bTick
                    })
                    console.log("Need " + d.name + sym(d.state) +
                                " dead=" + ev.tick + " best=" + bTick)
                }
            }

            // step 2: flush pending changes whose moment has arrived
            //
            // two triggers: atBest (reached the ideal slot) or forced (at/past deadline)
            //
            // curP is updated immediately on flush so that if the same change
            // comes up again in the next event, detection skips it. the dedup
            // guard on placed{} catches the edge case where two pending items
            // both try to write to the same tick.
            if (pending.length > 0) {
                var remaining = []
                for (var pi2 = 0; pi2 < pending.length; pi2++) {
                    var pc     = pending[pi2]
                    var atBest = (ev.tick === pc.bestSlotTick)
                    var forced = (ev.tick >= pc.deadlineTick)

                    if (!atBest && !forced) { remaining.push(pc); continue }

                    var isWarn = (ev.tick < lastS[pc.name] + safetyBeats * div)
                    if (isWarn)
                        console.log("WARN: " + pc.name + " @ " + ev.tick +
                                    " lastPluck=" + lastS[pc.name])

                    var ptStr = "" + ev.tick
                    if (!placed[ptStr])
                        placed[ptStr] = { left:[], right:[], leftW:[], rightW:[] }

                    curP[pc.name] = pc.newState  // commit immediately

                    var entry = { name: pc.name, state: pc.newState }

                    // dedup guard: if this pedal already has a label at this tick, skip
                    var already = false
                    var rows    = [ placed[ptStr].left, placed[ptStr].right,
                                    placed[ptStr].leftW, placed[ptStr].rightW ]
                    for (var ci = 0; ci < rows.length; ci++) {
                        for (var cj = 0; cj < rows[ci].length; cj++) {
                            if (rows[ci][cj].name === pc.name) { already = true; break }
                        }
                        if (already) break
                    }
                    if (already) continue

                    if (isLeftFoot(pc.name)) {
                        if (isWarn) placed[ptStr].leftW.push(entry)
                        else        placed[ptStr].left.push(entry)
                    } else {
                        if (isWarn) placed[ptStr].rightW.push(entry)
                        else        placed[ptStr].right.push(entry)
                    }

                    console.log("Place " + pc.name + sym(pc.newState) +
                                " @ " + ev.tick + (isWarn ? " [WARN]" : ""))
                }
                pending = remaining
            }

            // step 3: update lastS — must be last for the safety buffer to work correctly
            if (ev.hasNote) {
                for (var di3 = 0; di3 < ev.demands.length; di3++)
                    lastS[ev.demands[di3].name] = ev.tick
            }
        }

        // write all collected labels to the score
        // QML enumerates integer-like object keys in ascending order, so this
        // naturally writes labels left to right through the score
        for (var ptick in placed) {
            var p  = placed[ptick]
            var lc = curScore.newCursor()
            seekCursor(lc, topStaffIdx, parseInt(ptick))

            if (!lc.segment) {
                console.log("seek failed @ tick=" + ptick + ", skipped")
                continue
            }

            if (p.left.length   > 0)
                lc.add(makeChangeLabel(groupLabel(sortByName(p.left)),  normalLeftY,  false))
            if (p.leftW.length  > 0)
                lc.add(makeChangeLabel(groupLabel(sortByName(p.leftW)), warnLeftY,    true))
            if (p.right.length  > 0)
                lc.add(makeChangeLabel(groupLabel(sortByName(p.right)), normalRightY, false))
            if (p.rightW.length > 0)
                lc.add(makeChangeLabel(groupLabel(sortByName(p.rightW)),warnRightY,   true))
        }

        console.log("Harp[" + topStaffIdx + "] done. Final: " + JSON.stringify(curP))
    }


    onRun: {
        if (typeof curScore === "undefined") { Qt.quit(); return }

        var parts      = curScore.parts
        var harpGroups = []
        var staveBase  = 0

        for (var pi = 0; pi < parts.length; pi++) {
            var part = parts[pi]
            console.log("Part " + pi + ": '" + part.longName + "' / '" + part.shortName + "'")

            var trackStart, trackEnd
            if (typeof part.startTrack !== "undefined" &&
                typeof part.endTrack   !== "undefined") {
                trackStart = part.startTrack
                trackEnd   = part.endTrack
                staveBase  = Math.floor(trackEnd / 4)
            } else {
                var nStav  = (typeof part.nstaves !== "undefined") ? part.nstaves : 2
                trackStart = staveBase * 4
                trackEnd   = (staveBase + nStav) * 4
                staveBase += nStav
            }

            if (!isHarp(part)) continue

            var tracks = []
            for (var tr = trackStart; tr < trackEnd; tr++)
                tracks.push(tr)

            var topStaffIdx = Math.floor(trackStart / 4)
            harpGroups.push({ tracks: tracks, topStaffIdx: topStaffIdx })
            console.log("  harp found: topStaff=" + topStaffIdx +
                        " tracks=" + JSON.stringify(tracks))
        }

        if (harpGroups.length === 0) {
            console.log("no harp found — check Part names in the Plugin Console")
            Qt.quit()
            return
        }

        curScore.startCmd()
        for (var gi = 0; gi < harpGroups.length; gi++)
            processHarp(harpGroups[gi].tracks, harpGroups[gi].topStaffIdx)
        curScore.endCmd()

        console.log("done, " + harpGroups.length + " harp(s) processed")
        Qt.quit()
    }
}
