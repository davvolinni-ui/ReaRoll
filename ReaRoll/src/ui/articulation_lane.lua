-- @noindex
local M={}
function M.groups(app)
 local groups,seen={},{}
 for _,entry in ipairs(app.instrument_map and app.instrument_map.articulations or {})do local group=entry.group or 'Playing style';if not seen[group]then seen[group]=true;groups[#groups+1]=group end end
 return groups
end
function M.height(app)return #M.groups(app)*math.max(24,app.settings.row_height or 14)end
local function draw_group(app,v,x,y,w,h,group)
 local I,c,T=app.ImGui,app.ctx,app.theme
 local d=I.GetWindowDrawList(c);local channel=app.settings.channel or 0
 I.DrawList_AddRectFilled(d,x,y,x+w,y+h,T.panel)
 I.DrawList_PushClipRect(d,x,y,v.x,y+h,true);I.DrawList_AddText(d,x+4,y+4,T.hint,group);I.DrawList_PopClipRect(d)
 local _,hash=reaper.MIDI_GetHash(app.take,false,'')
 if not app.articulation_lane_cache or app.articulation_lane_cache.hash~=hash or app.articulation_lane_cache.take~=app.take then
  local stream=require('src.note_events').read(app.take)
  app.articulation_lane_cache={hash=hash,take=app.take,rows=stream and require('src.articulation_events').read(stream)or {}}
 end
 local rows={};for _,row in ipairs(app.articulation_lane_cache.rows)do if row.channel==channel and row.group==group then rows[#rows+1]=row end end
 local mx,my=I.GetMousePos(c);local hovered_row
 I.DrawList_PushClipRect(d,v.x,y,v.x+v.w,y+h,true)
 for i,row in ipairs(rows)do
  local first=reaper.MIDI_GetProjQNFromPPQPos(app.take,row.ppq)
  local last=rows[i+1]and reaper.MIDI_GetProjQNFromPPQPos(app.take,rows[i+1].ppq)or app.item_end_qn
  local left,right=math.max(v.x,v:x_from_qn(first)),math.min(v.x+v.w,v:x_from_qn(last))
  if right>left then
   I.DrawList_AddRectFilled(d,left,y+1,right,y+h-1,(T.accent&0xFFFFFF00)|55)
   I.DrawList_AddLine(d,left,y,left,y+h,T.accent)
   I.DrawList_PushClipRect(d,left,y,right,y+h,true);I.DrawList_AddText(d,left+4,y+4,T.text,row.name);I.DrawList_PopClipRect(d)
   if mx>=left and mx<right and my>=y and my<y+h then hovered_row=row end
  end
 end
 I.DrawList_PopClipRect(d)
 I.SetCursorScreenPos(c,v.x,y);I.InvisibleButton(c,'##articulation_lane',v.w,h,I.ButtonFlags_MouseButtonLeft|I.ButtonFlags_MouseButtonRight)
 if I.IsItemHovered(c)then
  I.SetTooltip(c,'Click: add / drag: move a change / right-click: edit. Channel '..(channel+1)..'.')
  if I.IsMouseClicked(c,I.MouseButton_Left)and not app.gesture then
   app.articulation_hold={group=group,row=hovered_row,x=mx,take=app.take,q=require('src.util').snap_time(app.settings,v:qn_from_x(mx))}
  end
  if I.IsMouseClicked(c,I.MouseButton_Right)and not app.gesture then
   app.articulation_lane_editing=hovered_row~=nil
   app.articulation_lane_q=hovered_row and reaper.MIDI_GetProjQNFromPPQPos(app.take,hovered_row.anchor)or require('src.util').snap_time(app.settings,v:qn_from_x(mx))
   I.OpenPopup(c,'##articulation_choose')
  end
 end
 local hold=app.articulation_hold
 if hold and hold.group==group then
  if hold.take~=app.take or app.gesture or I.IsKeyPressed(c,I.Key_Escape)then app.articulation_hold=nil
  else
   local q=require('src.util').snap_time(app.settings,v:qn_from_x(mx))
   if hold.row and math.abs(mx-hold.x)>=4 then hold.dragged=true end
   if hold.dragged then local px=v:x_from_qn(q);I.DrawList_AddLine(d,px,y,px,y+h,T.accent,2)end
   if I.IsMouseReleased(c,I.MouseButton_Left)then
    if hold.dragged then
     local _,notice=require('src.articulations').move_direction(app,channel,reaper.MIDI_GetProjQNFromPPQPos(app.take,hold.row.anchor),q,group)
     app.articulation_notice=notice;app.articulation_lane_cache=nil
    else app.articulation_lane_editing=false;app.articulation_lane_q=hold.q;I.OpenPopup(c,'##articulation_choose')end
    app.articulation_hold=nil
   end
  end
 end
 if I.BeginPopup(c,'##articulation_choose')then
  for index,entry in ipairs(app.instrument_map.articulations)do
   if (entry.group or 'Playing style')==group and(entry.channel<0 or entry.channel==channel)then
   if I.Selectable(c,entry.name..'##direction'..index)then
    local copy={};for k,value in pairs(entry)do copy[k]=value end
    if copy.channel<0 then copy.channel=channel end
    local _,notice=require('src.articulations').insert(app,copy,false,nil,true,app.articulation_lane_q)
    app.articulation_notice=notice;app.articulation_lane_cache=nil
   end
   end
  end
  if app.articulation_lane_editing and I.Selectable(c,'Remove this change')then
   local _,notice=require('src.articulations').remove_direction(app,channel,app.articulation_lane_q,group)
   app.articulation_notice=notice;app.articulation_lane_cache=nil
  end
  I.Separator(c)
  if I.Selectable(c,'Instrument setup...')then app.instrument_map_open=true;app.instrument_map_section='articulations'end
  I.EndPopup(c)
 end
 if app.articulation_notice then I.SetCursorScreenPos(c,v.x,y);I.TextColored(c,T.accent,app.articulation_notice)end
end
function M.draw(app,v,x,y,w,h)
 if h==0 then return end
 local groups=M.groups(app);local row_height=h/math.max(1,#groups)
 for index,group in ipairs(groups)do
  app.ImGui.PushID(app.ctx,'artgroup'..group)
  draw_group(app,v,x,y+(index-1)*row_height,w,row_height,group)
  app.ImGui.PopID(app.ctx)
 end
end
return M
