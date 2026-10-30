-- @noindex
local Notes=require 'src.note_events'
local Links=require 'src.slide_links'
local Selection=require 'src.selection'
local U=require 'src.util'
local M={}
function M.editable(app)local mode=app.settings.mode;return not app.settings.mpe_pitch_edit and(mode=='slide'or mode=='smart'or mode=='select')end
local function selection_key(app)local keys={};for id,value in pairs(app.selection.ids or {})do if value then keys[#keys+1]=id end end;table.sort(keys);return table.concat(keys,'|')end
local function refresh(app)
  local ok,hash=reaper.MIDI_GetHash(app.take,false,'');local cache=app.slide_target_cache
  if cache and cache.take==app.take and ok and cache.hash==hash then return cache end
  local stream=Notes.read(app.take);cache={take=app.take,hash=ok and hash,raw=stream and stream.original_raw,targets={}}
  if stream then for _,note in ipairs(stream.notes)do if Links.has(note)then
    local records=Links.records(stream,note)
    local source_s,source_e=note.s,note.e;if Links.structural(note)then source_s,source_e=Links.domain(note)end
    for _,r in ipairs(records)do if r.valid then
      cache.targets[#cache.targets+1]={source_index=note.index,slide_id=r.id,source_s=source_s,source_e=source_e,first=math.floor(note.s+r.first*(note.e-note.s)+.5),last=math.floor(note.s+r.last*(note.e-note.s)+.5),target=note.pitch+r.delta,linear=r.linear,curve=r.curve or 0,range=r.range,source_pitch=note.pitch,channel=note.chan,raw=stream.original_raw,take=app.take}
    end end
  end end end
  app.slide_target_cache=cache;return cache
end
local function same(a,b)return a and b and a.take==b.take and a.source_index==b.source_index and a.slide_id==b.slide_id end
local function target_key(h)return tostring(h.take)..':'..h.source_index..':'..h.slide_id end
local function group(app)
  local out={};for _,h in ipairs(refresh(app).targets)do if app.slide_group and app.slide_group[target_key(h)]then out[#out+1]=h end end
  return out
end
function M.selected(app)return group(app)end
function M.fold_notes(app,notes)
  if not app.settings.fold_enabled or app.settings.scale_view_only then return notes end
  local out={table.unpack(notes)}
  for _,h in ipairs(refresh(app).targets)do out[#out+1]={pitch=h.target}end
  return out
end
function M.reselect(app)app.slide_selection=group(app)[1]end
function M.select_new(app,before_raw)
  local old=Notes.read(app.take,before_raw);local known={}
  for _,note in ipairs(old.notes)do for _,record in ipairs(Links.records(old,note))do known[note.index..':'..record.id]=true end end
  app.slide_target_cache=nil;app.slide_group={};app.slide_selection=nil
  for _,h in ipairs(refresh(app).targets)do if not known[h.source_index..':'..h.slide_id]then app.slide_group[target_key(h)]=true;app.slide_selection=app.slide_selection or h end end
end

function M.draw(app,d,v)
  app.slide_hits={}

  if app.instrument_map and app.instrument_map.enabled then return end
  local selected={};for _,n in ipairs(app.cache:get(false))do if Selection.has(app.selection,n.id)then selected[n.index]=true end end
  local range=app.settings.mpe_enabled and(app.settings.mpe_pitch_bend_range or 48)or(app.settings.pitch_bend_range or 2)
  for _,h in ipairs(refresh(app).targets)do if (app.settings.edit_all_channels~=false or h.channel==app.settings.channel)then
    local y=v:y_from_pitch(h.target)
    if y then
      local x1,x2=v:x_from_ppq(h.first),v:x_from_ppq(h.last)
      if x2>=v.x and x1<=v.x+v.w then
        local chosen=same(app.slide_selection,h)or app.slide_group and app.slide_group[target_key(h)];local T,I=app.theme,app.ImGui
        I.DrawList_AddRectFilled(d,x1,y,math.max(x1+3,x2),y+app.settings.row_height,T.marquee_fill,3)
        I.DrawList_AddRect(d,x1,y,math.max(x1+3,x2),y+app.settings.row_height,T.selected_edge,3,0,chosen and 2 or 1)
        local cy=y+app.settings.row_height*.5
        I.DrawList_AddCircleFilled(d,x1,cy,chosen and 4 or 3,T.selected_edge);I.DrawList_AddCircleFilled(d,x2,cy,chosen and 4 or 3,T.selected_edge)
        if x2-x1>65 then I.DrawList_AddText(d,x1+6,y,T.text,U.pitch_name(h.target)..(h.range~=range and ' slide !'or ' slide'))end
        app.slide_hits[#app.slide_hits+1]={target=h,x1=x1,x2=x2,y=y,cy=cy}
      end
    end
  end end
end
local function apply(app,h,change)
  if app.slide_group_action then local handled,ok=app.slide_group_action(h,change);if handled then return ok end end
  local gesture={source_index=h.source_index,slide_id=h.slide_id,expected_raw=h.raw,take=h.take}
  local targets=group(app)
  if #targets>1 then
    gesture.targets=targets
    change={time_delta=(change.first or h.first)-h.first,length_delta=((change.last or h.last)-h.last)-((change.first or h.first)-h.first),pitch_delta=(change.target or h.target)-h.target,delete=change.delete,linear=change.linear,curve=change.curve}
  end
  local ok,notice=require('src.slide_draw').preview_edit(app,gesture,change);app.expression_notice=notice
  if ok then require('src.slide_draw').finish(app,gesture);app.slide_target_cache=nil;if not change.delete then for _,current in ipairs(refresh(app).targets)do if same(h,current)then app.slide_selection=current;break end end end end
  return ok
end
function M.interact(app,v,hovered,mx,my,mods)
  local I,c=app.ImGui,app.ctx;local consumed=false
  if not M.editable(app)then app.slide_selection=nil;app.slide_group=nil;return false end
  if hovered and not app.gesture then
    local best,distance
    for _,hit in ipairs(app.slide_hits or {})do
      if mx>=hit.x1-6 and mx<=hit.x2+6 and math.abs(my-hit.cy)<=math.max(7,app.settings.row_height*.5)then
        local d=math.abs(my-hit.cy);if not distance or d<distance then best,distance=hit,d end
      end
    end
    if best then
      I.SetTooltip(c,'Slide target / channel '..(best.target.channel+1)..'\nCtrl-click: select targets / Drag: move selection / edges: change duration\nAlt-drag body: curve / right-click: shape and delete')
      local range=app.settings.mpe_enabled and(app.settings.mpe_pitch_bend_range or 48)or(app.settings.pitch_bend_range or 2)
      if best.target.range~=range then
        local notice='This slide uses +/- '..best.target.range..' semitones; current setup uses +/- '..range..'. Match Setup and your instrument to the saved slide range before editing.'
        I.SetTooltip(c,notice)
        if I.IsMouseClicked(c,I.MouseButton_Left)or I.IsMouseClicked(c,I.MouseButton_Right)then app.expression_notice=notice;app.expression_editor_open=true;app.expression_setup_visible=true;return true end
        return false
      end
      local left,right=math.abs(mx-best.x1)<=6,math.abs(mx-best.x2)<=6
      if left or right then I.SetMouseCursor(c,I.MouseCursor_ResizeEW)end
      if I.IsMouseClicked(c,I.MouseButton_Left)then
        local h=best.target;app.slide_group=app.slide_group or {}
        if mods.ctrl then
          app.slide_group[target_key(h)]=not app.slide_group[target_key(h)];app.slide_selection=app.slide_group[target_key(h)]and h or group(app)[1];consumed=true
        else
          if not app.slide_group[target_key(h)]then app.slide_group={[target_key(h)]=true}end
          app.slide_selection=h;app.slide_focus=selection_key(app)
        app.gesture={kind='slide_edit',source_index=h.source_index,slide_id=h.slide_id,source_s=h.source_s,source_e=h.source_e,first=h.first,last=h.last,target=h.target,curve=h.curve,linear=h.linear,anchor_qn=v:qn_from_x(mx),anchor_pitch=v:pitch_from_y(my),mx=mx,my=my,edge=right and 'right'or left and 'left'or nil,expected_raw=h.raw,curve_drag=mods.alt and not(left or right)}
        local targets=group(app);if #targets>1 then app.gesture.targets=targets end
        consumed=true
        end
      elseif I.IsMouseClicked(c,I.MouseButton_Right)then if not(app.slide_group and app.slide_group[target_key(best.target)])then app.slide_group={[target_key(best.target)]=true}end;app.slide_selection=best.target;app.slide_focus=selection_key(app);app.slide_context=best.target;app.slide_shape=best.target.curve;app.slide_shape_linear=best.target.linear;I.OpenPopup(c,'##slide_target');consumed=true end
    elseif I.IsMouseClicked(c,I.MouseButton_Left)then app.slide_selection=nil;app.slide_group=nil end
  end
  if I.BeginPopup(c,'##slide_target')then
    local h=app.slide_context
    if h then
      I.Text(c,U.pitch_name(h.target)..' / channel '..(h.channel+1))
      local hit;hit,app.slide_shape_linear=I.Checkbox(c,'Linear',app.slide_shape_linear)
      hit,app.slide_shape=I.SliderDouble(c,'Curve',app.slide_shape or 0,-1,1,'%.2f')
      if I.Button(c,'Apply shape')then if apply(app,h,{linear=app.slide_shape_linear,curve=app.slide_shape})then app.slide_selection=nil;I.CloseCurrentPopup(c)end end
      I.SameLine(c);if I.Button(c,'Cancel')then I.CloseCurrentPopup(c)end
      if I.Button(c,'Delete slide target')then if apply(app,h,{delete=true})then app.slide_selection=nil;I.CloseCurrentPopup(c)end end
    end
    I.EndPopup(c)
  end
  return consumed
end
function M.update(app,g,v,mx,my,mods)
  if not g.moved and math.abs(mx-g.mx)<3 and math.abs(my-g.my)<3 then return end;g.moved=true
  local change={}
  if g.curve_drag then change.curve=math.max(-1,math.min(1,g.curve+(g.my-my)/100))else
    local raw=v:qn_from_x(mx)-g.anchor_qn;local mode=mods.alt and 'off'or U.snap_mode(app.settings)
    local origin=reaper.MIDI_GetProjQNFromPPQPos(app.take,g.edge=='right'and g.last or g.first)
    local delta=mode=='relative'and U.snap(raw,app.settings.grid_qn)or mode=='absolute'and(U.snap(origin+raw,app.settings.grid_qn)-origin)or raw
    local ppq=delta*v.ppq_per_qn
    if g.edge=='left'then change.first=math.max(g.source_s,math.min(g.source_e-2,g.last-2,math.floor(g.first+ppq+.5)))
    elseif g.edge=='right'then change.last=math.max(g.first+2,math.min(reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn),math.floor(g.last+ppq+.5)))
    else
      ppq=math.max(g.source_s-g.first,math.min(g.source_e-2-g.first,reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)-g.last,math.floor(ppq+.5)));change.first=g.first+ppq;change.last=g.last+ppq
      change.target=math.max(0,math.min(127,g.target+v:pitch_from_y(my)-g.anchor_pitch))
      if app.settings.scale_snap then change.target=require('src.harmony_regions').snap(app,reaper.MIDI_GetProjQNFromPPQPos(app.take,change.first),change.target)end
    end
  end
  if g.targets then
    local dt=(change.first or g.first)-g.first;local dl=((change.last or g.last)-g.last)-dt
    change={time_delta=dt,length_delta=dl,pitch_delta=(change.target or g.target)-g.target,curve=change.curve}
  end
  local signature=table.concat({change.first or change.time_delta or '',change.last or change.length_delta or '',change.target or change.pitch_delta or '',change.curve or ''},':')
  if signature==g.change_signature then return end;g.change_signature=signature
  local ok,notice=require('src.slide_draw').preview_edit(app,g,change);app.expression_notice=notice
  if ok then app.slide_target_cache=nil end
end
function M.finish(app,g)
  local ok=require('src.slide_draw').finish(app,g)
  if ok then app.slide_target_cache=nil;for _,h in ipairs(refresh(app).targets)do if h.source_index==g.source_index and h.slide_id==g.slide_id then app.slide_selection=h;break end end end
  return ok
end
local function paste(app,source,first)
  local clip=app.slide_clipboard;if not clip then return false end
  local range=app.settings.mpe_enabled and(app.settings.mpe_pitch_bend_range or 48)or(app.settings.pitch_bend_range or 2)
  if range~=clip.range then app.expression_notice='Match the copied slide bend range before pasting its target.';return false end
  local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,first)
  local last=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+clip.duration)+.5)
  local settings={};for k,v in pairs(app.settings)do settings[k]=v end;settings.slide_linear=clip.linear;settings.slide_curve=clip.curve;settings.slide_replace=false
  local g={source_index=source.index,first=first,slide_settings=settings}
  local ok,notice=require('src.slide_draw').preview(app,g,last,source.pitch+clip.delta);app.expression_notice=notice
  if ok then require('src.slide_draw').finish(app,g);app.slide_target_cache=nil;app.slide_selection=nil end
  return ok
