-- @noindex
local E=require 'src.expression'
local G=require 'src.expression_gesture'
local Model=require 'src.note_expression'
local Scope=require 'src.expression_scope'
local Selection=require 'src.selection'
local U=require 'src.util'
local M={}
local Points=require 'src.expression_points'
local PointUI=require 'src.ui.expression_points'
local function semitones(value,range)return(value-8192)/(value>=8192 and 8191 or 8192)*range end
local function pitch_value(delta,range)return math.floor(8192+math.max(-range,math.min(range,delta))/range*(delta>=0 and 8191 or 8192)+.5)end
local function selected(app)return Scope.selected(app)end
local function voice_label(note)
  return U.pitch_name(note.pitch)..' / Ch '..(note.chan+1)..(note.source and' / '..note.source.name or'')
end
local function xppq(v,take,ppq)
  if v.x_from_qn then return v:x_from_qn(reaper.MIDI_GetProjQNFromPPQPos(take,ppq))end
  return v:x_from_ppq(ppq)
end
local function from_x(v,take,x)
  if v.qn_from_x then return reaper.MIDI_GetPPQPosFromProjQN(take,v:qn_from_x(x))end
  return v:ppq_from_x(x)
end
local function draft_for(app,note)
  local take=note.take or app.take;local g=app.expression_direct_gesture
  if g and g.selection_group then
    local preview=require('src.expression_selection').draft(g,take,note.index);if preview then return preview end
  end
  if g and g.draft.take==take and g.draft.note.index==note.index then return g.draft end
  if app.expression_group_open and app.expression_group_draft then
    for _,entry in ipairs(app.expression_group_draft.entries)do if entry.take==take then
      for _,draft in ipairs(entry.batch.drafts)do if draft.note.index==note.index then return draft end end
    end end
  end
  local ok,raw=reaper.MIDI_GetAllEvts(take,'');if not ok then return nil end
  app.expression_direct_cache=app.expression_direct_cache or {}
  local cache=app.expression_direct_cache[take]
  if not cache or cache.raw~=raw or cache.zone~=app.settings.mpe_zone or cache.members~=app.settings.mpe_members then
    cache={raw=raw,zone=app.settings.mpe_zone,members=app.settings.mpe_members,drafts={}};app.expression_direct_cache[take]=cache
  end
  if not cache.drafts[note.index]then
    local draft,notice=Model.begin(Scope.owner(app,take),note);cache.drafts[note.index]={draft=draft,notice=notice}
  end
  return cache.drafts[note.index].draft,cache.drafts[note.index].notice
end
local function eligible(app,note)
  if app.settings.mpe_enabled then return E.member(note.chan,app.settings)end
  local draft=draft_for(app,note);return draft and draft.pitch_only
end
local function bend_range(s)return s.mpe_enabled and(s.mpe_pitch_bend_range or 48)or(s.pitch_bend_range or 2)end
local function coordinates(app,v,draft,kind,top,height,grid)
  local range=bend_range(app.settings)
  local span=math.max(1,draft.expression_end-draft.note.s)
  local function xy(time,value)
    local x=xppq(v,draft.take,draft.note.s+time*span)
    if grid then return x,v:y_from_pitch_unclipped(draft.note.pitch+semitones(value,range))+app.settings.row_height*.5 end
    local f=kind=='pitch'and(.5+semitones(value,range)/(2*(app.expression_view_range or 12)))or value/127
    return x,top+(1-f)*height
  end
  local function inverse(mx,my,mods)
    local ppq=from_x(v,draft.take,mx)
    if app.settings.snap_enabled and not mods.alt then
      local qn=reaper.MIDI_GetProjQNFromPPQPos(draft.take,ppq)
      ppq=reaper.MIDI_GetPPQPosFromProjQN(draft.take,U.snap(qn,app.settings.grid_qn))
    end
    local time=math.max(0,math.min(1,(ppq-draft.note.s)/span));local value
    if grid then
      local delta=(v:y_from_pitch_unclipped(draft.note.pitch)+app.settings.row_height*.5-my)/app.settings.row_height
      if not mods.shift then delta=math.floor(delta+.5)end
      value=pitch_value(delta,range)
    else
      local fraction=math.max(0,math.min(1,1-(my-top)/height))
      value=kind=='pitch'and pitch_value((fraction-.5)*2*(app.expression_view_range or 12),range)or math.floor(fraction*127+.5)
    end
    return time,value
  end
  return xy,inverse
