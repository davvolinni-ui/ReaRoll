-- @noindex
local Model=require 'src.multi_notes'
local Icons=require 'src.ui.icons'
local Controls=require 'src.ui.controls'
local M={}
function M.height(app)
 local z=math.max(.8,math.min(1.5,app.settings.ui_scale or 1))
 return math.max(app.ImGui.GetFrameHeight(app.ctx),26*z)+6*z
end
local function label(source,index)
 local track=reaper.GetMediaItemTrack and reaper.GetMediaItemTrack(source.item)
 local ok,name;if track and reaper.GetTrackName then ok,name=reaper.GetTrackName(track)end
 local text=ok and name~=''and(name..' / '..source.name)or source.name
 if reaper.format_timestr_pos and reaper.TimeMap2_QNToTime then
  text=text..' @ '..reaper.format_timestr_pos(reaper.TimeMap2_QNToTime(0,source.start_qn),'',2)
 else text=text..' ['..index..']'end
 return text
end
function M.draw(app,state,x,y,width)
 local I,c,s=app.ImGui,app.ctx,app.settings
 local z=math.max(.8,math.min(1.5,s.ui_scale or 1));local gap=6*z;local fit_width=28*z
 local locked=state.transaction~=nil or state.paint~=nil or state.drag~=nil or app.gesture~=nil or app.transform_preview~=nil
 local editable={};for _,src in ipairs(state.sources)do if not src.readonly then editable[#editable+1]=src end end
 local creation=app.multi_creation_take or app.take;local valid=false
 for _,src in ipairs(editable)do if src.take==creation then valid=true end end
 if not valid then creation=editable[1]and editable[1].take end
 app.multi_creation_take=creation
 local has_choice=#editable>1
 local oldscope=app.multi_source_scope or 'selected'
 local space=math.max(1,width-fit_width-gap*(has_choice and 2 or 1))
 local scope_width=has_choice and math.min(152*z,space*.4)or math.min(152*z,space)
 I.SetCursorScreenPos(c,x,y);I.BeginDisabled(c,locked)
 I.SetNextItemWidth(c,scope_width)
 local scope=app.multi_source_scope or 'selected'
 local title=(scope=='track'and 'Track'or 'Selected')..' ('..#state.sources..')'
 if I.BeginCombo(c,'##multi_source_scope',title)then
  for _,entry in ipairs({{'Selected MIDI items (across tracks)','selected'},{'MIDI items on the active track','track'}})do
   if I.Selectable(c,entry[1],scope==entry[2])then app.multi_source_scope=entry[2]end
  end;I.EndCombo(c)
 end
 app.multi_source_scope=Controls.cycle(app,{'selected','track'},app.multi_source_scope or 'selected',locked)
 if oldscope~=app.multi_source_scope then
  state=Model.refresh(app,true);editable={}
  for _,src in ipairs(state.sources)do if not src.readonly then editable[#editable+1]=src end end
  valid=false;for _,src in ipairs(editable)do if src.take==creation then valid=true end end
  if not valid then creation=editable[1]and editable[1].take end
  app.multi_creation_take=creation
 end
 if I.IsItemHovered(c)then I.SetTooltip(c,'Wheel: change item scope. Items shown together: selected MIDI items across tracks, or items on the active track. Each stays in its original track.')end
 if has_choice then
  I.SameLine(c,0,gap);I.SetNextItemWidth(c,math.min(320*z,space-scope_width))
  local name='Choose item'
  for i,src in ipairs(state.sources)do if src.take==creation then name=label(src,i)end end
  if I.BeginCombo(c,'##multi_draw_target','Draw: '..name)then
   for i,src in ipairs(state.sources)do
    I.BeginDisabled(c,src.readonly==true)
    if I.Selectable(c,label(src,i)..'##'..tostring(src.take),src.take==creation)then app.multi_creation_take=src.take end
    I.EndDisabled(c)
    if src.readonly and I.IsItemHovered(c)then I.SetTooltip(c,src.reason or 'Read-only MIDI item')end
   end;I.EndCombo(c)
  end
  local takes={};for _,src in ipairs(editable)do takes[#takes+1]=src.take end
  app.multi_creation_take=Controls.cycle(app,takes,app.multi_creation_take,locked)
  if I.IsItemHovered(c)then I.SetTooltip(c,'Wheel: choose the drawing item. New notes go into this item. Clicking an existing note also makes its item the drawing destination. Other items keep their notes and channels.')end
 end
 I.SameLine(c,0,gap)
 if Icons.button(app,'multi_fit','view','Fit all included MIDI items')then
  local first,last,low,high=math.huge,-math.huge,127,0
  for _,src in ipairs(state.sources)do first=math.min(first,src.start_qn);last=math.max(last,src.end_qn)end
  for _,note in ipairs(state.notes)do low=math.min(low,note.pitch);high=math.max(high,note.pitch)end
  if first<math.huge then s.start_qn=math.max(0,first-.25);s.visible_qn=math.max(1,last-first+.5)end
  if high>=low then s.low_pitch=math.max(0,low-2)end
 end
 I.EndDisabled(c)
 return state
end
return M
