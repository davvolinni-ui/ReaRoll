-- @noindex
local A={}; A.__index=A
function A.new(settings) return setmetatable({pitches=nil,channel=0,settings=settings},A) end
function A:play(pitch,velocity,channel)
  self:stop(); self.pitches={pitch}; self.channel=channel or 0
  if self.settings and self.settings.midi_preview_enabled==false then self.pitches=nil; return false end
  reaper.StuffMIDIMessage(0,0x90|(self.channel&0x0F),pitch,velocity or 100)
  return true
end
function A:play_many(pitches,velocity,channel)
  self:stop(); self.pitches={}; self.channel=channel or 0
  if self.settings and self.settings.midi_preview_enabled==false then self.pitches=nil; return false end
  for _,pitch in ipairs(pitches) do self.pitches[#self.pitches+1]=pitch; reaper.StuffMIDIMessage(0,0x90|(self.channel&0x0F),pitch,velocity or 100) end
  return true
end
function A:stop()
  if self.pitches then for _,pitch in ipairs(self.pitches) do reaper.StuffMIDIMessage(0,0x80|(self.channel&0x0F),pitch,0) end; self.pitches=nil end
end
return A
