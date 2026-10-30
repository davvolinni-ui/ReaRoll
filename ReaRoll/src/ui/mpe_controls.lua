-- @noindex
local Controls=require 'src.ui.controls'
local M={}
function M.draw(app,next_item)
 local I,c,s=app.ImGui,app.ctx,app.settings
 local z=math.max(.8,math.min(1.5,s.ui_scale or 1))
 next_item=next_item or function()I.SameLine(c)end
 local locked=app.gesture~=nil or app.edit.active~=nil or app.expression_direct_gesture~=nil or app.transform_preview~=nil or app.multi_notes and(app.multi_notes.transaction~=nil or app.multi_notes.paint~=nil or app.multi_notes.drag~=nil)or false
 local owner=app
 if app.multi_edit_mode then
  local target=require('src.multi_notes').creation_take(app)
  if target then owner=require('src.expression_scope').owner(app,target)end
 end
 local Overlap=require 'src.overlap_mode';local config=Overlap.state(owner)
 local draw_settings,saved_mode=Overlap.drawing_settings(owner)
 I.BeginDisabled(c,locked)
 local oldzone,oldvoices=s.mpe_zone,s.mpe_members
 if s.mpe_enabled then
  I.BeginDisabled(c,config~=nil and saved_mode==true)
  next_item(62*z);I.SetNextItemWidth(c,62*z)
  if I.BeginCombo(c,'##mpe_zone_inline',s.mpe_zone=='upper'and 'Upper'or 'Lower')then
   for _,zone in ipairs({'lower','upper'})do if I.Selectable(c,zone=='lower'and 'Lower zone'or 'Upper zone',s.mpe_zone==zone)then s.mpe_zone=zone end end;I.EndCombo(c)
  end
  if not locked and not(config and saved_mode)then Controls.choice(app,s,'mpe_zone','lower',{'lower','upper'},'MPE zone')end
  next_item(48*z);I.SetNextItemWidth(c,48*z)
  local changed;changed,s.mpe_members=I.DragInt(c,'##mpe_voices_inline',s.mpe_members or 15,1,1,15,'V %d')
  if not locked and not(config and saved_mode)then Controls.number(app,s,'mpe_members',15,1,1,15,'MPE voices (member channels)')end
  I.EndDisabled(c)
 end
 local key=s.mpe_enabled and 'mpe_pitch_bend_range'or 'pitch_bend_range'
 local saved=draw_settings[key]or s[key]or(s.mpe_enabled and 48 or 2)
 local range_id=tostring(owner.take)..':'..key..':'..saved
 if app.inline_mpe_range_id~=range_id then app.inline_mpe_range_id=range_id;app.inline_mpe_range={value=saved}end
 local field=app.inline_mpe_range;next_item(76*z);I.SetNextItemWidth(c,76*z)
 local changed;changed,field.value=I.DragInt(c,'##mpe_range_inline',field.value,1,1,96,'+/- %d st')
 local wheel=not locked and Controls.choice(app,field,'value',s.mpe_enabled and 48 or 2,{2,12,24,48,96},'Instrument pitch range (semitones)',true)
 if I.IsItemHovered(c)then I.SetTooltip(c,'Instrument pitch range: match the instrument. Wheel: 2 / 12 / 24 / 48 / 96. Ctrl-click to type a value.')end
 if wheel or I.IsItemDeactivatedAfterEdit(c)then
  if config then
   local ok,notice=Overlap.range(owner,field.value);app.expression_notice=notice
   if not ok then field.value=saved else s[key]=field.value;app.cache:invalidate();app.cc_cache:invalidate();if app.multi_edit_mode then require('src.multi_notes').refresh(app,true)end end
  else s[key]=field.value end
  app.expression_direct_cache=nil
 end
 if app.expression_dimension=='pitch'then
  next_item(68*z);I.SetNextItemWidth(c,68*z)
  local maximum=math.max(1,field.value)
  app.expression_view_range=math.max(1,math.min(maximum,app.expression_view_range or 12))
  local changed;changed,app.expression_view_range=I.DragInt(c,'##expression_view_inline',app.expression_view_range,1,1,maximum,'View %d st')
  if not locked then Controls.number(app,app,'expression_view_range',math.min(12,maximum),1,1,maximum,'Pitch view: vertical zoom only')end
 end
 if oldzone~=s.mpe_zone or oldvoices~=s.mpe_members then app.expression_direct_cache=nil;app.expression_group_draft=nil end
 I.EndDisabled(c)
end
return M
