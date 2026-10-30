-- @noindex
local Notes=require 'src.note_events'
local M={}
local function valid(take)
  return not reaper.ValidatePtr2 or reaper.ValidatePtr2(0,take,'MediaItem_Take*')
end
local function write(entry,after)
  if not valid(entry.take) then return false end
  if reaper.MIDI_Sort then reaper.MIDI_Sort(entry.take)end
  return reaper.MIDI_SetAllEvts(entry.take,after and entry.after_raw or entry.before_raw)
    and Notes.set_pairing_state(entry.take,after and entry.after_pairs or entry.before_pairs)
end
function M.restore(entries)
  local restored=true
  for _,entry in ipairs(entries)do
    if valid(entry.take) then
      local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'')
      if ok and (raw==entry.expected_raw or raw==entry.before_raw) then
        if not write(entry,false) then restored=false end
      else restored=false end
    else restored=false end
  end
  return restored
end
function M.commit(entries,name)
  for _,entry in ipairs(entries)do
    if not valid(entry.take) then return false,'An edit target was removed.' end
    local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'')
    if not ok or raw~=entry.expected_raw then return false,'A target changed outside this preview; its changes were preserved.' end
  end
  if not M.restore(entries) then return false,'Could not restore the source snapshots before committing.' end
  reaper.Undo_BeginBlock2(0)
  local success=true
  for _,entry in ipairs(entries)do if not write(entry,true) then success=false;break end end
  if not success then
    local rolled_back=true
    for _,entry in ipairs(entries)do if not write(entry,false) then rolled_back=false end end
    reaper.Undo_EndBlock2(0,name,0)
    return false,rolled_back and 'The edit failed; all targets were restored.' or 'The edit failed and a source could not be restored. Original snapshots remain available in this session.'
  end
  reaper.Undo_EndBlock2(0,name,-1);reaper.UpdateArrange();return true
end
return M
