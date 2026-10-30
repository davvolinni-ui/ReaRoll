-- @noindex
local Model=require 'src.multi_notes';local U=require 'src.util';local Tools=require 'src.ui.lane_tools'
local Mouse=require 'src.mouse';local Shortcuts=require 'src.shortcuts'
local M={}
local Marquee=require 'src.ui.multi_selection'
local function slice_line(app,v,brush,mx,my,mods)
  local cuts={};local dy=my-brush.y;local s=app.settings
  for _,n in ipairs(app.multi_notes.notes)do if not n.source.readonly then
    local top=v:y_from_pitch(n.pitch)
    if top then
      local x
      if math.abs(dy)<.001 then if my>=top and my<=top+s.row_height then x=mx end
      else
        local hit=U.clamp(top+s.row_height*.5,math.min(brush.y,my),math.max(brush.y,my))
        if hit>=top and hit<=top+s.row_height then x=brush.x+(mx-brush.x)*(hit-brush.y)/dy end
      end
      if x then local q=v:qn_from_x(x);if s.snap_enabled and not Mouse.is(s,'unsnap',mods)then q=U.snap_time(s,q,n.s)end
        if q>n.s and q<n.e then cuts[n.key]=q end
      end
    end
  end end
  return cuts
end
local function glue_line(app,v,brush,mx,my)
  local groups,seams={},{};local s=app.settings
  for _,n in ipairs(app.multi_notes.notes)do if not n.source.readonly and(s.edit_all_channels~=false or n.chan==(s.channel or 0))then
    local key=tostring(n.source.take)..':'..n.chan..':'..n.pitch;groups[key]=groups[key]or {};groups[key][#groups[key]+1]=n
  end end
  for _,notes in pairs(groups)do
    table.sort(notes,function(a,b)return a.s<b.s end)
    for i=2,#notes do local left,right=notes[i-1],notes[i]
      local gap=reaper.MIDI_GetPPQPosFromProjQN(left.source.take,right.s)-reaper.MIDI_GetPPQPosFromProjQN(left.source.take,left.e)
      local top=v:y_from_pitch(left.pitch)
      if math.abs(gap)<=1 and top then
        local x=v:x_from_qn((left.e+right.s)*.5);local dx=mx-brush.last_x;local hit=false
        if math.abs(dx)<.001 then hit=math.abs(mx-x)<=6 and math.max(brush.last_y,my)>=top and math.min(brush.last_y,my)<=top+s.row_height
        else local t=(x-brush.last_x)/dx
          if t>=0 and t<=1 then local y=brush.last_y+(my-brush.last_y)*t;hit=y>=top and y<=top+s.row_height end
          hit=hit or math.abs(mx-x)<=6 and my>=top and my<=top+s.row_height
        end
        if hit then seams[#seams+1]={left,right}end
      end
    end
  end
  return seams
end

function M.edit(app,operation,delta,pitch)
 local ok,notice=Model.preview(app,operation,delta,pitch)
 app.multi_notes.notice=notice
 if ok then return Model.commit(app,'ReaRoll: edit MIDI notes')end
 if app.multi_notes.transaction then Model.cancel(app)end
 return false,notice
end
function M.erase_begin(app,hit)
 local state=app.multi_notes;if hit.source.readonly then return end
 local before={};for k,value in pairs(state.selection)do before[k]=value end
 state.selection={};for _,n in ipairs(state.notes)do if not n.source.readonly then state.selection[n.key]=true end end;Model.sync(app)
 local ok,notice=Model.begin(app);state.notice=notice
 if not ok then state.selection=before;Model.sync(app);return end
 state.erase_brush={before=before,keys={[hit.key]=true}};state.selection={};Model.sync(app)
 app.gesture={kind='source_erase'}
 local _,notice=Model.preview(app,'erase',state.erase_brush.keys);state.notice=notice
end
function M.duplicate(app)
 local first,last=math.huge,-math.huge
 for _,n in ipairs(Model.chosen(app))do first=math.min(first,n.s);last=math.max(last,n.e)end
 if first<math.huge then return M.edit(app,'copy',math.max(app.settings.grid_qn,last-first),0)end
end
function M.adjust(app,note,wheel)
 local state=app.multi_notes;local n=note.owner
 if not n or n.source.readonly then return false end
 if not state.selection[n.key]then state.selection={[n.key]=true};Model.sync(app)end
 if app.settings.lane_target=='velocity'then return M.edit(app,'velocity',wheel>0 and 1 or -1)end
 return M.edit(app,'controller',wheel>0 and 1 or -1)
end
function M.velocity(app,v,notes,nearest,distance,hovered,mx,my,top,height,mods)
 local I,c,s=app.ImGui,app.ctx,app.settings;local state=app.multi_notes;local g=app.source_velocity
 if g and not state.transaction then app.source_velocity=nil;g=nil end
 if hovered and s.mode~='razor'and not g and not app.gesture and not state.transaction and I.IsMouseClicked(c,I.MouseButton_Left)then
  app.controller_selection_active=false
  if nearest and distance<=225 and not mods.shift then
   local n=nearest.owner
   if not state.selection[n.key]then state.selection={[n.key]=true};Model.sync(app)end
   local ok,notice=Model.begin(app);state.notice=notice
   if ok then g={anchor=nearest.vel,mouse_y=my,bottom=top+height-3,height=height-8};app.source_velocity=g end
  else
   local before={};for _,n in ipairs(Model.chosen(app))do before[tostring(n.source.take)..':'..n.index]=true end
   state.selection={}
   for _,n in ipairs(state.notes)do if not n.source.readonly and(s.edit_all_channels~=false or n.chan==(s.channel or 0))then state.selection[n.key]=true end end
   Model.sync(app);local ok,notice=Model.begin(app);state.notice=notice
   if ok then g={swipe=true,before=before,x=mx,y=my,last_x=mx,last_y=my,values={},bottom=top+height-3,height=height-8};app.source_velocity=g end
  end
 end
 if not g then return end
 if Shortcuts.pressed(app,'cancel',mods)then Model.cancel(app);app.source_velocity=nil;return end
 if I.IsMouseDown(c,I.MouseButton_Left)or I.IsMouseReleased(c,I.MouseButton_Left)then
  local value=U.clamp(math.floor((g.bottom-my)/math.max(1,g.height)*127+.5),1,127)
  local operation,delta='velocity',g.mouse_y and math.floor((g.mouse_y-my)/math.max(1,g.height)*127+.5)or 0
  if g.swipe then
   local ax,ay=mods.shift and g.x or g.last_x,mods.shift and g.y or g.last_y
   for _,n in ipairs(state.transaction.items)do
    local x=v:x_from_qn(n.s)
    if x>=math.min(ax,mx)-3 and x<=math.max(ax,mx)+3 then
     local t=math.abs(mx-ax)<1 and 1 or U.clamp((x-ax)/(mx-ax),0,1)
     g.values[n.key]=U.clamp(math.floor((g.bottom-(ay+(my-ay)*t))/math.max(1,g.height)*127+.5),1,127)
    end
   end
   operation,delta='velocity_values',g.values;g.last_x,g.last_y=mx,my
  end
  local ok,notice=Model.preview(app,operation,delta,0);state.notice=notice
  if not ok and not state.transaction then app.source_velocity=nil;return end
 end
 if I.IsMouseReleased(c,I.MouseButton_Left)then
  local ok,notice=Model.commit(app,'ReaRoll: edit note velocities');state.notice=notice;app.source_velocity=nil
  if g.before then state.selection={};for _,n in ipairs(state.notes)do if g.before[tostring(n.source.take)..':'..n.index]then state.selection[n.key]=true end end;Model.sync(app)end
 end
end
function M.bounds(app)
 local first,last=app.item_start_qn,app.item_end_qn
 for _,src in ipairs(app.multi_notes.sources or {})do first=math.min(first,src.start_qn);last=math.max(last,src.end_qn)end
 return first,last
end
-- All note coordinates handed to the original canvas are in its current take's
-- PPQ. The owner/key is retained; source-local indices never address that take.
function M.notes(app)
 local state=app.multi_notes;local out={};local children={}
 if app.scoped_phrase_preview then for _,child in ipairs(app.scoped_phrase_preview.children)do children[child.take]=child end end
 if app.source_draw then children[app.source_draw.child.take]=app.source_draw.child end
 for _,src in ipairs(state.sources or {})do
  local entry=state.transaction and state.transaction.by_take[src.take]
  local child=children[src.take]
  local raw=child and {notes=child.cache:get(true)}or entry and require('src.note_events').read(src.take)
  local source_notes={}
  if raw then
   for _,n in ipairs(raw.notes)do
    local q=reaper.MIDI_GetProjQNFromPPQPos(src.take,n.s);local e=reaper.MIDI_GetProjQNFromPPQPos(src.take,n.e)
    local key=tostring(src.take)..':'..n.s..':'..n.pitch..':'..n.chan..':'..n.vel..':'..n.index
    if entry then for _,old in ipairs(state.notes)do if old.source.take==src.take and math.abs(q-old.s)<1e-7 and math.abs(e-old.e)<1e-7 and old.pitch==n.pitch and old.chan==n.chan and old.vel==n.vel then key=old.key;break end end end
    local selected=false
    if entry then for _,w in ipairs(entry.wanted or {})do if math.abs(q-w.s)<1e-7 and n.pitch==w.pitch and n.chan==w.chan and n.vel==w.vel then selected=true;break end end
    elseif child then for _,cn in ipairs(child.cache:get(true))do if child.selection.ids[cn.id]and cn.index==n.index then selected=true;break end end end
    source_notes[#source_notes+1]={key=key,source=src,index=n.index,s=q,e=e,pitch=n.pitch,chan=n.chan,vel=n.vel,muted=n.muted,selected=selected}
   end
  else for _,n in ipairs(state.notes)do if n.source.take==src.take then source_notes[#source_notes+1]=n end end end
  for _,n in ipairs(source_notes)do if n.e>=src.start_qn and n.s<=src.end_qn then
   local copy={};for k,value in pairs(n)do copy[k]=value end
   copy.s=reaper.MIDI_GetPPQPosFromProjQN(app.take,n.s);copy.e=reaper.MIDI_GetPPQPosFromProjQN(app.take,n.e)
   copy.id=n.key;copy.owner=n;copy.source_selected=n.selected
   out[#out+1]=copy
  end end
 end
 return out
end
function M.focus(app,take)
 if take==app.take or not require('src.take').valid(take)then return end
 -- Changing the drawing destination must neither deselect arrange items nor fit
 -- the view. It only rebinds the existing canvas/controller caches.
 local Take=require 'src.take'
 app.take=take;app.cache:set_take(take);app.cc_cache:set_take(take)
 app.item_start_qn=Take.item_start_qn(take);app.item_end_qn=Take.item_end_qn(take);app.take_name=Take.name(take)
 app.note_names={};app.key_map_selection={};app.key_map_track=Take.track(take)
 app.key_colors=require('src.key_map').load_track(app.key_map_track)
 app.lane_ranges={};app.lane_time_selection=nil;app.controller_selection_active=false;app.controller_lane=nil
 app.controller_razor=nil;app.controller_razor_areas={};app.controller_razor_drag=nil
 if app.last_take_by_track and app.key_map_track then app.last_take_by_track[tostring(app.key_map_track)]=take end
end
local function child_view(v,take)
 local out=setmetatable({ppq_per_qn=reaper.MIDI_GetPPQPosFromProjQN(take,1)-reaper.MIDI_GetPPQPosFromProjQN(take,0)}, {__index=v})
 function out:x_from_ppq(p)return v:x_from_qn(reaper.MIDI_GetProjQNFromPPQPos(take,p))end
 function out:ppq_from_x(x)return reaper.MIDI_GetPPQPosFromProjQN(take,v:qn_from_x(x))end
 return out
end
function M.cancel_draw(app)
 local draw=app.source_draw;if not draw then return end
 local child=draw.child
 if child.edit.active then
  local ok,raw=false,nil;if require('src.take').valid(child.take)then ok,raw=reaper.MIDI_GetAllEvts(child.take,'')end
  if ok and raw==(child.edit.active.expected_raw or child.edit.active.original_raw)then child.edit:cancel()else child.edit.active=nil end
 end
 child.audition:stop();app.source_draw=nil;app.gesture=nil
 app.multi_notes.selection=draw.before;Model.refresh(app,true)
end
function M.current_source(app)
 for _,src in ipairs(app.multi_notes.sources or {})do if src.take==app.take then return src end end
end
function M.controller_context(app)
 if not app.controller_selection_active then app.controller_point_context=nil;app.multi_controller_point_focus=nil;return end
 local lane=app.controller_lane;local src=M.current_source(app)
 if not lane or not src or src.readonly then app.controller_point_context=nil;return end
 local ch=app.settings.channel or 0;local Points=require 'src.controller_points'
 local key=tostring(src.take)..':'..(lane.id or lane.short or tostring(lane.cc or lane.status or 'pitch'))..':'..ch
 if not app.controller_point_gesture then
  local selected=Points.selection(app,key,src.take);for index in pairs(selected)do selected[index]=nil end
  for _,p in ipairs(Points.points(src.take,lane,ch))do if p.selected then selected[p.index]=true end end
 end
 app.controller_point_context={take=src.take,lane=lane,ch=ch,key=key,name=src.name}
 app.multi_controller_point_focus=true
end
function M.controller_razor(app,v,d,lane,top,height,hovered,mx,my)
 local src=M.current_source(app);if not src or src.readonly then return false end
 app.multi_controller_owners=app.multi_controller_owners or {}
 local child=app.multi_controller_owners[src.take]
 if not child then child=require('src.phrase_scope').child_app(app,src.take);app.multi_controller_owners[src.take]=child end
 child.settings={};for k,value in pairs(app.settings)do child.settings[k]=value end
 if child.item_start_qn~=src.start_qn or child.item_end_qn~=src.end_qn or child.source_rate and(child.source_rate~=src.rate or child.source_offset~=src.offset)then
  child.controller_razor=nil;child.controller_razor_areas={};child.controller_razor_drag=nil
 end
 child.source_rate,child.source_offset=src.rate,src.offset;child.item_start_qn,child.item_end_qn=src.start_qn,src.end_qn
 child.multi_controller_parent=app;child.gesture=app.gesture;child.razor_area=app.razor_area;child.razor_areas=app.razor_areas;child.mixed_razor=app.mixed_razor
 if hovered and app.ImGui.IsMouseClicked(app.ctx,app.ImGui.MouseButton_Left)then app.multi_controller_drag_signature=require('src.multi_controller_razor').signature(app)end
 local used=require('src.ui.controller_razor').draw(child,v,d,lane,top,height,hovered,mx,my)
 app.controller_razor,app.controller_razor_areas,app.controller_razor_drag=child.controller_razor,child.controller_razor_areas,child.controller_razor_drag
 if used then app.razor_focus=child.razor_focus;app.controller_selection_active=child.controller_selection_active;app.controller_lane=child.controller_lane;app.multi_controller_focus=src.take end
 app.controller_razor_notice=child.controller_razor_notice
 if app.ImGui.IsMouseReleased(app.ctx,app.ImGui.MouseButton_Left)then app.multi_controller_drag_signature=nil end
 return used
end
function M.begin_draw(app,v,mx,my,mods,hooks)
 local take=app.multi_creation_take or app.take;local src
 for _,candidate in ipairs(Model.sources(app))do if candidate.take==take then src=candidate;break end end
 if not src or src.readonly then app.multi_notes.notice=src and src.reason or 'Choose an editable drawing item.';return end
 local q=v:qn_from_x(mx);if q<src.start_qn or q>=src.end_qn then return end
 local child=require('src.phrase_scope').child_app(app,take)
 child.gesture=nil;child.property_wheel=nil;child.expression_direct_gesture=nil
 child.selection.ids={};child.viewport=child_view(v,take)
 local before={};for k,value in pairs(app.multi_notes.selection)do before[k]=value end
 hooks.begin(child,take,child.viewport,child.cache:get(true),nil,nil,mx,my,mods,false)
 app.expression_notice=child.expression_notice
 if child.gesture then
  hooks.update(child,take,child.viewport,mx,my,mods)
  app.multi_notes.selection={};Model.sync(app)
  app.source_draw={child=child,source=src,before=before};app.gesture={kind='source_draw'}
 end
end
function M.update_draw(app,v,mx,my,mods,hooks)
 local draw=app.source_draw;if not draw then return false end
 local child,src=draw.child,draw.source;local current
 for _,s in ipairs(Model.sources(app))do if s.take==src.take then current=s;break end end
 local I,c=app.ImGui,app.ctx
 local active=child.edit.active;local ok,raw=false,nil
 if require('src.take').valid(child.take)then ok,raw=reaper.MIDI_GetAllEvts(child.take,'')end
 if active and (not ok or raw~=(active.expected_raw or active.original_raw))then
  child.edit.active=nil;M.cancel_draw(app);app.multi_notes.notice='The source changed externally; its edit was preserved.';return true
 end
 local cancel=not current or current.readonly or current.start_qn~=src.start_qn or current.end_qn~=src.end_qn or current.rate~=src.rate or current.offset~=src.offset or Shortcuts.pressed(app,'cancel',mods)
 if cancel then
  M.cancel_draw(app);return true
 end
 child.viewport=child_view(v,child.take)
 if I.IsMouseDown(c,I.MouseButton_Left)then hooks.update(child,child.take,child.viewport,mx,my,mods)end
 app.expression_notice=child.expression_notice
 if I.IsMouseReleased(c,I.MouseButton_Left)then
  hooks.finish(child,child.cache:get(true));app.gesture=nil;app.source_draw=nil
  local wanted={};for _,n in ipairs(require('src.selection').list(child.selection,child.cache:get(true)))do wanted[#wanted+1]={take=child.take,s=reaper.MIDI_GetProjQNFromPPQPos(child.take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end
  Model.select_wanted(app,wanted);app.cache:invalidate();app.cc_cache:invalidate()
  app.settings.length_qn=child.settings.length_qn;app.settings.velocity=child.settings.velocity
 end
 return true
end
function M.overlays(app,d,v,mx,my)
 local state=app.multi_notes;local I,T=app.ImGui,app.theme
 if state.marquee then local ax,ay,bx,by=Marquee.bounds(app,v,mx,my)
  I.DrawList_AddRectFilled(d,math.min(ax,bx),math.min(ay,by),math.max(ax,bx),math.max(ay,by),T.marquee_fill)
  I.DrawList_AddRect(d,math.min(ax,bx),math.min(ay,by),math.max(ax,bx),math.max(ay,by),T.marquee_edge)
 end
 if state.structure_brush and state.structure_brush.kind=='slice'then local b=state.structure_brush;I.DrawList_AddLine(d,b.x,b.y,mx,my,T.slice_line,1.5)end
end
function M.interact(app,v,hovered,mx,my,mods,projected,edge,hooks)
 local I,c,s=app.ImGui,app.ctx,app.settings;local state=app.multi_notes
 local hit=projected and projected.owner;
 local popup=Tools.any_popup_open(app)
 local unsnap=Mouse.is(s,'unsnap',mods)
 local clone=Mouse.is(s,'clone',mods)and not(mods.ctrl and mods.shift)
 local select_modifier=Mouse.is(s,'select',mods)and not clone
 if M.update_draw(app,v,mx,my,mods,hooks)then return end
 if app.source_draw then return end
  if hovered and not popup then
    if edge then I.SetMouseCursor(c,I.MouseCursor_ResizeEW)end
    if I.IsMouseClicked(c,I.MouseButton_Right)and not app.gesture and not state.transaction and not state.paint and not app.transform_preview then
      if not hit or Mouse.value(s,'right_note')=='Marquee'then Marquee.begin(app,v,mx,my,I.MouseButton_Right,mods.ctrl or mods.shift)
      elseif mods.alt or Mouse.value(s,'right_note')=='Actions'then
        if not state.selection[hit.key]then state.selection={[hit.key]=true};Model.sync(app)end
        I.OpenPopup(c,'##note_context')
      else
        M.erase_begin(app,hit)
      end
    end
    if I.IsMouseClicked(c,I.MouseButton_Left) and not app.transform_preview and not app.gesture and not state.drag then
      app.multi_controller_point_focus=false;app.controller_point_focus_key=nil;app.controller_point_context=nil
      if hooks.stretch and #Model.chosen(app)>1 then
        local first,last=math.huge,-math.huge;for _,n in ipairs(Model.chosen(app))do first=math.min(first,n.s);last=math.max(last,n.e)end
        local ok,notice=Model.begin(app);state.notice=notice
        if ok then state.drag={stretch=true,first=first,last=last,q=v:qn_from_x(mx),anchor=last,pitch=v:pitch_from_y(my)};app.gesture={kind='source_notes'}end
      elseif not hit and Mouse.is(s,'marquee',mods)then Marquee.begin(app,v,mx,my,I.MouseButton_Left,mods.ctrl or mods.shift)
      elseif(s.mode=='slice'or s.mode=='glue')and not select_modifier then
        local _,notice=Model.structure_begin(app,s.mode,mx,my);state.notice=notice
      elseif hit and not hit.source.readonly then
        if I.IsMouseDoubleClicked(c,I.MouseButton_Left)then
          if not state.selection[hit.key]then state.selection={[hit.key]=true};Model.sync(app)end
          if Mouse.value(s,'double_note')=='Erase'then M.edit(app,'delete')else s.inspector_open=true end
          return
        end
        app.expression_focus_id=hit.key;app.multi_creation_take=hit.source.take
        if select_modifier then state.selection[hit.key]=mods.shift or not state.selection[hit.key];Model.sync(app)
        elseif s.mode=='mute'then
          local _,notice=Model.mute_begin(app,hit);state.notice=notice
        else
          if not state.selection[hit.key]then state.selection={[hit.key]=true};Model.sync(app)end
          local ok,notice=Model.begin(app);state.notice=notice;if ok then state.drag={q=v:qn_from_x(mx),pitch=v:pitch_from_y(my),resize=edge,anchor=edge=='right' and hit.e or hit.s,copy=clone and not edge};app.gesture={kind='source_notes'};app.audition:play(hit.pitch,hit.vel,hit.chan)end
        end
      elseif not hit then
        if s.mode=='paint' or s.mode=='draw' or s.mode=='chord' or s.mode=='smart'and Mouse.value(s,'empty')~='Marquee' or I.IsMouseDoubleClicked(c,I.MouseButton_Left)then
          state.marquee=nil;M.begin_draw(app,v,mx,my,mods,hooks)
        else Marquee.begin(app,v,mx,my,I.MouseButton_Left,mods.ctrl or mods.shift)end
      end
    end
  end
  if state.erase_brush then
    local brush=state.erase_brush
    if Shortcuts.pressed(app,'cancel',mods)then Model.cancel(app);app.gesture=nil
    else
      if hovered and hit and not hit.source.readonly and I.IsMouseDown(c,I.MouseButton_Right)and not brush.keys[hit.key]then
        brush.keys[hit.key]=true;local _,notice=Model.preview(app,'erase',brush.keys);state.notice=notice
      end
      if state.erase_brush and I.IsMouseReleased(c,I.MouseButton_Right)then
        local _,notice=Model.commit(app,'ReaRoll: erase notes');state.notice=notice;state.erase_brush=nil;state.selection={};Model.sync(app);app.gesture=nil
      end
    end
  end
  if state.structure_brush then
    local brush=state.structure_brush
    if s.mode~=brush.kind or Shortcuts.pressed(app,'cancel',mods)then Model.cancel(app)
    else
      if I.IsMouseDown(c,I.MouseButton_Left)or I.IsMouseReleased(c,I.MouseButton_Left)then
        local signature=table.concat({mx,my,s.start_qn,s.visible_qn,s.low_pitch,s.row_height,s.fold_offset or 0,unsnap and 1 or 0,s.snap_enabled and 1 or 0,s.grid_qn,v.x,v.y,v.w,v.h},':')
        if signature~=brush.last_update then
          local _,notice
          if brush.kind=='slice'then _,notice=Model.slice_preview(app,slice_line(app,v,brush,mx,my,mods))
          else _,notice=Model.glue_preview(app,glue_line(app,v,brush,mx,my))end
          state.notice=notice
          if state.structure_brush then brush.last_x,brush.last_y=mx,my;brush.last_update=signature end
        end
      end
      if state.structure_brush and I.IsMouseReleased(c,I.MouseButton_Left)then local _,notice=Model.structure_finish(app);state.notice=notice end
    end
  end
  if state.mute_brush then
    if s.mode~='mute'or Shortcuts.pressed(app,'cancel',mods)then Model.cancel(app)
    else
      if hovered and hit and I.IsMouseDown(c,I.MouseButton_Left)then local _,notice=Model.mute_add(app,hit);state.notice=notice end
      if state.mute_brush and I.IsMouseReleased(c,I.MouseButton_Left)then local _,notice=Model.mute_finish(app);state.notice=notice end
    end
  end
  if state.drag then
    local drag=state.drag;local dq=v:qn_from_x(mx)-drag.q;if not unsnap then dq=U.snap_time(s,drag.anchor+dq,drag.anchor)-drag.anchor end
    local dp=v:pitch_from_y(my)-drag.pitch
    if dq~=(drag.dq or 0) or dp~=(drag.dp or 0)then
      local operation=drag.stretch and 'scale_time'or drag.resize=='left'and 'resize_left'or drag.resize and 'resize'or drag.copy and 'copy'or 'move'
      local amount=drag.stretch and math.max(.001,(drag.last+ dq-drag.first)/(drag.last-drag.first))or dq
      local pitches
      if not drag.resize and not drag.stretch then
        local steps=(s.scale_view_only or v.mapped)and v.fold_index and v.fold_index[v:pitch_from_y(my)]and v.fold_index[drag.pitch]
        if steps or s.scale_snap and #state.transaction.items==1 then
          pitches={};for _,n in ipairs(state.transaction.items)do
            local target=steps and v:shift_scale_pitch(n.pitch,v.fold_index[v:pitch_from_y(my)]-v.fold_index[drag.pitch])or U.clamp(n.pitch+dp,0,127)
            if s.scale_snap and #state.transaction.items==1 then target=require('src.harmony_regions').snap(app,n.s+dq,target,dp)end
            pitches[n.key]=target
          end
        end
      end
      local ok,notice=Model.preview(app,operation,amount,drag.stretch and 0 or dp,pitches);state.notice=notice
      if ok then drag.dq,drag.dp,drag.changed=dq,state.transaction.pitch_delta or dp,true end
    end
    if Shortcuts.pressed(app,'cancel',mods)then Model.cancel(app);state.drag=nil;app.gesture=nil;app.audition:stop()
    elseif I.IsMouseReleased(c,I.MouseButton_Left)then if drag.changed then Model.commit(app)else Model.cancel(app)end;state.drag=nil;app.gesture=nil;app.audition:stop()end
  elseif state.marquee then Marquee.update(app,v,mx,my)
  end
end
function M.keys(app)
  local I,c,s=app.ImGui,app.ctx,app.settings;local state=app.multi_notes
  local mods=U.mods(I,c);local popup=Tools.any_popup_open(app)
  local expression_keys=false
  if s.mode~='razor'and not state.marquee and not app.gesture and not app.multi_controller_point_focus and not expression_keys and not popup and not state.paint and not state.mute_brush and not state.structure_brush and not state.drag and not state.marquee and I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows) and not I.IsAnyItemActive(c)then
    local function edit(operation,delta,pitch)
      local ok,notice=Model.preview(app,operation,delta,pitch);state.notice=notice
      if ok then Model.commit(app,'ReaRoll: edit notes across MIDI items')elseif state.transaction then Model.cancel(app)end
    end
    if Shortcuts.pressed(app,'select_all',mods)then for _,n in ipairs(state.notes)do if not n.source.readonly then state.selection[n.key]=true end end;Model.sync(app)
    elseif Shortcuts.pressed(app,'deselect',mods)or Shortcuts.pressed(app,'cancel',mods)then state.selection={};Model.sync(app)
    elseif Shortcuts.pressed(app,'delete',mods)then edit('delete')
    elseif Shortcuts.pressed(app,'copy',mods)then local _,notice=Model.copy(app);state.notice=notice
    elseif Shortcuts.pressed(app,'cut',mods)then local ok,notice=Model.copy(app);state.notice=notice;if ok then edit('delete')end
    elseif Shortcuts.pressed(app,'paste',mods)then local _,notice=Model.paste(app,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()));state.notice=notice
    elseif Shortcuts.pressed(app,'duplicate',mods)then
      local a,b=math.huge,-math.huge;for _,n in ipairs(Model.chosen(app))do a=math.min(a,n.s);b=math.max(b,n.e)end;if a<math.huge then edit('copy',math.max(s.grid_qn,b-a),0)end
    elseif Shortcuts.pressed(app,'pitch_up',mods)then edit('move',0,1)
    elseif Shortcuts.pressed(app,'pitch_down',mods)then edit('move',0,-1)
    elseif Shortcuts.pressed(app,'octave_up',mods)then edit('move',0,12)
    elseif Shortcuts.pressed(app,'octave_down',mods)then edit('move',0,-12)
    elseif Shortcuts.pressed(app,'nudge_left',mods)then edit('move',-s.grid_qn,0)
    elseif Shortcuts.pressed(app,'nudge_right',mods)then edit('move',s.grid_qn,0)
    elseif Shortcuts.pressed(app,'length_shorter',mods)then edit('resize',-s.grid_qn,0)
    elseif Shortcuts.pressed(app,'length_longer',mods)then edit('resize',s.grid_qn,0)
    elseif Shortcuts.pressed(app,'velocity_up',mods)then edit('velocity',10,0)
    elseif Shortcuts.pressed(app,'velocity_down',mods)then edit('velocity',-10,0)
    elseif Shortcuts.pressed(app,'duplicate_octave_up',mods)then edit('copy',0,12)
    elseif Shortcuts.pressed(app,'duplicate_octave_down',mods)then edit('copy',0,-12)
    elseif Shortcuts.pressed(app,'undo',mods)then reaper.Undo_DoUndo2(0);Model.refresh(app,true)
    elseif Shortcuts.pressed(app,'redo',mods)then reaper.Undo_DoRedo2(0);Model.refresh(app,true)
    end
  end
end
return M