end
local function paste_clip(app,clip,anchor)
  local ok,notice=require('src.slide_draw').paste_targets(app,clip,anchor);app.expression_notice=notice
  if ok then
    app.slide_target_cache=nil;app.slide_group={};app.slide_selection=nil
    for _,h in ipairs(refresh(app).targets)do for _,target in ipairs(clip.targets)do
      local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,h.first)
      if math.abs(q-anchor-target.time)<1e-7 and h.channel==target.channel and h.target==target.pitch then
        app.slide_group[target_key(h)]=true;app.slide_selection=app.slide_selection or h
      end
    end end
  end
  return ok
end
function M.keys(app)
  local h=app.slide_selection;local I,c=app.ImGui,app.ctx

  if not M.editable(app)or app.controller_selection_active or app.gesture or I.IsAnyItemActive(c)or not I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows)then return false end
  local pressed=require('src.shortcuts').pressed;local mods=U.mods(I,c)
  if app.slide_clipboard and(app.settings.mode=='slide'or h)and pressed(app,'paste',mods)then
    if app.slide_clipboard.version==1 then
      paste_clip(app,app.slide_clipboard,U.snap_time(app.settings,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())));return true
    end
    local selected=Selection.list(app.selection,app.cache:get(false))
    if #selected~=1 then app.expression_notice='Select one source note before pasting a slide target.';return true end
    local q=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition());q=U.snap_time(app.settings,q)
    paste(app,selected[1],math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q)+.5));return true
  end
  if not h then return false end
  local range=app.settings.mpe_enabled and(app.settings.mpe_pitch_bend_range or 48)or(app.settings.pitch_bend_range or 2)
  if h.range~=range then app.slide_selection=nil;app.slide_group=nil;app.expression_notice='Slide range differs from instrument setup. Match the saved range before editing.';return false end
  local current=refresh(app)
  if h.take~=app.take or current.raw~=h.raw then
    app.slide_selection=nil
    if pressed(app,'delete',mods)or pressed(app,'cut',mods)then app.expression_notice='MIDI changed since this slide was selected. Select the target again.';return true end
    return false
  end
  local time,pitch,length=0,0,0
  if pressed(app,'nudge_left',mods)then time=-app.settings.grid_qn elseif pressed(app,'nudge_right',mods)then time=app.settings.grid_qn
  elseif pressed(app,'pitch_up',mods)then pitch=1 elseif pressed(app,'pitch_down',mods)then pitch=-1
  elseif pressed(app,'octave_up',mods)then pitch=12 elseif pressed(app,'octave_down',mods)then pitch=-12
  elseif pressed(app,'length_shorter',mods)then length=-app.settings.grid_qn elseif pressed(app,'length_longer',mods)then length=app.settings.grid_qn end
  if time~=0 or pitch~=0 or length~=0 then
    local first_q=reaper.MIDI_GetProjQNFromPPQPos(app.take,h.first);local last_q=reaper.MIDI_GetProjQNFromPPQPos(app.take,h.last)
    apply(app,h,{first=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,first_q+time)+.5),last=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,last_q+time+length)+.5),target=h.target+pitch});return true
  end
  if pressed(app,'quantize',mods)then local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,h.first);local delta=U.snap(q,app.settings.grid_qn)-q;apply(app,h,{first=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+delta)+.5),last=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,reaper.MIDI_GetProjQNFromPPQPos(app.take,h.last)+delta)+.5)});return true end
  if pressed(app,'velocity_up',mods)or pressed(app,'velocity_down',mods)or pressed(app,'legato',mods)or pressed(app,'duplicate_octave_up',mods)or pressed(app,'duplicate_octave_down',mods)then app.expression_notice='This command edits sounding notes. Select the source note with the Smart tool first.';return true end
  if pressed(app,'copy',mods)or pressed(app,'cut',mods)or pressed(app,'duplicate',mods)then
    local targets=group(app);if #targets==0 then targets={h}end
    local clip,anchor=require('src.slide_draw').copy_targets(app,targets)
    if not clip then app.expression_notice=anchor;return true end
    if pressed(app,'cut',mods)then
      if apply(app,h,{delete=true})then app.slide_clipboard=clip;app.slide_selection=nil;app.slide_group=nil end
    elseif pressed(app,'duplicate',mods)then
      paste_clip(app,clip,anchor+clip.span+1/(app.viewport and app.viewport.ppq_per_qn or 960))
    else app.slide_clipboard=clip end
    return true
  end
  if pressed(app,'delete',mods)then apply(app,h,{delete=true});app.slide_selection=nil;return true end
  if pressed(app,'cancel',mods)or pressed(app,'deselect',mods)then app.slide_selection=nil;app.slide_group=nil;return true end
  return false
end
return M
