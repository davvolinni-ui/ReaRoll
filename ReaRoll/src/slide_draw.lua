-- @noindex
-- A slide target is pitch expression on its source voice, never a second
-- sounding MIDI note. The ordinary drawing tool keeps ordinary overlap behavior.
local Notes=require 'src.note_events'
local E=require 'src.expression'
local G=require 'src.glide'
local M={}
function M.source(notes,first,channel)
  local matching,other={},{}
  for _,note in ipairs(notes)do if note.s<=first and note.e>first and not(note.source and note.source.readonly)then
    other[#other+1]=note;if note.chan==channel then matching[#matching+1]=note end
  end end
  if #matching>0 then
    table.sort(matching,function(a,b)if a.pitch~=b.pitch then return a.pitch>b.pitch end;return a.index<b.index end)
    return matching[1]
  end
  if #other==1 then return other[1]end
  return nil,#other==0 and 'Draw the slide over a sounding note in time.'or 'Several voice channels overlap here. Choose the target voice with the channel selector.'
end
local function pitch(event,channel)return not event.deleted and #event.msg>=3 and event.msg:byte(1)==(224|channel)end
local function value(event)return (event.msg:byte(3)<<7)|event.msg:byte(2)end
function M.owner(notes,note,first)
  if not note then return end
  local Links=require 'src.slide_links'
  for _,owner in ipairs(notes)do if owner.chan==note.chan and owner.pitch==note.pitch and Links.structural(owner)then local a,b=Links.domain(owner);if first>=a and first<b then return owner end end end
  return note
end
function M.plan(stream,note,first,last,target,settings,replace,item_end)
  local sounding=note and first>=note.s and first<=note.e-2
  if note and(settings.slide_structural or require('src.slide_links').structural(note))then for _,voice in ipairs(stream.notes)do if voice.chan==note.chan and voice.pitch==note.pitch and first>=voice.s and first<=voice.e-2 then sounding=true end end end
  if not sounding or last-first<2 then return nil,'Start the target over a sounding source note, with at least two MIDI ticks of duration.'end
  if item_end and last>item_end then return nil,'The slide target extends beyond its MIDI item.'end
  if (last-note.s)/math.max(1,note.e-note.s)>1000000 then return nil,'The slide target is too long for this source note.'end
  if target<0 or target>127 then return nil,'The slide target is outside the MIDI pitch range.'end
  if settings.mpe_enabled and not E.member(note.chan,settings)then return nil,'Select a note on an MPE member channel.'end
  local members,group_first,group_last=require('src.shared_slide').members(stream,note,settings.slide_domain_first,settings.slide_domain_last)
  if settings.mpe_enabled then group_first,group_last=note.s,note.e end
  if math.abs((group_first-note.s)/math.max(1,note.e-note.s))>1000000 or(group_last-note.s)/math.max(1,note.e-note.s)>1000000 then return nil,'This overlap group is too long for a durable slide link.'end
  for _,other in ipairs(stream.notes)do if other~=note and members[other.index or other]then
    if settings.mpe_enabled then return nil,'Overlapping notes share this MPE member channel. Independent pitch expression requires separate member channels.'end
    if other.s<=first and other.e>first and other.pitch>note.pitch then return nil,'The highest sounding note at the target start is the reference for this channel group.'end
  end end
  local range=math.max(1,settings.mpe_enabled and (settings.mpe_pitch_bend_range or 48)or(settings.pitch_bend_range or 2))
  if math.abs(target-note.pitch)>range then return nil,'The target exceeds the configured instrument bend range. Match the range in Note expression / MPE and the instrument.'end
  local previous,next_event;local remove={};local reset=false
  local master=settings.mpe_zone=='upper' and 15 or 0
  local pedal={}
  for i,event in ipairs(stream.events)do
    if not event.deleted and #event.msg>=3 and event.msg:byte(1)>>4==11 and event.msg:byte(2)==64 then
      local channel=event.msg:byte(1)&15
      if channel==note.chan or settings.mpe_enabled and channel==master then
        if event.ppq<=group_first then if not pedal[channel]or pedal[channel].ppq<=event.ppq then pedal[channel]={ppq=event.ppq,on=event.msg:byte(3)>=64}end
        elseif event.ppq<group_last and event.msg:byte(3)>=64 then return nil,'Release sustain before drawing this slide; held voices can share its pitch channel.'end
      end
    end
    if pitch(event,note.chan)then
      if event.ppq<first and (not previous or event.ppq>=previous.ppq)then previous=event end
      if event.ppq>=first and (not next_event or event.ppq<next_event.ppq)then next_event=event end
      if event.ppq>=first and event.ppq<=last and event.ppq<group_last then
        if not replace then return nil,'Pitch expression already occupies this span. Edit those points in Expression, or draw the slide in an empty span.'end
        remove[#remove+1]=event
        local metadata=stream.events[i+1]
        if metadata and metadata.ppq==event.ppq and metadata.msg:sub(1,7)==string.char(255,15)..'CCBZ 'then remove[#remove+1]=metadata end
      end
      if event.ppq==group_last then reset=true end
    end
  end
  for _,state in pairs(pedal)do if state.on then return nil,'Sustain is active on this voice. Release it before drawing a slide.'end end
  local start_value=previous and value(previous)or 8192
  if previous and next_event and next_event.ppq>previous.ppq and previous.ppq<first then
    local shape=((previous.flags or 0)>>4)&15
    if shape==1 then local t=(first-previous.ppq)/(next_event.ppq-previous.ppq);start_value=math.floor(start_value+(value(next_event)-start_value)*t+.5)
    elseif shape>1 then return nil,'This start lies in an existing curved segment. Edit that curve in the expression editor instead.'end
  end
  local target_value=G.value(target-note.pitch,range)
  local finish=math.min(last,group_last-1)
  local points={};local count=math.min(128,math.max(1,math.floor(finish-first)))
  local used={}
  for i=0,count do local t=i/count;if last>group_last then t=t*(finish-first)/(last-first)end;local curve=settings.slide_curve or 0;if curve>0 then t=t^(1+curve*4)elseif curve<0 then t=1-(1-t)^(1-curve*4)end;local shaped=settings.slide_linear and t or t*t*(3-2*t);local ppq=math.floor(first+(finish-first)*(i/count)+.5)
    local v=math.floor(start_value+(target_value-start_value)*shaped+.5)
    if used[ppq]then used[ppq].value=v else local point={ppq=ppq,value=v};used[ppq]=point;points[#points+1]=point end
  end
  -- Reserve note-off for a neutral reset, before a following note-on.
  return {points=points,remove=remove,reset=not reset,channel=note.chan,ending=group_last,group_first=group_first,first=first,last=last,target=target,range=range}
end
function M.preview(app,gesture,last,target)
  gesture.valid=false
  if gesture.take and gesture.take~=app.take then return false,'The source item changed. Select its slide target again.'end;gesture.take=app.take
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,'')
  if not ok or gesture.expected_raw and raw~=gesture.expected_raw then app.edit.active=nil;app.gesture=nil;app.cache:invalidate();return false,'MIDI changed externally; its edit was preserved.'end
  if app.edit.active then app.edit:cancel()end
  app.edit:begin('ReaRoll: draw slide target',app.take)
  local a=app.edit.active;local note=M.owner(a.notes,a.notes[gesture.source_index+1],gesture.first);gesture.source_index=note and note.index or gesture.source_index
  local item=reaper.GetMediaItemTake_Item(app.take)
  if reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then app.edit:cancel();return false,'Unlock this item before drawing a slide.'end
  local Links=require 'src.slide_links'
  for _,r in ipairs(Links.snapshot(a.stream,note))do
    local first=math.floor(note.s+r.first*(note.e-note.s)+.5);local ending=math.floor(note.s+r.last*(note.e-note.s)+.5)
    if gesture.first<=ending and last>=first then app.edit:cancel();gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));return false,'This span already has a slide target. Drag its handle to edit it.'end
  end
  local settings=gesture.slide_settings or app.settings
  local plan,notice=M.plan(a.stream,note,gesture.first,last,target,settings,settings.slide_replace,reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn))
  if not plan then app.edit:cancel();gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));return false,notice end
  for _,event in ipairs(plan.remove)do event.deleted=true end
  local function add(ppq,v)
    a.stream.events[#a.stream.events+1]={ppq=ppq,flags=note.muted and 2 or 0,msg=string.char(224|plan.channel,v&127,(v>>7)&127),order=-1000000000+#a.stream.events}
  end
  for _,point in ipairs(plan.points)do add(point.ppq,point.value)end
  if plan.reset then add(plan.ending,8192)end
  local linked,link_notice=Links.attach(a.stream,note,plan,settings)
  if not linked then app.edit:cancel();return false,link_notice end
  a.stream.dirty=true;a.changed=true;app.edit:flush();app.cc_cache:invalidate();app.cache:invalidate();app.cache:rebuild()
  gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));gesture.last=last;gesture.target=target;gesture.valid=true
  return true
