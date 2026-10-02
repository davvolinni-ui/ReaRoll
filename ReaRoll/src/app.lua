-- @noindex
local Settings=require 'src.settings'
local Theme=require 'src.theme'
local Take=require 'src.take'
local Cache=require 'src.midi_cache'
local Selection=require 'src.selection'
local Viewport=require 'src.viewport'
local Edit=require 'src.midi_edit'
local Audition=require 'src.audition'
local Toolbar=require 'src.ui.toolbar'
local Canvas=require 'src.ui.canvas'
local Music=require 'src.music'
local GhostCache=require 'src.ghost_cache'
local CCCache=require 'src.cc_cache'
local Transforms=require 'src.transforms'
local Clipboard=require 'src.clipboard'
local Appearance=require 'src.ui.appearance'
local Grid=require 'src.grid'
local Help=require 'src.ui.help'
local Shortcuts=require 'src.shortcuts'
local ShortcutUI=require 'src.ui.shortcuts'
local Sources=require 'src.ui.sources'
local KeyMap=require 'src.key_map'
local KeyMapUI=require 'src.ui.key_map'
local LaneTools=require 'src.ui.lane_tools'

local App={}; App.__index=App
local function draw_child(I,c,id,width,height,draw,window_flags)
  local visible=I.BeginChild(c,id,width,height,0,window_flags or 0)
  local ok,err=true,nil
  -- ReaImGui's Lua wrapper only pushes a child when BeginChild succeeds.
  -- Ending a clipped/zero-area child that returned false pops its parent and
  -- makes the later main-window End report "Calling End() too many times".
  if visible then ok,err=xpcall(draw,debug.traceback); I.EndChild(c) end
  if not ok then error(err) end
end
function App.new(ImGui)
  local self=setmetatable({},App)
  self.ImGui=ImGui; self.ctx=ImGui.CreateContext('ReaRoll'); self.open=true
  self.settings=Settings.load(); Shortcuts.load(self.settings); self.theme=Theme; self.music=Music; self.transforms=Transforms; self.clipboard=Clipboard; self.cache=Cache.new(); self.cc_cache=CCCache.new(); self.ghost=GhostCache.new(); self.selection=Selection.new()
  self.viewport=Viewport.new(self.settings); self.edit=Edit.new(self.cache,self.selection,self.cc_cache); self.edit.app=self; self.audition=Audition.new(self.settings)
  Appearance.init(self)
  self.take=nil; self.take_name='No MIDI take selected'; self.next_take_poll=0; self.gesture=nil; self.shut_down=false
  self.arrange_selected_items={}
  self.last_take_by_track={}
  self.note_names={}
  self.key_colors={}; self.key_map_selection={}; self.key_map_color=0xE8A653FF; self.key_mapping_mode=false; self.key_map_open=false
  return self
end
function App:reselect_notes(wanted)
  Selection.clear(self.selection); local used={}
  for _,w in ipairs(wanted) do
    local best,bestd
    for _,n in ipairs(self.cache.notes) do if not used[n] and n.pitch==w.pitch and n.vel==w.vel then local d=math.abs(n.s-w.s)+math.abs(n.e-w.e); if not bestd or d<bestd then best,bestd=n,d end end end
    if best then used[best]=true; Selection.add(self.selection,best.id) end
  end
end
function App:sync_item_bounds(take,preserve_view)
  if not take then return false end
  local new_start,new_end=Take.item_start_qn(take),Take.item_end_qn(take)
  if not new_start or not new_end then return false end
  local old_start,old_end=self.item_start_qn,self.item_end_qn
  if preserve_view and old_start and math.abs(new_start-old_start)>.000001 then
    -- Keep the same part of the item under the pointer when it is moved in the
    -- arrange view, while changing the ruler to its new absolute project bars.
    self.settings.start_qn=(self.settings.start_qn or old_start)+(new_start-old_start)
  end
  self.item_start_qn,self.item_end_qn=new_start,new_end
  return not old_start or math.abs(new_start-old_start)>.000001 or not old_end or math.abs(new_end-old_end)>.000001
