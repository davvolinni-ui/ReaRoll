-- @noindex
local M={}
local Mouse=require 'src.mouse'
function M.draw(app)
  if not app.help_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,520,500,I.Cond_FirstUseEver)
  local visible; visible,app.help_open=I.Begin(c,'ReaRoll / Quick guide',app.help_open)
  if visible then
    I.TextColored(c,app.theme.note,'ReaRoll editing guide'); I.Separator(c)
    local sections={
      {'Create and edit',{
        'Cancel (Escape by default) during a note or controller edit drag restores the MIDI from before the gesture.',
        Mouse.value(app.settings,'empty')=='Marquee' and 'Smart: drag empty grid to select; double-click empty grid to insert. Paint draws directly.' or 'Smart: click empty grid to insert; drag while inserting to choose its end.',
        'Drag a note body to move it. Drag either edge to resize it.',
        'The overlapping-items icon changes Single item / Multiple items scope. The channel selector chooses the drawing channel and also contains the editing-channel filter.',
        'Properties opens precise note fields. Only changed fields apply; group timing/pitch fields are relative.',
        'CC follows notes (in Settings) moves and copies controllers with notes. Complete sustain cycles follow whole selected passages automatically. A pedal shared with unselected notes stays in place; no tool change is needed.',
        'Glide: use ordinary notes or the Chord tool. Start the next note or chord before the current one ends. Each overlap sets the bend start, finish and duration; no separate slide tool is needed.',
        'For independent chord glides, enable MPE in ReaRoll and the instrument. Whole chords pair lowest-to-lowest in pitch order, retaining source voice channels. Short destinations use their own end as the end of the overlap.',
        'With MPE Glide, drag a note connector onto an overlapping destination, or drag the dot on a connection to change its destination. Several source voices can converge on one note. Right-click a connection dot to unlink.',
        Mouse.value(app.settings,'clone')..'-drag clones. Right-click note: '..Mouse.value(app.settings,'right_note')..'. Double-click note: '..Mouse.value(app.settings,'double_note')..'.',
        'Paint draws notes. Slice click/drag paints cuts; '..Mouse.value(app.settings,'unsnap')..' bypasses snap. Glue click/drag removes touched note seams.',
        'Ctrl+Shift+wheel changes the number of equal divisions across selected note runs.',
      }},
      {'Expression',{
        'Expression panel: right-drag a box to select points across visible note curves. Ctrl adds points; drag the selected points to move them, or press Delete. Escape cancels the drag. Note selection stays unchanged.',
        'MPE gives notes independent voices. Match the visible zone, voice count and pitch range to the instrument. Pitch, Pressure and Timbre curve editing is optional; overlapping-note Glide does not require curve editing.',
        'For existing ordinary notes, select them and use Make selected notes MPE in the Expression panel. The explicit action assigns independent member channels with one Undo in either item view.',
        'Slice and Chop preserve member channels and expression boundaries. Nonlinear curves inside the voice become editable line segments within MIDI value resolution. Curves crossing other voices and partial shared-pedal splits stay protected.',
        'Controller areas support Copy, Move, Delete and Stretch across nonlinear curves. Affected segments become editable line segments within MIDI value resolution; outside curve values are retained. Undo restores the original native shapes.',
        'Slice and Chop keep target handles in neutral gaps. Cuts through an active slide or held bend retain the exact pitch data as note curves: edit with Expression / Pitch or Note Pitch. Shared-channel chord Slice/Chop/Glue retains editable targets and the shared pitch timeline. Release shared sustain before splitting.',
        'Shared-channel slide groups may have staggered note edges; the bend resets at the complete group final release. Independent simultaneous pitch curves require separate MPE member channels.',
      }},
      {'Select',{
        Mouse.value(app.settings,'select')..'-click toggles a note; Ctrl+Shift adds to the selection.',
        Mouse.value(app.settings,'marquee')..'-drag empty grid selects. Right-drag empty grid is also a marquee.',
        'Select mode uses ordinary left-drag for marquee selection. Ctrl+A selects all. Note selection is local to ReaRoll.',
      }},
      {'Navigate',{
        'The scale-rows icon beside Harmony shows only scale notes without altering MIDI. Scale snapping is a separate setting.',
        'Workspace > Show incoming MIDI notes highlights the active track\'s configured input on the keyboard and pitch rows without recording.',
        'Wheel scrolls pitches. Shift+wheel scrolls time.',
        'Ctrl+wheel zooms time. Ctrl+Alt+wheel zooms pitch. Middle-drag pans.',
        'The Time/Pitch buttons and Fit actions work without keyboard modifiers.',
      }},
      {'Velocity and controller lanes',{
        'Use the controller-lane controls to choose a parameter or display multiple lanes. Drag the lane splitter upward if the dock is too small.',
        'Each lane picker can add, remove or reorder lanes. Click a graph to focus the bottom tools on its parameter.',
        'Drag empty controller lane space to draw or reshape points. Drag a point to move it.',
        'Ctrl-click a point adds or removes it from the selection. Drag selected points to move them; Shift-drag duplicates.',
        'Right-click near a controller point deletes it. Right-click empty lane space clears the selection.',
        'Right-drag empty lane space selects a snapped musical range. Right-drag either range edge resizes it.',
        'Drag a velocity handle to change that note or the selected notes. Drag empty space to paint velocities; hold Shift for a straight line.',
        'Protected channel-mode lanes allow existing points to be moved or deleted, but do not allow drawing new points.',
        'The lane header shows the position and value under the pointer. The mouse wheel in a lane does not scroll note pitches.',
      }},
      {'Per-note expression / MPE',{
        'The envelope icon in the top toolbar opens Pitch, Pressure and Timbre editing. The MPE switch enables independent voices. Match the compact instrument settings in the expression toolbar.',
        'The note-curve icon beside Pitch in the expression editor enables manual pitch editing on notes. This is optional and is separate from automatic overlap Glide.',
        'Pitch curves snap to semitones; Shift allows free pitch. Alt-drag a curve segment changes its shape. Right-click a point deletes it.',
        'Select multiple MPE notes to edit their Pitch, Pressure or Timbre together, including across items. Curve point timing follows each note length; existing curve differences are preserved. Select one note to edit it alone.',
        'Edits commit when the mouse is released, with one Undo. Escape discards the current drag. Recorded channels and the ordinary drawing channel are preserved.',
        'The selected-note adjustments icon scales or offsets existing expression with a preview. Folded rows do not support on-grid pitch editing.',
      }},
      {'Controls',{
        'Hover a value and use the wheel to adjust it. Right-click restores its shown default.',
        'Grid controls placement spacing. Len controls the inserted note duration.',
        'Ctrl+Z / Ctrl+Shift+Z undo and redo. Delete removes selected notes. Space controls playback.',
        'The three-dot menu > Shortcuts and mouse modifiers offers ReaRoll, REAPER, FL Studio and Ableton Live presets, plus custom bindings.',
      }},
    }
    for _,section in ipairs(sections) do
      I.Text(c,section[1]); for _,line in ipairs(section[2]) do I.BulletText(c,line) end; I.Spacing(c)
    end
    I.Separator(c); I.TextWrapped(c,'Please report the exact gesture, expected result, actual result, active tool, zoom level, operating system, REAPER version, and whether the MIDI item used custom note names.')
  end
  if visible then I.End(c) end
end
return M