end
local function draw_curve(app,d,v,draft,kind,top,height,grid,active,handles)
  local I=app.ImGui;local points=G.points(draft,kind);local xy=coordinates(app,v,draft,kind,top,height,grid)
  local color=active and app.theme.selected_edge or app.theme.hint
  local first=math.max(draft.note.s,v.x and from_x(v,draft.take,v.x)or draft.note.s);local last=math.min(draft.expression_end,v.x and from_x(v,draft.take,v.x+v.w)or draft.expression_end)
  if last<first then return end
  local span=math.max(1,draft.expression_end-draft.note.s)
  local steps=math.max(1,math.min(512,math.ceil(math.abs(xppq(v,draft.take,last)-xppq(v,draft.take,first))/3)))
  local px,py
  for step=0,steps do
    local t=(first+(last-first)*step/steps-draft.note.s)/span;local value=(kind=='velocity'or kind=='release_velocity')and draft[kind]or G.value(points,t,kind);local x,y=xy(t,value)
    if px then I.DrawList_AddLine(d,px,py,x,y,color,active and 2 or 1)end;px,py=x,y
  end
  if active and handles~=false then for _,p in ipairs(points)do if not p.context then
    local x,y=xy(p.time,p.value);local focus=app.expression_point_focus
    local focused=focus and focus.take==draft.take and focus.index==draft.note.index and focus.kind==kind and math.abs(focus.time-p.time)<1e-9 and focus.value==p.value
    local selected_point=not p.shared and Points.selected(app,draft,p)
    if selected_point then I.DrawList_AddCircleFilled(d,x,y,7,0x10131AFF)end
    I.DrawList_AddCircleFilled(d,x,y,(focused or selected_point)and 6 or p.shared and 2 or 4,(focused or selected_point)and(app.theme.text or 0xFFFFFFFF)or color)
  end end end
end
local function interact(app,v,draft,kind,top,height,grid,hovered,mx,my,mods)
  local I,c=app.ImGui,app.ctx;local g=app.expression_direct_gesture
  local surface=grid and 'grid'or 'lane'
  if g and g.surface~=surface then return false end
  local xy,inverse=coordinates(app,v,draft,kind,top,height,grid)
  if g then
    if g.selection_group then
      local valid,notice=require('src.expression_selection').valid(app,g)
      if not valid then app.expression_direct_gesture=nil;app.expression_notice=notice;app.expression_point_focus=nil;return true end
    end
    if (not app.multi_edit_mode and app.take~=g.draft.take)or g.draft.mpe_enabled~=(app.settings.mpe_enabled==true)or not Selection.has(app.selection,g.note_id) or I.IsKeyPressed(c,I.Key_Escape)then
      app.expression_direct_gesture=nil;return true
    end
    if I.IsMouseDown(c,g.button)then
      local time,value=inverse(mx,my,mods)
      if not grid and mods.shift then
        if not g.axis and math.max(math.abs(mx-g.mx),math.abs(my-g.my))>3 then g.axis=math.abs(mx-g.mx)>=math.abs(my-g.my)and 'time'or 'value'end
        if g.axis=='time'then value=g.value elseif g.axis=='value'then time=g.time end
      else g.axis=nil end
      G.update(g,time,value,(g.my-my)/math.max(40,height)*2)
    else
      local ok,notice=Scope.finish(app,g);app.expression_notice=notice;app.expression_direct_gesture=nil;app.expression_direct_cache=nil
      if ok and g.operation~='delete'then
        local span=math.max(1,g.draft.expression_end-g.draft.note.s)
        local time=(math.floor(g.draft.note.s+g.point.time*span+.5)-g.draft.note.s)/span
        app.expression_point_focus={take=g.draft.take,index=g.draft.note.index,note_id=g.note_id,kind=g.kind,time=time,value=g.point.value,raw=select(2,reaper.MIDI_GetAllEvts(g.draft.take,''))}
      else app.expression_point_focus=nil end
    end
    return true
  end
  if not hovered or app.gesture then return false end
  local points=G.points(draft,kind);local nearest,distance,segment
  for _,p in ipairs(points)do if not p.context then local x,y=xy(p.time,p.value);local delta=(x-mx)^2+(y-my)^2;if delta<=81 and(not distance or delta<distance)then nearest,distance=p,delta end end end
  local raw_time=(from_x(v,draft.take,mx)-draft.note.s)/math.max(1,draft.expression_end-draft.note.s)
  if raw_time<0 or raw_time>1 then return false end
  if mods.alt then for i=1,#points-1 do local p=points[i];if not p.context and raw_time>=p.time and raw_time<points[i+1].time then local _,y=xy(raw_time,G.value(points,raw_time,kind));if math.abs(my-y)<10 then segment=p end end end end
  if grid and not nearest and not segment then local _,y=xy(raw_time,G.value(points,raw_time,kind));if math.abs(my-y)>9 then return false end end
  local count=app.settings.mpe_enabled and #selected(app)or 1
  local scope=count>1 and('All '..count..' selected notes: ')or ''
  I.SetTooltip(c,scope..(grid and 'Click to add, drag to bend. Shift: free pitch. Alt-drag: curve. Right-click point: delete.'or 'Click to add; drag points to edit. Shift: lock axis. Alt-drag: curve. Right-drag: select points. Delete: remove selected points. Escape: cancel.'))
  local left,right=I.IsMouseClicked(c,0),I.IsMouseClicked(c,1)
  if left or right and nearest then
    local time,value=inverse(mx,my,mods)
    local operation=right and 'delete'or segment and 'curve'or 'move'
    local gesture,notice=Scope.begin(app,draft,kind,time,value,operation,segment or nearest)
    app.expression_notice=notice
    if gesture then gesture.surface=surface;gesture.mx=mx;gesture.my=my;gesture.note_id=app.expression_focus_id;gesture.button=right and 1 or 0;app.expression_direct_gesture=gesture end
    return true
  end
  return false
