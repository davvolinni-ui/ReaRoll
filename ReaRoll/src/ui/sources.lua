-- @noindex
local U=require 'src.util'; local M={}

local function widget_color(color) return ((color&0xFF)<<24)|((color>>8)&0xFFFFFF) end
local function draw_color(color) return ((color&0xFFFFFF)<<8)|((color>>24)&0xFF) end

local function set_track_color(track,color)
  if not reaper.SetTrackColor then return end
  if not color then reaper.SetTrackColor(track,0)
  elseif reaper.ColorToNative then
    local r,g,b=(color>>24)&255,(color>>16)&255,(color>>8)&255
    reaper.SetTrackColor(track,reaper.ColorToNative(r,g,b)|0x1000000)
  end
  if reaper.UpdateArrange then reaper.UpdateArrange() end
end

function M.track_key(track)
  local guid=reaper.GetTrackGUID and reaper.GetTrackGUID(track)
  return guid and guid~='' and guid or tostring(track)
end

local function track_selected(track)
  return reaper.GetMediaTrackInfo_Value and reaper.GetMediaTrackInfo_Value(track,'I_SELECTED')>0
end

local function select_track(app,track,track_index,take,mods)
  local selected=track_selected(track)
  if mods.shift and app.source_selection_anchor~=nil then
    local first,last=math.min(app.source_selection_anchor,track_index),math.max(app.source_selection_anchor,track_index)
    if reaper.SetTrackSelected then
      for i=0,reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,i),i>=first and i<=last) end
    end
  elseif mods.ctrl then
    if reaper.SetTrackSelected then reaper.SetTrackSelected(track,not selected) end
    if selected then return end
    app.source_selection_anchor=track_index
  else
    if reaper.SetOnlyTrackSelected then reaper.SetOnlyTrackSelected(track)
    elseif reaper.SetTrackSelected then for i=0,reaper.CountTracks(0)-1 do reaper.SetTrackSelected(reaper.GetTrack(0,i),i==track_index) end end
    app.source_selection_anchor=track_index
  end
  app.primary_source_track=track
  if take then app:focus_take(take) end
end

local function relevant_take(app,track,midi_items)
  if reaper.CountSelectedMediaItems then
    for i=0,reaper.CountSelectedMediaItems(0)-1 do
      local item=reaper.GetSelectedMediaItem(0,i)
      if item and reaper.GetMediaItemTrack(item)==track then
        local take=reaper.GetActiveTake(item); if take and reaper.TakeIsMIDI(take) then return take end
      end
    end
  end
  local active_item=app.take and reaper.GetMediaItemTake_Item(app.take)
  if active_item and reaper.GetMediaItemTrack(active_item)==track then return app.take end
  local cursor=reaper.GetCursorPosition and reaper.GetCursorPosition() or 0; local nearest,nearest_distance
  for _,entry in ipairs(midi_items) do
    local position=reaper.GetMediaItemInfo_Value(entry.item,'D_POSITION'); local ending=position+reaper.GetMediaItemInfo_Value(entry.item,'D_LENGTH')
    if cursor>=position and cursor<ending then return entry.take end
    local distance=cursor<position and position-cursor or cursor-ending
    if not nearest_distance or distance<nearest_distance then nearest,nearest_distance=entry.take,distance end
  end
  return nearest or midi_items[1].take
end

local function set_ghost_visibility(app,track,visible)
  -- A checkbox on a selected row applies to the whole REAPER track
  -- selection. An unselected row changes only itself.
  if track_selected(track) then
    for i=0,reaper.CountTracks(0)-1 do
      local candidate=reaper.GetTrack(0,i)
      if track_selected(candidate) then app.source_visibility[M.track_key(candidate)]=visible end
    end
  else app.source_visibility[M.track_key(track)]=visible end
  app.source_revision=(app.source_revision or 0)+1; app.settings.ghost_enabled=true
end

local function set_single_ghost_visibility(app,track,visible)
  app.source_visibility[M.track_key(track)]=visible
  app.source_revision=(app.source_revision or 0)+1; app.settings.ghost_enabled=true
end

