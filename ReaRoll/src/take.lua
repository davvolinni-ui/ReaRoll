-- @noindex
local M={}
function M.valid(take)
  if take==nil then return false end
  local ok,valid=pcall(function()
    return reaper.ValidatePtr2(0,take,'MediaItem_Take*') and reaper.TakeIsMIDI(take)
  end)
  return ok and not not valid
end
function M.item(take)
  if take==nil then return nil end
  if reaper.ValidatePtr2 and reaper.TakeIsMIDI and not M.valid(take) then return nil end
  -- A project edit can invalidate userdata between REAPER API calls.  Keep
  -- that narrow race from terminating the deferred UI loop.
  local ok,item=pcall(reaper.GetMediaItemTake_Item,take)
  return ok and item or nil
end
function M.active(preferred)
  -- Arrange selection is the public source of truth, so selecting an item on
  -- the timeline immediately changes ReaRoll's editable take.
  if M.valid(preferred) then return preferred end
  local item=reaper.GetSelectedMediaItem(0,0); local take=item and reaper.GetActiveTake(item) or nil
  if M.valid(take) then return take end
  local editor=reaper.MIDIEditor_GetActive(); take=editor and reaper.MIDIEditor_GetTake(editor) or nil
  if M.valid(take) then return take end
end
function M.name(take) local _,n=reaper.GetSetMediaItemTakeInfo_String(take,'P_NAME','',false); return n~='' and n or 'Untitled MIDI take' end
function M.item_start_qn(take) local item=M.item(take); if not item then return nil end; return reaper.TimeMap2_timeToQN(0,reaper.GetMediaItemInfo_Value(item,'D_POSITION')) end
function M.item_end_qn(take)
  local item=M.item(take); if not item then return nil end; local pos=reaper.GetMediaItemInfo_Value(item,'D_POSITION'); local len=reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
  return reaper.TimeMap2_timeToQN(0,pos+len)
end
return M
