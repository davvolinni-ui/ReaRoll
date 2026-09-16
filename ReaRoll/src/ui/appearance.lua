-- @noindex
local Suite=require 'src.suite_theme'
local Controls=require 'src.ui.controls'
local M={}
local function blend(a,b,t)
  local out=255
  for _,shift in ipairs({8,16,24}) do out=out|(math.floor(((a>>shift)&255)*(1-t)+((b>>shift)&255)*t+.5)<<shift) end
  return out
end
-- Draw-list colors in ReaRoll are stored as RRGGBBAA. ReaImGui's color-edit
-- widgets expose the same bytes as AARRGGBB, so convert only at the widget
-- boundary. Keeping this explicit prevents the palette from showing blue for
-- a dark gray such as 0x171A1EFF.
local function to_widget_color(color)
  return ((color&0xFF)<<24)|((color>>8)&0xFFFFFF)
end
local function from_widget_color(color)
  return ((color&0xFFFFFF)<<8)|((color>>24)&0xFF)
end
M.to_widget_color=to_widget_color
M.from_widget_color=from_widget_color
function M.apply(app)
  local c,T=app.theme_state.colors,app.theme
  if not app.settings.playhead_color_custom then app.settings.playhead_color=c.accent end
  local light=Suite.luminance(c.panel_bg)>145
  T.bg=c.window_bg; T.panel=c.panel_bg; T.panel2=blend(c.panel_bg,c.text,.08)
  T.text=c.text; T.hint=blend(c.text,c.panel_bg,.28); T.note=c.midi_note
  T.note_hover=blend(c.midi_note,c.text,.25); T.accent=c.accent; T.header_icon=c.header_icon
  T.selected=c.accent; T.selected_edge=blend(c.accent,c.text,.40)
  T.selected_text=c.selected_text; T.playhead=c.folder_text
  -- Keep row shading restrained, but preserve the user's grid-line color.
  -- Blending it down to 18% made subdivisions effectively disappear.
  T.row=blend(c.preview_bg,c.step_light,light and .72 or .40)
  T.row_alt=blend(blend(c.preview_bg,c.step_dark,light and .70 or .32),0x000000FF,light and .025 or .09)
  T.c_row=T.row
  -- Piano-roll divisions read as recessed grooves. If an imported grid color
  -- is brighter than its canvas, retain its hue elsewhere but use black as
  -- the line target so the roll never turns into a bright spreadsheet.
  local grid_target=Suite.luminance(c.preview_grid)<Suite.luminance(c.preview_bg) and c.preview_grid or 0x000000FF
  T.grid_soft=blend(c.preview_bg,grid_target,light and .34 or .27)
  T.grid=blend(c.preview_bg,grid_target,light and .46 or .35)
  T.beat=blend(c.preview_bg,grid_target,light and .58 or .47)
  T.bar=blend(c.preview_bg,grid_target,light and .70 or .59)
  T.beat_shade=(blend(c.preview_bg,c.text,light and .24 or .18)&0xFFFFFF00)|(light and 0x18 or 0x20)
  T.ruler=blend(c.panel_bg,c.preview_bg,.35); T.ruler_top=blend(c.panel_bg,c.text,.035)
  T.ruler_text=blend(c.text,c.panel_bg,.12); T.lane_header=blend(c.panel_bg,c.preview_bg,.22)
  T.lane_bg=blend(c.preview_bg,0x000000FF,light and .09 or .08); T.lane_grid=T.grid_soft
  T.lane_beat_shade=(blend(T.lane_bg,c.text,.18)&0xFFFFFF00)|0x14
  local scale_amount=math.max(.02,math.min(.40,app.settings.scale_opacity or .16))
  T.scale_row=blend(T.row,c.scale_highlight or c.accent,scale_amount*.55); T.root_row=blend(T.row,c.scale_highlight or c.accent,scale_amount)
  T.velocity=c.value_marker; T.scrollbar_track=c.window_bg; T.scrollbar_thumb=blend(c.panel_bg,c.text,.25)
  T.scrollbar_hover=blend(c.panel_bg,c.text,.45); T.channel_colors[1]=c.midi_note
  T.note_text=Suite.luminance(c.midi_note)>130 and 0x101820FF or 0xF0F3F7FF
  local c_key_target=light and 0x66717CFF or 0x515B67FF
  T.c_key=blend(T.white_key,c_key_target,.52); T.c_key_top=blend(T.white_key_top,c_key_target,.35)
  T.ghost_note=(c.text&0xFFFFFF00)|50; T.ghost_edge=(c.text&0xFFFFFF00)|85
  T.note_border=light and 0x202830AA or 0x090B0FAA