end
local function lane_target(app,v,notes,kind,top,height,mx,my,focused)
  local g=app.expression_direct_gesture
  if g then for _,note in ipairs(notes)do if note.id==g.note_id then return note,g.draft end end;return end
  local best,best_draft,best_score
  for _,note in ipairs(notes)do if eligible(app,note)then
    local draft=draft_for(app,note)
    if draft then
      local time=(from_x(v,draft.take,mx)-draft.note.s)/math.max(1,draft.expression_end-draft.note.s)
      if time>=0 and time<=1 then
        local xy=coordinates(app,v,draft,kind,top,height,false)
        local points=G.points(draft,kind);local _,curve_y=xy(time,G.value(points,time,kind))
        local score=math.abs(curve_y-my)+100
        for _,point in ipairs(points)do if not point.context then local x,y=xy(point.time,point.value);local distance=(x-mx)^2+(y-my)^2;if distance<=81 then score=math.min(score,math.sqrt(distance))end end end
        if focused and note.id==focused.id then score=score-.01 end
        if not best_score or score<best_score then best,best_draft,best_score=note,draft,score end
      end
    end
  end end
  return best,best_draft
end
function M.keys(app)
  local I,c=app.ImGui,app.ctx
  if require('src.ui.lane_tools').any_popup_open(app)then return false end
  if app.expression_point_marquee and not Points.current(app)then app.expression_point_marquee=nil end
  if app.expression_direct_gesture or app.expression_point_marquee then return true end
  if PointUI.keys(app)then return true end
  local focus=app.expression_point_focus
  if not focus then return false end
  if not(app.expression_editor_open or app.settings.mpe_pitch_edit)then app.expression_point_focus=nil;return false end
  if (not app.multi_edit_mode and focus.take~=app.take)or not Selection.has(app.selection,focus.note_id)or not require('src.note_events').available(focus.take)or focus.raw~=select(2,reaper.MIDI_GetAllEvts(focus.take,''))then app.expression_point_focus=nil;return false end
  if I.IsAnyItemActive(c)or not I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows)then return false end
  if I.IsKeyPressed(c,I.Key_Escape)then app.expression_point_focus=nil;return true end
  if not require('src.shortcuts').pressed(app,'delete',U.mods(I,c))then return false end
  for _,note in ipairs(selected(app))do if note.id==focus.note_id then
    local draft=draft_for(app,note)
    if draft then for _,point in ipairs(draft.points)do if point.kind==focus.kind and math.abs(point.time-focus.time)<1e-9 and point.value==focus.value then
      local gesture,notice=Scope.begin(app,draft,focus.kind,point.time,point.value,'delete',point)
      if gesture then local _,message=Scope.finish(app,gesture);notice=message end
      app.expression_notice=notice;app.expression_point_focus=nil;app.expression_direct_cache=nil;return true
    end end end
  end end
  app.expression_point_focus=nil;return true
