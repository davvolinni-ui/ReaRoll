-- @noindex
local Points=require 'src.expression_points'
local Shared=require 'src.expression_selection'
local G=require 'src.expression_gesture'
local U=require 'src.util'
local M={}
local function list(state)
 local out={};for _,ref in pairs(state and state.points or {})do out[#out+1]=ref end;return out
end
local function visible(app,v,notes,kind,top,height,helpers)
 local out={}
 for _,note in ipairs(notes)do if helpers.eligible(app,note)then
  local draft=helpers.draft_for(app,note)
  if draft then local xy=helpers.coordinates(app,v,draft,kind,top,height,false)
   for _,point in ipairs(G.points(draft,kind))do if not point.context and not point.shared then
    local x,y=xy(point.time,point.value)
    if x>=v.x and x<=v.x+v.w and y>=top and y<=top+height then out[#out+1]={draft=draft,point=point,ref=Points.ref(draft,point,note.id),x=x,y=y}end
   end end
  end
 end end
 return out
end
local function box(app,v,top,height,m)
 local I,c=app.ImGui,app.ctx;local d=I.GetWindowDrawList(c)
 local left,right=math.min(m.x,m.mx),math.max(m.x,m.mx);local first,last=math.min(m.y,m.my),math.max(m.y,m.my)
 I.DrawList_PushClipRect(d,v.x,top,v.x+v.w,top+height,true)
 I.DrawList_AddRectFilled(d,left,first,right,last,app.theme.marquee_fill or((app.theme.selected_edge&0xFFFFFF00)|40))
 I.DrawList_AddRect(d,left,first,right,last,app.theme.marquee_edge or app.theme.selected_edge,0,I.DrawFlags_None,1)
 I.DrawList_PopClipRect(d)
end
local function finish(app,g)
 local ok,notice=Points.finish(app,g)
 app.expression_notice=notice;app.expression_direct_gesture=nil;app.expression_direct_cache=nil;app.expression_point_focus=nil
 return ok
end
function M.interact(app,v,notes,kind,top,height,hovered,mx,my,helpers)
 local I,c=app.ImGui,app.ctx;local mods=U.mods(I,c)
 local g=app.expression_direct_gesture;local m=app.expression_point_marquee
 if g and not g.point_selection then return false end
 if g then
  local valid,notice=Shared.valid(app,g)
  if not valid then app.expression_direct_gesture=nil;app.expression_notice=notice;app.expression_point_selection=nil;return true end
  if I.IsKeyPressed(c,I.Key_Escape)then app.expression_direct_gesture=nil;app.expression_point_selection=g.original_selection;return true end
  if I.IsMouseDown(c,0)then
   local dx,dy=mx-g.mx,my-g.my
   if mods.shift then
    if not g.axis and math.max(math.abs(dx),math.abs(dy))>3 then g.axis=math.abs(dx)>=math.abs(dy)and 'time'or 'value'end
    if g.axis=='time'then dy=0 elseif g.axis=='value'then dx=0 end
   else g.axis=nil end
   local q=v:qn_from_x(g.mx+dx);local delta=q-g.mouse_qn
   if app.settings.snap_enabled and not mods.alt then delta=U.snap(g.reference_qn+delta,app.settings.grid_qn)-g.reference_qn end
   local scale=kind=='pitch'and(2*(app.expression_view_range or 12)/math.max(1,app.settings.mpe_enabled and app.settings.mpe_pitch_bend_range or app.settings.pitch_bend_range or 2))*8191.5 or 127
   Points.update(g,delta,-dy/math.max(1,height)*scale)
  else finish(app,g)end
  return true
 end
 local state=Points.current(app)
 if m then
  if kind~=m.kind or not state then app.expression_point_marquee=nil;return true end
  if I.IsKeyPressed(c,I.Key_Escape)then app.expression_point_selection=m.previous;app.expression_point_marquee=nil;return true end
  m.mx,m.my=mx,my;m.dragged=m.dragged or math.max(math.abs(mx-m.x),math.abs(my-m.y))>=3
  if m.dragged then
   local refs={};for _,ref in ipairs(m.base)do refs[#refs+1]=ref end
   local left,right=math.min(m.x,mx),math.max(m.x,mx);local first,last=math.min(m.y,my),math.max(m.y,my)
   for _,item in ipairs(visible(app,v,notes,kind,top,height,helpers))do if item.x>=left and item.x<=right and item.y>=first and item.y<=last then refs[#refs+1]=item.ref end end
   Points.set(app,refs,kind);box(app,v,top,height,m)
  end
  if not I.IsMouseDown(c,1)then
   app.expression_point_marquee=nil
   if not m.dragged then
    local refs=m.tap and(m.previous and m.previous.points[m.tap.ref.key]and list(m.previous)or{m.tap.ref})or{}
    Points.set(app,refs,kind)
    if #refs>0 then local gesture,notice=Points.begin(app,'delete');app.expression_notice=notice
     if gesture then app.expression_direct_gesture=gesture;finish(app,gesture)end
    end
   end
  end
  return true
 end
 if not hovered or app.gesture or app.expression_group_open then return false end
 local items=visible(app,v,notes,kind,top,height,helpers);local hit,distance
 for _,item in ipairs(items)do local delta=(item.x-mx)^2+(item.y-my)^2
  if delta<=81 and(not distance or delta<distance)then hit,distance=item,delta end
 end
 if I.IsMouseClicked(c,1)then
  local previous=state;local base=mods.ctrl and list(state)or{}
  Points.set(app,list(state),kind)
  app.expression_point_marquee={x=mx,y=my,mx=mx,my=my,previous=previous,base=base,kind=kind,tap=hit}
  app.expression_point_focus=nil;return true
 end
 if I.IsMouseClicked(c,0)then
  if mods.ctrl and hit then
   local refs={};for _,ref in ipairs(list(state))do if ref.key~=hit.ref.key then refs[#refs+1]=ref end end
   if not(state and state.points[hit.ref.key])then refs[#refs+1]=hit.ref end
   Points.set(app,refs,kind);return true
  end
  if state and hit and not mods.alt then
   if not state.points[hit.ref.key]then Points.set(app,{hit.ref},kind)end
   local gesture,notice=Points.begin(app,'move');app.expression_notice=notice
   if gesture then
    gesture.surface='lane';gesture.mx,gesture.my=mx,my;gesture.mouse_qn=v:qn_from_x(mx)
    gesture.reference_qn=reaper.MIDI_GetProjQNFromPPQPos(hit.draft.take,hit.draft.note.s+hit.point.time*(hit.draft.expression_end-hit.draft.note.s))
    gesture.note_id=hit.ref.note_id;app.expression_focus_id=hit.ref.note_id;app.expression_direct_gesture=gesture
   end
   return true
  end
  app.expression_point_selection=nil
 end
 if state then I.SetTooltip(c,'Right-drag: select points. Ctrl: add to selection. Drag selected points to move; Delete: remove. Shift-drag: lock axis. Escape: cancel.');return not I.IsMouseClicked(c,0)end
 return false
end
function M.keys(app)
 local state=Points.current(app);if not state then return false end
 local I,c=app.ImGui,app.ctx
 if not app.expression_editor_open then app.expression_point_selection=nil;return false end
 if I.IsAnyItemActive(c)or not I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows)then return false end
 if I.IsKeyPressed(c,I.Key_Escape)then app.expression_point_selection=nil;return true end
 if not require('src.shortcuts').pressed(app,'delete',U.mods(I,c))then return false end
 if state.count>0 then
  local g,notice=Points.begin(app,'delete');app.expression_notice=notice
  if g then app.expression_direct_gesture=g;finish(app,g)end
 end
 return true
end
return M
