-- @noindex
-- Freeze controller ownership before a note group moves. Shared events are
-- handled once; a shared pedal stays put unless its whole passage is moving.
local M={}
local function clone(value)local out={};for k,v in pairs(value)do out[k]=v end;return out end
local function shape(event)return event and not event.deleted and event.msg:sub(1,7)==string.char(255,15)..'CCBZ 'end
local protected={[0]=true,[6]=true,[32]=true,[38]=true,[96]=true,[97]=true,[98]=true,[99]=true,[100]=true,[101]=true}
local function controller(event)
  if event.deleted or #event.msg<2 then return false end
  local status=event.msg:byte(1)>>4
  if status==11 then local cc=event.msg:byte(2);return #event.msg>=3 and cc<120 and not protected[cc] end
  return status==13 or status==14 and #event.msg>=3
end
local function managed(event,note,settings)
  local effective=require('src.slide_links').expression_settings(note,settings)
  return effective and require('src.expression').message(event,note.chan)and(not effective.expression_pitch_only or event.msg:byte(1)>>4==14)
end
local function translated(note,target)
  return target and target.e-target.s==note.e-note.s and(target.s~=note.s or target.chan~=note.chan)
end
function M.prepare(stream,changes,settings,copy)
  if not(settings and settings.cc_follows_notes==true)then return nil end
  local plan={events={},voices={},destinations={},copy=copy,stream=stream,order_base=#stream.events+1}
  local selected={}
  for _,change in ipairs(changes)do local note=stream.notes[change.index+1];if note then
    local v=change.values or {};plan.destinations[note.index]={s=math.floor((v.s or note.s)+.5),e=math.floor((v.e or note.e)+.5),chan=v.chan or note.chan};selected[note.index]=true
  end end
  local life=require('src.voice_lifetime').index(stream,settings)
  local master=settings.mpe_enabled and(settings.mpe_zone=='upper'and 15 or 0)or nil
  local cycles,held={},{}
  for _,event in ipairs(stream.events)do if not event.deleted and #event.msg>=3 and event.msg:byte(1)>>4==11 then
    local ch,cc=event.msg:byte(1)&15,event.msg:byte(2)
    if cc==120 or cc==121 then held[ch]=nil end
    if cc==64 then
    if event.msg:byte(3)>=64 then
      if not held[ch]then held[ch]={first=event.ppq,events={},channel=ch}end
      held[ch].events[#held[ch].events+1]=event
    elseif held[ch]then local cycle=held[ch];held[ch]=nil;cycle.last=event.ppq;cycle.events[#cycle.events+1]=event;cycles[#cycles+1]=cycle end
    end
  end end
  local assignments={}
  for _,cycle in ipairs(cycles)do
    local delta,channel,complete,affected=nil,nil,true,false
    for _,note in ipairs(stream.notes)do if(note.chan==cycle.channel or cycle.channel==master)and note.s<cycle.last and life(note)>cycle.first then
      affected=true;local target=plan.destinations[note.index]
      if not target or not(copy or translated(note,target))or target.e-target.s~=note.e-note.s then complete=false;break end
      local shift=target.s-note.s;local ch=cycle.channel==master and master or target.chan
      if delta and(delta~=shift or channel~=ch)then complete=false;break end
      delta,channel=shift,ch
    end end
    if affected and complete and(copy or delta~=0 or channel~=cycle.channel)then
      for _,event in ipairs(cycle.events)do assignments[event]={ppq=event.ppq+delta,chan=channel}end
    end
  end
  for i,event in ipairs(stream.events)do if controller(event)then
    local target=assignments[event];local ch=event.msg:byte(1)&15;local pedal=event.msg:byte(1)>>4==11 and event.msg:byte(2)==64
    if not pedal then
      for _,note in ipairs(stream.notes)do local destination=plan.destinations[note.index]
        if destination and(copy or translated(note,destination))and destination.e-destination.s==note.e-note.s and ch==note.chan and event.ppq>=note.s and event.ppq<note.e and not managed(event,note,settings)then
          target={ppq=event.ppq+destination.s-note.s,chan=destination.chan};break
        end
      end
    end
    if target then
      plan.events[#plan.events+1]={event=event,ppq=target.ppq,chan=target.chan,shape=shape(stream.events[i+1])and stream.events[i+1].ppq==event.ppq and stream.events[i+1]or nil}
    end
  end end
  -- Evaluate the resulting sounding lifetimes on a detached view. This also
  -- covers moving a single MPE note while its shared pedal remains stationary.
  local view={notes={},events={}}
  for _,note in ipairs(stream.notes)do local n=clone(note);local destination=plan.destinations[note.index]
    if not copy and destination then n.s,n.e,n.chan=destination.s,destination.e,destination.chan end
    view.notes[#view.notes+1]=n
  end
  for _,event in ipairs(stream.events)do
    if not copy and assignments[event]then local e=clone(event);e.order=plan.order_base+event.order;e.ppq=assignments[event].ppq;e.msg=string.char((e.msg:byte(1)&240)|assignments[event].chan)..e.msg:sub(2);view.events[#view.events+1]=e
    else view.events[#view.events+1]=event end
  end
  if copy then for event,target in pairs(assignments)do local e=clone(event);e.order=plan.order_base+event.order;e.ppq=target.ppq;e.msg=string.char((e.msg:byte(1)&240)|target.chan)..e.msg:sub(2);view.events[#view.events+1]=e end end
  local ending=require('src.voice_lifetime').index(view,settings)
  for _,note in ipairs(stream.notes)do local destination=plan.destinations[note.index];if destination then
    local n=clone(note);n.s,n.e,n.chan=destination.s,destination.e,destination.chan
    if copy or destination.s~=note.s or destination.e~=note.e or destination.chan~=note.chan then n.off=clone(note.off);n.off.order=plan.order_base+note.off.order end
    destination.sounding_end=ending(n)
    plan.voices[note.index]={ending=destination.sounding_end,old_ending=life(note),order_base=plan.order_base}
    if copy then
      local effective=require('src.slide_links').expression_settings(note,settings)
      if effective then
        local cohort,notice
        if effective.expression_pitch_only then cohort,notice=require('src.slide_links').cohort(stream,note,selected);if not cohort then return false,notice end end
        local owned;owned,notice=require('src.expression').capture(stream,note,effective,cohort)
        if not owned then return false,notice end
        plan.voices[note.index].owned=owned
      end
    end
  end end
  return plan
end
function M.copy_note(plan,source,note)
  if not plan then return end
  note.on.order,note.off.order=plan.order_base+source.on.order,plan.order_base+source.off.order
  note.on.original_ppq,note.off.original_ppq=note.s,note.e
end
function M.bounds(app,plan)
  if not plan then return true end
  local first=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)
  local last=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
  for _,entry in ipairs(plan.events)do if entry.ppq<first or entry.ppq>last then return false,'The notes and their controllers do not fit inside this MIDI item.'end end
  if app.settings.mpe_enabled then for _,destination in pairs(plan.destinations)do if destination.sounding_end==math.huge or destination.sounding_end>last then return false,'The moved MPE voice needs a sustain release inside this MIDI item.'end end end
  return true
end
function M.apply(plan)
  if not plan then return end
  for _,entry in ipairs(plan.events)do
    local event=entry.event
    if plan.copy then event=clone(event);plan.stream.events[#plan.stream.events+1]=event end
    event.order=plan.order_base+entry.event.order
    event.ppq=entry.ppq;event.msg=string.char((event.msg:byte(1)&240)|entry.chan)..event.msg:sub(2)
    if entry.shape then local metadata=entry.shape
      if plan.copy then metadata=clone(metadata);plan.stream.events[#plan.stream.events+1]=metadata end
      metadata.ppq=event.ppq;metadata.order=event.order+.1
    end
  end
  if #plan.events>0 then plan.stream.dirty=true end
end
return M
