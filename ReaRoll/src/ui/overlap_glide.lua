-- @noindex
local Mode=require 'src.overlap_mode'
local M={}
function M.draw(app,d,v,notes)
  app.glide_connection_handles={}
  local config=Mode.state(app);if not config then return end
  local plan=require('src.overlap_glide').plan(notes,config);if not plan then return end
  local I,T=app.ImGui,app.theme;local z=math.max(.8,math.min(1.5,app.settings.ui_scale or 1))
  local function y(pitch)
    local result=v:y_from_pitch(pitch)
    if result or not v.fold then return result end
    local low,high
    for _,p in ipairs(v.fold)do if p<pitch and(not low or p>low)then low=p elseif p>pitch and(not high or p<high)then high=p end end
    if low and high then local a,b=v:y_from_pitch(low),v:y_from_pitch(high);if a and b then return a+(b-a)*(pitch-low)/(high-low)end end
  end
  for _,link in ipairs(plan.connections)do
    local sy,ey=y(link.from_pitch or link.source.pitch),y(link.to_pitch or link.target.pitch)
    if sy and ey then
      sy=sy+app.settings.row_height*.5;ey=ey+app.settings.row_height*.5
      local x1,x2=v:x_from_ppq(link.first),v:x_from_ppq(link.last)
      I.DrawList_AddLine(d,x1,sy,x2,ey,T.accent,2)
      I.DrawList_AddCircleFilled(d,x1,sy,3,T.accent);I.DrawList_AddCircleFilled(d,x2,ey,3,T.accent)
      if link.mpe_enabled then
        local x,y=(x1+x2)*.5,(sy+ey)*.5
        I.DrawList_AddCircleFilled(d,x,y,4*z,T.accent)
        app.glide_connection_handles[#app.glide_connection_handles+1]={x=x,y=y,source=(link.source.logical or link.source).index,old_target=(link.target.logical or link.target).index,channel=link.channel}
      end
    end
  end
  do
    for _,note in ipairs(notes)do local setup=require('src.glide_setup').get(note,config)
    if setup.mpe_enabled and not note.muted and require('src.expression').member(note.chan,setup)then
      local top=v:y_from_pitch(note.pitch);local a,ending=v:x_from_ppq(note.s),v:x_from_ppq(note.e)
      if top and ending-a>=28*z then
        local x=ending-14*z;local y=top+app.settings.row_height*.5
        if x>=v.x and x<=v.x+v.w then
          I.DrawList_AddCircleFilled(d,x,y,3*z,T.accent)
          app.glide_connection_handles[#app.glide_connection_handles+1]={x=x,y=y,source=note.index}
        end
      end
    end end
  end
  local g=app.gesture
  if g and g.kind=='glide_connection'then
    I.DrawList_AddLine(d,g.x,g.y,g.mx,g.my,T.selected_edge or T.accent,2)
    I.DrawList_AddCircleFilled(d,g.mx,g.my,4,T.selected_edge or T.accent)
  end
end
function M.interact(app,v,hovered,mx,my,mods,edge)
  local I,c=app.ImGui,app.ctx;local g=app.gesture
  if g and g.kind=='glide_connection'then
    if I.IsKeyPressed(c,I.Key_Escape)then app.gesture=nil;return true end
    g.mx,g.my=mx,my
    if I.IsMouseReleased(c,I.MouseButton_Left)then
      app.gesture=nil
      local source=app.cache:get(false)[g.source+1];local target
      if source then for _,note in ipairs(app.cache:get(false))do local y=v:y_from_pitch(note.pitch)
        if note.index~=source.index and note.s>source.s and note.s<source.e and y and my>=y and my<=y+app.settings.row_height and mx>=v:x_from_ppq(note.s)and mx<=v:x_from_ppq(note.e)then target=note end
      end end
      if target then local _,notice=require('src.glide_connections').change(app,g.source,target.index,g.old_target,g.raw,false,g.channel);app.expression_notice=notice end
    end
    return true
  end
  if not hovered or edge or g or app.edit.active or app.transform_preview or app.expression_direct_gesture then return false end
  local config=Mode.state(app);if not config then return false end
  if app.settings.mode~='smart'and app.settings.mode~='chord'and app.settings.mode~='select'then return false end
  local best,distance;local z=math.max(.8,math.min(1.5,app.settings.ui_scale or 1))
  for _,h in ipairs(app.glide_connection_handles or {})do local delta=(mx-h.x)^2+(my-h.y)^2;if delta<=49*z*z and(not distance or delta<distance)then best,distance=h,delta end end
  if not best then return false end
  I.SetMouseCursor(c,I.MouseCursor_Hand)
  I.SetTooltip(c,best.old_target and 'Glide connection: drag this dot onto another overlapping destination. Right-click: unlink.'or 'Drag this note connector onto an overlapping destination. Several voices can connect to one note.')
  if I.IsMouseClicked(c,I.MouseButton_Right)and best.old_target then
    local _,notice=require('src.glide_connections').change(app,best.source,best.old_target,nil,nil,true,best.channel);app.expression_notice=notice
  elseif I.IsMouseClicked(c,I.MouseButton_Left)then
    app.gesture={kind='glide_connection',source=best.source,old_target=best.old_target,channel=best.channel,x=best.x,y=best.y,mx=mx,my=my,raw=select(2,reaper.MIDI_GetAllEvts(app.take,''))}
  end
  return true
end
return M
