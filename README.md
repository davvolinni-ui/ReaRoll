# ReaRoll

ReaRoll is a MIDI piano roll for REAPER by Davvo. **0.7.0-test** expands note editing, chords, controller editing, glides and MPE while keeping the familiar piano roll and bottom tools. This is a release for user testing.

## Requirements

- REAPER
- ReaPack
- ReaImGui 0.10 or newer

## Install or update

1. In REAPER, choose **Extensions > ReaPack > Import repositories**.
2. Import `https://raw.githubusercontent.com/davvolinni-ui/ReaRoll/main/index.xml`.
3. Synchronize packages, then install or update **ReaRoll**. If the testing version is not offered, enable pre-releases for this package or select **0.7.0-test** in the package browser.
4. Close an already running ReaRoll instance, then run **ReaRoll - MIDI piano roll** from the Action List. The action file remains `ReaRoll/ReaRoll.lua`.

Existing preferences are retained. The package also installs **ReaRoll - Reset Window** for recovering a hidden or off-screen window.

## What's new in 0.7.0-test

- Overlap-driven mono glides and independent MPE chord glides.
- Automatic MPE member-channel allocation for drawing, per-note Pitch/Pressure/Timbre editing, live curve previews and multi-note expression editing.
- Multiple-item editing through the same piano roll, with the original note tools and navigation.
- Scale-aware chord palettes, click or drag chord placement, pitch-locked note painting and tool context menus.
- Expanded controller lanes, controller editing tools, and controller/sustain following for supported note moves and copies.
- Compact toolbar controls, optional mouse tooltips, stronger key-color selection feedback and recalled floating-window placement.
- Fixes for drawing, resizing, take lifetime handling and glide persistence at item boundaries.

## Getting started

- **Notes:** click empty grid to draw; drag while inserting to set the end. Drag a note body to move it or either edge to resize. Input presets can change these gestures.
- **Chords:** choose a scale, open the chord palette, and drag a chord into the roll. Drag while placing to choose its duration.
- **Glide:** enable the glide icon, then overlap successive notes. The overlap sets the transition timing. For independent chord voices, enable MPE in ReaRoll and use an MPE-capable instrument.
- **MPE:** match the instrument's zone, member-channel count and pitch-bend range. New MPE notes receive channels automatically. The expression icon opens Pitch, Pressure and Timbre editing; right-drag selects curve points. Changing ReaRoll's MPE switch changes its editing mode and does not remove MIDI already written.
- **Multiple items:** use the overlapping-items icon to choose the editing scope and drawing destination.
- **Settings:** use the three-dot menu for mouse tooltips, appearance, shortcuts and mouse modifiers. **Quick guide** explains the editing gestures.

ReaRoll's pitch-bend range must match the instrument. It does not automatically configure a plug-in. Ordinary MIDI pitch bends affect their whole channel; independent simultaneous bends use MPE member channels.

## Input presets

Open **the three-dot menu > Shortcuts and mouse modifiers** to choose **ReaRoll Default**, **REAPER**, **FL Studio**, or **Ableton Live**. Applying a preset replaces keyboard and note-grid mouse bindings; individual edits become **Custom**. Existing saved shortcuts are preserved until you choose a preset.

Presets adapt familiar Windows controls to supported ReaRoll actions. See [input preset details](docs/INPUT_PRESETS.md).

## Feedback and license

Report issues in the [ReaRoll forum thread](https://forum.cockos.com/showthread.php?t=311021). Include the exact steps, expected and actual results, active tool, REAPER/ReaImGui versions, and instrument settings when relevant. A small reproducible MIDI example is helpful.

ReaRoll is distributed under its [End User License Agreement](ReaRoll/EULA.md). Public access to this repository does not grant an open-source license. See also [third-party notices](ReaRoll/THIRD_PARTY_NOTICES.md).
