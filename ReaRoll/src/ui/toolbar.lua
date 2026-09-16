-- @noindex
local Selection=require 'src.selection'
local U=require 'src.util'
local M={}
local Icons=require 'src.ui.icons'
local Controls=require 'src.ui.controls'
local Grid=require 'src.grid'
local Suite=require 'src.suite_theme'
local Appearance=require 'src.ui.appearance'
local grids={{'1/4',1},{'1/8',.5},{'1/16',.25},{'1/32',.125},{'1/16T',1/6}}

local function chord_controls(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  local changed; changed,s.chord_diatonic=I.Checkbox(c,'Use selected scale',s.chord_diatonic)
  changed,s.chord_drag_length=I.Checkbox(c,'Drag to set length',s.chord_drag_length)
  if I.IsItemHovered(c) then I.SetTooltip(c,'Press and drag to set the duration of all chord notes. Disable for one-click stamping.') end
  I.SetNextItemWidth(c,190)
  if I.BeginCombo(c,'Fixed shape##chord_type',s.chord_name) then
    if app.music.chord_groups then
      for _,group in ipairs(app.music.chord_groups) do
        if I.BeginMenu(c,group[1]) then
          for _,name in ipairs(group[2]) do if I.Selectable(c,name,name==s.chord_name) then s.chord_name=name end end
          I.EndMenu(c)
        end
      end
    else
      for _,name in ipairs(app.music.chord_order) do if I.Selectable(c,name,name==s.chord_name) then s.chord_name=name end end
    end
    I.EndCombo(c)
  end
  I.BeginDisabled(c,not s.chord_diatonic)
  if I.RadioButton(c,'Triad',s.chord_size==3) then s.chord_size=3; s.chord_inversion=math.min(s.chord_inversion,2) end
  I.SameLine(c); if I.RadioButton(c,'Seventh',s.chord_size==4) then s.chord_size=4 end
  I.EndDisabled(c)
  I.SetNextItemWidth(c,190)
  local inversion_count=s.chord_diatonic and (s.chord_size or 3) or #(app.music.chords[s.chord_name] or app.music.chords.Major)
  s.chord_inversion=math.min(s.chord_inversion,math.max(0,inversion_count-1))
  if I.BeginCombo(c,'Inversion##chord_inversion','Inversion '..tostring(s.chord_inversion)) then for inv=0,inversion_count-1 do if I.Selectable(c,'Inversion '..inv,s.chord_inversion==inv) then s.chord_inversion=inv end end; I.EndCombo(c) end
  I.TextDisabled(c,s.chord_diatonic and 'Scale mode builds from the clicked degree.' or 'Fixed mode uses the selected chord shape.')
end

local function main_menu(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if Icons.button(app,'main_menu','more','Menu and Setup') then I.OpenPopup(c,'##main_menu') end
  if I.BeginPopup(c,'##main_menu') then
    I.TextDisabled(c,'ReaRoll 0.4 improvement preview'); I.Separator(c)
    if I.MenuItem(c,'Quick guide...') then app.help_open=true end
    if I.MenuItem(c,'Reset view') then s.start_qn=app.item_start_qn or 0; s.low_pitch=48; s.visible_qn=8; s.row_height=14 end
    if I.MenuItem(c,'Center C4') then s.low_pitch=48; s.row_height=14 end
    if I.BeginMenu(c,'New MIDI item length') then
      for _,bars in ipairs({1,2,4,8,16}) do if I.MenuItem(c,tostring(bars)..' bar'..(bars==1 and '' or 's'),nil,s.empty_item_bars==bars) then s.empty_item_bars=bars end end
      I.EndMenu(c)
    end
    I.Separator(c)
    if I.MenuItem(c,'Appearance...') then app.appearance_open=true end
    if I.MenuItem(c,'Keyboard shortcuts...') then app.shortcuts_open=true end
    local changed; changed,s.fold_enabled=I.Checkbox(c,'Fold to used pitches',s.fold_enabled)
    changed,s.prevent_overlaps=I.Checkbox(c,'Prevent same-pitch overlaps',s.prevent_overlaps)
    changed,s.ghost_enabled=I.Checkbox(c,'Ghost notes',s.ghost_enabled)
    I.Separator(c); I.TextDisabled(c,'Bottom-docked MIDI sketch editor'); I.EndPopup(c)
  end
end

local function view_menu(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if Icons.button(app,'view_menu','view','View') then I.OpenPopup(c,'##view_menu') end
  if I.BeginPopup(c,'##view_menu') then
    local changed; changed,s.fold_enabled=I.Checkbox(c,'Fold to used pitches',s.fold_enabled)
    if changed then s.fold_offset=0 end
    if Controls.toggle(app,s,'fold_enabled',false,'Fold') then s.fold_offset=0 end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Show only pitches used by notes in the active MIDI item') end
    I.Separator(c)
    if I.MenuItem(c,'Fit all notes') then app:fit_notes() end
    if I.MenuItem(c,'Zoom to selection') then app:fit_selection() end
    if I.MenuItem(c,'Center C4') then s.low_pitch=48; s.row_height=14 end
    I.Separator(c)
    I.BeginDisabled(c,not app.take or not app.viewport.w)
    if I.MenuItem(c,'Zoom time in') then app:zoom_time(.8,app.viewport.x+app.viewport.w*.5) end
    if I.MenuItem(c,'Zoom time out') then app:zoom_time(1.25,app.viewport.x+app.viewport.w*.5) end
    if I.MenuItem(c,'Increase note height') then app.viewport:zoom_pitch(1.18,app.viewport.y+app.viewport.h*.5) end
    if I.MenuItem(c,'Decrease note height') then app.viewport:zoom_pitch(.85,app.viewport.y+app.viewport.h*.5) end
    I.EndDisabled(c)
    I.Separator(c); I.TextDisabled(c,'Ctrl + wheel: timeline zoom'); I.TextDisabled(c,'Ctrl + Alt + wheel: pitch zoom'); I.TextDisabled(c,'Middle-drag: pan')
    I.EndPopup(c)
  end
end

local function setup_menu(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if Icons.button(app,'setup_menu','setup','Setup') then I.OpenPopup(c,'##setup_menu') end
  if I.BeginPopup(c,'##setup_menu') then
    if I.MenuItem(c,'Appearance / suite themes...') then app.appearance_open=true end
    if I.MenuItem(c,'Keyboard shortcuts...') then app.shortcuts_open=true end
    I.Separator(c)
    local changed; changed,s.scale_enabled=I.Checkbox(c,'Scale highlighting',s.scale_enabled)
    Controls.toggle(app,s,'scale_enabled',false,'Scale highlighting')
    if s.scale_enabled then
      I.SetNextItemWidth(c,70)
      if I.BeginCombo(c,'Root##scale_root',app.music.roots[s.scale_root+1]) then for i,n in ipairs(app.music.roots) do if I.Selectable(c,n,i-1==s.scale_root) then s.scale_root=i-1 end end; I.EndCombo(c) end
      Controls.number(app,s,'scale_root',0,1,0,11,'Scale root (C=0)')
      I.SetNextItemWidth(c,130)
      if I.BeginCombo(c,'Scale##scale_name',s.scale_name) then for _,n in ipairs(app.music.scale_order) do if I.Selectable(c,n,n==s.scale_name) then s.scale_name=n end end; I.EndCombo(c) end
      Controls.choice(app,s,'scale_name','Major',app.music.scale_order,'Scale')
      changed,s.scale_snap=I.Checkbox(c,'Pitch Safe',s.scale_snap)
      Controls.toggle(app,s,'scale_snap',false,'Pitch Safe')
    end
    I.Separator(c); changed,s.prevent_overlaps=I.Checkbox(c,'Prevent same-pitch overlaps',s.prevent_overlaps)
    if I.IsItemHovered(c) then I.SetTooltip(c,'Trim an earlier note when an edit would overlap another note on the same pitch and channel. This prevents ambiguous MIDI note-off pairing.') end
    I.Separator(c); changed,s.ghost_enabled=I.Checkbox(c,'Ghost notes',s.ghost_enabled)
    Controls.toggle(app,s,'ghost_enabled',false,'Ghost notes')
    if s.ghost_enabled then
      I.TextDisabled(c,'Sources are controlled by the MIDI Track List.')
    end
    I.EndPopup(c)
  end
end

function M.draw(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if Icons.button(app,'sources_panel','ghost','MIDI Track List',app.sources_open) then app.sources_open=not app.sources_open; if app.sources_open then s.ghost_enabled=true end end
  I.SameLine(c)
  if I.GetWindowWidth and I.GetCursorPosX and I.SetCursorPosX then
    local group_width=816
    I.SetCursorPosX(c,math.max(I.GetCursorPosX(c),(I.GetWindowWidth(c)-group_width)*.5))
  end
  local first_center_item=true
  local function group_gap()
    I.SameLine(c,0,24)
  end
  local function icon(id,kind,tip,active)
    if not first_center_item then I.SameLine(c) end
    first_center_item=false
    return Icons.button(app,id,kind,tip,active)
  end
  local modes={'smart','select','paint','slice','glue','mute'}
  for index,mode in ipairs(modes) do
    local name=mode:sub(1,1):upper()..mode:sub(2)
    local clicked,hot=icon('mode_'..mode,mode,name..' tool\nWheel: switch tools / right-click: Smart',s.mode==mode)
    if clicked then s.mode=mode end
    if hot and not I.IsAnyItemActive(c) then
      if I.IsMouseClicked(c,I.MouseButton_Right) then s.mode='smart' end
      local wheel=I.GetMouseWheel(c)
      if wheel~=0 then s.mode=modes[math.max(1,math.min(#modes,index+(wheel>0 and 1 or -1)))] end
    end
  end
  group_gap()
  local chord_clicked,chord_hot=Icons.button(app,'mode_chord','chord','Chord tool\nClick again for chord options',s.mode=='chord')
  if chord_clicked then
    if s.mode=='chord' then app.chord_palette_open=not app.chord_palette_open else s.mode='chord'; app.chord_palette_open=true end
  end
  if chord_hot and I.IsMouseClicked(c,I.MouseButton_Right) then app.chord_palette_open=true end
  if icon('scale_options','scale','Scale and highlighting options',s.scale_enabled) then I.OpenPopup(c,'##scale_options_popup') end
  if I.BeginPopup(c,'##scale_options_popup') then
    I.TextDisabled(c,'Scale & Highlighting'); I.Separator(c)
    local changed; changed,s.scale_enabled=I.Checkbox(c,'Highlight scale rows',s.scale_enabled)
    changed,s.scale_snap=I.Checkbox(c,'Pitch Safe drawing',s.scale_snap)
    I.SetNextItemWidth(c,90)
    if I.BeginCombo(c,'Root##header_scale_root',app.music.roots[s.scale_root+1]) then for i,n in ipairs(app.music.roots) do if I.Selectable(c,n,i-1==s.scale_root) then s.scale_root=i-1 end end; I.EndCombo(c) end
    I.SetNextItemWidth(c,170)
    if I.BeginCombo(c,'Scale##header_scale_name',s.scale_name) then
      if app.music.scale_groups then
        for _,group in ipairs(app.music.scale_groups) do
          if I.BeginMenu(c,group[1]) then
            for _,name in ipairs(group[2]) do if I.Selectable(c,name,name==s.scale_name) then s.scale_name=name end end
            I.EndMenu(c)
          end
        end
      else
        for _,name in ipairs(app.music.scale_order) do if I.Selectable(c,name,name==s.scale_name) then s.scale_name=name end end
      end
      I.EndCombo(c)
    end
    changed,s.scale_opacity=I.SliderDouble(c,'Highlight strength',s.scale_opacity or .16,.02,.40,'%.2f'); if changed then Appearance.apply(app) end
    local color_changed,color=I.ColorEdit4(c,'Highlight color',Appearance.to_widget_color(app.theme_state.colors.scale_highlight),I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoOptions)
    if color_changed then Suite.set_color(reaper,app.theme_state,'scale_highlight',Appearance.from_widget_color(color)); Appearance.apply(app) end
    I.EndPopup(c)
  end
  group_gap()
  local snap_mode=U.snap_mode(s); local snap_names={off='Off',absolute='Absolute',relative='Relative'}
  local snap_icon=snap_mode=='relative' and 'snap_relative' or 'snap_absolute'
  local snap_clicked,snap_hot=Icons.button(app,'snap',snap_icon,'Snap: '..snap_names[snap_mode]..'\nClick: cycle Off / Absolute / Relative\nRight-click: Absolute',snap_mode~='off')
  if snap_clicked then snap_mode=snap_mode=='off' and 'absolute' or snap_mode=='absolute' and 'relative' or 'off'; s.snap_mode=snap_mode; s.snap_enabled=snap_mode~='off' end
  if snap_hot and I.IsMouseClicked(c,I.MouseButton_Right) then s.snap_mode='absolute'; s.snap_enabled=true end
  I.SameLine(c); I.SetNextItemWidth(c,66)
  local grid=s.adaptive_grid and 'Auto' or 'Grid'; if not s.adaptive_grid then for _,g in ipairs(grids) do if math.abs(g[2]-s.grid_qn)<.0001 then grid=g[1] end end end
  if I.BeginCombo(c,'##toolbar_grid_combo',grid) then
    if I.Selectable(c,'Adaptive',s.adaptive_grid) then s.adaptive_grid=true end
    for _,g in ipairs(grids) do if I.Selectable(c,g[1],not s.adaptive_grid and math.abs(g[2]-s.grid_qn)<.0001) then s.adaptive_grid=false; s.grid_qn=g[2] end end
    I.EndCombo(c)
  end
  if Controls.choice(app,s,'grid_qn',.25,{.125,1/6,.25,.5,1},'Grid (quarter notes)') then s.adaptive_grid=false end
  I.SameLine(c); I.SetNextItemWidth(c,110)
  local current_length=Grid.note_length(s)
  local length_label=s.mode=='paint' and 'Grid' or (s.length_follow_grid and 'Grid' or string.format('%.3g QN',current_length))
  if s.mode~='paint' and not s.length_follow_grid then for _,g in ipairs({{'1 bar',4},{'1/2',2},{'1/4',1},{'1/8',.5},{'1/16',.25},{'1/32',.125}}) do if math.abs(current_length-g[2])<.00001 then length_label=g[1] end end end
  if I.BeginCombo(c,'##insert_length','Len '..length_label) then
    if I.Selectable(c,'Follow grid',s.length_follow_grid) then s.length_follow_grid=true; s.inherit_length=false end
    for _,g in ipairs({{'1 bar (4 QN)',4},{'1/2',2},{'1/4',1},{'1/8',.5},{'1/16',.25},{'1/32',.125},{'1/16 triplet',1/6}}) do
      if I.Selectable(c,g[1],not s.length_follow_grid and math.abs(s.length_qn-g[2])<.00001) then s.length_qn=g[2]; s.length_follow_grid=false; s.inherit_length=false end
    end
    local changed; changed,s.inherit_length=I.Checkbox(c,'Learn length from clicked notes',s.inherit_length)
    Controls.toggle(app,s,'inherit_length',true,'Learn note length')
    I.EndCombo(c)
  end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Length for Smart and Chord notes. Follow grid tracks fixed or adaptive grid changes.\nPaint always creates one grid-cell note per step.') end
  if s.mode~='paint' and Controls.choice(app,s,'length_qn',.25,{.125,1/6,.25,.5,1,2,4},'Insert length (quarter notes)') then s.length_follow_grid=false; s.inherit_length=false end
  group_gap(); I.SetNextItemWidth(c,54); local changed
  changed,s.velocity=I.DragInt(c,'##toolbar_velocity',s.velocity,1,1,127,'V %d')
  Controls.number(app,s,'velocity',100,1,1,127,'Insert velocity')
  I.SameLine(c); I.SetNextItemWidth(c,62)
  if I.BeginCombo(c,'##target_channel','Ch '..tostring(s.channel+1)) then
    for ch=0,15 do if I.Selectable(c,'Channel '..tostring(ch+1),ch==s.channel) then s.channel=ch end end
    I.EndCombo(c)
  end
  Controls.number(app,s,'channel',0,1,0,15,'Active drawing/editing channel (0=channel 1)')
  if I.IsItemHovered(c) then I.SetTooltip(c,'Active channel for drawing and direct note editing.\nOther channels remain visible but do not intercept the tools.\nSelect mode can select notes across all channels.') end
  group_gap(); if I.SmallButton(c,'Fit##nav') then app:fit_notes() end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Fit all notes in time and pitch') end
  I.SameLine(c); I.BeginDisabled(c,Selection.count(app.selection)==0); if I.SmallButton(c,'Sel##nav') then app:fit_selection() end; I.EndDisabled(c)
  if I.IsItemHovered(c) then I.SetTooltip(c,'Zoom to selected notes') end
  I.SameLine(c); if I.SmallButton(c,'-##time_zoom') then app:zoom_time(1.25,(app.viewport.x or 0)+(app.viewport.w or 1)*.5) end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Zoom timeline out') end
  I.SameLine(c); if I.SmallButton(c,'+##time_zoom') then app:zoom_time(.8,(app.viewport.x or 0)+(app.viewport.w or 1)*.5) end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Zoom timeline in') end
  local overlap_count=app.cache.overlap_count or 0
  if overlap_count>0 then
    I.SameLine(c); if I.SmallButton(c,'Fix overlaps ('..tostring(overlap_count)..')##native_overlap_fix') then app:repair_overlaps() end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Ambiguous same-channel, same-pitch overlaps detected.\nClick to open REAPER\'s native MIDI editor if needed and run Correct overlapping notes.\nThe MIDI editor will remain open afterward.') end
  end
  I.SameLine(c)
  if I.GetWindowWidth and I.GetCursorPosX and I.SetCursorPosX then I.SetCursorPosX(c,math.max(I.GetCursorPosX(c),I.GetWindowWidth(c)-38)) end
  main_menu(app)
end

function M.draw_chord_palette(app)
  if not app.chord_palette_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,238,150,I.Cond_FirstUseEver)
  local visible; visible,app.chord_palette_open=I.Begin(c,'Chord Palette',app.chord_palette_open,I.WindowFlags_AlwaysAutoResize)
  if visible then chord_controls(app) end
  if visible then I.End(c) end
end
return M