end
function M.init(app)
  app.theme_state=Suite.new(reaper); M.apply(app)
end
local function alternate_colors(app,key)
  local current=app.theme_state.colors[key]
  local out={}
  for _,choice in ipairs(app.theme_state.suggestions[key] or {}) do
    if #out>=4 then break end
    local duplicate=choice.color==current
    for _,existing in ipairs(out) do if existing==choice.color then duplicate=true end end
    if not duplicate then out[#out+1]=choice.color end
  end
  -- Fill sparse rows with tonal variations of the detected/active color, not
  -- unrelated built-in preset colors.
  for _,color in ipairs({blend(current,0xFFFFFFFF,.14),blend(current,0x000000FF,.14),blend(current,0xFFFFFFFF,.28),blend(current,0x000000FF,.28)}) do
    if #out>=4 then break end
    local duplicate=color==current
    for _,existing in ipairs(out) do if existing==color then duplicate=true end end
    if not duplicate then out[#out+1]=color end
  end
  return out
end
local function palette_row(app,key,active_x,alternate_x)
  local I,c=app.ImGui,app.ctx
  I.Text(c,Suite.LABELS[key])
  I.SameLine(c); I.SetCursorPosX(c,active_x); I.SetNextItemWidth(c,54)
  local flags=I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoOptions
  if I.ColorEditFlags_NoInputs then flags=flags|I.ColorEditFlags_NoInputs end
  if I.ColorEditFlags_NoLabel then flags=flags|I.ColorEditFlags_NoLabel end
  local changed,color=I.ColorEdit4(c,'##active_'..key,to_widget_color(app.theme_state.colors[key]),flags)
  if changed then Suite.set_color(reaper,app.theme_state,key,from_widget_color(color)); M.apply(app) end
  I.SameLine(c); I.SetCursorPosX(c,alternate_x)
  for index,alternate in ipairs(alternate_colors(app,key)) do
    if index>1 then I.SameLine(c) end
    if I.ColorButton(c,'##alternate_'..key..index,to_widget_color(alternate),I.ColorEditFlags_NoAlpha,34,24) then
      Suite.set_color(reaper,app.theme_state,key,alternate); M.apply(app)
    end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Use this alternate for '..Suite.LABELS[key]) end
  end
end
function M.draw(app)
  if not app.appearance_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,540,650,I.Cond_FirstUseEver)
  local visible; visible,app.appearance_open=I.Begin(c,'ReaRoll / Theme',app.appearance_open)
  if visible then
    if I.BeginTabBar(c,'##theme_tabs') then
      if I.BeginTabItem(c,'General') then
        I.Text(c,'Theme behavior')
        I.TextDisabled(c,'Colors are checked automatically for readable contrast.')
        local ui_changed; ui_changed,app.settings.ui_scale=I.SliderDouble(c,'Interface size',app.settings.ui_scale or 1,.80,1.50,'%.2fx')
        ui_changed=Controls.number(app,app.settings,'ui_scale',1,.05,.80,1.50,'Interface size') or ui_changed
        I.SameLine(c); I.TextDisabled(c,string.format('%d%%',math.floor((app.settings.ui_scale or 1)*100+.5)))
        local uniform_changed; uniform_changed,app.settings.uniform_note_color=I.Checkbox(c,'Use one note color for all MIDI channels',app.settings.uniform_note_color)
        Controls.toggle(app,app.settings,'uniform_note_color',false,'Uniform note color')
        local opacity_changed; opacity_changed,app.settings.scale_opacity=I.SliderDouble(c,'Scale highlight strength',app.settings.scale_opacity or .16,.02,.40,'%.2f')
        opacity_changed=Controls.number(app,app.settings,'scale_opacity',.16,.02,.02,.40,'Scale highlight strength') or opacity_changed
        if opacity_changed then M.apply(app) end
        if I.Button(c,'Reset Dark') then Suite.reset(reaper,app.theme_state,'dark'); M.apply(app) end
        I.SameLine(c); if I.Button(c,'Reset Light') then Suite.reset(reaper,app.theme_state,'light'); M.apply(app) end
        I.EndTabItem(c)
      end
      if I.BeginTabItem(c,'Appearance') then
        I.TextDisabled(c,'Import from the current REAPER theme')
        for index,entry in ipairs({{'Auto Detect','auto'},{'Import Dark','dark'},{'Import Light','light'}}) do
          if index>1 then I.SameLine(c) end
          if I.Button(c,entry[1]) then Suite.import(reaper,app.theme_state,entry[2]); M.apply(app) end
        end
        local start_x=I.GetCursorPosX(c); local active_x=start_x+235; local alternate_x=start_x+315
        I.Dummy(c,1,2)
        I.SetCursorPosX(c,active_x); I.TextDisabled(c,'Active')
        I.SameLine(c); I.SetCursorPosX(c,alternate_x); I.TextDisabled(c,'Alternates')
        I.Separator(c)
        for _,key in ipairs(Suite.KEYS) do palette_row(app,key,active_x,alternate_x) end
        I.Separator(c)
        if I.Button(c,'Preset: ReaRoll Dark') then Suite.reset(reaper,app.theme_state,'dark'); M.apply(app) end
        I.SameLine(c); if I.Button(c,'Preset: Light') then Suite.reset(reaper,app.theme_state,'light'); M.apply(app) end
        I.SameLine(c); if I.Button(c,'Preset: FL Studio') then Suite.reset(reaper,app.theme_state,'fl'); app.settings.uniform_note_color=true; M.apply(app) end
        I.EndTabItem(c)
      end
      if I.BeginTabItem(c,'Playhead') then
        local s=app.settings
        local changed; changed,s.note_playback_animation=I.Checkbox(c,'Animate sounding notes',s.note_playback_animation~=false)
        Controls.toggle(app,s,'note_playback_animation',true,'Sounding-note animation')
        if I.IsItemHovered(c) then I.SetTooltip(c,'Attack flash, sustained breathing, traveling sheen, and release glow.') end
        I.Separator(c)
        changed,s.playhead_smooth=I.Checkbox(c,'Interpolation',s.playhead_smooth)
        Controls.toggle(app,s,'playhead_smooth',true,'Interpolation')
        local presets={
          {'Clean',2,.95,0,0,.10,0,false,false,false,false,false},
          {'LED','2.6',1,.88,.08,.22,.15,false,false,false,false,true},
          {'Comet',2.4,.98,.78,.88,.28,.22,false,false,false,false,true},
          {'Beat Pulse',2.6,1,.86,.28,.25,.86,false,false,false,false,false},
          {'Aurora',2.4,1,.82,.35,.18,.30,true,true,false,false,true},
          {'Sparks',2.5,1,.80,.32,.22,.38,false,false,true,true,true},
          {'Matrix',2.2,1,.72,.32,.06,.18,false,false,false,false,false,true},
        }
        I.SetNextItemWidth(c,170)
        if I.BeginCombo(c,'Preset','Choose preset...') then
          for _,p in ipairs(presets) do if I.Selectable(c,p[1],false) then s.playhead_width=tonumber(p[2]); s.playhead_opacity=p[3]; s.playhead_glow=p[4]; s.playhead_trail=p[5]; s.playhead_shadow=p[6]; s.playhead_pulse=p[7]; s.playhead_wave=p[8]; s.playhead_rainbow=p[9]; s.playhead_sparks=p[10]; s.playhead_cycle=p[11] or false; s.playhead_scan=p[12] or false; s.playhead_matrix=p[13] or false; if p[1]=='Matrix' then s.playhead_color=0x37FF72FF; s.playhead_color_custom=true end end end
          I.EndCombo(c)
        end
        local color_changed,widget_color=I.ColorEdit4(c,'Color',to_widget_color(s.playhead_color),I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoOptions); if color_changed then s.playhead_color=from_widget_color(widget_color); s.playhead_color_custom=true end
        local _,reset_color=Controls.input(app,'Color',string.format('#%06X',(s.playhead_color>>8)&0xFFFFFF),string.format('#%06X',(app.theme_state.colors.accent>>8)&0xFFFFFF)); if reset_color then s.playhead_color=app.theme_state.colors.accent; s.playhead_color_custom=false end
        changed,s.playhead_width=I.SliderDouble(c,'Line width',s.playhead_width,1,6,'%.1f px')
        Controls.number(app,s,'playhead_width',2.4,.1,1,6,'Line width')
        changed,s.playhead_opacity=I.SliderDouble(c,'Opacity',s.playhead_opacity,.15,1,'%.2f')
        Controls.number(app,s,'playhead_opacity',.95,.02,.15,1,'Opacity')
        changed,s.playhead_glow=I.SliderDouble(c,'Glow',s.playhead_glow,0,1,'%.2f')
        Controls.number(app,s,'playhead_glow',.72,.02,0,1,'Glow')
        changed,s.playhead_trail=I.SliderDouble(c,'Trail',s.playhead_trail,0,1,'%.2f')
        Controls.number(app,s,'playhead_trail',.34,.02,0,1,'Trail')
        changed,s.playhead_shadow=I.SliderDouble(c,'Shadow',s.playhead_shadow,0,1,'%.2f')
        Controls.number(app,s,'playhead_shadow',.25,.02,0,1,'Shadow')
        changed,s.playhead_pulse=I.SliderDouble(c,'Beat pulse',s.playhead_pulse,0,1,'%.2f')
        Controls.number(app,s,'playhead_pulse',.35,.02,0,1,'Beat pulse')
        I.Separator(c); I.TextDisabled(c,'Visual FX')
        changed,s.playhead_wave=I.Checkbox(c,'Wave',s.playhead_wave); Controls.toggle(app,s,'playhead_wave',false,'Wave'); I.SameLine(c)
        changed,s.playhead_rainbow=I.Checkbox(c,'Rainbow',s.playhead_rainbow); Controls.toggle(app,s,'playhead_rainbow',false,'Rainbow'); I.SameLine(c)
        changed,s.playhead_cycle=I.Checkbox(c,'Cycle colors',s.playhead_cycle); Controls.toggle(app,s,'playhead_cycle',false,'Cycle colors')
        changed,s.playhead_sparks=I.Checkbox(c,'Sparks',s.playhead_sparks); Controls.toggle(app,s,'playhead_sparks',false,'Sparks'); I.SameLine(c)
        changed,s.playhead_scan=I.Checkbox(c,'Vertical pulse',s.playhead_scan); Controls.toggle(app,s,'playhead_scan',false,'Vertical pulse')
        changed,s.playhead_matrix=I.Checkbox(c,'Matrix rain',s.playhead_matrix)
        Controls.toggle(app,s,'playhead_matrix',false,'Matrix rain')
        if s.playhead_wave then changed,s.playhead_wave_amount=I.SliderDouble(c,'Wave amount',s.playhead_wave_amount,0,1,'%.2f'); Controls.number(app,s,'playhead_wave_amount',.45,.02,0,1,'Wave amount') end
        if s.playhead_cycle then changed,s.playhead_cycle_speed=I.SliderDouble(c,'Cycle speed',s.playhead_cycle_speed,.03,.8,'%.2f'); Controls.number(app,s,'playhead_cycle_speed',.18,.02,.03,.8,'Cycle speed') end
        if s.playhead_sparks then changed,s.playhead_spark_amount=I.SliderDouble(c,'Spark amount',s.playhead_spark_amount,0,1,'%.2f'); Controls.number(app,s,'playhead_spark_amount',.45,.02,0,1,'Spark amount') end
        if s.playhead_matrix then changed,s.playhead_matrix_amount=I.SliderDouble(c,'Matrix amount',s.playhead_matrix_amount,0,1,'%.2f'); Controls.number(app,s,'playhead_matrix_amount',.55,.02,0,1,'Matrix amount') end
        if s.playhead_scan then
          changed,s.playhead_scan_amount=I.SliderDouble(c,'Vertical pulse amount',s.playhead_scan_amount,0,1,'%.2f')
          Controls.number(app,s,'playhead_scan_amount',.55,.02,0,1,'Vertical pulse amount')
          I.SetNextItemWidth(c,130)
          local direction_labels={down='Down',up='Up',pingpong='Ping-pong'}
          if I.BeginCombo(c,'Pulse direction',direction_labels[s.playhead_scan_direction] or 'Down') then
            for _,direction in ipairs({'down','up','pingpong'}) do
              if I.Selectable(c,direction_labels[direction],s.playhead_scan_direction==direction) then s.playhead_scan_direction=direction end
            end
            I.EndCombo(c)
          end
          Controls.choice(app,s,'playhead_scan_direction','down',{'down','up','pingpong'},'Pulse direction')
        end
        local fps=I.GetFramerate and I.GetFramerate(c) or nil
        I.TextDisabled(c,'Effects draw only while the playhead is visible.'..(fps and string.format('  UI: %.0f FPS',fps) or ''))
        I.EndTabItem(c)
      end
      I.EndTabBar(c)
    end
  end
  -- Some ReaImGui builds report a closed auxiliary window without pushing it
  -- onto the window stack.  End is still required by other builds, so make the
  -- compatibility call tolerant instead of terminating the entire editor.
  if visible then I.End(c) end
end
return M