end
function M.grid_visible(app)
  return app.settings.mpe_pitch_edit==true or app.expression_group_open==true and app.expression_group_draft~=nil
    or app.expression_editor_open==true and app.expression_dimension=='pitch'and app.settings.note_expression_overlay==true
end
function M.grid_draw(app,d,v)
  Points.current(app)
  if not M.grid_visible(app)or v.fold then return end
  local notes=selected(app)
  for _,note in ipairs(notes)do if eligible(app,note)then local draft=draft_for(app,note);if draft then draw_curve(app,d,v,draft,'pitch',v.y,v.h,true,true,app.settings.mpe_pitch_edit==true)end end end
end
function M.grid_interact(app,v,hovered,mx,my,mods)
  if app.expression_group_open then return false end
  if not app.settings.mpe_pitch_edit or v.fold then
    if app.expression_direct_gesture and app.expression_direct_gesture.surface=='grid'then app.expression_direct_gesture=nil end
    return false
  end
  if app.expression_direct_gesture and app.expression_direct_gesture.surface=='grid'then
    return interact(app,v,app.expression_direct_gesture.draft,'pitch',v.y,v.h,true,hovered,mx,my,mods)
  end
  -- Note edges retain their ordinary duration gesture in pitch-edit mode.
  -- Only an already active expression gesture owns expression endpoints.
  if app.gesture then return false end
  if hovered then for _,note in ipairs(Scope.all(app))do
    local take=note.take or app.take;local left,right=xppq(v,take,note.s),xppq(v,take,note.e)
    local y=v:y_from_pitch_unclipped(note.pitch);local zone=math.min(12,math.max(4,(right-left)*.3))
    if my>=y and my<=y+app.settings.row_height and((left>=v.x and math.abs(mx-left)<=zone)or(right<=v.x+v.w and math.abs(mx-right)<=zone))then return false end
  end end
  local notes=selected(app)
  local previous_focus=app.expression_focus_id
  table.sort(notes,function(a,b)if(a.id==previous_focus)~=(b.id==previous_focus)then return a.id==previous_focus end;return a.index<b.index end)
  for _,note in ipairs(notes)do if eligible(app,note)then
    local draft=draft_for(app,note)
    if draft then app.expression_focus_id=note.id;if interact(app,v,draft,'pitch',v.y,v.h,true,hovered,mx,my,mods)then return true end end
  end end
  app.expression_focus_id=previous_focus
  -- In this explicit expression mode, selecting a voice must not depend on the
  -- ordinary drawing-channel filter. It never reassigns that voice's channel.
  if hovered and app.ImGui.IsMouseClicked(app.ctx,0)and not app.gesture then
    for _,note in ipairs(Scope.all(app))do if eligible(app,note)and mx>=xppq(v,note.take or app.take,note.s)and mx<=xppq(v,note.take or app.take,note.e)and math.abs(my-(v:y_from_pitch_unclipped(note.pitch)+app.settings.row_height*.5))<=app.settings.row_height*.5 then
      Scope.select(app,note);app.expression_focus_id=note.id;return true
    end end
  end
  return false
