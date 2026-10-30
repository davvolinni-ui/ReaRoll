-- @noindex
local M={}
function M.member(channel,settings)
  if settings and settings.expression_all_channels then return channel>=0 and channel<=15 end
  local count=math.max(1,math.min(15,math.floor(settings and settings.mpe_members or 15)))
  if settings and settings.mpe_zone=='upper' then return channel>=15-count and channel<15 end
  return channel>=1 and channel<=count
end
function M.message(event,channel)
  local msg=event.msg
  if event.deleted or #msg<2 or msg:byte(1)&15~=channel then return false end
  local status=msg:byte(1)>>4
  return status==14 and #msg>=3 or status==13 or status==11 and #msg>=3 and msg:byte(2)==74
end
local function clone(event)
  local out={};for k,v in pairs(event)do out[k]=v end;return out
end
local function shape(event)
  return not event.deleted and event.msg:sub(1,7)==string.char(255,15)..'CCBZ '
end
-- Read ownership before modifying any events. Shared endpoints are copied on
-- movement and retained on deletion, so adjacent voices keep their resets.
function M.capture(stream,note,settings,cohort)
  if not M.member(note.chan,settings)then return {} end
  local lifetime=require('src.voice_lifetime').index(stream,settings)
  local first=settings and settings.expression_start or note.s
  local nominal_end=settings and settings.expression_end or note.e
  local ending=math.max(lifetime(note),nominal_end)
  if cohort then for _,other in ipairs(stream.notes)do if cohort[other.index]then ending=math.max(ending,lifetime(other))end end end
  if ending==math.huge then return nil,'This note is held by sustain with no recorded pedal release. Add the release before editing its expression.'end
  for _,other in ipairs(stream.notes)do
    if other~=note and other.chan==note.chan and other.s<ending and lifetime(other)>first and not(cohort and cohort[other.index])then
      return nil,'Overlapping notes share this expression channel. Their expression cannot be separated safely.'
    end
  end
  local function matches(event)return M.message(event,note.chan)and(not(settings and settings.expression_pitch_only)or event.msg:byte(1)>>4==14)end
  local out,prior,initial,next_points={start_ppq=first,end_ppq=ending,sustained=ending>nominal_end},{},{},{}
  for i,event in ipairs(stream.events)do
    if matches(event)then
      local kind=event.msg:byte(1)>>4
      if event.ppq<first and (not prior[kind]or prior[kind].ppq<=event.ppq)then prior[kind]=event end
      if event.ppq==first then initial[kind]=true end
      if event.ppq>first and (not next_points[kind]or event.ppq<next_points[kind].ppq)then next_points[kind]=event end
    end
    if matches(event)and event.ppq>=first and event.ppq<=ending then
      local shared=false
      for _,other in ipairs(stream.notes)do
        if other~=note and other.chan==note.chan and (event.ppq==first and lifetime(other)==first or event.ppq==ending and other.s==ending)then shared=true;break end
      end
      local entry={event=event,shared=shared}
      local next_event=stream.events[i+1]
      if next_event and next_event.ppq==event.ppq and shape(next_event)then entry.shape=next_event end
      out[#out+1]=entry
    end
  end
  if settings and settings.expression_start and not prior[14]and not initial[14]then
    out[#out+1]={event={ppq=first,flags=note.muted and 2 or 0,msg=string.char(224|note.chan,0,64),order=-1000000000+#stream.events},synthetic=true}
  end
  -- Controllers retain their previous value. Materialize that value at the
  -- moved/copied note start without stealing the earlier channel event.
  for _,kind in ipairs({14,13,11})do if prior[kind]and not initial[kind]then
    local event=clone(prior[kind]);event.ppq=first;event.flags=(event.flags or 0)&3;event.order=(note.on and note.on.order or #stream.events+1)-.5+kind*.001
    local next_point=next_points[kind];local curve=(prior[kind].flags>>4)&15
    if next_point and curve>1 then return nil,'A curved expression segment crosses this note start. Add a boundary point before moving or editing this voice.'end
    if next_point and curve==1 then
      local function value(msg)return kind==14 and((msg:byte(3)<<7)|msg:byte(2))or kind==13 and msg:byte(2)or msg:byte(3)end
      local low,high=value(prior[kind].msg),value(next_point.msg)
      local v=math.floor(low+(high-low)*(first-prior[kind].ppq)/(next_point.ppq-prior[kind].ppq)+.5)
      if kind==14 then event.msg=string.char(event.msg:byte(1),v&127,(v>>7)&127)
      elseif kind==13 then event.msg=string.char(event.msg:byte(1),v)else event.msg=string.char(event.msg:byte(1),74,v)end
      event.flags=event.flags|16
    end
    out[#out+1]={event=event,synthetic=true}
  end end
  return out
end
function M.release_only(stream,note,values,settings)
  local ns,ne,nc=values.s or note.s,values.e or note.e,values.chan or note.chan
  if ns~=note.s or nc~=note.chan or ne==note.e or ne<=ns or require('src.slide_links').has(note)then return false end
  -- A key-release move within the same recorded pedal-held lifetime changes
  -- neither the voice's expression timeline nor the shared pedal.
  for _,event in ipairs(stream.events)do if not event.deleted and event.ppq==ne and #event.msg>=3 and event.msg:byte(1)>>4==11 then
    local ch,cc=event.msg:byte(1)&15,event.msg:byte(2)
    local master=settings.mpe_zone=='upper'and 15 or 0
    if(ch==note.chan or ch==master)and(cc==64 or cc==120 or cc==121)then return false end
  end end
  local life=require('src.voice_lifetime').index(stream,settings)
  local previous=life(note);local following=life({s=note.s,e=ne,chan=note.chan,off=note.off})
  return previous~=math.huge and previous==following and previous>math.min(note.e,ne)
end
function M.follow(stream,note,values,settings,batch)
  if not M.member(note.chan,settings)then return true end
  local ns,ne,nc=values.s or note.s,values.e or note.e,values.chan or note.chan
  if ns==note.s and ne==note.e and nc==note.chan then return true end
  if M.release_only(stream,note,values,settings)then return true end
  local events,notice=batch and batch.owned[note.index]
  if not events then events,notice=M.capture(stream,note,settings)end
  if not events then return false,notice end
  if events.sustained and not(batch and batch.cc_follow)then return false,'Enable CC follows notes to move this pedal-held voice with its expression.'end
  if not M.member(nc,settings)then return false,'Expression cannot be moved onto an MPE master or outside the member zone.'end
  local lifetime=require('src.voice_lifetime').index(stream,settings)
  local old_span=math.max(1,note.e-note.s)
  local domain=batch and batch.domains and batch.domains[note.index]
  local following=batch and batch.cc_follow and batch.cc_follow.voices[note.index]
  local function mapped(t)
    if following and not(settings and settings.expression_start)then return math.floor(ns+(t-note.s)/math.max(1,events.end_ppq-note.s)*(following.ending-ns)+.5)end
    if domain then return math.floor(domain.s+(t-domain.old_s)/math.max(1,domain.old_e-domain.old_s)*(domain.e-domain.s)+.5)end;return math.floor(ns+(t-note.s)/old_span*(ne-ns)+.5)end
  local domain_first=mapped(settings and settings.expression_start or note.s)
  local domain_last=mapped(following and events.end_ppq or settings and settings.expression_end or note.e)
  for _,other in ipairs(stream.notes)do
    local planned=batch and batch.destinations[other.index]
    local channel=planned and planned.chan or other.chan
    local first=planned and planned.s or other.s;local last=planned and(planned.sounding_end or planned.e)or lifetime(other)
    if other~=note and channel==nc and first<domain_last and last>domain_first and not(batch and batch.groups and batch.groups[note.index]and batch.groups[note.index][other.index])then return false,'The destination expression channel is occupied by another note.'end
  end
  if #events==0 then return true end
  local span=math.max(1,note.e-note.s)
  for _,entry in ipairs(events)do
    local event=entry.event;local original_order=entry.old_order or event.order
    local ppq=mapped(event.ppq)
    local reused=false
    if entry.shared or entry.synthetic then
      local key=tostring(ppq)..':'..nc
      local copies=batch and batch.copies[entry.event]
      if copies and copies[key]then event=copies[key];reused=true
      else
        event=clone(event);event.order=entry.event.ppq<note.s and(-1000000000+#stream.events)or entry.event.ppq==note.s and(note.on and note.on.order or #stream.events+1)-.5 or #stream.events+1;stream.events[#stream.events+1]=event
        if batch and entry.shared then copies=copies or {};batch.copies[entry.event]=copies;copies[key]=event end
      end
      if reused and entry.event.ppq==note.s then
        event.order=math.min(event.order,(note.on and note.on.order or #stream.events+1)-.5)
        if batch.metadata[event]then batch.metadata[event].order=event.order+.1 end
      end
    end
    if following then event.order=following.order_base+original_order end
    event.ppq=ppq;event.msg=string.char((event.msg:byte(1)&240)|nc)..event.msg:sub(2)
    if entry.shape and not reused then
      local metadata=entry.shape
      if entry.shared then metadata=clone(metadata);metadata.order=event.order+.1;stream.events[#stream.events+1]=metadata end
      metadata.ppq=ppq;if following then metadata.order=event.order+.1 end
      if batch then batch.metadata[event]=metadata end
    end
  end
  stream.dirty=true;return true
end
function M.remove(stream,note,settings)
  local events,notice=M.capture(stream,note,settings);if not events then return false,notice end
  for _,entry in ipairs(events)do if not entry.shared and not entry.synthetic then entry.event.deleted=true;if entry.shape then entry.shape.deleted=true end end end
  stream.dirty=true;return true
end
function M.duplicate(stream,source,first,last,pitch,settings,cohort,group,following)
  local owned,notice=following and following.owned
  if not owned then owned,notice=M.capture(stream,source,settings,cohort)end
  if not owned then return nil,notice end
  if owned.sustained and not following then return nil,'Enable CC follows notes to copy this pedal-held voice with its expression.'end
  local function mapped(t)
    if following and not settings.expression_start then return math.floor(first+(t-source.s)/math.max(1,owned.end_ppq-source.s)*(following.ending-first)+.5)end
    return math.floor(first+(t-source.s)/math.max(1,source.e-source.s)*(last-first)+.5)
  end
  local domain_first=mapped(settings and settings.expression_start or source.s)
  local domain_last=mapped(following and owned.end_ppq or settings and settings.expression_end or source.e)
  if M.member(source.chan,settings)then
    for _,other in ipairs(stream.notes)do if other.chan==source.chan and other.s<domain_last and require('src.voice_lifetime').ending(stream,other,settings)>domain_first and not(group and other.slide_copy_group==group)then return nil,'The copy would share an expression channel with another sounding note.'end end
  end
  local index=stream:insert_fragment(source,first,last,pitch)
  local note=stream.notes[index+1]
  note.slide_copy_group=group
  if following then note.on.order,note.off.order=following.order_base+source.on.order,following.order_base+source.off.order;note.on.original_ppq,note.off.original_ppq=first,last end
  for i,entry in ipairs(owned)do
    local event=clone(entry.event)
    event.ppq=mapped(event.ppq)
    event.order=event.ppq<first and(-1000000000+#stream.events)or event.ppq==first and note.on.order-.5+i*.001 or #stream.events+1
    if following then event.order=following.order_base+entry.event.order end
    stream.events[#stream.events+1]=event
    if entry.shape then local metadata=clone(entry.shape);metadata.ppq=event.ppq;metadata.order=event.order+.0001;stream.events[#stream.events+1]=metadata end
  end
  stream.dirty=true;return index
end
return M
