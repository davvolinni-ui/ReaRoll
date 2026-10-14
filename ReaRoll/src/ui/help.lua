-- @noindex
local M={}
local Mouse=require 'src.mouse'
function M.draw(app)
  if not app.help_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,520,500,I.Cond_FirstUseEver)
  local visible; visible,app.help_open=I.Begin(c,'ReaRoll / Quick guide',app.help_open)
  if visible then
    I.TextColored(c,app.theme.note,'ReaRoll 0.4 improvement preview'); I.Separator(c)
    local sections={
      {'Create and edit',{
        Mouse.value(app.settings,'empty')=='Marquee' and 'Smart: drag empty grid to select; double-click empty grid to insert. Paint draws directly.' or 'Smart: click empty grid to insert; drag while inserting to choose its end.',
        'Drag a note body to move it. Drag either edge to resize it.',
        Mouse.value(app.settings,'clone')..'-drag clones. Right-click note: '..Mouse.value(app.settings,'right_note')..'. Double-click note: '..Mouse.value(app.settings,'double_note')..'.',
        'Paint draws notes. Slice click/drag paints cuts; '..Mouse.value(app.settings,'unsnap')..' bypasses snap. Glue click/drag removes touched note seams.',
        'Ctrl+Shift+wheel changes the number of equal divisions across selected note runs.',
      }},
      {'Select',{
        Mouse.value(app.settings,'select')..'-click toggles a note; Ctrl+Shift adds to the selection.',
        Mouse.value(app.settings,'marquee')..'-drag empty grid selects. Right-drag empty grid is also a marquee.',
        'Select mode uses ordinary left-drag for marquee selection. Ctrl+A selects all. Note selection is local to ReaRoll.',
      }},
      {'Navigate',{
        'Wheel scrolls pitches. Shift+wheel scrolls time.',
        'Ctrl+wheel zooms time. Ctrl+Alt+wheel zooms pitch. Middle-drag pans.',
        'The Time/Pitch buttons and Fit actions work without keyboard modifiers.',
      }},
      {'Velocity and controller lanes',{
        'Drag empty controller lane space to draw or reshape points. Drag a point to move it.',
        'Ctrl-click a point adds or removes it from the selection. Drag selected points to move them; Shift-drag duplicates.',
        'Right-click near a controller point deletes it. Right-click empty lane space clears the selection.',
        'Right-drag empty lane space selects a snapped musical range. Right-drag either range edge resizes it.',
        'Drag a velocity handle to change that note or the selected notes. Drag empty space to paint velocities; hold Shift for a straight line.',
        'Protected channel-mode lanes allow existing points to be moved or deleted, but do not allow drawing new points.',
        'The lane header shows the position and value under the pointer. The mouse wheel in a lane does not scroll note pitches.',
      }},
      {'Controls',{
        'Hover a value and use the wheel to adjust it. Right-click restores its shown default.',
        'Grid controls placement spacing. Len controls the inserted note duration.',
        'Ctrl+Z / Ctrl+Shift+Z undo and redo. Delete removes selected notes. Space controls playback.',
        'Setup > Shortcuts and mouse modifiers offers ReaRoll, REAPER, FL Studio and Ableton Live presets, plus custom bindings.',
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