end
function M.draw(app)
  if not app.expression_editor_open then return end
  local I,c,s=app.ImGui,app.ctx,app.settings
  local selected_notes=selected(app)
  if not Points.current(app)then app.expression_point_marquee=nil end
  require('src.ui.expression_group').sync_selection(app,#selected_notes)
  local z=math.max(.8,math.min(1.5,s.ui_scale or 1))
  local left=I.GetCursorScreenPos(c);local right=left+I.GetContentRegionAvail(c);local first=true
  local function next_item(width)
    if not first then local last=I.GetItemRectMax(c);if last+6*z+width<=right then I.SameLine(c)end end
    first=false
  end
  local Icons=require 'src.ui.icons'
  local options={{'Pitch','pitch','pitch_curve'},{'Pressure','pressure','pressure'},{'Timbre','timbre','timbre'}}
  for _,entry in ipairs(options)do
    next_item(28*z);I.BeginDisabled(c,not s.mpe_enabled and entry[2]~='pitch')
    if Icons.button(app,'expression_'..entry[2],entry[3],entry[1],app.expression_dimension==entry[2])then app.expression_dimension=entry[2];app.expression_direct_gesture=nil end
    I.EndDisabled(c)
  end
  if app.expression_dimension=='pitch'then
    next_item(28*z)
    if Icons.button(app,'expression_pitch_overlay','pitch_overlay','Edit pitch curves directly on notes in the piano roll',s.mpe_pitch_edit==true)then s.mpe_pitch_edit=not s.mpe_pitch_edit;app.expression_direct_gesture=nil;if s.mpe_pitch_edit then s.note_expression_overlay=true end end
  end
  require('src.ui.mpe_controls').draw(app,next_item)
  local notes=selected(app);local focused
  for _,note in ipairs(notes)do if eligible(app,note)then if not focused or note.id==app.expression_focus_id then focused=note end end end
  if focused and #notes>1 and s.mpe_enabled and not app.expression_group_open then
    next_item(68*z);I.TextDisabled(c,#notes..' notes')
    if I.IsItemHovered(c)then I.SetTooltip(c,'Curve edits affect every selected note, including other items. Time follows each note length; existing curve differences are preserved. Select one note to edit it alone.')end
  elseif focused and #notes>1 and not app.expression_group_open then
    next_item(126*z);I.SetNextItemWidth(c,126*z)
    if I.BeginCombo(c,'##expression_voice',voice_label(focused))then for _,note in ipairs(notes)do if eligible(app,note)and I.Selectable(c,voice_label(note)..'##'..note.id,note.id==focused.id)then app.expression_focus_id=note.id;focused=note end end;I.EndCombo(c)end
    local ids={};for _,note in ipairs(notes)do if eligible(app,note)then ids[#ids+1]=note.id end end
    local id,changed=require('src.ui.controls').cycle(app,ids,focused.id,app.gesture~=nil or app.edit.active~=nil or app.expression_direct_gesture~=nil)
    if changed then app.expression_focus_id=id;for _,note in ipairs(notes)do if note.id==id then focused=note;break end end end
    if I.IsItemHovered(c)then I.SetTooltip(c,'Wheel: choose the active note. Choose the note whose points you want to edit. You can also click a curve directly; the note selection stays intact.')end
  end
  next_item(28*z);I.BeginDisabled(c,not s.mpe_enabled or #selected_notes<2)
  local tip=app.expression_group_open and 'Discard group preview and return to editing curve points'or 'Adjust selected notes: scale or offset their existing expression'
  if Icons.button(app,'expression_group','expression_group',tip,app.expression_group_open)then
    if app.expression_group_open then require('src.ui.expression_group').close(app)
    else app.expression_group_open=true;app.expression_group_draft=nil end
    app.expression_direct_gesture=nil
  end
  I.EndDisabled(c)
  local group_drawn=require('src.ui.expression_group').draw(app,next_item)
  next_item(28*z)
  if Icons.button(app,'expression_close','close','Close the expression editor')then require('src.midi_mode').view(app,false);return end
  if group_drawn and not app.expression_group_draft then return end
  local function prepare_notes()
    if s.mpe_enabled and #notes>0 then
      if I.Button(c,'Make selected notes MPE')then local ok,notice=Scope.assign(app);app.expression_notice=notice or(ok and 'Selected notes are ready for Pitch, Pressure and Timbre editing.'or nil)end
      if I.IsItemHovered(c)then I.SetTooltip(c,'Assign independent member channels to these notes. Recorded expression keeps its channels. One Undo restores the original notes.')end
    end
    if app.expression_notice then I.TextWrapped(c,app.expression_notice)end
  end
  if not focused then
    I.TextWrapped(c,s.mpe_enabled and(#notes>0 and 'Give these notes independent voices, then draw their expression below.'or 'Select a note to edit its Pitch, Pressure or Timbre. New notes drawn in MPE mode are ready automatically.')or 'Select a split slide curve to edit its pitch, or choose MPE in the toolbar for per-note expression.')
    prepare_notes();return
  end
  app.expression_focus_id=focused.id
  local draft,notice=draft_for(app,focused)
  if not draft then I.TextWrapped(c,notice or 'This note cannot be edited.');prepare_notes();return end
  local kind=app.expression_dimension or 'pressure'
  if kind=='pitch'then
    s.note_expression_overlay=true;app.expression_view_range=math.max(1,math.min(bend_range(s),app.expression_view_range or 12))
  end
  local _,top=I.GetCursorScreenPos(c);local width,available=I.GetContentRegionAvail(c);local v=app.viewport
  local height=math.max(35,available-3);local x=v.x;local right=math.min(x+v.w,select(1,I.GetCursorScreenPos(c))+width)
  if right<=x then return end
  local d=I.GetWindowDrawList(c)
  I.SetCursorScreenPos(c,x,top);I.InvisibleButton(c,'##expression_timeline',right-x,height)
  local hovered=I.IsItemHovered(c);local mx,my=I.GetMousePos(c)
  I.DrawList_AddRectFilled(d,x,top,right,top+height,app.theme.panel2,3)
  I.DrawList_PushClipRect(d,x,top,right,top+height,true)
  local grid_color=(app.theme.hint&0xFFFFFF00)|32
  for i=0,4 do local y=top+height*i/4;I.DrawList_AddLine(d,x,y,right,y,grid_color,1)end
  local step=math.max(s.grid_qn or .25,1/64)
  while step*(v.px_per_qn or 100)<16 do step=step*2 end
  local first=math.ceil(v:qn_from_x(x)/step)*step
  for i=0,512 do local q=first+i*step;local px=v:x_from_qn(q);if px>right then break end;I.DrawList_AddLine(d,px,top,px,top+height,grid_color,1)end
  local first_selected,last_selected=right,x
  for _,note in ipairs(notes)do if eligible(app,note)then local other=draft_for(app,note);if other then
    local left=math.max(x,xppq(v,other.take,other.note.s));local ending=math.min(right,xppq(v,other.take,other.expression_end))
    if ending>left then
      first_selected=math.min(first_selected,left);last_selected=math.max(last_selected,ending)
      I.DrawList_AddRect(d,left,top,ending,top+height,app.theme.hint,2)
    end
  end end end
  if last_selected>first_selected then I.DrawList_AddRect(d,first_selected,top,last_selected,top+height,app.theme.selected_edge,2)end
  local left_note=math.max(x,xppq(v,draft.take,draft.note.s));local right_note=math.min(right,xppq(v,draft.take,draft.expression_end))
  if right_note>left_note then
    I.DrawList_AddRect(d,left_note,top,right_note,top+height,app.theme.selected_edge,2)
    local label=app.expression_group_open and(kind:gsub('_',' ')..' | Preview: '..#notes..' notes')or(s.mpe_enabled and #notes>1 and(kind:sub(1,1):upper()..kind:sub(2)..' | '..#notes..' selected notes'))or(U.pitch_name(focused.pitch)..'  Ch '..(focused.chan+1))
    I.DrawList_AddText(d,left_note+4,top+3,app.theme.selected_edge,label)
    if draft.expression_end>draft.note.e then local release=xppq(v,draft.take,draft.note.e);I.DrawList_AddLine(d,release,top,release,top+height,app.theme.hint,1);I.DrawList_AddText(d,release+3,top+3,app.theme.hint,'Release')end
  end
  for _,note in ipairs(notes)do if eligible(app,note)then local other=draft_for(app,note);if other then draw_curve(app,d,v,other,kind,top,height,false,not app.expression_group_open)end end end
  I.DrawList_PopClipRect(d)
  local label_x=x-48
  I.DrawList_AddText(d,label_x,top,app.theme.hint,kind=='pitch'and '+'..(app.expression_view_range or 12)..' st'or '100%')
  I.DrawList_AddText(d,label_x,top+height*.5-6,app.theme.hint,kind=='pitch'and '0 st'or kind=='timbre'and '0%'or '50%')
  I.DrawList_AddText(d,label_x,top+height-12,app.theme.hint,kind=='pitch'and '-'..(app.expression_view_range or 12)..' st'or kind=='timbre'and '-100%'or '0%')
  if not app.expression_group_open and not PointUI.interact(app,v,notes,kind,top,height,hovered,mx,my,{draft_for=draft_for,eligible=eligible,coordinates=coordinates})then
    local target,target_draft=lane_target(app,v,notes,kind,top,height,mx,my,focused)
    if target and(hovered or app.expression_direct_gesture)then
      if I.IsMouseClicked(c,0)or I.IsMouseClicked(c,1)then app.expression_focus_id=target.id end
      interact(app,v,target_draft,kind,top,height,false,hovered,mx,my,U.mods(I,c))
    end
  end
  if app.expression_notice then I.TextWrapped(c,app.expression_notice)end
end
return M
