-- @noindex
local U=require 'src.util'; local Ghost={}; Ghost.__index=Ghost
function Ghost.new() return setmetatable({take=nil,mode=nil,state_count=-1,notes={}},Ghost) end
local function add_item(items,seen,item,active_item)
  if item and item~=active_item and not seen[item] then seen[item]=true; items[#items+1]=item end
end
local function track_key(track)
  local guid=reaper.GetTrackGUID and reaper.GetTrackGUID(track)
  return guid and guid~='' and guid or tostring(track)
end
function Ghost:rebuild(active_take,mode,visibility,revision)
  self.notes={}; self.take=active_take; self.mode=mode; self.visibility_revision=revision or 0; self.state_count=reaper.GetProjectStateChangeCount(0)
  if not active_take then return end
  local active_item=reaper.GetMediaItemTake_Item(active_take); local items,seen={},{}
  -- Item editing remains take-scoped, but every sibling MIDI item on the
  -- active track is always useful context and ignores that track's toggle.
  local active_track=reaper.GetMediaItemTrack(active_item)
  for i=0,reaper.CountTrackMediaItems(active_track)-1 do add_item(items,seen,reaper.GetTrackMediaItem(active_track,i),active_item) end
  if visibility then
    for track_index=0,reaper.CountTracks(0)-1 do local track=reaper.GetTrack(0,track_index)
      if visibility[track_key(track)]==true then for item_index=0,reaper.CountTrackMediaItems(track)-1 do add_item(items,seen,reaper.GetTrackMediaItem(track,item_index),active_item) end end
    end
  else
    local track=reaper.GetMediaItemTrack(active_item); local a0=reaper.GetMediaItemInfo_Value(active_item,'D_POSITION'); local a1=a0+reaper.GetMediaItemInfo_Value(active_item,'D_LENGTH')
    for i=0,reaper.CountTrackMediaItems(track)-1 do
      local item=reaper.GetTrackMediaItem(track,i); local p=reaper.GetMediaItemInfo_Value(item,'D_POSITION'); local e=p+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
      if e>a0 and p<a1 then add_item(items,seen,item,active_item) end
    end
  end
  for source_index,item in ipairs(items) do
    local take=reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local track=reaper.GetMediaItemTrack(item); local color=U.track_color(track,nil)
      local _,count=reaper.MIDI_CountEvts(take)
      for i=0,count-1 do
        local ok,_,muted,s,e,chan,pitch,vel=reaper.MIDI_GetNote(take,i)
        if ok then self.notes[#self.notes+1]={source=source_index,item=item,take=take,track=track,color=color,s_qn=reaper.MIDI_GetProjQNFromPPQPos(take,s),e_qn=reaper.MIDI_GetProjQNFromPPQPos(take,e),pitch=pitch,vel=vel,chan=chan,muted=muted} end
      end
    end
  end
end
function Ghost:get(active_take,mode,active_gesture,visibility,revision)
  if active_gesture and active_take==self.take and mode==self.mode and (revision or 0)==(self.visibility_revision or 0) then return self.notes end
  local count=reaper.GetProjectStateChangeCount(0)
  if active_take~=self.take or mode~=self.mode or count~=self.state_count or (revision or 0)~=(self.visibility_revision or 0) then self:rebuild(active_take,mode,visibility,revision) end
  return self.notes
end
return Ghost
