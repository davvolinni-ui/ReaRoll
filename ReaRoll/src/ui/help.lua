-- @noindex
local M={}
function M.draw(app)
  if not app.help_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,520,500,I.Cond_FirstUseEver)
  local visible; visible,app.help_open=I.Begin(c,'ReaRoll / Quick guide',app.help_open)
  if visible then
    I.TextColored(c,app.theme.note,'ReaRoll 0.4 improvement preview'); I.Separator(c)
    local sections={
      {'Create and edit',{
        'Smart: click empty grid to insert; drag while inserting to choose its end.',
        'Drag a note body to move it. Drag either edge to resize it.',
        'Shift-drag clones. Right-click/drag from a note erases; Alt+right-click opens note actions.',
        'Paint draws notes. Slice click/drag paints cuts; Alt bypasses snap. Glue click/drag removes touched note seams.',
        'Ctrl+Shift+wheel changes the number of equal divisions across selected note runs.',
      }},
      {'Select',{
        'Ctrl-click toggles a note; Ctrl+Shift adds to the selection.',
        'Ctrl-drag empty grid selects; Ctrl+Shift-drag adds. Right-drag empty grid is also a marquee.',
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
        'Setup > Keyboard shortcuts reassigns or disables ReaRoll commands.',
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
