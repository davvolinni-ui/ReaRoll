# Input presets

Choose a preset in **the three-dot menu > Shortcuts and mouse modifiers**. It replaces both keyboard and note-grid mouse bindings. You can then change or disable individual controls; the selector shows **Custom**. Closing ReaRoll saves these settings. Existing custom shortcuts are retained on upgrade, and **ReaRoll Default** restores the original controls.

These are Windows-oriented starting points for ReaRoll's supported actions, rather than imports of another application's complete keymap or your REAPER preferences.

| Control | ReaRoll Default | REAPER | FL Studio | Ableton Live |
| --- | --- | --- | --- | --- |
| Duplicate to right | Ctrl+B | Ctrl+D | Ctrl+B | Ctrl+D |
| Quantize starts | Ctrl+U | Q | Ctrl+Q | Ctrl+U |
| Toggle snap | Backspace | Alt+S | Backspace | Ctrl+4 |
| Clone note drag | Shift | Ctrl | Shift | Ctrl |
| Toggle note selection | Ctrl | Shift | Ctrl | Shift |
| Bypass snap during note editing | Alt | Shift | Alt | Alt |
| Right-click note | Erase | Marquee | Erase | Actions |
| Double-click note | Properties | Erase | Properties | Erase |
| Empty-grid drag in Smart tool | Draw | Draw | Draw | Marquee |

In Live's preset, double-click empty space to insert a note, or press **B** to toggle between Smart and Paint. In FL Studio's preset, **Shift+Left/Right** nudges by grid; the inherited length shortcuts are disabled to avoid collisions. The Live preset leaves PageUp/PageDown unbound rather than using them for ReaRoll's horizontal zoom.

Paint and Chord tools still draw directly. The selection modifier takes priority over drawing; cloning takes priority on note bodies, while Ctrl+Shift remains additive selection. Middle-drag, controller lanes, and ruler interactions keep ReaRoll behavior. DAW-specific editing features and alternative shortcuts are not reproduced. The settings dialog displays Command and Option on macOS. Note properties and other commands remain accessible through note actions when double-click is assigned to erase.

Reference manuals: [REAPER](https://www.reaper.fm/userguide.php), [FL Studio piano roll](https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm), [Ableton Live shortcuts](https://www.ableton.com/en/manual/live-keyboard-shortcuts/), [Ableton Live MIDI editing](https://www.ableton.com/en/manual/editing-midi/).

## Mouse wheel navigation

The main view includes all four REAPER navigation gestures, plus Shift + wheel. Selecting **REAPER** resets wheel settings and applies these bindings over notes and the empty roll:

| Gesture (Windows / macOS) | Action |
| --- | --- |
| Wheel | Zoom horizontally |
| Ctrl / Command + wheel | Zoom vertically |
| Alt / Option + wheel | Scroll left / right |
| Ctrl + Alt / Command + Option + wheel | Scroll up / down |

Modifier bindings apply to both wheel axes; unmodified horizontal input still scrolls time. Other wheel gestures and the piano-key area use ReaRoll defaults. **ReaRoll Default** resets wheel settings; FL Studio and Ableton Live preserve wheel settings. Existing saved bindings are preserved on startup; reselect REAPER to apply these wheel bindings. Editing an individual wheel binding marks the preset Custom.
