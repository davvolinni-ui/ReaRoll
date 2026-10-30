-- @noindex
local M={prefix=string.char(255,1)..'REAROLL_ATTR ',render=string.char(255,1)..'REAROLL_ATTR_OUTPUT1 '}
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)if #s%2~=0 or s:find('[^%da-f]')then return end;return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
function M.get(note)
 local out={}
 for _,event in ipairs(note.notation or {})do
  if not event.deleted and event.msg:sub(1,#M.prefix)==M.prefix then
   local encoded=event.msg:match('^..REAROLL_ATTR %d+ %d+ ([%da-f]+)$')
   local raw=encoded and unhex(encoded);local map=raw and require('src.instrument_map').decode(raw)
   if map and #map.articulations==2 then local a=map.articulations[1];out[a.group or 'Playing style']={entry=a,default=map.articulations[2],event=event}end
  end
 end
 return out
end
function M.bind(stream,note,entry,default)
 local group=entry.group or 'Playing style'
 local old=M.get(note)[group];if old then old.event.deleted=true end
 local Map=require 'src.instrument_map';local map=Map.new();map.articulations={entry,default}
 local event={ppq=note.s,flags=0,msg=M.prefix..note.chan..' '..note.pitch..' '..hex(Map.encode(map)),order=#stream.events+1}
 stream.events[#stream.events+1]=event;note.notation[#note.notation+1]=event;stream.dirty=true
end
function M.strip(events)
 local markers,remove={},{}
 for _,event in ipairs(events)do if event.msg:sub(1,#M.render)==M.render then markers[#markers+1]=event end end
 for _,marker in ipairs(markers)do
  for tick,flags,payload in marker.msg:sub(#M.render+1):gmatch('(%-?%d+):(%d+):([%da-f]+);')do
   local msg=unhex(payload);local found
   for _,event in ipairs(events)do if event.ppq==tonumber(tick)and event.msg==msg and event.flags==tonumber(flags)then
    if found then return nil,'Articulation output is ambiguous after an external edit.'end;found=event
   end end
   if not found then return nil,'Generated articulation output changed externally. Restore or undo that edit before editing note assignments.'end
   remove[found]=true
  end
  remove[marker]=true
 end
 local clean={};for _,event in ipairs(events)do if not remove[event]then clean[#clean+1]=event end end
 return clean
end
local function signature(entry)
 local copy={};for k,v in pairs(entry)do copy[k]=v end;copy.name='';copy.group=nil;copy.channel=-1
 local map=require('src.instrument_map').new();map.articulations={copy};return require('src.instrument_map').encode(map)
end
function M.render_events(stream)
 local groups={};local attributes={}
 for _,note in ipairs(stream.notes)do
  local assigned=M.get(note);attributes[note]=assigned
  for group,value in pairs(assigned)do groups[group]=groups[group]or {};groups[group][note.chan]=value.default end
 end
 if not next(groups)then return {}end
 if stream.overlap_config then return nil,'Note articulations cannot yet be combined with rendered Overlap Glide.'end
 local emitted={};local record={};local seen={};local slots={}
 local first=reaper.MIDI_GetPPQPosFromProjQN(stream.take,require('src.take').item_start_qn(stream.take))
 local ending=reaper.MIDI_GetPPQPosFromProjQN(stream.take,require('src.take').item_end_qn(stream.take))
 local function emit(ppq,msg,priority)
  if ppq<first or ppq>=ending then return false end
  local key=ppq..':'..hex(msg);if seen[key]then return true end;seen[key]=true
  local status=msg:byte(1);local slot=ppq..':'..status..':'..((status&0xf0)==0xc0 and ''or msg:byte(2))
  if slots[slot]and slots[slot]~=msg then return false end;slots[slot]=msg
  -- Identical authored switches are already sufficient; conflicting ones refuse.
  for _,event in ipairs(stream.events)do if not event.deleted and event.ppq==ppq then
   local a,b=event.msg:byte(1),msg:byte(1)
   if event.msg==msg then return true end
   if a==b and (b&0xf0==0xc0 or b&0xf0==0xb0 and event.msg:byte(2)==msg:byte(2))then return false end
  end end
  local event={ppq=ppq,flags=0,msg=msg,order=priority};emitted[#emitted+1]=event
  record[#record+1]=ppq..':0:'..hex(msg)..';';return true
 end
 local directions=require('src.articulation_events').read(stream)
 for group,defaults in pairs(groups)do
  local voices={}
  for _,note in ipairs(stream.notes)do if not note.muted and defaults[note.chan]then
   local default=defaults[note.chan]
   local attr=attributes[note][group];local entry=attr and attr.entry or default
   -- A persistent direction supplies the unassigned baseline when present.
   if not attr then
    local active
    for _,row in ipairs(directions)do if row.channel==note.chan and row.group==group and row.ppq<=note.s then active=row end end
    if active then
     for _,definition in ipairs({default})do if definition.name==active.name then entry=definition end end
     -- Unresolved direction definitions are refused instead of guessed.
     if active.name~=entry.name then return nil,'An unassigned note follows a different timeline articulation. Use one articulation workflow for this group.'end
    end
   end
   if entry.channel>=0 and entry.channel~=note.chan then return nil,'Note articulations must use the note channel. Set the map output to Follows selection.'end
   local voice=voices[note.chan]or {};voices[note.chan]=voice
   voice[#voice+1]={note=note,entry=entry,key=signature(entry)}
  end end
  for channel,voice in pairs(voices)do
   table.sort(voice,function(a,b)return a.note.s<b.note.s end)
   for i,value in ipairs(voice)do
    local note,entry=value.note,value.entry
    local start_q=reaper.MIDI_GetProjQNFromPPQPos(stream.take,note.s)-entry.lead
    local start=math.floor(reaper.MIDI_GetPPQPosFromProjQN(stream.take,start_q)+.5)
    for j=1,i-1 do local previous=voice[j]
     if previous.note.e>start and previous.key~=value.key then return nil,'Overlapping notes on the same channel require the same articulation. Use separate instrument channels for different playing styles.'end
    end
    local messages={}
    if entry.bank_msb~=nil then messages[#messages+1]=string.char(0xb0|channel,0,entry.bank_msb);messages[#messages+1]=string.char(0xb0|channel,32,entry.bank_lsb)end
    messages[#messages+1]=entry.kind=='note'and string.char(0x90|channel,entry.number,entry.value)or entry.kind=='cc'and string.char(0xb0|channel,entry.number,entry.value)or string.char(0xc0|channel,entry.number)
    for order,msg in ipairs(messages)do if not emit(start,msg,-100000+order)then return nil,'An articulation switch conflicts with MIDI or extends outside the item.'end end
    if entry.kind=='note'then
     local last=math.max(start+1,math.floor(reaper.MIDI_GetPPQPosFromProjQN(stream.take,start_q+entry.length)+.5))
     for _,other in ipairs(stream.notes)do if other.chan==channel and other.pitch==entry.number and other.s<last and other.e>start then return nil,'The articulation keyswitch overlaps a musical note.'end end
     if not emit(last,string.char(0x80|channel,entry.number,0),-100001)then return nil,'Keyswitch release extends outside the MIDI item.'end
    end
   end
  end
 end
 emitted[#emitted+1]={ppq=first,flags=0,msg=M.render..table.concat(record),order=-200000}
 return emitted
end
function M.selection_label(stream,selected,group)
 local label
 for _,cached in ipairs(selected)do local note=stream.notes[cached.index+1]
  local value=note and M.get(note)[group];local name=value and value.entry.name or 'Default'
  if label and label~=name then return 'Mixed'end;label=name
 end
 return label or 'No notes selected'
end
return M
