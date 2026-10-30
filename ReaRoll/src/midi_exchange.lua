-- @noindex
local File=require 'src.midi_file';local Notes=require 'src.note_events';local Curve=require 'src.midi_curve'
local M={}
function M.read(path)
  local file,notice=io.open(path,'rb');if not file then return nil,notice end
  local raw=file:read(16777217);file:close();return File.decode(raw or '')
end
function M.plan(app,file,track_index,anchor)
  if not app.take then return nil,'Select an active MIDI item first.'end
  if type(anchor)~='number'or anchor~=anchor or anchor<app.item_start_qn then return nil,'Choose an insertion point inside the item.'end
  local events,span={},0
  for index,track in ipairs(file.tracks)do if not track_index or track_index==index then
    span=math.max(span,track.span)
    for _,event in ipairs(track.events)do local meta=event.msg:byte(1)==255 and event.msg:byte(2)
      -- Project tempo/signature changes are deliberately separate from importing notes.
      if meta~=0x51 and meta~=0x58 then events[#events+1]={q=event.q,msg=event.msg,track=index,order=event.order}end
    end
  end end
  if anchor+span>app.item_end_qn+1e-8 then return nil,'The MIDI file does not fit here. Extend the item or move the edit cursor.'end
  table.sort(events,function(a,b)if a.q~=b.q then return a.q<b.q end;if a.track~=b.track then return a.track<b.track end;return a.order<b.order end)
  local notes,pending={},{}
  for _,event in ipairs(events)do local msg=event.msg;local status=msg:byte(1)>>4
    if status==9 and msg:byte(3)>0 then local key=(msg:byte(1)&15)..':'..msg:byte(2);local queue=pending[key]or {first=1,last=0};pending[key]=queue;queue.last=queue.last+1;queue[queue.last]=event
    elseif status==8 or status==9 and msg:byte(3)==0 then local key=(msg:byte(1)&15)..':'..msg:byte(2);local queue=pending[key]
      if queue and queue.first<=queue.last then local on=queue[queue.first];queue[queue.first]=nil;queue.first=queue.first+1
        if event.q<=on.q then return nil,'The file contains a note without positive duration.'end
        notes[#notes+1]={s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor+on.q)+.5),e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor+event.q)+.5),pitch=msg:byte(2),chan=msg:byte(1)&15,vel=on.msg:byte(3)}
      end
    end
  end
  for _,queue in pairs(pending)do if queue.first<=queue.last then return nil,'The file has notes without recorded note-offs. Repair them before importing.'end end
  local source=Notes.read(app.take);if not source then return nil,'The destination MIDI item is unavailable.'end
  local existing=source.notes
  for _,note in ipairs(notes)do
    if note.e<=note.s then return nil,'A note is shorter than one destination MIDI tick.'end
    if app.settings.prevent_overlaps then for _,old in ipairs(existing)do if old.chan==note.chan and old.pitch==note.pitch and old.s<note.e and old.e>note.s then return nil,'Imported notes overlap existing pitches on the same channels. Choose an empty range or disable overlap prevention.'end end end
    if app.settings.mpe_enabled and require('src.expression').member(note.chan,app.settings)then
      for _,old in ipairs(existing)do if old.chan==note.chan and old.s<note.e and old.e>note.s then return nil,'The import would share an occupied MPE voice channel. Choose an empty destination.'end end
    end
  end
  return {take=app.take,events=events,notes=notes,span=span,anchor=anchor,raw=source.original_raw,file=file,track_index=track_index}
end
function M.apply(app,plan)
  if app.take~=plan.take or app.edit.active or app.gesture or app.transform_preview or app.lane_tool_preview or app.multi_edit_mode then return false,'Select the original active item and finish the current edit.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The destination item is unavailable.'end
  local item=reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(app.take)
  if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'Unlock the destination item first.'end
  if select(2,reaper.MIDI_GetAllEvts(app.take,''))~=plan.raw then return false,'Destination MIDI changed. Review the import again.'end
  if plan.anchor<app.item_start_qn or plan.anchor+plan.span>app.item_end_qn+1e-8 then return false,'The destination bounds changed. Review the import again.'end
  local checked,reason=M.plan(app,plan.file,plan.track_index,plan.anchor);if not checked then return false,reason end;plan=checked
  if #plan.events==0 then return false,'This track has no MIDI events to insert.'end
  local ok,notice=xpcall(function()
    app.edit:begin('ReaRoll: import MIDI file',app.take);local a=app.edit.active;a.allow_overlaps=true
    local count=#a.stream.events
    for index,event in ipairs(plan.events)do a.stream.events[#a.stream.events+1]={ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,plan.anchor+event.q)+.5),flags=0,msg=event.msg,order=count+index}end
    a.stream.dirty=true;a.changed=true;assert(app.edit:finish()~=false)
  end,debug.traceback)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,notice end
  app.cache:rebuild();app.cc_cache:invalidate();app:reselect_notes(plan.notes);return true
end
local function parameter(event)
  local msg=event.msg;local status=msg:byte(1)>>4
  if status==14 then return (msg:byte(1)&15)..':pitch',((msg:byte(3)<<7)|msg:byte(2)),16383
  elseif status==13 then return (msg:byte(1)&15)..':pressure',msg:byte(2),127
  elseif status==11 then return (msg:byte(1)&15)..':cc'..msg:byte(2),msg:byte(3),127 end
end
local function valued(msg,value)
  value=math.floor(value+.5);local status=msg:byte(1)>>4
  if status==14 then return string.char(msg:byte(1),value&127,(value>>7)&127)
  elseif status==13 then return string.char(msg:byte(1),value)
  else return msg:sub(1,2)..string.char(value)end
end
function M.export(app)
  if not app.take or app.edit.active or app.gesture or app.transform_preview or app.lane_tool_preview then return nil,'Finish the current edit and select a MIDI item.'end
  local stream=Notes.read(app.take);if not stream then return nil,'The MIDI source is unavailable.'end
  local first,last=app.item_start_qn,app.item_end_qn;local events,skipped,groups={},{},{}
  for _,note in ipairs(stream.notes)do
    skipped[note.on]=true;skipped[note.off]=true
    local a,b=reaper.MIDI_GetProjQNFromPPQPos(app.take,note.s),reaper.MIDI_GetProjQNFromPPQPos(app.take,note.e)
    if not note.muted and b>first and a<last then
      events[#events+1]={q=math.max(first,a)-first,msg=note.on.msg:sub(1,3),order=note.on.order}
      events[#events+1]={q=math.min(last,b)-first,msg=note.off.msg:sub(1,3),order=note.off.order}
    end
  end
  for index,event in ipairs(stream.events)do if not skipped[event]and #event.msg>0 and(event.flags&2)==0 then
    local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq)-first
    local metadata=event.msg:sub(1,7)==string.char(255,15)..'CCBZ '
    if not metadata then
      if q>=0 and q<=last-first then events[#events+1]={q=q,msg=event.msg,order=event.order}end
      local key,value,maximum=parameter(event)
      if key then local group=groups[key]or {maximum=maximum};groups[key]=group;local next_event=stream.events[index+1]
        group[#group+1]={time=q,value=value,flags=event.flags,msg=event.msg,order=event.order,shape=next_event and next_event.ppq==event.ppq and next_event.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and {msg=next_event.msg}or nil}
      end
    end
  end end
  local count=#events
  for _,group in pairs(groups)do
    table.sort(group,function(a,b)if a.time~=b.time then return a.time<b.time end;return a.order<b.order end)
    for index,point in ipairs(group)do local next_point=group[index+1]
      if point.time<0 and(not next_point or next_point.time>0)then
        local value=next_point and Curve.value(group,index,0,0,group.maximum)or point.value
        if not value then return nil,'An unknown controller curve crosses the item start.'end
        events[#events+1]={q=0,msg=valued(point.msg,value),order=-10000+point.order}
      end
      if next_point and point.time<last-first and next_point.time>0 and((point.flags>>4)&15)~=0 then
        local start=math.max(0,point.time);local ending=math.min(last-first,next_point.time)
        local previous=point.value
        local steps=math.max(0,math.floor(ending*960)-math.floor(start*960))
        if count+steps>500000 then return nil,'Baked curves exceed the export limit. Export a shorter item.'end
        for tick=math.floor(start*960)+1,math.floor(ending*960)do local time=tick/960
          if time<next_point.time then local value=Curve.value(group,index,time,0,group.maximum);if not value then return nil,'An unknown controller curve cannot be exported safely.'end
            value=math.floor(value+.5);if value~=previous then events[#events+1]={q=time,msg=valued(point.msg,value),order=point.order+.1};previous=value;count=count+1 end
          end
        end
      end
    end
  end
  if reaper.TimeMap_GetTimeSigAtTime and reaper.TimeMap2_QNToTime then
    local span=last-first;if span*64>500000 then return nil,'The item is too long for tempo-aware MIDI export. Export a shorter range.'end
    local samples={0};for tick=1,math.floor(span*64)do samples[#samples+1]=tick/64 end
    if reaper.CountTempoTimeSigMarkers and reaper.GetTempoTimeSigMarker then
      for index=0,reaper.CountTempoTimeSigMarkers(0)-1 do
        local got,time=reaper.GetTempoTimeSigMarker(0,index)
        if got then local q=reaper.TimeMap2_timeToQN(0,time)-first;if q>0 and q<span then samples[#samples+1]=q end end
      end
    end
    table.sort(samples);local previous_tempo,previous_meter
    for _,q in ipairs(samples)do
      local num,den,bpm=reaper.TimeMap_GetTimeSigAtTime(0,reaper.TimeMap2_QNToTime(0,first+q))
      if bpm and bpm>0 then
        local tempo=math.floor(60000000/bpm+.5)
        if tempo<=0 or tempo>0xFFFFFF then return nil,'The project tempo is outside the Standard MIDI File range.'end
        if tempo~=previous_tempo then events[#events+1]={q=q,msg=string.char(255,81,(tempo>>16)&255,(tempo>>8)&255,tempo&255),order=-1000000};previous_tempo=tempo end
      end
      if num and den and num>0 and num<256 then
        local power=math.log(den,2)
        if power%1==0 and power>=0 and power<=7 then
          local meter=num..':'..den
          if meter~=previous_meter then events[#events+1]={q=q,msg=string.char(255,88,num,power,24,8),order=-999999};previous_meter=meter end
        end
      end
    end
  end
  return File.encode(events,last-first,960)
end
function M.write(path,raw,overwrite)
  if not File.decode(raw)then return false,'The prepared MIDI file is invalid. Prepare the export again.'end
  if type(path)~='string'or not path:lower():match('%.mid$')or path:find('%z')then return false,'Choose a destination ending in .mid.'end
  local exists=io.open(path,'rb');if exists then exists:close();if not overwrite then return false,'The destination exists. Confirm overwrite to replace it.'end end
  local suffix='.rearoll-'..os.time()..'-'..math.random(100000,999999)
  local temporary=path..suffix..'.tmp';local backup=path..suffix..'.bak'
  local file,notice=io.open(temporary,'wb');if not file then return false,notice end
  local ok,error=file:write(raw);local closed,close_error=file:close()
  if not ok or not closed then os.remove(temporary);return false,error or close_error end
  local old=io.open(path,'rb');local had_old=old~=nil;if old then old:close()end
  if had_old and not overwrite then os.remove(temporary);return false,'The destination exists. Confirm overwrite to replace it.'end
  if had_old then local renamed,reason=os.rename(path,backup);if not renamed then os.remove(temporary);return false,reason end end
  local renamed,reason=os.rename(temporary,path)
  if not renamed then if had_old then os.rename(backup,path)end;os.remove(temporary);return false,reason end
  if had_old then os.remove(backup)end
  return true
end
return M