end
function M.finish(app,gesture)
  if gesture.take and gesture.take~=app.take then return false end
  if not app.edit.active then return false end
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,'')
  if not ok or raw~=gesture.expected_raw then app.edit.active=nil;app.cache:invalidate();return false end
  local committed=app.edit:finish();app.cache:rebuild();app.cc_cache:invalidate();return committed~=false
end
function M.preview_edit(app,gesture,change)
  gesture.valid=false
  if gesture.take and gesture.take~=app.take then return false,'The source item changed. Select its slide target again.'end;gesture.take=app.take
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,'')
  if not ok or gesture.expected_raw and raw~=gesture.expected_raw then app.edit.active=nil;app.gesture=nil;app.cache:invalidate();return false,'MIDI changed externally; its edit was preserved.'end
  if app.edit.active then app.edit:cancel()end
  app.edit:begin('ReaRoll: edit slide target',app.take,gesture.preview)
  local a=app.edit.active;local note=a.notes[gesture.source_index+1]
  if not note or reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(app.take),'C_LOCK')~=0 then app.edit:cancel();return false,'The source note is unavailable or locked.'end
  local groups={}
  if gesture.targets then
    for _,h in ipairs(gesture.targets)do
      local edits=groups[h.source_index]or {};groups[h.source_index]=edits
      edits[h.slide_id]={first=h.first+(change.time_delta or 0),last=h.last+(change.time_delta or 0)+(change.length_delta or 0),target=h.target+(change.pitch_delta or 0),delete=change.delete,linear=change.linear,curve=change.curve}
    end
  else groups[gesture.source_index]={[gesture.slide_id]=change}end
  for index,changes in pairs(groups)do
    local source=a.notes[index+1];local changed,notice
    if source then changed,notice=require('src.slide_links').edit_many(a.stream,source,changes,app.settings,reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn))end
    if not changed then app.edit:cancel();gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));return false,notice or 'A slide source is unavailable.'end
  end
  a.changed=true;app.edit:flush();app.cache:invalidate();app.cache:rebuild();app.cc_cache:invalidate()
  gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));gesture.valid=true;return true
