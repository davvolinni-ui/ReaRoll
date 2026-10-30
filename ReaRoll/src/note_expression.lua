-- @noindex
local E=require 'src.expression'
local Notes=require 'src.note_events'
local M={}
function M.select_range(points,kind,first,last,add)
  first,last=math.min(first,last),math.max(first,last)
  for _,p in ipairs(points)do if p.kind==kind then
    local inside=not p.deleted and not p.shared and p.time>=first and p.time<=last
    p.selected=inside or (add and p.selected) or false
  end end
end
function M.group_snapshot(points,kind)
  local group={}
  for _,p in ipairs(points)do if p.kind==kind and p.selected and not p.deleted and not p.shared then group[#group+1]={point=p,time=p.time,value=p.value}end end
  return group
end
function M.move_group(group,dt,dv,maximum)
  if #group==0 then return end
  local tmin,tmax,vmin,vmax=-math.huge,math.huge,-math.huge,math.huge
  for _,entry in ipairs(group)do
    tmin=math.max(tmin,-entry.time);tmax=math.min(tmax,1-entry.time)
    vmin=math.max(vmin,-entry.value);vmax=math.min(vmax,maximum-entry.value)
  end
  -- Clamp one common delta, preserving distances at the note/value boundaries.
  dt=math.max(tmin,math.min(tmax,dt));dv=math.max(vmin,math.min(vmax,dv))
  for _,entry in ipairs(group)do entry.point.time=entry.time+dt;entry.point.value=math.floor(entry.value+dv+.5)end
end
M.shapes={'Hold','Linear','Slow start/end','Fast start','Fast end','Bézier'}
function M.tension(point)
  if not point.shape or #point.shape.msg~=12 then return 0 end
  local ok,v=pcall(string.unpack,'f',point.shape.msg,9)
  return ok and v==v and math.max(-1,math.min(1,v)) or 0
end
function M.set_shape(point,shape,tension)
  if point.shared then return false end
  if type(shape)~='number' or shape%1~=0 or shape<0 or shape>5 then return false end
  tension=tension or 0
  if type(tension)~='number' or tension~=tension or math.abs(tension)>1 then return false end
  point.flags=((point.flags or 0)&15)|(shape<<4)
  point.shape=shape==5 and {flags=point.shape and point.shape.flags or 0,msg=string.char(255,15)..'CCBZ '..string.pack('Bf',0,tension)} or nil
  return true
end
local function dimension(msg)
  local status=msg:byte(1)>>4
  return status==14 and 'pitch' or status==13 and 'pressure' or 'timbre'
end
local function value(msg)
  return msg:byte(1)>>4==14 and ((msg:byte(3)<<7)|msg:byte(2)) or msg:byte(1)>>4==13 and msg:byte(2) or msg:byte(3)
end
local function message(kind,channel,v)
  v=math.floor(v+.5)
  if kind=='pitch'then return string.char(224|channel,v&127,(v>>7)&127)end
  if kind=='pressure'then return string.char(208|channel,v)end
  return string.char(176|channel,74,v)
end
function M.begin(app,note)
  local stream=Notes.read(app.take);if not stream then return nil,'The MIDI item is unavailable.'end
  local source=stream.notes[note.index+1];if not source then return nil,'Select the note again.'end
  local Links=require 'src.slide_links'
  if not app.settings.mpe_enabled and not Links.has_curve(source)then return nil,'Select an MPE note or a split slide pitch curve.'end
  local effective=Links.expression_settings(source,app.settings)or app.settings
  if not E.member(source.chan,effective)then return nil,'Select a note on an MPE member channel.'end
  local owned,notice=E.capture(stream,source,effective);if not owned then return nil,notice end
  local draft={take=app.take,raw=stream.original_raw,note=source,expression_end=owned.end_ppq or source.e,velocity=source.vel,release_velocity=source.off.msg:byte(3),points={},pitch_only=effective.expression_pitch_only==true,mpe_enabled=app.settings.mpe_enabled==true,zone=app.settings.mpe_zone,members=app.settings.mpe_members}
  for _,entry in ipairs(owned)do local event=entry.event
    draft.points[#draft.points+1]={kind=dimension(event.msg),time=(event.ppq-source.s)/math.max(1,draft.expression_end-source.s),value=value(event.msg),flags=event.flags,original_flags=event.flags,original_shape=entry.shape and entry.shape.msg,original_shape_flags=entry.shape and entry.shape.flags,order=event.order,shared=entry.shared,original_time=event.ppq,original_msg=event.msg,shape=entry.shape and {msg=entry.shape.msg,flags=entry.shape.flags}}
  end
  draft.context_points={};local context={}
  for index,event in ipairs(stream.events)do if E.message(event,source.chan)and(not draft.pitch_only or event.msg:byte(1)>>4==14)then
    local kind=dimension(event.msg);local edge=event.ppq<source.s and 'before'or event.ppq>draft.expression_end and 'after'or nil
    if edge then
      local key=kind..edge;local old=context[key]
      if not old or edge=='before'and event.ppq>=old.event.ppq or edge=='after'and event.ppq<old.event.ppq then context[key]={event=event,shape=stream.events[index+1]}end
    end
  end end
  for _,entry in pairs(context)do local event=entry.event;local shape=entry.shape
    draft.context_points[#draft.context_points+1]={kind=dimension(event.msg),time=(event.ppq-source.s)/math.max(1,draft.expression_end-source.s),value=value(event.msg),flags=event.flags,context=true,shared=true,shape=shape and shape.ppq==event.ppq and shape.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and {msg=shape.msg,flags=shape.flags}or nil}
  end
  -- Editing a note must not leave a changed channel value on the next voice.
  -- Freeze the original end value/outgoing segment before the draft is changed.
  draft.boundaries={}
  for _,point in ipairs(draft.points)do point.original_value=point.value end
  for _,kind in ipairs({'pitch','pressure','timbre'})do
    local points={}
    for _,p in ipairs(draft.points)do if p.kind==kind then points[#points+1]=p end end
    for _,p in ipairs(draft.context_points)do if p.kind==kind then points[#points+1]=p end end
    table.sort(points,function(a,b)if a.time~=b.time then return a.time<b.time end;return(a.order or 0)<(b.order or 0)end)
    local index
    for i,p in ipairs(points)do if p.time<=1 then index=i end end
    local previous=index and points[index];local following=index and points[index+1]
    local flags=previous and previous.flags or 0;local shape=(flags>>4)&15
    local boundary={value=previous and require('src.midi_curve').value(points,index,1,0,kind=='pitch'and 16383 or 127)or(kind=='pitch'and 8192 or kind=='timbre'and 64 or 0),flags=flags,shape=previous and previous.shape}
    boundary.unsafe=following and following.time>1 and(shape>1 and previous.time<1 or shape==5 and previous.time==1)
    boundary.retained=previous and previous.time==1 and previous.shared
    if not following then boundary.flags=flags&15;boundary.shape=nil end
    for _,other in ipairs(stream.notes)do if other~=source and other.chan==source.chan and other.s==draft.expression_end then boundary.protected=true;boundary.order=other.on.order-.25 end end
    draft.boundaries[kind]=boundary
  end
  return draft
end
function M.apply(app,draft,options)
  if app.take~=draft.take or reaper.ValidatePtr2 and not reaper.ValidatePtr2(0,draft.take,'MediaItem_Take*')then return false,'The source item changed; reopen its expression.'end
  local item=reaper.GetMediaItemTake_Item(draft.take)
  if reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'Unlock the item before editing expression.'end
  local ok,raw=reaper.MIDI_GetAllEvts(draft.take,'')
  if not ok or raw~=draft.raw then return false,'MIDI changed while expression was open. Reopen the note to keep those changes.'end
  if draft.mpe_enabled~=nil and draft.mpe_enabled~=(app.settings.mpe_enabled==true)or not draft.pitch_only and(not app.settings.mpe_enabled or draft.zone~=app.settings.mpe_zone or draft.members~=app.settings.mpe_members)then return false,'MIDI/MPE setup changed; reopen the note.'end
  local effective=draft.pitch_only and require('src.slide_links').expression_settings(draft.note,app.settings)or app.settings
  if not effective then return false,'The note no longer owns this pitch curve.'end
  if type(draft.velocity)~='number' or draft.velocity~=math.floor(draft.velocity) or draft.velocity<1 or draft.velocity>127 or type(draft.release_velocity)~='number' or draft.release_velocity~=math.floor(draft.release_velocity) or draft.release_velocity<0 or draft.release_velocity>127 then return false,'Note velocities must be valid MIDI values.'end
  for _,point in ipairs(draft.points)do
    if draft.pitch_only and point.kind~='pitch'then return false,'This Standard MIDI note owns pitch only.'end
    if point.kind~='pitch' and point.kind~='pressure' and point.kind~='timbre' or type(point.time)~='number' or point.time~=point.time or point.time<0 or point.time>1 or type(point.value)~='number' or point.value~=point.value or point.value<0 or point.value>(point.kind=='pitch' and 16383 or 127)then return false,'An expression point is outside the note or value range.'end
    if point.shared and (point.deleted or point.flags~=point.original_flags or (point.shape and point.shape.msg)~=point.original_shape or (point.shape and point.shape.flags)~=point.original_shape_flags or math.floor(draft.note.s+point.time*((draft.expression_end or draft.note.e)-draft.note.s)+.5)~=point.original_time or message(point.kind,draft.note.chan,point.value)~=point.original_msg)then return false,'This endpoint is shared with an adjacent note. Leave it unchanged to preserve the neighboring expression.'end
  end
  local changed_dimensions={}
  for _,point in ipairs(draft.points)do
    if point.deleted or not point.original_msg or point.flags~=point.original_flags or(point.shape and point.shape.msg)~=point.original_shape or math.floor(draft.note.s+point.time*(draft.expression_end-draft.note.s)+.5)~=point.original_time or message(point.kind,draft.note.chan,point.value)~=point.original_msg then changed_dimensions[point.kind]=true end
  end
  for kind in pairs(changed_dimensions)do local boundary=draft.boundaries and draft.boundaries[kind]
    if boundary and boundary.unsafe then return false,'A curved '..kind..' segment continues beyond this voice. Add an explicit held or linear boundary before changing it; the following voice was preserved.'end
    if boundary and boundary.protected then for _,point in ipairs(draft.points)do if point.kind==kind and not point.deleted and point.time==1 and not point.shared then return false,'The end of this voice is shared with the next note. Keep its endpoint unchanged.'end end end
  end
  if options and options.transaction then
    if not app.edit.active or app.edit.active.take~=draft.take then return false,'The expression transaction is unavailable.'end
  elseif options and options.preview then app.edit:begin_preview(draft.take)
  else app.edit:begin('ReaRoll: edit note expression',draft.take)end
  local stream=app.edit.active.stream;local note=stream.notes[draft.note.index+1]
  stream:set(note.index,{vel=draft.velocity})
  if draft.release_velocity~=note.off.msg:byte(3)then note.off.msg=string.char(128|note.chan,note.pitch,draft.release_velocity)..note.off.msg:sub(4)end
  local removed,notice=E.remove(stream,note,effective)
  if not removed then app.edit:cancel();return false,notice end
  for _,point in ipairs(draft.points)do if not point.deleted and not point.shared then
    local event={ppq=math.floor(note.s+point.time*((draft.expression_end or note.e)-note.s)+.5),flags=point.flags or 0,msg=message(point.kind,note.chan,point.value),order=point.order or (point.time==0 and note.on.order-.5 or #stream.events+1)}
    stream.events[#stream.events+1]=event
    if point.shape then stream.events[#stream.events+1]={ppq=event.ppq,flags=point.shape.flags,msg=point.shape.msg,order=event.order+.1}end
  end end
  for kind in pairs(changed_dimensions)do local boundary=draft.boundaries and draft.boundaries[kind]
    if boundary and not boundary.retained then
      local event={ppq=draft.expression_end,flags=boundary.flags,msg=message(kind,note.chan,boundary.value),order=boundary.order or #stream.events+1}
      stream.events[#stream.events+1]=event
      if boundary.shape then stream.events[#stream.events+1]={ppq=event.ppq,flags=boundary.shape.flags or 0,msg=boundary.shape.msg,order=event.order+.001}end
    end
  end
  stream.dirty=true;app.edit:touch()
  if not(options and options.transaction)then
    local committed=app.edit:finish();app.cache:rebuild()
    if committed==false then return false,app.expression_notice or 'Could not commit expression changes.'end
  end
  return true
end
return M
