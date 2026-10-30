-- @noindex
local M={}
-- Consider each member channel once, using its latest overlapping score note.
-- Destinations at this onset already own their channels; a second chord tone
-- must not connect to the same voice or reassign an existing note.
local function candidates(notes,first,settings,selection)
  notes=require('src.glide_connections').expand(notes,settings)
  local active,used,chosen={},{},{}
  for _,note in ipairs(notes)do if not note.muted and require('src.expression').member(note.chan,settings)then
    if note.s==first then used[note.chan]=true end
    if note.s<first and note.e>first then
      local prior=active[note.chan]
      if not prior or note.s>prior.s then active[note.chan]=note end
      if selection and selection[note.index]then chosen[note.chan]=true end
    end
  end end
  for channel in pairs(used)do active[channel]=nil;chosen[channel]=nil end
  return active,chosen
end
function M.resolve(notes,first,last,settings,selection,pitch)
  local active,chosen=candidates(notes,first,settings,selection)
  local function single(channels)
    local found
    for channel in pairs(channels)do if found~=nil then return nil end;found=channel end
    return found
  end
  local channel=single(chosen)
  if channel~=nil then return channel end
  if active[settings.channel]then return settings.channel end
  channel=single(active);if channel~=nil then return channel end
  -- Hand-drawn destinations use an available nearby voice. Explicit source
  -- selection or the drawing-channel selector takes precedence.
  if type(pitch)=='number'then
    local best,distance
    for ch,note in pairs(active)do
      local delta=math.abs(note.pitch-pitch)
      if not best or delta<distance or delta==distance and(note.pitch<active[best].pitch or note.pitch==active[best].pitch and ch<best)then best,distance=ch,delta end
    end
    return best
  end
  if next(active)then return nil,'Select the note you want to glide from, then draw its overlapping destination.'end
end
-- Whole chords have all destinations available at once. Pair bottom-to-top;
-- pitches may arrive in any order (including inversions and library cards).
function M.chord(notes,first,settings,pitches)
  local active=candidates(notes,first,settings)
  local sources,targets,result={},{},{}
  for _,note in pairs(active)do sources[#sources+1]=note end
  table.sort(sources,function(a,b)if a.pitch~=b.pitch then return a.pitch<b.pitch end;return a.chan<b.chan end)
  for i,pitch in ipairs(pitches)do targets[#targets+1]={pitch=pitch,index=i}end
  table.sort(targets,function(a,b)if a.pitch~=b.pitch then return a.pitch<b.pitch end;return a.index<b.index end)
  for i=1,math.min(#sources,#targets)do result[targets[i].index]=sources[i].chan end
  return result
end
return M
