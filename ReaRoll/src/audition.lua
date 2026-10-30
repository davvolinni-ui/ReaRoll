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
  if self.voices then for _,voice in ipairs(self.voices)do reaper.StuffMIDIMessage(0,0x80|(voice.channel&0x0F),voice.pitch,0)end;self.voices=nil end
  if self.pitches then for _,pitch in ipairs(self.pitches) do reaper.StuffMIDIMessage(0,0x80|(self.channel&0x0F),pitch,0) end; self.pitches=nil end
end
function A:play_voices(voices,velocity)
  self:stop()
  if self.settings and self.settings.midi_preview_enabled==false then return false end
  self.voices={}
  for _,voice in ipairs(voices)do
    self.voices[#self.voices+1]={pitch=voice.pitch,channel=voice.channel}
    reaper.StuffMIDIMessage(0,0x90|(voice.channel&0x0F),voice.pitch,velocity or 100)
  end
  return true
end
function A:play_note(app,note)
  self:stop()
  if self.settings and self.settings.midi_preview_enabled==false then return false end
  local stream=app.edit and app.edit.active and app.edit.active.stream or require('src.note_events').read(app.take)
  local source=stream and stream.notes[note.index+1]
  local assigned=source and require('src.note_articulations').get(source)or {}
  local groups={}
  for _,entry in ipairs(app.instrument_map and app.instrument_map.articulations or {})do local group=entry.group or 'Playing style';groups[group]=groups[group]or entry end
  for group,value in pairs(assigned)do groups[group]=value.entry end
  self.keyswitches={}
  for _,entry in pairs(groups)do
    local channel=note.chan or 0
    if entry.channel<0 or entry.channel==channel then
      if entry.bank_msb~=nil then reaper.StuffMIDIMessage(0,0xb0|channel,0,entry.bank_msb);reaper.StuffMIDIMessage(0,0xb0|channel,32,entry.bank_lsb)end
      if entry.kind=='note'then reaper.StuffMIDIMessage(0,0x90|channel,entry.number,entry.value);self.keyswitches[#self.keyswitches+1]={pitch=entry.number,channel=channel}
      elseif entry.kind=='cc'then reaper.StuffMIDIMessage(0,0xb0|channel,entry.number,entry.value)
      else reaper.StuffMIDIMessage(0,0xc0|channel,entry.number,0)end
    end
  end
  self.pitches={note.pitch};self.channel=note.chan or 0
  reaper.StuffMIDIMessage(0,0x90|self.channel,note.pitch,note.vel or 100)
  return true
end
return A
