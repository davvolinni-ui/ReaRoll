-- @noindex
-- Plan continuous playback from ordinary overlapping melodic notes. The
-- editor's notes are inputs, never mutated by the playback planner.
local M={}
local Setup=require 'src.glide_setup'
function M.plan(notes,settings)
  notes=require('src.glide_connections').expand(notes,settings)
  local channels={};local out={voices={},connections={}}
  for _,n in ipairs(notes)do if not n.muted then
    local key=n.chan..'/'..Setup.key(Setup.get(n,settings))
    channels[key]=channels[key]or {};table.insert(channels[key],n)
  end end
  for _,list in pairs(channels)do
  local channel=list[1].chan;local config=Setup.get(list[1],settings)
  local range=Setup.range(config)
  local function bend(delta)
    if math.abs(delta)>range then return nil end
    return require('src.glide').value(delta,range)
  end
  local function value_at(voice,ppq)
    local value=8192
    for _,point in ipairs(voice.points)do if point.ppq>ppq then break end;value=point.value end
    return value
  end
  local function sounding_pitch(voice,value)
    return voice.pitch+(value-8192)/(value>=8192 and 8191 or 8192)*range
  end
    table.sort(list,function(a,b)if a.s~=b.s then return a.s<b.s end;return a.pitch<b.pitch end)
    local voice,previous
    for _,note in ipairs(list)do
      if voice and note.s<voice.e then
        if config.mpe_enabled and not require('src.expression').member(channel,config)then return nil,'MPE overlap glide needs a member voice channel, not the global channel.'end
        if note.s<=previous.s then return nil,'These notes start together on one channel. Use separate MPE voices for independent glides.'end
        local source
        for i=#voice.notes,1,-1 do if voice.notes[i].e>note.s then source=voice.notes[i];break end end
        local ending=math.min(source.e,note.e)
        local from,to=value_at(voice,note.s),bend(note.pitch-voice.pitch)
        if not to then return nil,'This connected phrase exceeds the instrument bend range. Match a wider range before generating glide.'end
        -- A new destination takes over from the pitch already sounding. Remove
        -- only the superseded future ramp, without restarting the carrier or
        -- jumping to the previous destination's nominal note pitch.
        if voice.connection and note.s<voice.connection.last then
          voice.connection.last=note.s;voice.connection.to_pitch=sounding_pitch(voice,from)
        end
        while #voice.points>0 and voice.points[#voice.points].ppq>=note.s do table.remove(voice.points)end
        local connection={mpe_enabled=config.mpe_enabled==true,setup=config,channel=channel,source=source,target=note,first=note.s,last=ending,from_pitch=sounding_pitch(voice,from),to_pitch=note.pitch}
        out.connections[#out.connections+1]=connection;voice.connection=connection
        local steps=math.min(128,math.max(1,math.floor(ending-note.s)))
        for i=0,steps do
          local t=i/steps
          voice.points[#voice.points+1]={ppq=math.floor(note.s+(ending-note.s)*t+.5),value=math.floor(from+(to-from)*t+.5)}
        end
        if note.e>=voice.e then voice.e=note.e;voice.release_velocity=note.release_velocity or 0;voice.release_note=note end
        voice.notes[#voice.notes+1]=note
      else
        voice={setup=config,s=note.s,e=note.e,pitch=note.pitch,channel=channel,velocity=note.vel,release_velocity=note.release_velocity or 0,notes={note},points={},release_note=note}
        out.voices[#out.voices+1]=voice
      end
      previous=note
    end
  end
  for i,voice in ipairs(out.voices)do for j=i+1,#out.voices do local other=out.voices[j]
    if voice.channel==other.channel and voice.s<other.e and other.s<voice.e and(#voice.notes>1 or #other.notes>1)then
      return nil,'This channel already carries another glide setup. Choose a free drawing channel so the existing glide stays unchanged.'
    end
  end end
  table.sort(out.voices,function(a,b)if a.s~=b.s then return a.s<b.s end;return a.channel<b.channel end)
  return out
end
function M.render(stream,settings)
  local plan,notice=M.plan(stream.notes,settings);if not plan then return nil,notice end
  local removed,channels,masters={},{},{}
  for _,voice in ipairs(plan.voices)do if #voice.notes>1 then
    channels[voice.channel]=true
    if voice.setup.mpe_enabled then masters[voice.setup.mpe_zone=='upper'and 15 or 0]=true end
    for _,note in ipairs(voice.notes)do removed[note.on]=true;removed[note.off]=true end
  end end
  for event_index,event in ipairs(stream.events)do if not event.deleted and #event.msg>=2 then
    local status,channel=event.msg:byte(1)>>4,event.msg:byte(1)&15
    if channels[channel]then
      if status==14 and event.msg:byte(2)==0 and event.msg:byte(3)==64 then removed[event]=true;local following=stream.events[event_index+1];if following and following.ppq==event.ppq and following.msg:sub(1,7)==string.char(255,15)..'CCBZ 'then removed[following]=true end
      elseif status==14 or status==10 or status==13 and event.msg:byte(2)~=0 or status==11 and event.msg:byte(2)==74 and event.msg:byte(3)~=64 then return nil,'Existing pitch or note expression needs explicit handling before overlap glide can use this voice.'end
    end
    if status==11 and event.msg:byte(2)==64 and event.msg:byte(3)>=64 and(channels[channel]or masters[channel])then return nil,'Sustain can keep another voice on this pitch channel. Release the pedal before using overlap glide.'end
  end end
  local events={}
  for _,event in ipairs(stream.events)do if not event.deleted and not removed[event]then events[#events+1]={ppq=event.ppq,flags=event.flags,msg=event.msg,order=event.order or #events+1,source_end=event==stream.source_end}end end
  local function add(ppq,msg,order)events[#events+1]={ppq=ppq,flags=0,msg=msg,order=order}end
  for _,voice in ipairs(plan.voices)do if #voice.notes>1 then
    add(voice.s,string.char(224|voice.channel,0,64),-30)
    add(voice.s,string.char(144|voice.channel,voice.pitch,voice.velocity),-10)
    for _,point in ipairs(voice.points)do add(point.ppq,string.char(224|voice.channel,point.value&127,(point.value>>7)&127),-20)end
    local last=voice.release_note or voice.notes[#voice.notes]
    local release=last.off and last.off.msg:byte(3)or voice.release_velocity
    add(voice.e,string.char(128|voice.channel,voice.pitch,release),-40)
    add(voice.e,string.char(224|voice.channel,0,64),-30)
  end end
  table.sort(events,function(a,b)if a.ppq~=b.ppq then return a.ppq<b.ppq end;if(a.source_end==true)~=(b.source_end==true)then return b.source_end==true end;return a.order<b.order end)
  local chunks,previous={},0
  for _,event in ipairs(events)do chunks[#chunks+1]=string.pack('i4Bs4',event.ppq-previous,event.flags,event.msg);previous=event.ppq end
  return table.concat(chunks),plan
end
return M
