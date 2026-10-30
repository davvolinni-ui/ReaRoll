-- @noindex
-- Recognize recorded MPE without assigning channels or rewriting the source.
local Take=require 'src.take'
local Notes=require 'src.note_events'
local M={}
local function member(channel,zone,count)
  return zone=='upper'and channel>=15-count and channel<15 or zone=='lower'and channel>0 and channel<=count
end
function M.inspect(stream)
  if not stream or stream.overlap_config or stream.overlap_error then return nil end
  local channels,channel_count={},0
  for _,note in ipairs(stream.notes)do
    if not channels[note.chan]then channels[note.chan]={notes={},dimensions={}};channel_count=channel_count+1 end
    local notes=channels[note.chan].notes;notes[#notes+1]=note
  end
  for _,voice in pairs(channels)do
    table.sort(voice.notes,function(a,b)return a.s<b.s end)
    voice.position=1;local ending=-math.huge
    for _,note in ipairs(voice.notes)do
      if note.s<ending then voice.polyphonic=true end
      ending=math.max(ending,note.e)
    end
  end
  local rpn,zones,ranges,managers={},{},{},{}
  local programmed=false
  for order,event in ipairs(stream.events)do if not event.deleted and #event.msg>=2 then
    local status=event.msg:byte(1);local kind,ch=status>>4,status&15
    if status<240 then
      local cc,value=event.msg:byte(2),event.msg:byte(3)
      if kind==11 and value then
        local state=rpn[ch]or {msb=127,lsb=127};rpn[ch]=state
        if cc==101 then state.msb=value
        elseif cc==100 then state.lsb=value
        elseif cc==99 or cc==98 then state.msb=127;state.lsb=127
        elseif cc==6 and state.msb==0 then
          if state.lsb==6 and(ch==0 or ch==15)and value<=15 then
            zones[ch]=value
            for channel=0,15 do if member(channel,ch==0 and 'lower'or 'upper',value)then ranges[channel]={semitones=48,cents=0,order=order}end end
          elseif state.lsb==0 then ranges[ch]={semitones=value,cents=0,order=order}end
        elseif cc==38 and state.msb==0 and state.lsb==0 and ranges[ch]then ranges[ch].cents=value;ranges[ch].order=order end
        if(ch==0 or ch==15)and(cc==64 or cc==74)then managers[ch]=true end
      end
      local voice=channels[ch]
      if voice then
        if kind==12 or kind==11 and(cc==0 or cc==32)then programmed=true end
        local dimension=kind==14 and 'pitch'or kind==13 and 'pressure'or kind==11 and cc==74 and 'timbre'
        if dimension then
          -- Ignore unrelated automation outside every note on this channel.
          while voice.notes[voice.position]and voice.notes[voice.position].e<event.ppq do voice.position=voice.position+1 end
          local note=voice.notes[voice.position]
          if note and event.ppq>=note.s and event.ppq<=note.e then voice.dimensions[dimension]=true end
        end
      end
    end
  end end
  local zone,count,explicit
  if(zones[0]or 0)>0 and(zones[15]or 0)>0 then return nil end -- Two zones need separate editing contexts.
  if(zones[0]or 0)>0 then zone,count,explicit='lower',zones[0],true
  elseif(zones[15]or 0)>0 then zone,count,explicit='upper',zones[15],true
  elseif zones[0]~=nil or zones[15]~=nil then return nil -- Recorded MPE-off must not be guessed back on.
  else
    if channel_count==0 or programmed or channels[0]and channels[15]or channel_count==1 and(channels[0]or channels[15])then return nil end
    zone=channels[0]and 'upper'or channels[15]and 'lower'or managers[15]and not managers[0]and 'upper'or 'lower'
    count=15
    local expressive,rich=0,false
    for _,voice in pairs(channels)do
      if voice.polyphonic then return nil end
      local d=voice.dimensions
      if next(d)then expressive=expressive+1 end
      if d.timbre and(d.pitch or d.pressure)then rich=true end
    end
    -- Channel numbers alone do not distinguish MPE from ordinary multitimbral MIDI.
    if expressive<2 and not rich then return nil end
  end
  local range,latest
  for ch in pairs(channels)do
    if not member(ch,zone,count)then return nil end
  end
  -- The last member-channel RPN 0 applies to the whole zone (MPE 1.0, 2.4).
  for ch,value in pairs(ranges)do
    if member(ch,zone,count)and(not latest or value.order>latest.order)then
      latest=value
    end
  end
  if latest then
    if latest.cents~=0 or latest.semitones<1 or latest.semitones>96 then return nil end
    range=latest.semitones
  end
  return {zone=zone,members=count,range=range or 48,explicit=explicit==true}
end

local keys={'mpe_enabled','mpe_zone','mpe_members','mpe_pitch_bend_range','mpe_pitch_edit','note_expression_overlay','edit_all_channels'}
function M.restore(app)
  local state=app.mpe_auto
  if not state then return end
  for _,key in ipairs(keys)do app.settings[key]=state.settings[key]end
  app.expression_editor_open=state.expression_editor_open
  app.expression_dimension=state.expression_dimension
  app.expression_group_open=state.expression_group_open
  app.mpe_previous_view=state.previous_view
  app.expression_direct_cache=nil;app.expression_group_draft=nil
  app.mpe_auto=nil
end
function M.manual(app)
  if not app.take then return end
  app.mpe_manual_takes=app.mpe_manual_takes or {};app.mpe_manual_takes[app.take]=true
  app.mpe_auto=nil
end
function M.poll(app)
  if app.gesture or app.edit and app.edit.active or app.expression_direct_gesture or app.transform_preview
    or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint or app.multi_notes.drag)then return end
  if app.mpe_auto and app.mpe_auto.take~=app.take then M.restore(app)end
  if not Take.valid(app.take) or app.mpe_manual_takes and app.mpe_manual_takes[app.take]then return end
  if app.mpe_auto and app.mpe_auto.take==app.take then return end
  local ran,ok,hash=pcall(reaper.MIDI_GetHash,app.take,false,'')
  if not ran or not ok then return end
  local cached=app.mpe_detection_cache
  if cached and cached.take==app.take and cached.hash==hash then return end
  local read,stream=pcall(Notes.read,app.take)
  if not read or not stream then return end
  app.mpe_detection_cache={take=app.take,hash=hash}
  local found=M.inspect(stream)
  if not found then return end
  local state={take=app.take,settings={},expression_editor_open=app.expression_editor_open,expression_dimension=app.expression_dimension,expression_group_open=app.expression_group_open,previous_view=app.mpe_previous_view}
  for _,key in ipairs(keys)do state.settings[key]=app.settings[key]end
  app.settings.mpe_zone=found.zone;app.settings.mpe_members=found.members;app.settings.mpe_pitch_bend_range=found.range
  app.settings.edit_all_channels=true;app.settings.note_expression_overlay=true
  local enabled=require('src.midi_mode').set(app,true,true)
  if enabled then app.mpe_auto=state end
end
return M
