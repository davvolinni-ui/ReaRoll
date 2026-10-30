-- @noindex
local M={}

-- Reserve the canvas first. Narrow docks temporarily hide the inspector without
-- changing the user's layout preference.
function M.geometry(width,scale,sources,inspector)
  scale=scale or 1
  local gap=7*scale
  local source_width=sources and math.min(148*scale,math.max(132*scale,width*.12)) or 0
  local remaining=width-source_width-(sources and gap or 0)
  local inspector_width=inspector and remaining>=580*scale and 210*scale or 0
  return source_width,inspector_width,math.max(1,remaining-inspector_width-(inspector_width>0 and gap or 0))
end

-- Opening group controls must not enlarge the lower editor. Keep its default
-- compact and reserve most of the workspace for notes, even in a short dock.
function M.expression_height(height,scale,requested)
  scale=scale or 1
  local maximum=math.max(0,math.min(height*.45,height-100*scale))
  return math.max(0,math.min(maximum,math.max(110*scale,(requested or 170)*scale)))
end

function M.menu(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if I.BeginMenu(c,'Workspace') then
    if I.MenuItem(c,'Show incoming MIDI notes',nil,s.input_note_display~=false)then s.input_note_display=s.input_note_display==false end
    if I.IsItemHovered(c)then I.SetTooltip(c,'Highlight live notes from the active track\'s configured MIDI input and channel. Recording is not required; MIDI is not modified.')end
    if I.MenuItem(c,'Selected-note pitch curves',nil,s.note_expression_overlay) then s.note_expression_overlay=not s.note_expression_overlay end
    if s.mode=='razor' and app.controller_razor then
      if I.MenuItem(c,'Include controller areas with note razor',nil,app.mixed_razor==true)then app.mixed_razor=not app.mixed_razor end
    end
    I.EndMenu(c)
  end
end
return M
