-- @noindex
-- Store the editable score alongside its generated playback, in the take's
-- MIDI metadata. Never reconstruct a score from externally changed playback.
local M={}
local prefix=string.char(255,1)..'REAROLL_OVERLAP 1 '
local function unpack_events(raw)
  local out,pos,ppq={},1,0
  while pos<=#raw do
    local delta,flags,msg,nextpos=string.unpack('i4Bs4',raw,pos)
    ppq=ppq+delta;pos=nextpos;out[#out+1]={ppq=ppq,flags=flags,msg=msg}
  end
  return out
end
local function hex(raw)return(raw:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(raw)
  if #raw%2~=0 or raw:find('[^0-9a-f]')then return nil end
  return(raw:gsub('..',function(pair)return string.char(tonumber(pair,16))end))
end
local function fingerprint(events)
  local tokens={}
  for _,event in ipairs(events)do if #event.msg>0 and event.msg:sub(1,#prefix)~=prefix then
    -- Selection and metadata ordering may change during host sorting.
    tokens[#tokens+1]=string.pack('dBs4',event.ppq,event.flags&~1,event.msg)
  end end
  table.sort(tokens)
  local a,b=2166136261,5381
  for _,token in ipairs(tokens)do for i=1,#token do local byte=token:byte(i);a=((a~byte)*16777619)&0xffffffff;b=(b*33+byte)&0xffffffff end end
  return string.format('%08x%08x',a,b)
end
function M.encode(logical,playback,settings)
  local ok,events=pcall(unpack_events,playback);if not ok then return nil,'Invalid playback MIDI.'end
  if not pcall(unpack_events,logical)then return nil,'Invalid source MIDI.'end
  for _,event in ipairs(events)do if event.msg:sub(1,#prefix)==prefix then return nil,'Overlap playback is already encoded.'end end
  local range=settings.mpe_enabled and(settings.mpe_pitch_bend_range or 48)or(settings.pitch_bend_range or 2)
  if range<1 or range>96 or range%1~=0 then return nil,'Invalid bend range.'end
  local msg=prefix..range..' '..(settings.mpe_enabled and 1 or 0)..' '..(settings.mpe_zone=='upper'and 1 or 0)..' '..(settings.mpe_members or 15)..' '..fingerprint(events)..' '..hex(logical)
  return string.pack('i4Bs4',0,0,msg)..playback
end
function M.decode(raw)
  if not raw:find('REAROLL_OVERLAP',1,true)then return raw,nil end
  local ok,events=pcall(unpack_events,raw);if not ok then return nil,nil,'Invalid MIDI data.'end
  local saved
  for _,event in ipairs(events)do if event.msg:sub(1,#prefix)==prefix then
    if saved then return nil,nil,'Multiple overlap scores found. Playback was preserved.'end
    saved=event.msg:sub(#prefix+1)
  end end
  if not saved then return raw,nil end
  local range,mpe,zone,members,hash,encoded=saved:match('^(%d+) ([01]) ([01]) (%d+) (%x+) ([0-9a-f]*)$')
  range=tonumber(range);members=tonumber(members)
  if not members or members<1 or members>15 or not range or range<1 or range>96 or not hash or #hash~=16 then return nil,nil,'Invalid overlap score metadata. Playback was preserved.'end
  if fingerprint(events)~=hash then
    -- REAPER appends a source terminator if our existing one precedes a note-off
    -- at the same final tick. Accept only that exact duplicate, and only when
    -- removing it restores the original fingerprint of every other event.
    local tail=events[#events];local duplicate=false
    if tail and tail.flags==0 and tail.msg==string.char(176,123,0)then
      for i=#events-1,1,-1 do local event=events[i]
        if event.ppq~=tail.ppq then break end
        if event.flags==0 and event.msg==tail.msg then duplicate=true;break end
      end
    end
    local unchanged=false
    if duplicate then
      table.remove(events);unchanged=fingerprint(events)==hash
    end
    if not unchanged then return nil,nil,'Overlap playback changed outside ReaRoll. Its changes were preserved; automatic regeneration is disabled.'end
  end
  local source=unhex(encoded)
  if not source or not pcall(unpack_events,source)then return nil,nil,'Invalid saved overlap score.'end
  if source:find('REAROLL_OVERLAP',1,true)then return nil,nil,'Nested overlap score refused.'end
  return source,{mpe_enabled=mpe=='1',mpe_zone=zone=='1'and 'upper'or 'lower',mpe_members=members,pitch_bend_range=range,mpe_pitch_bend_range=range}
end
return M
