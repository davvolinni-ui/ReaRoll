-- @noindex
-- Keep note-on/off pairs explicit. REAPER's high-level note API can re-pair
-- overlapping notes even when only velocity, mute, or selection is changed.
local Notes={}; Notes.__index=Notes
local pairing_key='P_EXT:ReaRollNotePairs'

function Notes.get_pairing_state(take)
  local ok,state=reaper.GetSetMediaItemTakeInfo_String(take,pairing_key,'',false)
  return ok and state or ''
end
function Notes.set_pairing_state(take,state)
  state=state or ''
  local ok=reaper.GetSetMediaItemTakeInfo_String(take,pairing_key,state,true)
  -- REAPER reports false when deleting an already absent P_EXT value.
  -- An empty value read back means the requested clear succeeded.
  return ok or (state=='' and Notes.get_pairing_state(take)=='')
end

local function kind(msg)
  if #msg<3 then return end
  local status=msg:byte(1)>>4
  if status==8 or status==9 and msg:byte(3)==0 then return 'off' end
  if status==9 then return 'on' end
end
local function key(event)
  return (event.msg:byte(1)&15)..':'..event.msg:byte(2)..':'..(event.flags&3)
end
local function ordered(a,b)
  if a.ppq~=b.ppq then return a.ppq<b.ppq end
  local ap,bp=a.kind=='off' and 0 or 1,b.kind=='off' and 0 or 1
  if ap~=bp then return ap<bp end
  return a.order<b.order
end
local function copy_note(n)
  return {index=n.index,s=n.s,e=n.e,chan=n.chan,pitch=n.pitch,vel=n.vel,muted=n.muted,selected=n.selected}
end
Notes.copy_note=copy_note