end
function App:poll_take()
  local now=reaper.time_precise()
  -- Item deletion invalidates its take immediately. Bypass the normal polling
  -- throttle so no frame can render with the stale userdata.
  local project_change=reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0) or nil
  if now<self.next_take_poll and project_change==self.project_state_change and (not self.take or Take.valid(self.take)) then return end
  self.next_take_poll=now+.15
  self.project_state_change=project_change
  local selected,seen,new_take={}, {},nil
  if reaper.CountSelectedMediaItems then for i=0,reaper.CountSelectedMediaItems(0)-1 do
    local item=reaper.GetSelectedMediaItem(0,i); local candidate=item and reaper.GetActiveTake(item)
    if candidate and Take.valid(candidate) then
      local key=tostring(item); selected[#selected+1]={item=item,take=candidate}; seen[key]=true
      if not self.arrange_selected_items[key] then new_take=candidate end
    end
  end end
  local current_selected=false
  if self.take then local current_item=Take.item(self.take); current_selected=current_item~=nil and seen[tostring(current_item)]==true end
  local selected_track=reaper.GetSelectedTrack and reaper.GetSelectedTrack(0,0) or nil
  local track_take=selected_track and self.last_take_by_track[tostring(selected_track)] or nil
  if track_take and (not Take.valid(track_take) or (reaper.GetMediaItemTake_Track and reaper.GetMediaItemTake_Track(track_take)~=selected_track)) then
    self.last_take_by_track[tostring(selected_track)]=nil; track_take=nil
  end
  if selected_track and not track_take then
    local cursor=reaper.GetCursorPosition and reaper.GetCursorPosition() or 0; local nearest_distance
    if reaper.CountTrackMediaItems and reaper.GetTrackMediaItem then for i=0,reaper.CountTrackMediaItems(selected_track)-1 do
      local item=reaper.GetTrackMediaItem(selected_track,i); local candidate=item and reaper.GetActiveTake(item)
      if candidate and Take.valid(candidate) then
        local position=reaper.GetMediaItemInfo_Value(item,'D_POSITION'); local ending=position+reaper.GetMediaItemInfo_Value(item,'D_LENGTH')
        local distance=cursor<position and position-cursor or cursor>ending and cursor-ending or 0
        if not nearest_distance or distance<nearest_distance then track_take,nearest_distance=candidate,distance end
      end
    end end
  end
  local current_track=nil
  if self.take and Take.valid(self.take) and reaper.GetMediaItemTake_Track then
    local ok,track=pcall(reaper.GetMediaItemTake_Track,self.take); if ok then current_track=track end
  end
  local preferred=new_take or (current_selected and self.take) or (selected[1] and selected[1].take) or (selected_track==current_track and self.take) or track_take
  self.arrange_selected_items=seen
  local take
  if selected_track and not preferred and #selected==0 then take=nil else take=Take.active(preferred) end
  if take==self.take then self.empty_track=not take and selected_track or nil; if take then self:sync_item_bounds(take,true) end; return end
  if self.transform_preview then self.transforms.cancel_preview(self) end
  if self.lane_tool_preview then LaneTools.cancel(self) end
  self:flush_property_wheel(true)
  if self.edit.active then self.edit:finish() end; self.audition:stop(); self.gesture=nil; Selection.clear(self.selection)
  self.take=take; self.empty_track=not take and selected_track or nil; self.cache:set_take(take); self.cc_cache:set_take(take); self.note_names={}; self.key_map_selection={}
  if take then
    self.take_name=Take.name(take); self:sync_item_bounds(take,false)
    local duration=math.max(.25,self.item_end_qn-self.item_start_qn); self.settings.visible_qn=math.max(1,duration*1.2); self.settings.start_qn=math.max(0,self.item_start_qn-(self.settings.visible_qn-duration)*.5)
    self.key_map_track=reaper.GetMediaItemTake_Track and reaper.GetMediaItemTake_Track(take) or nil; self.key_colors=KeyMap.load_track(self.key_map_track)
    if self.key_map_track then self.last_take_by_track[tostring(self.key_map_track)]=take end
    if self.pending_note_select and self.pending_note_select.take==take then
      local target=self.pending_note_select; self.cache:rebuild()
      for _,n in ipairs(self.cache.notes) do
        local q=reaper.MIDI_GetProjQNFromPPQPos(take,n.s)
        if n.pitch==target.pitch and math.abs(q-target.qn)<.001 then Selection.set_only(self.selection,n.id); break end
      end
      self.pending_note_select=nil
    end
  else self.take_name='No MIDI take selected'; self.key_map_track=nil; self.key_colors={} end
end
function App:save_key_colors() KeyMap.save_track(self.key_map_track,self.key_colors) end
function App:focus_take(take,note)
  if not Take.valid(take) then return false end
  local item=Take.item(take); if not item then return false end
  if reaper.SelectAllMediaItems then reaper.SelectAllMediaItems(0,false) end
  if reaper.SetMediaItemSelected then reaper.SetMediaItemSelected(item,true) end
  if reaper.UpdateArrange then reaper.UpdateArrange() end
  if note then self.pending_note_select={take=take,pitch=note.pitch,qn=note.s_qn} end
  self.next_take_poll=0; self:poll_take(); return true
end
function App:create_empty_item(track,qn)
  if not track or not reaper.CreateNewMIDIItemInProj then return false end
  local _,bar_start,bar_end=reaper.TimeMap_QNToMeasures(0,qn)
  bar_start,bar_end=bar_start or math.floor(qn/4)*4,bar_end or (math.floor(qn/4)+1)*4
  local bars=math.max(1,math.floor(self.settings.empty_item_bars or 4))
  for _=2,bars do
    local _,next_start,next_end=reaper.TimeMap_QNToMeasures(0,bar_end+.000001)
    if not next_end or next_end<=bar_end then break end
    bar_end=next_end
  end
  reaper.Undo_BeginBlock2(0)
  local item=reaper.CreateNewMIDIItemInProj(track,reaper.TimeMap2_QNToTime(0,bar_start),reaper.TimeMap2_QNToTime(0,bar_end),false)
  local take=item and reaper.GetActiveTake(item)
  if not take or not Take.valid(take) then reaper.Undo_EndBlock2(0,'ReaRoll: create MIDI item',-1); return false end
  reaper.SelectAllMediaItems(0,false); reaper.SetMediaItemSelected(item,true); reaper.UpdateArrange()
  reaper.Undo_EndBlock2(0,'ReaRoll: create '..tostring(bars)..'-bar MIDI item',-1)
  self.next_take_poll=0; self:poll_take(); return true
end
function App:extend_item_end(target_qn)
  if not self.take or not target_qn or target_qn<=self.item_end_qn+.000001 then return false end
  local item=reaper.GetMediaItemTake_Item(self.take)
  if not item or not reaper.MIDI_SetItemExtents then return false end
  local ok=reaper.MIDI_SetItemExtents(item,self.item_start_qn,target_qn)
  if ok then self.item_end_qn=target_qn; self.edit:touch(); reaper.UpdateArrange() end
  return ok
end
function App:set_item_extents(start_qn,end_qn)
  if not self.take or not start_qn or not end_qn or end_qn<=start_qn then return false end
  local item=reaper.GetMediaItemTake_Item(self.take)
  if not item or not reaper.MIDI_SetItemExtents then return false end
  local ok=reaper.MIDI_SetItemExtents(item,start_qn,end_qn)
  if ok then
    self.item_start_qn,self.item_end_qn=start_qn,end_qn
    self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end; reaper.UpdateArrange()
  end
  return ok
end
function App:note_label(pitch)
  local key=self.settings.channel..':'..pitch
  if self.note_names[key]~=nil then return self.note_names[key] or nil end
  local name=nil
  if self.take and reaper.GetTrackMIDINoteNameEx and reaper.GetMediaItemTake_Track then
    local track=reaper.GetMediaItemTake_Track(self.take)
    local ok,value=pcall(reaper.GetTrackMIDINoteNameEx,0,track,pitch,self.settings.channel)
    if ok and value and value~='' then name=value end
  end
  self.note_names[key]=name or false
  return name
end
function App:fit_notes()
  if not self.take then return end; local notes=self.cache:get(false)
  local lo,hi,minppq,maxppq=127,0,math.huge,-math.huge
  for _,n in ipairs(notes) do lo=math.min(lo,n.pitch); hi=math.max(hi,n.pitch); minppq=math.min(minppq,n.s); maxppq=math.max(maxppq,n.e) end
  local q0=minppq<math.huge and reaper.MIDI_GetProjQNFromPPQPos(self.take,minppq) or math.huge
  local q1=maxppq>-math.huge and reaper.MIDI_GetProjQNFromPPQPos(self.take,maxppq) or -math.huge
  if self.settings.ghost_enabled then for _,n in ipairs(self.ghost:get(self.take,self.settings.ghost_mode,false,self.source_visibility,self.source_revision)) do
    lo=math.min(lo,n.pitch); hi=math.max(hi,n.pitch); q0=math.min(q0,n.s_qn); q1=math.max(q1,n.e_qn)
  end end
  if q0==math.huge then self.settings.start_qn=self.item_start_qn; self.settings.visible_qn=8; return end
  self.settings.start_qn=q0-.5; self.settings.visible_qn=math.max(1,(q1-q0)+1); self.settings.low_pitch=math.max(0,lo-2)
  if self.viewport.h then self.settings.row_height=math.max(8,math.min(32,self.viewport.h/(hi-lo+5))) end
end
function App:fit_time()
  if not self.take then return end; local notes=self.cache:get(false); if #notes==0 then self.settings.start_qn=self.item_start_qn; self.settings.visible_qn=8; return end
  local minppq,maxppq=math.huge,-math.huge; for _,n in ipairs(notes) do minppq=math.min(minppq,n.s); maxppq=math.max(maxppq,n.e) end
  local q0=reaper.MIDI_GetProjQNFromPPQPos(self.take,minppq); local q1=reaper.MIDI_GetProjQNFromPPQPos(self.take,maxppq); self.settings.start_qn=q0-.5; self.settings.visible_qn=math.max(1,q1-q0+1)
end
function App:fit_pitches()
  if not self.take then return end; local notes=self.cache:get(false); if #notes==0 then self.settings.low_pitch=48; self.settings.row_height=14; return end
  local lo,hi=127,0; for _,n in ipairs(notes) do lo=math.min(lo,n.pitch); hi=math.max(hi,n.pitch) end; self.settings.low_pitch=math.max(0,lo-2)
  if self.viewport.h then self.settings.row_height=math.max(8,math.min(32,self.viewport.h/(hi-lo+5))) end
end
function App:fit_selection()
  local chosen=Selection.list(self.selection,self.cache:get(false)); if #chosen==0 then return self:fit_notes() end
  local lo,hi,minppq,maxppq=127,0,math.huge,-math.huge
  for _,n in ipairs(chosen) do lo=math.min(lo,n.pitch); hi=math.max(hi,n.pitch); minppq=math.min(minppq,n.s); maxppq=math.max(maxppq,n.e) end
  local q0=reaper.MIDI_GetProjQNFromPPQPos(self.take,minppq); local q1=reaper.MIDI_GetProjQNFromPPQPos(self.take,maxppq)
  self.settings.start_qn=q0-.25; self.settings.visible_qn=math.max(.5,(q1-q0)+.5); self.settings.low_pitch=math.max(0,lo-2)
  if self.viewport.h then self.settings.row_height=math.max(8,math.min(32,self.viewport.h/(hi-lo+5))) end
end
function App:repair_overlaps()
  if not self.take or (self.cache.overlap_count or 0)==0 then return false end
  local editor=reaper.MIDIEditor_GetActive and reaper.MIDIEditor_GetActive() or nil
  if not editor then
    reaper.Main_OnCommand(40153,0) -- Open selected item in REAPER's built-in MIDI editor.
    editor=reaper.MIDIEditor_GetActive and reaper.MIDIEditor_GetActive() or nil
  end
  if not editor or not reaper.MIDIEditor_GetTake or reaper.MIDIEditor_GetTake(editor)~=self.take then
    self.transform_notice='REAPER could not open the active take in its built-in MIDI editor.'; return false
  end
  reaper.MIDIEditor_OnCommand(editor,40659)
  self.cache:invalidate(); self.cache:rebuild(); Selection.clear(self.selection)
  self.transform_notice=(self.cache.overlap_count or 0)==0 and 'REAPER corrected the overlapping notes.' or 'Some ambiguous overlaps remain.'
  return (self.cache.overlap_count or 0)==0
end
function App:zoom_time(factor,mx)
  if not self.viewport.w then return end
  -- The caller chooses the focus explicitly: wheel gestures pass the pointer,
  -- while buttons and shortcuts pass the centre of the grid.
  self.viewport:zoom_time(factor,mx)
end
function App:zoom_bar(factor)
  local v,s=self.viewport,self.settings
  if not v.w then return end
  local cursor=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())
  local focus=self.bar_zoom_focus
  if not focus or focus.take~=self.take or math.abs(focus.cursor-cursor)>1e-9
    or math.abs(focus.last_start-s.start_qn)>1e-9 or math.abs(focus.last_visible-s.visible_qn)>1e-9 then
    -- An off-screen edit cursor must not yank the user to another phrase.
    local qn=math.max(s.start_qn,math.min(s.start_qn+s.visible_qn,cursor))
    focus={take=self.take,cursor=cursor,qn=qn,ratio=(qn-s.start_qn)/s.visible_qn}
    self.bar_zoom_focus=focus
  end
  v:zoom_time_at(factor,focus.qn,focus.ratio)
  focus.last_start=s.start_qn; focus.last_visible=s.visible_qn
