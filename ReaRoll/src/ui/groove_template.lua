-- @noindex
local Model=require 'src.groove_template'
local M={}
function M.draw(app)
  local I,c=app.ImGui,app.ctx;local changed=false
  app.groove_slot=app.groove_slot or 1;app.groove_cycle=app.groove_cycle or 4
  if I.BeginCombo(c,'Timing source',app.groove_enabled and ('Saved groove '..app.groove_slot) or 'Grid / swing')then
    if I.Selectable(c,'Grid / swing',not app.groove_enabled)then app.groove_enabled=false;changed=true end
    for i=1,8 do
      local available=Model.decode(app.settings['groove_slot_'..i])~=nil
      if I.Selectable(c,'Groove '..i..(available and '' or ' (empty)'),app.groove_enabled and app.groove_slot==i)then app.groove_slot=i;app.groove_enabled=true;changed=true end
    end
    I.EndCombo(c)
  end
  if app.groove_enabled then
    local hit;hit,app.groove_cycle=I.SliderDouble(c,'Capture cycle (beats)',app.groove_cycle,.25,16,'%.2f')
    if I.Button(c,'Capture selection into groove '..app.groove_slot)then
      app.transforms.cancel_preview(app)
      local selected=require('src.selection').list(app.selection,app.cache:get(false));local source={}
      for _,n in ipairs(selected)do source[#source+1]={q=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s),vel=n.vel}end
      local template,notice=Model.capture(source,app.groove_cycle,app.item_start_qn or 0)
      app.groove_notice=notice
      if template then
        app.settings['groove_slot_'..app.groove_slot]=Model.encode(template)
        reaper.SetExtState('ReaRoll','groove_slot_'..app.groove_slot,app.settings['groove_slot_'..app.groove_slot],true)
        changed=true
      end
    end
    app.groove_velocity_strength=app.groove_velocity_strength or 0
    hit,app.groove_velocity_strength=I.SliderInt(c,'Groove velocity',app.groove_velocity_strength,0,100,'%d%%');changed=hit or changed
    local template=Model.decode(app.settings['groove_slot_'..app.groove_slot])
    if template then I.TextDisabled(c,string.format('%d onsets / %.2f beat cycle',#template.points,template.length))
    else I.TextWrapped(c,'Capture notes into this slot before using it.');end
    if app.groove_notice then I.TextWrapped(c,app.groove_notice)end
    return changed,template,template~=nil
  end
  return changed,nil,true
end
return M
