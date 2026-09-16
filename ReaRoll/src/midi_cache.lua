-- @noindex
local Cache={}; Cache.__index=Cache
local function detect_overlaps(take)
  if not take or not reaper.MIDI_GetAllEvts then return 0 end
  local ok,raw=reaper.MIDI_GetAllEvts(take,''); if not ok or type(raw)~='string' then return 0 end
  local events,position,pos={},0,1
  while pos<=#raw do
    local unpacked,offset,flags,msg,next_pos=pcall(string.unpack,'i4Bs4',raw,pos)
    if not unpacked then break end
    position=position+offset; pos=next_pos
    if #msg>=3 then local status=msg:byte(1)>>4; local velocity=msg:byte(3)
      if status==8 or status==9 then events[#events+1]={ppq=position,key=tostring(msg:byte(1)&0x0F)..':'..tostring(msg:byte(2)),on=status==9 and velocity>0} end
    end
  end
  local active,overlaps,i={},0,1
  while i<=#events do
    local j=i; while j<=#events and events[j].ppq==events[i].ppq do j=j+1 end
    for k=i,j-1 do if not events[k].on then active[events[k].key]=nil end end
    for k=i,j-1 do if events[k].on then if active[events[k].key] then overlaps=overlaps+1 else active[events[k].key]=true end end end
    i=j
  end
  return overlaps
end
Cache.detect_overlaps=detect_overlaps
function Cache.new() return setmetatable({take=nil,hash=nil,notes={},overlap_count=0,dirty=true,next_poll=0},Cache) end
function Cache:set_take(take) if self.take==take then return end; self.take,self.hash,self.notes,self.overlap_count,self.dirty,self.next_poll=take,nil,{},0,true,0 end
function Cache:invalidate() self.dirty=true; self.hash=nil end
function Cache:rebuild()
  self.notes={}; if not self.take then self.dirty=false return end
  local _,count=reaper.MIDI_CountEvts(self.take)
  for i=0,count-1 do
    local ok,sel,muted,s,e,chan,pitch,vel=reaper.MIDI_GetNote(self.take,i)
    if ok then self.notes[#self.notes+1]={id=string.format('%.3f:%d:%d:%d',s,pitch,chan,vel),index=i,selected=sel,muted=muted,s=s,e=e,chan=chan,pitch=pitch,vel=vel} end
  end
  self.overlap_count=detect_overlaps(self.take)
  local ok,hash=reaper.MIDI_GetHash(self.take,true,''); self.hash=ok and hash or nil; self.dirty=false
end
function Cache:get(active)
  if self.dirty then self:rebuild() end
  local now=reaper.time_precise()
  if not active and now>=self.next_poll and self.take then self.next_poll=now+.12; local ok,h=reaper.MIDI_GetHash(self.take,true,''); if ok and h~=self.hash then self:rebuild() end end
  return self.notes
end
function Cache:visible(s,e,lo,hi,active)
  local out={} for _,n in ipairs(self:get(active)) do if n.e>=s and n.s<=e and n.pitch>=lo and n.pitch<=hi then out[#out+1]=n end end return out
end
return Cache