end
function M.copy_targets(app,targets)
  if not targets or #targets==0 then return nil,'Select slide targets first.'end
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,'');if not ok then return nil,'The MIDI source is unavailable.'end
  local first=math.huge;for _,h in ipairs(targets)do
    if h.take~=app.take or h.raw~=raw then return nil,'MIDI changed since the targets were selected. Select them again.'end
    first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,h.first))
  end
  local clip={version=1,targets={},span=0}
  for _,h in ipairs(targets)do
    local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,h.first);local ending=reaper.MIDI_GetProjQNFromPPQPos(app.take,h.last)
    clip.targets[#clip.targets+1]={time=q-first,duration=ending-q,pitch=h.target,channel=h.channel,range=h.range,linear=h.linear,curve=h.curve or 0}
    clip.span=math.max(clip.span,ending-first)
  end
  return clip,first
end
function M.paste_targets(app,clip,anchor,preview)
  if not clip or clip.version~=1 or type(clip.targets)~='table'or #clip.targets==0 then return false,'No slide targets were copied.'end
  if app.gesture or app.transform_preview or app.edit.active then return false,'Finish the current edit first.'end
  if not require('src.take').valid(app.take)or reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(app.take),'C_LOCK')~=0 then return false,'Choose an unlocked destination item.'end
  local range=app.settings.mpe_enabled and(app.settings.mpe_pitch_bend_range or 48)or(app.settings.pitch_bend_range or 2)
  local stream=Notes.read(app.take);local groups={}
  for _,target in ipairs(clip.targets)do
    if anchor+target.time<app.item_start_qn-1e-8 or anchor+target.time+target.duration>app.item_end_qn+1e-8 then return false,'The slide targets would leave the destination item.'end
    if target.range~=range then return false,'Match the copied slide bend range before pasting.'end
    local first=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor+target.time)+.5)
    local last=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,anchor+target.time+target.duration)+.5)
    local note,notice=M.source(stream.notes,first,target.channel);note=M.owner(stream.notes,note,first)
    if not note or note.chan~=target.channel then return false,notice or 'A copied slide needs an overlapping source note on its original channel.'end
    local group=groups[note.index]or {};groups[note.index]=group
    group[#group+1]={first=first,last=last,target=target.pitch,linear=target.linear,curve=target.curve}
  end
  local ok,notice=xpcall(function()
    app.edit:begin('ReaRoll: paste slide targets',app.take,preview)
    local active=app.edit.active
    assert(active.original_raw==stream.original_raw,'The MIDI changed before Paste.')
    for index,targets in pairs(groups)do
      local changed,reason=require('src.slide_links').edit_many(active.stream,active.notes[index+1],{_insert=targets},app.settings,reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn))
      assert(changed,reason)
    end
    active.changed=true;assert(app.edit:finish()~=false,app.expression_notice or 'The slide targets could not be pasted.')
  end,debug.traceback)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,notice end
  app.cache:invalidate();app.cache:rebuild();app.cc_cache:invalidate();return true
end
return M