end
function App:flush_property_wheel(force)
  local state=self.property_wheel; if not state or not force and reaper.time_precise()<state.deadline then return false end
  self.edit:finish(); self.cache:rebuild(); self.cc_cache:rebuild(); if state.wanted then self:reselect_notes(state.wanted) end; self.property_wheel=nil; return true
end
function App:shutdown()
  if self.shut_down then return end; self.shut_down=true
  if self.transform_preview then self.transforms.cancel_preview(self) end
  if self.lane_tool_preview then LaneTools.cancel(self) end
  self:flush_property_wheel(true); self.audition:stop(); if self.edit.active then self.edit:finish() end; Settings.save(self.settings); Shortcuts.save(self.settings)
end
function App:frame()
  local I,c=self.ImGui,self.ctx
  if I.GetFrameCount then
    local frame=I.GetFrameCount(c)
    if self.last_ui_frame==frame then
      if self.open then reaper.defer(function()self:frame()end) else self:shutdown() end
      return
    end
    self.last_ui_frame=frame
  end
  self:poll_take(); local T=self.theme
  self:flush_property_wheel(false)
  local ui_scale=math.max(.8,math.min(1.5,self.settings.ui_scale or 1))
  local rescue=reaper.GetExtState('ReaRoll','window_rescue')=='1'
  if rescue then reaper.DeleteExtState('ReaRoll','window_rescue',false) end
  if rescue then
    if I.SetNextWindowDockID then I.SetNextWindowDockID(c,0,I.Cond_Always) end
    if I.GetMainViewport and I.Viewport_GetCenter and I.SetNextWindowPos then
      local center_x,center_y=I.Viewport_GetCenter(I.GetMainViewport(c))
      I.SetNextWindowPos(c,center_x,center_y,I.Cond_Always,.5,.5)
    end
    I.SetNextWindowSize(c,1040*ui_scale,390*ui_scale,I.Cond_Always)
  else I.SetNextWindowSize(c,1040*ui_scale,390*ui_scale,I.Cond_FirstUseEver) end
  I.PushStyleColor(c,I.Col_WindowBg,T.bg); I.PushStyleColor(c,I.Col_ChildBg,T.bg); I.PushStyleColor(c,I.Col_Border,T.grid)
  I.PushStyleColor(c,I.Col_Button,T.panel2); I.PushStyleColor(c,I.Col_ButtonHovered,T.beat); I.PushStyleColor(c,I.Col_ButtonActive,T.note)
  I.PushStyleColor(c,I.Col_FrameBg,T.panel2); I.PushStyleColor(c,I.Col_FrameBgHovered,T.beat); I.PushStyleColor(c,I.Col_FrameBgActive,T.ruler_top)
  I.PushStyleColor(c,I.Col_Header,T.panel2); I.PushStyleColor(c,I.Col_HeaderHovered,T.beat); I.PushStyleColor(c,I.Col_HeaderActive,T.ruler_top)
  I.PushStyleColor(c,I.Col_Separator,T.grid); I.PushStyleColor(c,I.Col_CheckMark,T.accent); I.PushStyleColor(c,I.Col_SliderGrab,T.accent)
  I.PushStyleColor(c,I.Col_Text,T.text); I.PushStyleColor(c,I.Col_TextDisabled,T.hint); I.PushStyleColor(c,I.Col_PopupBg,T.panel)
  I.PushStyleVar(c,I.StyleVar_WindowPadding,0,7*ui_scale); I.PushStyleVar(c,I.StyleVar_FrameRounding,5*ui_scale); I.PushStyleVar(c,I.StyleVar_ItemSpacing,6*ui_scale,5*ui_scale)
  I.PushStyleVar(c,I.StyleVar_FramePadding,7*ui_scale,3*ui_scale); I.PushStyleVar(c,I.StyleVar_PopupRounding,6*ui_scale)
  local font_pushed=I.PushFont and pcall(I.PushFont,c,nil,13*ui_scale) or false
  local visible; visible,self.open=I.Begin(c,'ReaRoll',self.open,I.WindowFlags_NoScrollbar|I.WindowFlags_NoScrollWithMouse)
  if visible then
    Grid.update(self)
    Toolbar.draw(self); I.Separator(c)
    if self.take then
      local width,height=I.GetContentRegionAvail(c)
      local sources_width=self.sources_open and math.min(174*ui_scale,math.max(148*ui_scale,width*.15)) or 0
      local spacing=(self.sources_open and 7*ui_scale or 0)
      if self.sources_open then
        draw_child(I,c,'##midi_sources_panel',sources_width,height,function() Sources.draw(self) end); I.SameLine(c)
      end
      local canvas_width=math.max(180,width-sources_width-spacing)
      -- The piano-roll workspace owns its complete geometry. Child padding
      -- otherwise leaves an inherited empty strip below the bottom toolbar.
      I.PushStyleVar(c,I.StyleVar_WindowPadding,0,0)
      draw_child(I,c,'##piano_roll_workspace',canvas_width,height,function() Canvas.draw(self) end,I.WindowFlags_NoScrollbar|I.WindowFlags_NoScrollWithMouse)
      I.PopStyleVar(c)
    elseif self.empty_track then
      local width,height=I.GetContentRegionAvail(c); I.PushStyleVar(c,I.StyleVar_WindowPadding,0,0)
      draw_child(I,c,'##empty_piano_roll_workspace',width,height,function() Canvas.draw_empty(self,self.empty_track) end,I.WindowFlags_NoScrollbar|I.WindowFlags_NoScrollWithMouse)
      I.PopStyleVar(c)
    else I.Dummy(c,1,70); I.TextDisabled(c,'Select a track or MIDI item to start sketching.'); I.TextDisabled(c,'On an empty selected track, click the grid to create a MIDI item using the configured bar length.') end
  end
  if visible then I.End(c) end
  Toolbar.draw_chord_palette(self); KeyMapUI.draw(self); Appearance.draw(self); Help.draw(self); ShortcutUI.draw(self); if font_pushed then I.PopFont(c) end; I.PopStyleVar(c,5); I.PopStyleColor(c,18)
  self.edit:flush()
  if self.open then reaper.defer(function() self:frame() end) else self:shutdown() end
end
return App
