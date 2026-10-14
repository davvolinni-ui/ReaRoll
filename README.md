# ReaRoll

ReaRoll is a compact piano roll for sketching MIDI ideas in REAPER. This is a testing release by Davvo.

## Requirements

- REAPER
- ReaPack
- ReaImGui 0.10 or newer

## Install

1. In REAPER, choose **Extensions > ReaPack > Import repositories**.
2. Import `https://raw.githubusercontent.com/davvolinni-ui/ReaRoll/main/index.xml`.
3. Synchronize packages, then install **ReaRoll**.
4. Run **ReaRoll - compact sketching piano roll** from the Action List.

The package also installs **ReaRoll - Reset Window** for recovering a hidden or off-screen window. ReaRoll remains a testing release until it is proven stable. Updates are delivered through ReaPack synchronization.

## Input presets

Open **Setup > Shortcuts and mouse modifiers** to choose **ReaRoll Default**, **REAPER**, **FL Studio**, or **Ableton Live**. Applying a preset replaces keyboard and note-grid mouse bindings; individual edits become **Custom**. Existing saved shortcuts are preserved until you choose a preset.

Presets adapt familiar Windows controls to supported ReaRoll actions. Wheel navigation, controller lanes, and DAW-specific features retain ReaRoll behavior. See [input preset details](docs/INPUT_PRESETS.md).

## Support and license

Report issues in the [ReaRoll forum thread](https://forum.cockos.com/showthread.php?t=311021).

ReaRoll is distributed under its [End User License Agreement](ReaRoll/EULA.md). Public access to this repository does not grant an open-source license.
