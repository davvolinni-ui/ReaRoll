-- @noindex
local Selection=require 'src.selection'
local U=require 'src.util'
local M={}
local Icons=require 'src.ui.icons'
local Controls=require 'src.ui.controls'
local Grid=require 'src.grid'
local Harmony=require 'src.ui.harmony'
local Workspace=require 'src.ui.workspace'
local grids={{'1/4',1},{'1/8',.5},{'1/16',.25},{'1/32',.125},{'1/16T',1/6}}

local function main_menu(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if Icons.button(app,'main_menu','more','Menu and Setup') then I.OpenPopup(c,'##main_menu') end
  if I.BeginPopup(c,'##main_menu') then
    I.TextDisabled(c,'ReaRoll 0.7.0-test'); I.Separator(c)
    if I.MenuItem(c,'Quick guide...') then app.help_open=true end
    Workspace.menu(app)
    if I.MenuItem(c,'Mouse tooltips',nil,s.tooltips_enabled~=false)then s.tooltips_enabled=s.tooltips_enabled==false end
    if I.MenuItem(c,'Reset view') then s.start_qn=app.item_start_qn or 0; s.low_pitch=48; s.visible_qn=8; s.row_height=14 end
    if I.MenuItem(c,'Center C4') then s.low_pitch=48; s.row_height=14 end
    if I.BeginMenu(c,'New MIDI item length') then
      for _,bars in ipairs({1,2,4,8,16}) do if I.MenuItem(c,tostring(bars)..' bar'..(bars==1 and '' or 's'),nil,s.empty_item_bars==bars) then s.empty_item_bars=bars end end
      I.EndMenu(c)
    end
    I.Separator(c)
    if I.MenuItem(c,'Appearance...') then app.appearance_open=true end
    if I.MenuItem(c,'Shortcuts and mouse modifiers...') then app.shortcuts_open=true end
    local changed
    if I.MenuItem(c,'CC follows notes',nil,s.cc_follows_notes==true)then s.cc_follows_notes=not s.cc_follows_notes end
    if I.IsItemHovered(c)then I.SetTooltip(c,'Move and copy controllers with notes. A complete sustain cycle follows when all affected notes move together; otherwise the shared pedal stays in place. MPE voice expression always follows its note.')end
    changed,s.prevent_overlaps=I.Checkbox(c,'Prevent same-pitch overlaps',s.prevent_overlaps)
    if I.IsItemHovered(c) then I.SetTooltip(c,'When enabled, note edits trim or replace overlapping notes on the same pitch and MIDI channel.\nWhen disabled, overlaps are allowed and neighboring notes keep their timing and length.') end
    changed,s.ghost_enabled=I.Checkbox(c,'Ghost notes',s.ghost_enabled)
    I.Separator(c); I.TextDisabled(c,'MIDI composition and editing'); I.EndPopup(c)
  end
end

function M.draw(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  local z=math.max(.8,math.min(1.5,s.ui_scale or 1))
  local Overlap=require 'src.overlap_mode'
  local overlap_owner=app
  if app.multi_edit_mode then
   local target=require('src.multi_notes').creation_take(app)
   if target then overlap_owner=require('src.expression_scope').owner(app,target)end
  end
  local overlap_config,overlap_error=Overlap.state(overlap_owner)
  local overlap_count=app.cache.overlap_count or 0
  local slots={}
  local function slot(width,gap)slots[#slots+1]={width=width or 28*z,gap=gap or 4*z}end
  local function text_width(text)return I.CalcTextSize(c,text)+14*z end
  local range_width=math.max(28*z,text_width('88'))
  slot() -- Item scope.
  for _=1,7 do slot()end -- Note tools.
  slot(nil,8*z);slot();slot() -- Chords and scale.
  slot(nil,8*z);slot(66*z);slot(90*z) -- Snap, grid, insert length.
  slot(54*z,8*z);slot();slot(75*z) -- Velocity, audition, channel.
  slot(text_width('Fit'),8*z);slot(text_width('Sel'));slot() -- Navigation.
  if s.prevent_overlaps and overlap_count>0 then slot(text_width('Fix overlaps ('..tostring(overlap_count)..')'))end
  slot() -- Glide.
  if overlap_error then slot(text_width('Recover...'))end
  if overlap_config then slot(range_width)end
  slot();slot();slot() -- MPE, selection properties, expression editor.
  local layout=require('src.ui.toolbar_layout').new(app,slots)
  local function same_line()layout:next()end
  if Icons.button(app,'sources_panel','ghost','MIDI Track List',app.sources_open) then app.sources_open=not app.sources_open; if app.sources_open then s.ghost_enabled=true end end
  same_line(28*math.max(.8,math.min(1.5,s.ui_scale or 1)))
  local scope_locked=not app.take or app.gesture~=nil or app.edit.active~=nil or app.expression_direct_gesture~=nil or app.transform_preview~=nil or app.multi_notes and(app.multi_notes.transaction~=nil or app.multi_notes.paint~=nil or app.multi_notes.drag~=nil)or false
  I.BeginDisabled(c,scope_locked)
  if Icons.button(app,'item_scope','item_scope',app.multi_edit_mode and 'Multiple items: click to edit a single item'or 'Single item: click to edit multiple MIDI items',app.multi_edit_mode==true)then
    local Multi=require 'src.multi_notes';if app.multi_edit_mode then Multi.exit(app)else Multi.enter(app)end
  end
  I.EndDisabled(c)
  same_line()
  local first_center_item=true
  local function group_gap()
    same_line(32,8)
  end
  local function icon(id,kind,tip,active)
    if not first_center_item then same_line(28*math.max(.8,math.min(1.5,s.ui_scale or 1))) end
    first_center_item=false
    return Icons.button(app,id,kind,tip,active)
  end
  local modes={'smart','select','paint','slice','glue','mute','razor'}
  for index,mode in ipairs(modes) do
    local name=mode:sub(1,1):upper()..mode:sub(2)
    local tip=name..' tool'
    if mode=='paint'then tip=tip..'\nRight-click: pattern settings\nPaint locks the starting pitch; hold Shift during the stroke to change pitch.'end
    local clicked,hot=icon('mode_'..mode,mode,tip,s.mode==mode)
    if clicked then require('src.midi_mode').tool(app,mode)end
    if mode=='paint'then
      local x=I.GetItemRectMin(c);local _,bottom=I.GetItemRectMax(c)
      if x and bottom then app.paint_popup_anchor={x=x,y=bottom+4}end
      if hot and not I.IsAnyItemActive(c)and I.IsMouseClicked(c,I.MouseButton_Right)then I.OpenPopup(c,'##paint_settings')end
    end
  end
  if app.paint_popup_anchor and I.IsPopupOpen(c,'##paint_settings')then
    local z=math.max(.8,math.min(1.5,s.ui_scale or 1))
    I.SetNextWindowPos(c,app.paint_popup_anchor.x,app.paint_popup_anchor.y,I.Cond_Appearing)
    I.SetNextWindowSizeConstraints(c,230*z,0,230*z,480*z)
  end
  if I.BeginPopup(c,'##paint_settings')then
    I.TextDisabled(c,'Paint pattern');I.Separator(c)
    for _,every in ipairs({1,2,3,4,6,8,16})do
      if I.MenuItem(c,every==1 and 'Every grid cell' or ('Every '..every..' grid cells'),nil,(s.paint_every or 1)==every)then s.paint_every=every end
    end
    I.Separator(c);I.TextWrapped(c,'Notes are one grid cell long. Hold Shift during a stroke to paint across pitches.')
    I.EndPopup(c)
  end
  group_gap()
  local chord_clicked,chord_hot=Icons.button(app,'mode_chord','chord','Chord tool\nRight-click: chord library',s.mode=='chord')
  if chord_clicked then require('src.midi_mode').tool(app,'chord')end
  if chord_hot and I.IsMouseClicked(c,I.MouseButton_Right) then Harmony.open(app) end
  if icon('scale_options','scale','Harmony: key, scale and chord voicings',s.scale_enabled or s.scale_snap) then Harmony.open(app) end
  if icon('scale_rows','scale_rows','Show only notes in the selected scale',s.scale_view_only)then s.scale_view_only=not s.scale_view_only end
  group_gap()
  local snap_mode=U.snap_mode(s); local snap_names={off='Off',absolute='Absolute',relative='Relative'}
  local snap_icon=snap_mode=='relative' and 'snap_relative' or 'snap_absolute'
  local snap_clicked,snap_hot=Icons.button(app,'snap',snap_icon,'Snap: '..snap_names[snap_mode]..'\nClick: cycle Off / Absolute / Relative\nRight-click: Absolute',snap_mode~='off')
  if snap_clicked then snap_mode=snap_mode=='off' and 'absolute' or snap_mode=='absolute' and 'relative' or 'off'; s.snap_mode=snap_mode; s.snap_enabled=snap_mode~='off' end
  if snap_hot and I.IsMouseClicked(c,I.MouseButton_Right) then s.snap_mode='absolute'; s.snap_enabled=true end
  same_line(66); I.SetNextItemWidth(c,66*z)
  local grid=s.adaptive_grid and 'Auto' or 'Grid'; if not s.adaptive_grid then for _,g in ipairs(grids) do if math.abs(g[2]-s.grid_qn)<.0001 then grid=g[1] end end end
  if I.BeginCombo(c,'##toolbar_grid_combo',grid) then
    if I.Selectable(c,'Adaptive',s.adaptive_grid) then s.adaptive_grid=true end
    for _,g in ipairs(grids) do if I.Selectable(c,g[1],not s.adaptive_grid and math.abs(g[2]-s.grid_qn)<.0001) then s.adaptive_grid=false; s.grid_qn=g[2] end end
    I.EndCombo(c)
  end
  if Controls.choice(app,s,'grid_qn',.25,{.125,1/6,.25,.5,1},'Grid (quarter notes)') then s.adaptive_grid=false end
  same_line(90); I.SetNextItemWidth(c,90*z)
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
  group_gap(); I.SetNextItemWidth(c,54*z); local changed
  changed,s.velocity=I.DragInt(c,'##toolbar_velocity',s.velocity,1,1,127,'V %d')
  Controls.number(app,s,'velocity',100,1,1,127,'Insert velocity')
  same_line()
  if Icons.button(app,'audition','speaker','Audition notes while drawing, moving and clicking keys',s.midi_preview_enabled)then s.midi_preview_enabled=not s.midi_preview_enabled;if not s.midi_preview_enabled then app.audition:stop()end end
  same_line(75); I.SetNextItemWidth(c,75*z)
  if I.BeginCombo(c,'##target_channel',(s.edit_all_channels==false and 'Only 'or 'Ch ')..tostring(s.channel+1)) then
    if I.Selectable(c,'Edit all channels',s.edit_all_channels~=false)then s.edit_all_channels=true end
    if I.Selectable(c,'Edit drawing channel only',s.edit_all_channels==false)then s.edit_all_channels=false end
    I.Separator(c)
    for ch=0,15 do if I.Selectable(c,'Channel '..tostring(ch+1),ch==s.channel) then s.channel=ch end end
    I.EndCombo(c)
  end
  Controls.number(app,s,'channel',0,1,0,15,'Active drawing/editing channel (0=channel 1)')
  if I.IsItemHovered(c) then I.SetTooltip(c,'Channel for newly drawn notes. Existing notes keep their channels. Open this selector to edit all channels or only the drawing channel.') end
  group_gap(); if I.SmallButton(c,'Fit##nav') then if app.multi_edit_mode then local state=app.multi_notes;local selected=state.selection;state.selection={};app:fit_selection();state.selection=selected else app:fit_notes()end end
  if I.IsItemHovered(c) then I.SetTooltip(c,'Fit all notes in time and pitch') end
  same_line(); I.BeginDisabled(c,Selection.count(app.selection)==0); if I.SmallButton(c,'Sel##nav') then app:fit_selection() end; I.EndDisabled(c)
  if I.IsItemHovered(c) then I.SetTooltip(c,'Zoom to selected notes') end
  same_line()
  local follow_active=s.follow_playback and not app.viewport.follow_suspended
  local follow_icon=not s.follow_playback and 'follow_off' or (app.viewport.follow_suspended and 'follow_suspended' or (s.follow_style=='continuous' and 'follow_continuous' or 'follow_page'))
  local follow_tip='Follow: '..app.viewport:follow_label()..'\nClick: cycle Off / Page / Continuous, or resume after manual scrolling.\nPage advances near the right edge. Continuous holds the playhead at 35% of the view.\nStop returns to the starting view; Pause keeps your place.'
  if Icons.button(app,'playback_follow',follow_icon,follow_tip,follow_active) then app.viewport:toggle_follow() end
  if s.prevent_overlaps and overlap_count>0 then
    same_line(); if I.SmallButton(c,'Fix overlaps ('..tostring(overlap_count)..')##native_overlap_fix') then app:repair_overlaps() end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Ambiguous same-channel, same-pitch overlaps detected.\nClick to open REAPER\'s native MIDI editor if needed and run Correct overlapping notes.\nThe MIDI editor will remain open afterward.') end
  end
  same_line(72)
  I.BeginDisabled(c,not app.take or app.gesture~=nil or app.edit.active~=nil or app.expression_direct_gesture~=nil or (app.multi_notes~=nil and(app.multi_notes.transaction~=nil or app.multi_notes.paint~=nil or app.multi_notes.drag~=nil)))
  if Icons.button(app,'glide','slide',overlap_error or 'Glide: overlap notes or chords to bend into the next notes. The overlap sets the timing. With MPE, chord voices glide independently.',overlap_config~=nil)then
    local ok,notice=Overlap.set(overlap_owner,not overlap_config);app.expression_notice=notice
    if ok then app.cache:invalidate();app.cc_cache:invalidate();if app.multi_edit_mode then require('src.multi_notes').refresh(app,true)end end
  end
  I.EndDisabled(c)
  if overlap_error then
    same_line(68)
    if I.SmallButton(c,'Recover...##overlap')then I.OpenPopup(c,'##overlap_recover')end
    if I.BeginPopup(c,'##overlap_recover')then
      I.TextWrapped(c,'Keep the current notes and bends as ordinary MIDI and remove the stored overlap score. This does not restore the original overlapping notes. Undo can reverse this recovery.')
      if I.Button(c,'Keep external MIDI')then
        local ok,notice=Overlap.keep_external(overlap_owner);app.expression_notice=notice
        if ok then app.cache:invalidate();app.cc_cache:invalidate();if app.multi_edit_mode then require('src.multi_notes').refresh(app,true)end end
        I.CloseCurrentPopup(c)
      end
      I.EndPopup(c)
    end
  end
  if overlap_config then
    same_line(58)
    local drawing_setup=Overlap.drawing_settings(overlap_owner)
    local range=drawing_setup.mpe_enabled and drawing_setup.mpe_pitch_bend_range or drawing_setup.pitch_bend_range
    if app.glide_range_take~=overlap_owner.take or app.glide_range_saved~=range then
      app.glide_range_take=overlap_owner.take;app.glide_range_saved=range;app.glide_range_draft=range
    end
    I.SetNextItemWidth(c,range_width)
    I.BeginDisabled(c,app.gesture~=nil or app.edit.active~=nil)
    local changed;changed,app.glide_range_draft=I.InputInt(c,'##glide_range_inline',app.glide_range_draft or range,0,0)
    if I.IsItemDeactivatedAfterEdit(c)then
      local ok,notice=Overlap.range(overlap_owner,app.glide_range_draft);app.expression_notice=notice
      if ok then app.cache:invalidate();app.cc_cache:invalidate();if app.multi_edit_mode then require('src.multi_notes').refresh(app,true)end
      else app.glide_range_draft=range end
    end
    if I.IsItemHovered(c)then I.SetTooltip(c,'Pitch-bend range (+/- semitones). Type a value, then click away. Match your instrument; ReaRoll cannot read its range automatically.')end
    I.EndDisabled(c)
  end
  same_line(58)
  I.BeginDisabled(c,app.gesture~=nil or app.edit.active~=nil or app.expression_direct_gesture~=nil)
  if Icons.button(app,'mpe','mpe','MPE: independent note voices with Pitch, Pressure and Timbre. Click to enable or disable MPE mode.',s.mpe_enabled==true)then
    local ok,notice=require('src.midi_mode').set(app,not s.mpe_enabled);app.expression_notice=notice
  end
  I.EndDisabled(c)
  same_line(28*math.max(.8,math.min(1.5,s.ui_scale or 1)))
  if Icons.button(app,'selection_properties','setup','Selection properties',s.inspector_open)then s.inspector_open=not s.inspector_open end
  same_line(28*math.max(.8,math.min(1.5,s.ui_scale or 1)))
  if Icons.button(app,'expression_editor','expression','Show / hide the note-expression editor',app.expression_editor_open)then require('src.midi_mode').view(app,not app.expression_editor_open)end
  layout:menu();main_menu(app);layout:finish()
  -- Feedback lives in the fixed canvas status line / expression panel.
  -- Adding wrapped rows here moves the note grid underneath a held gesture.
end

function M.draw_chord_palette(app) Harmony.draw(app) end
return M
