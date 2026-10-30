-- @noindex
-- Read-only input visualization. Never records, routes, or sends MIDI.
local M={};M.__index=M
function M.new()return setmetatable({groups={},pitches={}},M)end
function M:clear()self.groups={};self.pitches={}end
function M.accept(input,device,channel)
  if input<0 or input&4096==0 or device&0x10000~=0 then return false end
  local source=(input>>5)&63;local wanted=input&31
  return (source==63 or source==(device&0xFFFF)) and (wanted==0 or wanted==channel+1)
end
function M:feed(msg,device,input)
  if #msg<1 then return end
  local status=msg:byte(1)
  if status==0xFF then for key,g in pairs(self.groups)do if g.device==device then self.groups[key]=nil end end;return end
  if #msg<3 or status>=0xF0 then return end
  local channel=status&15;status=status&0xF0
  if not M.accept(input,device,channel)then return end
  local key=device..':'..channel
  local g=self.groups[key] or {device=device,channel=channel,notes={},sustain=false};self.groups[key]=g
  local p,value=msg:byte(2,3)
  if p>127 or value>127 then return end
  if status==0x90 and value>0 then
    local n=g.notes[p] or {count=0};n.count=n.count+1;n.velocity=value;g.notes[p]=n
  elseif status==0x80 or status==0x90 then
    local n=g.notes[p];if n then n.count=math.max(0,n.count-1);if n.count==0 and not g.sustain then g.notes[p]=nil end end
  elseif status==0xB0 then
    if p==64 then
      g.sustain=value>=64
      if not g.sustain then for pitch,n in pairs(g.notes)do if n.count==0 then g.notes[pitch]=nil end end end
    elseif p==120 then g.notes={};g.sustain=false
    elseif p==123 then for pitch,n in pairs(g.notes)do n.count=0;if not g.sustain then g.notes[pitch]=nil end end
    elseif p==121 then g.sustain=false;for pitch,n in pairs(g.notes)do if n.count==0 then g.notes[pitch]=nil end end end
  end
end
function M:collect()
  local out={}
  for _,g in pairs(self.groups)do for pitch,n in pairs(g.notes)do
    local p=out[pitch] or {velocity=0,channels={}};out[pitch]=p
    p.velocity=math.max(p.velocity,n.velocity);p.channels[g.channel]=true
  end end
  self.pitches=out;return out
end
function M:poll(track,enabled)
  if not reaper.MIDI_GetRecentInputEvent then self:clear();return self.pitches end
  local input=track and math.floor(reaper.GetMediaTrackInfo_Value(track,'I_RECINPUT')) or -1
  local sequence,msg,_,device=reaper.MIDI_GetRecentInputEvent(0)
  local route=tostring(track)..':'..input..':'..tostring(enabled)
  if route~=self.route then self:clear();self.route=route;self.sequence=sequence;return self.pitches end
  if not enabled or input<0 or input&4096==0 then self.sequence=sequence;self:clear();return self.pitches end
  if sequence~=0 and sequence~=self.sequence then
    local events={{msg=msg,device=device}};local found=self.sequence==nil or self.sequence==0
    for i=1,1023 do
      local seq,message,_,dev=reaper.MIDI_GetRecentInputEvent(i)
      if seq==self.sequence then found=true;break end
      if seq==0 then break end
      events[#events+1]={msg=message,device=dev}
    end
    -- A history overrun can lose note-offs. Reset stale state before replay.
    if not found then self:clear()end
    for i=#events,1,-1 do self:feed(events[i].msg,events[i].device,input)end
    self.sequence=sequence
  elseif sequence==0 then self:clear();self.sequence=0 end
  local now=reaper.time_precise()
  if now>=(self.next_device_check or 0)then
    self.next_device_check=now+1
    if reaper.GetMIDIInputName then for key,g in pairs(self.groups)do
      local dev=g.device&0xFFFF
      if dev~=62 and not reaper.GetMIDIInputName(dev,'')then self.groups[key]=nil end
    end end
  end
  return self:collect()
end
function M.update(app)
  app.input_monitor=app.input_monitor or M.new()
  local track=app.take and require('src.take').track(app.take) or app.empty_track
  app.input_notes=app.input_monitor:poll(track,app.settings.input_note_display~=false)
end
return M
