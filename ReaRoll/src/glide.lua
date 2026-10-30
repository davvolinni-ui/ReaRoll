-- @noindex
-- Musical glide planning is independent from host writes and popup state.
local M={}
local function overlaps(a,b)return a.s<b.e and b.s<a.e end
function M.plan(selected,all,events,options)
  local o=options or {}; local range=math.max(1,o.range or 12)
  if #selected<(o.vibrato_only and 1 or 2) then return nil,o.vibrato_only and 'Select notes for vibrato.' or 'Select at least two notes to connect.' end
  local notes={}; local chosen={}
  for _,n in ipairs(selected) do local copy={};for k,v in pairs(n)do copy[k]=v end;copy.source_chan=n.chan;notes[#notes+1]=copy;chosen[n.index]=true end
  table.sort(notes,function(a,b)if a.s~=b.s then return a.s<b.s end;if a.pitch~=b.pitch then return a.pitch<b.pitch end;return a.index<b.index end)
  local plan={notes=notes,curves={},replace=o.replace,mpe=o.mpe}
  for _,n in ipairs(notes) do
    local target
    for _,candidate in ipairs(notes) do
      if candidate.s>n.s and (o.mpe or candidate.chan==n.chan) then
        if not target or candidate.s<target.s or candidate.s==target.s and math.abs(candidate.pitch-n.pitch)<math.abs(target.pitch-n.pitch) then target=candidate end
      end
    end
    if o.vibrato_only then
      plan.curves[#plan.curves+1]={note=n,target=n.pitch,start=n.s,ending=n.e}
    elseif target then
      if math.abs(target.pitch-n.pitch)>range then return nil,'A transition exceeds the instrument pitch-bend range.' end
      local ending=o.connect~=false and target.s or math.min(n.e,target.s)
      if ending<=n.s then return nil,'A note is too short for a glide.' end
      n.e=ending
      plan.curves[#plan.curves+1]={note=n,target=target.pitch,start=math.max(n.s,ending-math.max(.001,o.duration or .25)),ending=ending}
    end
  end
  if #plan.curves==0 then return nil,'No later selected note exists on the same channel.' end
  if o.mpe then
    -- Allocate member channels 2..16 only when free of unrelated notes/data.
    -- Existing expression on the selected notes needs the expression editor;
    -- this authoring tool must not silently detach it during reassignment.
    local reserved={};local occupied={}
    for _,n in ipairs(all)do if not chosen[n.index] then reserved[n.chan]=true end end
    for _,e in ipairs(events or {})do
      if e.status==0xE0 or e.status==0xD0 or e.status==0xB0 and e.cc==74 then
        for _,n in ipairs(selected)do if e.chan==n.chan and e.q>=n.s and e.q<=n.e then return nil,'Selected notes already have expression. Preserve or edit that expression before assigning new MPE channels.' end end
      end
      reserved[e.chan]=true
    end
    for _,n in ipairs(notes)do
      local channel
      for ch=0,15 do if require('src.expression').member(ch,{mpe_zone=o.zone,mpe_members=o.members}) and not reserved[ch] and (not occupied[ch] or occupied[ch]<=n.s) then channel=ch;break end end
      if not channel then return nil,'No free MPE member channel remains for this note.' end
      n.chan=channel;occupied[channel]=n.e
    end
  else
    local planned={};for _,n in ipairs(notes)do planned[n.index]=n end
    for _,curve in ipairs(plan.curves)do
      local n=curve.note
      for _,other in ipairs(all)do
        other=planned[other.index] or other
        if other.index~=n.index and other.chan==n.chan and overlaps(n,other) then return nil,'Channel glide would bend another sounding note. Use MPE for polyphonic glides.' end
      end
    end
  end
  for _,curve in ipairs(plan.curves)do
    local sustain=false;local last_pedal=-math.huge
    for _,event in ipairs(events or {})do
      if event.status==0xB0 and event.cc==64 and (event.chan==curve.note.chan or o.mpe and event.chan==curve.note.source_chan) then
        if event.q<=curve.note.s and event.q>=last_pedal then sustain=(event.value or 0)>=64;last_pedal=event.q end
        if event.q>curve.note.s and event.q<curve.ending and (event.value or 0)>=64 then return nil,'Sustain holds notes across this glide. Release sustain before authoring pitch transitions.' end
      end
      if event.status==0xE0 and event.chan==curve.note.chan and event.q>=curve.note.s and event.q<=curve.ending and not o.replace then return nil,'Existing pitch bend occupies a glide span. Enable replacement to overwrite that span.' end
    end
    if sustain then return nil,'Sustain is active at this glide. Release sustain before authoring pitch transitions.' end
  end
  plan.range=range;plan.shape=o.shape or 'smooth'
  plan.depth=math.max(0,o.vibrato_depth or 0);plan.rate=math.max(.1,o.vibrato_rate or 4)
  for _,curve in ipairs(plan.curves)do if math.abs(curve.target-curve.note.pitch)+plan.depth>range then return nil,'Glide plus vibrato exceeds the instrument pitch-bend range.' end end
  return plan
end
function M.value(semitones,range)
  return math.max(0,math.min(16383,math.floor(8192+semitones/range*(semitones>=0 and 8191 or 8192)+.5)))
end
function M.points(plan,to_ppq)
  local result,at={},{}
  local function add(q,chan,value)
    local ppq=math.floor(to_ppq(q)+.5);local key=chan..':'..ppq
    if at[key] then at[key].value=value else local point={ppq=ppq,chan=chan,value=value};at[key]=point;result[#result+1]=point end
  end
  for _,curve in ipairs(plan.curves)do
    local n=curve.note;local first,last=to_ppq(curve.start),to_ppq(curve.ending)
    local finish=math.floor(last+.5)-1
    if finish<=first then return nil,'A glide needs at least two MIDI ticks. Increase its duration.' end
    add(n.s,n.chan,8192)
    local count=math.min(plan.depth>0 and 1024 or 128,math.max(8,plan.depth>0 and math.ceil((curve.ending-curve.start)*plan.rate*16) or math.floor(finish-first)))
    for i=0,count do
      local t=i/count;local shaped=plan.shape=='linear' and t or t*t*(3-2*t)
      local ppq=math.floor(first+(finish-first)*t+.5)
      local vibrato=plan.depth*math.sin(2*math.pi*plan.rate*(curve.ending-curve.start)*t)*math.sin(math.pi*t)
      local key=n.chan..':'..ppq;local value=M.value((curve.target-n.pitch)*shaped+vibrato,plan.range)
      if at[key] then at[key].value=value else local point={ppq=ppq,chan=n.chan,value=value};at[key]=point;result[#result+1]=point end
    end
    add(curve.ending,n.chan,8192)
  end
  table.sort(result,function(a,b)if a.ppq~=b.ppq then return a.ppq<b.ppq end;return a.chan<b.chan end)
  return result
end
return M