function Notes.read(take)
  local ok,raw=reaper.MIDI_GetAllEvts(take,''); if not ok then return nil end
  local self=setmetatable({take=take,events={},notes={},dirty=false},Notes)
  local position,pos=0,1
  while pos<=#raw do
    local offset,flags,msg,next_pos=string.unpack('i4Bs4',raw,pos)
    position=position+offset; pos=next_pos
    self.events[#self.events+1]={ppq=position,flags=flags,msg=msg,kind=kind(msg),order=#self.events+1}
  end
  local chronological={}; for _,event in ipairs(self.events) do chronological[#chronological+1]=event end
  table.sort(chronological,ordered)
  local note_events={}; for _,event in ipairs(chronological) do if event.kind then note_events[#note_events+1]=event end end
  -- MIDI contains no per-note IDs. Persist ambiguous pairs with the take,
  -- without adding MIDI messages or changing channels. A notes-only hash
  -- invalidates this metadata after external note edits, but not CC edits.
  local pairs_by_on
  local saved_hash,encoded=Notes.get_pairing_state(take):match('^1 ([^\n]+)\n(.*)$')
  if saved_hash then
    local hashed,hash=reaper.MIDI_GetHash(take,true,'')
    if hashed and hash==saved_hash then
      pairs_by_on={}
      for on_index,off_index in encoded:gmatch('(%d+):(%d+)') do pairs_by_on[tonumber(on_index)]=tonumber(off_index) end
    end
  end
  local matched,used={},{}
  for on_index,off_index in pairs(pairs_by_on or {}) do
    local on,off=note_events[on_index],note_events[off_index]
    if on and off and on.kind=='on' and off.kind=='off' and key(on)==key(off) and on.ppq<off.ppq and not used[off] then matched[on]=off; used[off]=true end
  end
  local pending={}
  for _,event in ipairs(chronological) do
    if event.kind=='on' and not matched[event] then
      local k=key(event); local queue=pending[k] or {first=1,last=0}; pending[k]=queue
      queue.last=queue.last+1; queue[queue.last]=event
    elseif event.kind=='off' and not used[event] then
      local queue=pending[key(event)]
      if queue and queue.first<=queue.last then
        local on=queue[queue.first]; queue[queue.first]=nil; queue.first=queue.first+1; matched[on]=event
      end
    end
  end
  for _,on in ipairs(self.events) do local off=matched[on]; if off then
    self.notes[#self.notes+1]={index=#self.notes,s=on.ppq,e=off.ppq,chan=on.msg:byte(1)&15,pitch=on.msg:byte(2),vel=on.msg:byte(3),selected=(on.flags&1)~=0,muted=(on.flags&2)~=0,on=on,off=off,notation={}}
  end end
  -- Keep REAPER's notation attached when its note moves or changes pitch.
  local at_start={}
  for _,n in ipairs(self.notes) do at_start[n.s..':'..n.chan..':'..n.pitch]=n end
  for _,event in ipairs(self.events) do
    if event.msg:sub(1,2)==string.char(0xFF,0x0F) then
      local chan,pitch=event.msg:match('^..NOTE (%d+) (%d+) ')
      local n=chan and at_start[event.ppq..':'..chan..':'..pitch]
      if n then n.notation[#n.notation+1]=event end
    end
  end
  return self
end

function Notes:set(index,values)
  local n=self.notes[index+1]; if not n then return false end
  local changed=false
  for k,value in pairs(values) do if n[k]~=value then n[k]=value; changed=true end end
  if not changed then return false end
  n.s,n.e=math.floor(n.s+.5),math.floor(n.e+.5)
  n.on.ppq,n.off.ppq=n.s,n.e
  n.on.msg=string.char(0x90|n.chan,n.pitch,n.vel)..n.on.msg:sub(4)
  n.off.msg=string.char((n.off.msg:byte(1)&0xF0)|n.chan,n.pitch,n.off.msg:byte(3))..n.off.msg:sub(4)
  if values.selected~=nil or values.muted~=nil then
    local flags=(n.selected and 1 or 0)|(n.muted and 2 or 0)
    n.on.flags=(n.on.flags&~3)|flags; n.off.flags=(n.off.flags&~3)|flags
  end
  for _,event in ipairs(n.notation) do
    event.ppq=n.s; event.msg=event.msg:gsub('^(..NOTE )%d+ %d+ ',function(prefix)return prefix..n.chan..' '..n.pitch..' ' end)
  end
  self.dirty=true; return true
end

function Notes:insert(s,e,pitch,vel,chan,selected,muted)
  s,e=math.floor(s+.5),math.floor(e+.5); chan=chan or 0
  local flags=(selected~=false and 1 or 0)|(muted and 2 or 0)
  local on={ppq=s,flags=flags,msg=string.char(0x90|chan,pitch,vel),kind='on',order=#self.events+1}
  local off={ppq=e,flags=flags,msg=string.char(0x80|chan,pitch,0),kind='off',order=#self.events+2}
  self.events[#self.events+1]=on; self.events[#self.events+1]=off
  local index=#self.notes
  self.notes[index+1]={index=index,s=s,e=e,chan=chan,pitch=pitch,vel=vel,selected=selected~=false,muted=muted or false,on=on,off=off,notation={}}
  self.dirty=true; return index
end

function Notes:delete(index)
  local n=self.notes[index+1]; if not n then return false end
  n.on.deleted,n.off.deleted=true,true
  for _,event in ipairs(n.notation) do event.deleted=true end
  table.remove(self.notes,index+1)
  for i=index+1,#self.notes do self.notes[i].index=i-1 end
  self.dirty=true; return true
end

function Notes:write()
  if not self.dirty then return true end
  local events={}; for _,event in ipairs(self.events) do if not event.deleted then events[#events+1]=event end end
  table.sort(events,ordered)
  local chunks,position={},0
  for _,event in ipairs(events) do
    local offset=event.ppq-position
    while offset>0x7FFFFFFF or offset< -0x80000000 do
      local step=offset>0 and 0x7FFFFFFF or -0x80000000
      chunks[#chunks+1]=string.pack('i4Bs4',step,0,''); offset=offset-step
    end
    chunks[#chunks+1]=string.pack('i4Bs4',offset,event.flags,event.msg)
    position=event.ppq
  end
  local raw=table.concat(chunks)
  -- Release any native DisableSort before writing our already sorted buffer.
  reaper.MIDI_Sort(self.take)
  if not reaper.MIDI_SetAllEvts(self.take,raw) then return false end
  local note_events={}; for _,event in ipairs(events) do if event.kind then note_events[#note_events+1]=event end end
  local indices={}; for i,event in ipairs(note_events) do indices[event]=i end
  local pairings={}; for _,n in ipairs(self.notes) do pairings[indices[n.on]]=indices[n.off] end
  local state=''
  if self:overlap_count()>0 then
    local hashed,hash=reaper.MIDI_GetHash(self.take,true,''); if not hashed then return false end
    local encoded={}
    for i,event in ipairs(note_events) do if pairings[i] then encoded[#encoded+1]=i..':'..pairings[i] end end
    state='1 '..hash..'\n'..table.concat(encoded,' ')
  end
  if not Notes.set_pairing_state(self.take,state) then return false end
  self.dirty=false; return true
end

function Notes:overlap_count()
  local groups,count={},0
  for _,n in ipairs(self.notes) do local k=n.chan..':'..n.pitch; groups[k]=groups[k] or {}; groups[k][#groups[k]+1]=n end
  for _,group in pairs(groups) do
    table.sort(group,function(a,b) if a.s~=b.s then return a.s<b.s end; return a.index<b.index end)
    local ending=-math.huge
    for _,n in ipairs(group) do if n.s<ending then count=count+1 end; ending=math.max(ending,n.e) end
  end
  return count
end
return Notes
