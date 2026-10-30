-- @noindex
local M={}
function M.width(app)
 local map=app.instrument_map
 if not map or not map.enabled or map.channel~=(app.settings.channel or 0)or app.settings.scale_view_only then return 88 end
 local z=app.settings.ui_scale or 1;local width=164*z
 for _,row in ipairs(map.rows)do if not row.hidden then width=math.max(width,app.ImGui.CalcTextSize(app.ctx,row.name)+20*z)end end
 return math.min(width,220*z)
end
function M.draw(app,d,v,x,groups,hover)
 local I,c,T=app.ImGui,app.ctx,app.theme
 for _,keys in ipairs(groups)do for _,key in ipairs(keys)do
  local color=key.pitch==hover and T.key_hover or T.panel
  I.DrawList_AddRectFilled(d,x,key.top,v.x-1,key.bottom,color)
  if app.input_notes and app.input_notes[key.pitch]then I.DrawList_AddRectFilled(d,x,key.top,v.x-1,key.bottom,(T.accent&0xFFFFFF00)|90)end
  I.DrawList_AddLine(d,x,key.bottom,v.x-1,key.bottom,T.grid)
  local label=app:note_label(key.pitch)or require('src.util').pitch_name(key.pitch)
  local available=v.x-x-12
  local shown=label
  while #shown>0 and I.CalcTextSize(c,shown)>available do
   local at=utf8.offset(shown,-1);shown=shown:sub(1,(at or #shown)-1)
  end
  if shown~=label then
   while #shown>0 and I.CalcTextSize(c,shown..'...')>available do local at=utf8.offset(shown,-1);shown=shown:sub(1,(at or #shown)-1)end
   shown=shown..'...'
  end
  local _,height=I.CalcTextSize(c,shown)
  I.DrawList_PushClipRect(d,x,key.top,v.x-1,key.bottom,true)
  I.DrawList_AddText(d,x+6,(key.top+key.bottom-(height or 12))*.5,T.text,shown)
  I.DrawList_PopClipRect(d)
 end end
end
function M.activate(app,map)
 local Map=require 'src.instrument_map';local changed=Map.copy(map)
 changed.articulations=app.instrument_map and app.instrument_map.articulations or {}
 changed.enabled=true;changed.channel=app.settings.channel or 0
 local ok,notice=Map.save(app,changed);app.instrument_map_notice=notice
 if ok then app.settings.scale_view_only=false;app.settings.fold_enabled=false end
 return ok
end
function M.menu(app,x,y,w)
 local I,c=app.ImGui,app.ctx;local Map=require 'src.instrument_map';local map=app.instrument_map or Map.new()
 local picker_width=math.max(22,w-66)
 I.SetCursorScreenPos(c,x+w-picker_width,y+2);I.SetNextItemWidth(c,picker_width)
 if I.BeginCombo(c,'##drum_map_picker',picker_width>=70 and(map.enabled and 'Drums' or 'Piano')or '')then
  if I.Selectable(c,'Piano',not map.enabled)then local copy=Map.copy(map);copy.enabled=false;local _,notice=Map.save(app,copy);app.instrument_map_notice=notice end
  if #map.rows>0 and I.Selectable(c,'Current drum map',map.enabled)then M.activate(app,map)end
  if I.Selectable(c,'GM essentials (12 drums)')then M.activate(app,Map.essentials(app.settings.channel or 0))end
  for _,name in ipairs(Map.presets())do if I.Selectable(c,name)then local loaded,notice=Map.load_preset(name);if loaded then M.activate(app,loaded)else app.instrument_map_notice=notice end end end
  I.Separator(c)
  if I.Selectable(c,'Edit drum map...')then app.instrument_map_open=true;app.instrument_map_section='drums'end
  I.EndCombo(c)
 end
 if I.IsItemHovered(c)then I.SetTooltip(c,'Piano / drum map')end
end
function M.edit_row(app,v,pitch)
 local I,c=app.ImGui,app.ctx;local Map=require 'src.instrument_map'
 if v.mapped and I.IsItemHovered(c)and not app.gesture and I.IsMouseDoubleClicked(c,I.MouseButton_Left)then
  for _,row in ipairs(app.instrument_map.rows)do if row.pitch==pitch then app.drum_row_edit={pitch=pitch,name=row.name};I.OpenPopup(c,'##drum_row_name');break end end
 end
 if I.BeginPopup(c,'##drum_row_name')then
  local edit=app.drum_row_edit
  if edit then
   I.Text(c,'Drum name');I.SetNextItemWidth(c,200)
   local hit;hit,edit.name=I.InputText(c,'##drum_name',edit.name,I.InputTextFlags_EnterReturnsTrue)
   if hit or I.IsItemDeactivatedAfterEdit(c)then
    local map=Map.copy(app.instrument_map)
    for _,row in ipairs(map.rows)do if row.pitch==edit.pitch then row.name=edit.name end end
    local ok,notice=Map.save(app,map);app.instrument_map_notice=notice;if ok then I.CloseCurrentPopup(c)end
   end
  end
  I.EndPopup(c)
 end
end
return M
