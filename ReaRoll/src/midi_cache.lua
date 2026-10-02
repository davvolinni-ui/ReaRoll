-- @noindex
local Notes=require 'src.note_events'
local Cache={}; Cache.__index=Cache
local function detect_overlaps(take)
  local stream=take and Notes.read(take)
  return stream and stream:overlap_count() or 0
end
Cache.detect_overlaps=detect_overlaps
function Cache.new() return setmetatable({take=nil,hash=nil,notes={},overlap_count=0,dirty=true,next_poll=0},Cache) end
function Cache:set_take(take) if self.take==take then return end; self.take,self.hash,self.notes,self.overlap_count,self.dirty,self.next_poll=take,nil,{},0,true,0 end
function Cache:invalidate() self.dirty=true; self.hash=nil end
function Cache:rebuild()
  self.notes={}; if not self.take then self.dirty=false return end
  local a=self.edit and self.edit.active
  local stream=a and a.take==self.take and a.stream or Notes.read(self.take)
  if not stream then self.dirty=true; return end
  for _,source in ipairs(stream.notes) do
    local n=Notes.copy_note(source)
    n.id=string.format('%.3f:%d:%d:%d:%d',n.s,n.pitch,n.chan,n.vel,n.index)
    self.notes[#self.notes+1]=n
  end
  self.overlap_count=stream:overlap_count()
  local ok,hash=reaper.MIDI_GetHash(self.take,true,''); self.hash=ok and hash or nil; self.dirty=false
end
function Cache:get(active)
  active=active or self.edit and self.edit.active~=nil
  if self.dirty then self:rebuild() end
  local now=reaper.time_precise()
  if not active and now>=self.next_poll and self.take then self.next_poll=now+.12; local ok,h=reaper.MIDI_GetHash(self.take,true,''); if ok and h~=self.hash then self:rebuild() end end
  return self.notes
end
function Cache:visible(s,e,lo,hi,active)
  local out={} for _,n in ipairs(self:get(active)) do if n.e>=s and n.s<=e and n.pitch>=lo and n.pitch<=hi then out[#out+1]=n end end return out
end
return Cache