function M.draw(app)
  local I,c=app.ImGui,app.ctx
  local mx,my=I.GetMousePos(c)
  I.TextColored(c,app.theme.header_icon or app.theme.note,'MIDI Track List')
  I.Separator(c)
  app.source_visibility=app.source_visibility or {}
  local active_item=app.take and reaper.GetMediaItemTake_Item(app.take)
  local active_track=active_item and reaper.GetMediaItemTrack(active_item)
  local d=I.GetWindowDrawList(c)
  local function active_row(strength)
    local x,y=I.GetCursorScreenPos(c); local width=I.GetContentRegionAvail(c)
    local height=I.GetFrameHeight(c)
    local accent=app.theme.selected or app.theme.accent
    I.DrawList_AddRectFilled(d,x-3,y-1,x+width,y+height+1,(accent&0xFFFFFF00)|strength,3)
    I.DrawList_AddRectFilled(d,x-3,y-1,x,y+height+1,accent,2)
  end
  for track_index=0,reaper.CountTracks(0)-1 do
    local track=reaper.GetTrack(0,track_index); local midi_items={}
    for item_index=0,reaper.CountTrackMediaItems(track)-1 do
      local item=reaper.GetTrackMediaItem(track,item_index); local take=reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then midi_items[#midi_items+1]={item=item,take=take,index=item_index} end
    end
    if #midi_items>0 then
      local _,track_name=reaper.GetTrackName(track); if not track_name or track_name=='' then track_name='Track '..tostring(track_index+1) end
      local key=M.track_key(track); local visible=app.source_visibility[key]==true
      local selected=track_selected(track); if selected then active_row(track==active_track and 0x48 or 0x24) end
      local color=U.track_color(track,app.theme.note); local box=I.GetFrameHeight(c); local bx,by=I.GetCursorScreenPos(c)
      I.InvisibleButton(c,'##source_track_'..key,box,box)
      local toggle_hot=U.contains(mx,my,bx,by,bx+box,by+box)
      if toggle_hot and I.IsMouseClicked(c,I.MouseButton_Left) then
        local target=not visible; set_ghost_visibility(app,track,target)
        local visited={[key]=true}
        if track_selected(track) then for i=0,reaper.CountTracks(0)-1 do local candidate=reaper.GetTrack(0,i); if track_selected(candidate) then visited[M.track_key(candidate)]=true end end end
        app.source_paint={value=target,visited=visited}
        visible=target
      elseif toggle_hot and app.source_paint and I.IsMouseDown(c,I.MouseButton_Left) and not app.source_paint.visited[key] then
        set_single_ghost_visibility(app,track,app.source_paint.value); app.source_paint.visited[key]=true; visible=app.source_paint.value
      end
      local inset=3; local fill=visible and color or U.color_scale(color,.32)
      I.DrawList_AddRectFilled(d,bx+inset,by+inset,bx+box-inset,by+box-inset,fill,3)
      local border=visible and U.color_scale(color,1.18) or (app.theme.note_border or app.theme.grid or 0x404040FF)
      I.DrawList_AddRect(d,bx+inset,by+inset,bx+box-inset,by+box-inset,border,3,I.DrawFlags_None,1)
      local toggle_hovered=toggle_hot
      if toggle_hovered and I.IsMouseClicked(c,I.MouseButton_Right) then I.OpenPopup(c,'##source_color_popup_'..key) end
      if toggle_hovered then
        local scope=track==active_track and '\nSibling items stay visible while this is the active track.' or ''
        I.SetTooltip(c,(visible and 'Hide' or 'Show')..' this track when it is not active'..scope..'\nRight-click: choose track color\nApplies to all selected tracks when this track is selected.')
      end
      if I.BeginPopup(c,'##source_color_popup_'..key) then
        I.Text(c,track_name); I.TextDisabled(c,'REAPER track color'); I.Separator(c)
        local palette={0xE35D6AFF,0xE8873AFF,0xD9B83FFF,0x84B84AFF,0x42B883FF,0x3CAFC8FF,0x4C8DE5FF,0x7567D8FF,0xA966D8FF,0xD35DA8FF,0xA58C72FF,0x8D98A5FF}
        for index,preset in ipairs(palette) do
          if index==7 then I.NewLine(c) elseif index>1 then I.SameLine(c) end
          if I.ColorButton(c,'##track_preset_'..key..'_'..index,widget_color(preset),I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoTooltip,20,20) then set_track_color(track,preset) end
        end
        local changed,picked=I.ColorEdit4(c,'Custom##source_track_color_'..key,widget_color(U.track_color(track,app.theme.note)),I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoOptions)
        if changed then set_track_color(track,draw_color(picked)) end
        if I.Button(c,'Use ReaRoll default') then set_track_color(track,app.theme.note); I.CloseCurrentPopup(c) end
        if I.IsItemHovered(c) then I.SetTooltip(c,'Apply ReaRoll\'s current Appearance → MIDI Notes color to the REAPER track.') end
        I.EndPopup(c)
      end
      I.SameLine(c)
      if I.Selectable(c,string.format('%02d  %s##source_row_%s',track_index+1,track_name,key),selected) then
        select_track(app,track,track_index,relevant_take(app,track,midi_items),U.mods(I,c))
      end
      if I.IsItemHovered(c) then I.SetTooltip(c,'Click: select track and its relevant MIDI item\nCtrl/Shift: standard Arrange track selection\nChoose a specific item in Arrange\nGhost color square is independent') end
      I.Separator(c)
    end
  end
  if app.source_paint and I.IsMouseReleased(c,I.MouseButton_Left) then app.source_paint=nil end
end

return M
