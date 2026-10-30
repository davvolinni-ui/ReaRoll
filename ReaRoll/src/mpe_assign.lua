-- @noindex
local E=require 'src.expression'
local Notes=require 'src.note_events'
local M={}
-- Allocate only newly drawn notes. Imported/recorded notes are never reassigned.
function M.new_channel(stream,first,last,settings,preferred)
  local lifetime=require('src.voice_lifetime').index(stream,settings)
  local candidates={};if E.member(preferred or -1,settings)then candidates[1]=preferred end
  for channel=0,15 do if E.member(channel,settings)and channel~=preferred then candidates[#candidates+1]=channel end end
  for _,channel in ipairs(candidates)do
    local sounding=lifetime({s=first,e=last,chan=channel,off={order=#stream.events+2}})
    local free=true
    for _,note in ipairs(stream.notes)do if note.chan==channel and note.s<sounding and lifetime(note)>first then free=false;break end end
    if free then for _,event in ipairs(stream.events)do if E.message(event,channel)and event.ppq>=first and event.ppq<=sounding then free=false;break end end end
    if free then return channel end
  end
  return nil,'No free MPE voice ('..tostring(settings.mpe_members or 15)..' configured). For an ordinary VSTi choose Standard MIDI in the toolbar; otherwise increase V (voices) in the expression toolbar to match the instrument.'
end
-- A freshly drawn note can outgrow the channel chosen for its initial length.
-- Ignore only its own expression; existing notes and recorded events reserve
-- their channels throughout the requested duration.
function M.draw_channel(stream,note,first,last,settings)
  local owned,notice=E.capture(stream,note,settings)
  if not owned then return nil,notice end
  local excluded={}
  for _,entry in ipairs(owned)do if not entry.shared and not entry.synthetic then
    excluded[entry.event]=true;if entry.shape then excluded[entry.shape]=true end
  end end
  local available={notes={},events={}}
  for _,other in ipairs(stream.notes)do if other~=note then available.notes[#available.notes+1]=other end end
  for _,event in ipairs(stream.events)do if not excluded[event]then available.events[#available.events+1]=event end end
  local channel=M.new_channel(available,first,last,settings,note.chan)
  if channel==nil then return nil,'No free MPE voice for this length. The note keeps its last valid length; shorten it or increase V (voices).'end
  return channel
end
function M.initialize(stream,note)
  for i,msg in ipairs({string.char(224|note.chan,0,64),string.char(208|note.chan,0),string.char(176|note.chan,74,64)})do
    stream.events[#stream.events+1]={ppq=note.s,flags=note.muted and 2 or 0,msg=msg,order=note.on.order-.5+i*.01}
  end
  stream.dirty=true
end
local function pedal_events(stream,channel,master)
  local events={}
  for _,e in ipairs(stream.events)do if not e.deleted and #e.msg>=3 and e.msg:byte(1)>>4==11 and (e.msg:byte(2)==64 or e.msg:byte(2)==121) and (e.msg:byte(1)&15==channel or e.msg:byte(1)&15==master)then events[#events+1]=e end end
  table.sort(events,function(a,b)if a.ppq~=b.ppq then return a.ppq<b.ppq end;return (a.order or 0)<(b.order or 0)end);return events
end
function M.plan(stream,indices,settings)
  local master=settings.mpe_zone=='upper' and 15 or 0
  local lifetime=require('src.voice_lifetime').index(stream,settings)
  local chosen,notes,occupied={},{},{}
  for _,index in ipairs(indices)do if not chosen[index]then local n=stream.notes[index+1];if not n then return nil,'A selected note is unavailable.'end;chosen[index]=true;notes[#notes+1]=n end end
  if #notes==0 then return nil,'Select notes to assign independent MPE voices.'end
  for _,n in ipairs(stream.notes)do if not chosen[n.index]and E.member(n.chan,settings)then occupied[n.chan]=occupied[n.chan]or {};occupied[n.chan][#occupied[n.chan]+1]={s=n.s,e=lifetime(n)}end end
  table.sort(notes,function(a,b)if a.s~=b.s then return a.s<b.s end;if a.pitch~=b.pitch then return a.pitch<b.pitch end;return a.index<b.index end)
  local assignments={}
  local function free(channel,first,last)
    for _,span in ipairs(occupied[channel]or {})do if span.s<last and span.e>first then return false end end
    return true
  end
  for _,n in ipairs(notes)do
    local has_expression=false
    if n.chan~=master then
      for _,event in ipairs(stream.events)do if E.message(event,n.chan)and event.ppq<=n.e then has_expression=true;break end end
      -- Shared multitimbral expression cannot be split into separate voices.
      local ownership_settings={expression_all_channels=true,mpe_zone=settings.mpe_zone,mpe_members=settings.mpe_members}
      local owned,notice={}
      if has_expression then owned,notice=E.capture(stream,n,ownership_settings)end
      if not owned then return nil,notice end
      has_expression=#owned>0
      if not E.member(n.chan,settings)and #owned>0 then return nil,'A note outside the configured zone already has expression. Keep its channel or edit the zone first.'end
    end
    local last=lifetime(n)
    local function available(candidate)
      if not free(candidate,n.s,last)then return false end
      if candidate==n.chan then return true end
      for _,event in ipairs(stream.events)do if E.message(event,candidate)and event.ppq>=n.s and event.ppq<=last then return false end end
      return true
    end
    local channel=E.member(n.chan,settings)and available(n.chan)and n.chan or nil
    if not channel and has_expression then return nil,'A recorded expression voice needs its current channel. Assign the other notes separately to preserve it.'end
    if not channel then for candidate=0,15 do if E.member(candidate,settings)and available(candidate)then channel=candidate;break end end end
    if channel~=nil and channel~=n.chan and require('src.slide_links').has(n)then return nil,'Assign MPE voices before drawing slides, or retain this note current channel to preserve its slide links.'end
    if channel==nil then return nil,'The MPE zone has no free voice for this selection, including notes held by sustain.'end
    if channel~=n.chan and n.chan~=master then
      local held=false
      for _,e in ipairs(pedal_events(stream,n.chan,master))do if e.msg:byte(1)&15==n.chan then
        if e.ppq<=n.s then held=e.msg:byte(2)==64 and e.msg:byte(3)>=64
        elseif e.ppq<last and e.msg:byte(2)==64 and e.msg:byte(3)>=64 then held=true;break end
      end end
      if held then return nil,'This voice has channel-specific sustain. Keep its channel to preserve the recorded pedal behavior.'end
    end
    occupied[channel]=occupied[channel]or {};occupied[channel][#occupied[channel]+1]={s=n.s,e=last}
    assignments[#assignments+1]={index=n.index,channel=channel,original=n.chan,first=n.s,last=n.e,pitch=n.pitch,velocity=n.vel}
  end
  return assignments
end
function M.begin(app,selected)
  local stream=Notes.read(app.take);if not stream then return nil,'MIDI is unavailable.'end
  local indices={};for _,n in ipairs(selected)do indices[#indices+1]=n.index end
  local assignments,notice=M.plan(stream,indices,app.settings);if not assignments then return nil,notice end
  return {take=app.take,raw=stream.original_raw,assignments=assignments,zone=app.settings.mpe_zone,members=app.settings.mpe_members}
end
function M.apply(app,draft,options)
  if not app.settings.mpe_enabled or app.take~=draft.take or app.settings.mpe_zone~=draft.zone or app.settings.mpe_members~=draft.members then return false,'The MPE source or setup changed. Prepare the assignment again.'end
  if reaper.ValidatePtr2 and not reaper.ValidatePtr2(0,draft.take,'MediaItem_Take*')then return false,'The source item is unavailable.'end
  local ok,raw=reaper.MIDI_GetAllEvts(draft.take,'')
  if not ok or raw~=draft.raw then return false,'MIDI changed externally. Prepare the assignment again.'end
  if reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(draft.take),'C_LOCK')~=0 then return false,'Unlock the item before assigning voices.'end
  app.edit:begin('ReaRoll: assign MPE voices',draft.take,options and options.preview)
  local a=app.edit.active;local changed=false
  for _,assignment in ipairs(draft.assignments)do if assignment.original~=assignment.channel then
    local n=a.notes[assignment.index+1]
    a.stream:set(assignment.index,{chan=assignment.channel});a.changed,a.note_changed=true,true;changed=true
    -- Fresh voices must not inherit an earlier note's bend, pressure or timbre.
    for _,msg in ipairs({string.char(224|assignment.channel,0,64),string.char(208|assignment.channel,0),string.char(176|assignment.channel,74,64)})do
      local initialized=false
      for _,event in ipairs(a.stream.events)do if not event.deleted and event.ppq==n.s and event.msg:byte(1)==msg:byte(1)and (msg:byte(1)>>4~=11 or event.msg:byte(2)==74)then initialized=true;break end end
      if not initialized then a.stream.events[#a.stream.events+1]={ppq=n.s,flags=0,msg=msg,order=-1000000000+#a.stream.events}end
    end
  end end
  if changed then a.stream.dirty=true end
  app.edit:finish();app.cache:rebuild()
  local wanted={};for _,assignment in ipairs(draft.assignments)do wanted[#wanted+1]={s=assignment.first,e=assignment.last,pitch=assignment.pitch,chan=assignment.channel,vel=assignment.velocity}end
  app:reselect_notes(wanted);return true
end
return M
