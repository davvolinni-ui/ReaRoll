-- @noindex
local Notes=require 'src.note_events'
local Cache={}; Cache.__index=Cache
function Cache.new() return setmetatable({take=nil,hash=nil,events={},dirty=true,next_poll=0},Cache) end
function Cache:set_take(take) if take==self.take then return end; self.take,self.hash,self.events,self.dirty,self.next_poll=take,nil,{},true,0 end
function Cache:invalidate() self.dirty=true; self.hash=nil end
local function available(cache)
  if Notes.available(cache.take)then return true end
  cache.events={}; cache.hash=nil
  cache.dirty=cache.take~=nil; cache.next_poll=0
  return false
end
function Cache:rebuild()
  if not available(self)then return end
  self.events={}; if not self.take then self.dirty=false return end
  local _,_,count=reaper.MIDI_CountEvts(self.take)
  for i=0,count-1 do
    local ok,selected,muted,ppq,chanmsg,chan,msg2,msg3=reaper.MIDI_GetCC(self.take,i)
    if ok then local shape,tension=0,0;if reaper.MIDI_GetCCShape then local valid;valid,shape,tension=reaper.MIDI_GetCCShape(self.take,i);if not valid then shape,tension=0,0 end end;self.events[#self.events+1]={index=i,selected=selected,muted=muted,ppq=ppq,chanmsg=chanmsg,chan=chan,msg2=msg2,msg3=msg3,shape=shape,tension=tension} end
  end
  local ok,hash=reaper.MIDI_GetHash(self.take,false,''); self.hash=ok and hash or nil; self.dirty=false
end
function Cache:get(active)
  if not available(self)then return self.events end
  if self.dirty then self:rebuild() end; local now=reaper.time_precise()
  if not active and now>=self.next_poll and self.take then self.next_poll=now+.15; local ok,h=reaper.MIDI_GetHash(self.take,false,''); if ok and h~=self.hash then self:rebuild() end end
  return self.events
end
return Cache
