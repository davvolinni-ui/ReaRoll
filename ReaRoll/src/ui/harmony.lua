-- @noindex
local U=require 'src.util'
local Music=require 'src.music'
local Palettes=require 'src.chord_palettes'
local Appearance=require 'src.ui.appearance'
local Suite=require 'src.suite_theme'
local M={}

local function blend(a,b,t)
  local out=255
  for _,shift in ipairs({8,16,24}) do out=out|(math.floor(((a>>shift)&255)*(1-t)+((b>>shift)&255)*t+.5)<<shift) end
  return out
end
local function scale(app) return U.clamp(app.settings.ui_scale or 1,.8,1.5) end
local function width(app) return math.max(1,(app.ImGui.GetContentRegionAvail(app.ctx))) end
local function family(groups,name)
  for index,group in ipairs(groups) do for _,value in ipairs(group[2]) do if value==name then return index end end end
  return 1
end
local function heading(app,label)
  app.ImGui.Spacing(app.ctx); app.ImGui.TextColored(app.ctx,app.theme.hint,label)
end

-- Cards use the current suite colors and reserve real ImGui items, so their
-- hit areas and layout remain aligned at every UI scale.
local function card(app,id,label,detail,selected,w,h,dots)
  local I,c,T=app.ImGui,app.ctx,app.theme; local z=scale(app)
  local x,y=I.GetCursorScreenPos(c)
  local clicked=I.InvisibleButton(c,'##harmony_'..id,w,h)
  local hot=I.IsItemHovered(c); local d=I.GetWindowDrawList(c)
  local accent=app.theme_state.colors.scale_highlight or T.accent
  local bg=blend(T.panel,T.text,hot and .10 or .045)
  if selected then bg=blend(T.panel,accent,.22) end
  I.DrawList_AddRectFilled(d,x,y,x+w,y+h,bg,6*z)
  I.DrawList_AddRect(d,x,y,x+w,y+h,selected and accent or (hot and T.hint or T.grid),6*z,I.DrawFlags_None,selected and 1.5*z or z)
  local function fit(text)
    if I.CalcTextSize(c,text)<=w-12*z then return text end
    local short=text
    while #short>1 and I.CalcTextSize(c,short..'...')>w-12*z do short=short:sub(1,-2) end
    return short..'...'
  end
  local shown=fit(label); local tw,th=I.CalcTextSize(c,shown)
  I.DrawList_AddText(d,x+(w-tw)*.5,y+((detail or dots) and 7*z or (h-th)*.5),T.text,shown)
  if detail then
    local sub=fit(detail); local dw=I.CalcTextSize(c,sub)
    I.DrawList_AddText(d,x+(w-dw)*.5,y+h-21*z,selected and T.text or T.hint,sub)
  end
  if dots then
    local step=math.min(10*z,(w-20*z)/12); local left=x+(w-step*11)*.5
    for pc=0,11 do
      I.DrawList_AddCircleFilled(d,left+pc*step,y+h-12*z,2.4*z,dots[pc] and accent or blend(T.panel,T.text,.16))
    end
  end
  if hot and shown~=label then I.SetTooltip(c,label) end
  return clicked,hot
end

local function audition(app,pitches)
  if app.audition:play_many(pitches,app.settings.velocity,app.settings.channel) then
    app.harmony_audition={pitches=app.audition.pitches,until_time=reaper.time_precise()+.8}
  end
end
local function stop_audition(app)
  local playing=app.harmony_audition
  if playing and app.audition.pitches==playing.pitches then app.audition:stop() end
  app.harmony_audition=nil
end

local function browser(app,groups,index_key,selected_key,is_scale)
  local I,c,s=app.ImGui,app.ctx,app.settings; local z=scale(app)
  local picked=false
  app[index_key]=app[index_key] or family(groups,s[selected_key])
  I.SetNextItemWidth(c,200*z)
  if I.BeginCombo(c,'Family##'..index_key,groups[app[index_key]][1]) then
    for index,group in ipairs(groups) do if I.Selectable(c,group[1],index==app[index_key]) then app[index_key]=index end end
    I.EndCombo(c)
  end
  local avail=width(app); local gap=6*z; local cols=math.max(1,math.floor((avail+gap)/(156*z+gap))); local w=(avail-gap*(cols-1))/cols
  local anchor=60+s.scale_root
  for index,name in ipairs(groups[app[index_key]][2]) do
    if (index-1)%cols~=0 then I.SameLine(c,0,gap) end
    local dots,detail
    if is_scale then
      dots={}; for _,pc in ipairs(Music.scales[name]) do dots[pc]=true end
    else
      local names={}; for _,interval in ipairs(Music.chords[name]) do names[#names+1]=Music.roots[(anchor+interval)%12+1] end
      detail=table.concat(names,' ')
    end
    local clicked,hot=card(app,selected_key..name,name,detail,s[selected_key]==name,w,52*z,dots)
    if clicked then s[selected_key]=name; s.chord_inversion=0; app.harmony_degree=1; picked=true end
    if hot and is_scale then
      local names={}; for _,pc in ipairs(Music.scales[name]) do names[#names+1]=Music.roots[(s.scale_root+pc)%12+1] end
      I.SetTooltip(c,table.concat(names,'  '))
    end
  end
  return picked
end

local function keyboard(app,pitches,root)
  local I,c,T=app.ImGui,app.ctx,app.theme; local z=scale(app)
  local first=math.floor(math.min(root,pitches[1])/12)*12
  local last=math.max(first+23,math.floor(pitches[#pitches]/12)*12+11)
  first=math.max(0,math.min(first,104)); last=math.min(127,last)
  local keys,white={},{}; local selected={}; for _,pitch in ipairs(pitches) do selected[pitch]=true end
  for pitch=first,last do if not U.is_black(pitch) then white[#white+1]=pitch; keys[pitch]=#white end end
  local w,h=width(app),70*z; local x,y=I.GetCursorScreenPos(c)
  I.InvisibleButton(c,'##harmony_keyboard',w,h)
  local d=I.GetWindowDrawList(c); local kw=w/#white; local accent=app.theme_state.colors.scale_highlight or T.accent
  local function color(pitch,black)
    local base=black and T.black_key or T.white_key
    if selected[pitch] then return pitch%12==root%12 and accent or T.note end
    if Music.contains(app.settings.scale_root,app.settings.scale_name,pitch) then return blend(base,accent,black and .25 or .16) end
    return base
  end
  for index,pitch in ipairs(white) do
    local left=x+(index-1)*kw; local col=color(pitch,false)
    I.DrawList_AddRectFilled(d,left+1,y+1,left+kw-1,y+h-1,col,3*z)
    I.DrawList_AddRect(d,left+1,y+1,left+kw-1,y+h-1,T.key_border,3*z)
    if selected[pitch] or pitch%12==0 then
      local label=U.pitch_name(pitch); local tw=I.CalcTextSize(c,label)
      local text=Suite.luminance(col)>130 and 0x101820FF or 0xF0F3F7FF
      I.DrawList_AddText(d,left+(kw-tw)*.5,y+h-20*z,text,label)
    end
  end
  for pitch=first,last do if U.is_black(pitch) then
    local preceding=keys[pitch-1]
    if preceding then
      local center=x+preceding*kw; local bw=kw*.62; local col=color(pitch,true)
      I.DrawList_AddRectFilled(d,center-bw*.5,y,center+bw*.5,y+h*.61,col,3*z)
      I.DrawList_AddRect(d,center-bw*.5,y,center+bw*.5,y+h*.61,T.key_border,3*z)
    end
  end end
end

function M.open(app)
  app.chord_palette_open=true; app.harmony_focus=true
end

function M.draw(app)
  if app.harmony_audition and (not app.chord_palette_open or reaper.time_precise()>=app.harmony_audition.until_time) then stop_audition(app) end
  if not app.chord_palette_open then return end
  local I,c,s,T=app.ImGui,app.ctx,app.settings,app.theme; local z=scale(app)
  I.SetNextWindowSize(c,570*z,640*z,I.Cond_FirstUseEver)
  if I.SetNextWindowSizeConstraints then I.SetNextWindowSizeConstraints(c,420*z,380*z,1000*z,1000*z) end
  if app.harmony_focus then I.SetNextWindowFocus(c); app.harmony_focus=nil end
  I.PushStyleVar(c,I.StyleVar_WindowPadding,16*z,14*z)
  local visible; visible,app.chord_palette_open=I.Begin(c,'ReaRoll / Harmony',app.chord_palette_open)
  if visible then
    s.scale_root=U.clamp(math.floor(s.scale_root or 0),0,11)
    s.scale_name=Music.scales[s.scale_name] and s.scale_name or 'Major'
    s.chord_name=Music.chords[s.chord_name] and s.chord_name or 'Major'
    s.chord_size=s.chord_size==4 and 4 or 3
    I.TextColored(c,app.theme_state.colors.scale_highlight or T.accent,Music.roots[s.scale_root+1]..'  '..s.scale_name)
    I.SameLine(c)
    if s.harmony_listen==nil then s.harmony_listen=true end
    local listen_changed; listen_changed,s.harmony_listen=I.Checkbox(c,'Listen',s.harmony_listen)
    if listen_changed and not s.harmony_listen then stop_audition(app) end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Audition a chord when you select it or change its voicing.') end
    local gap=4*z; local w=(width(app)-11*gap)/12
    for pc=0,11 do
      if pc>0 then I.SameLine(c,0,gap) end
      if card(app,'root'..pc,Music.roots[pc+1],nil,s.scale_root==pc,w,30*z) then s.scale_root=pc end
    end
    browser(app,Music.scale_groups,'harmony_scale_family','scale_name',true)
    local changed; changed,s.scale_enabled=I.Checkbox(c,'Scale highlight',s.scale_enabled)
    I.SameLine(c); changed,s.scale_snap=I.Checkbox(c,'Pitch Safe',s.scale_snap)
    if I.IsItemHovered(c) then I.SetTooltip(c,'Constrain drawing and single-note moves to the selected scale, even when row highlighting is hidden.') end
    do
      I.SetNextItemWidth(c,120*z); I.SameLine(c)
      changed,s.scale_opacity=I.SliderDouble(c,'##Highlight strength',s.scale_opacity or .16,.02,.40,'%.2f')
      if I.IsItemHovered(c) then I.SetTooltip(c,'Scale highlight strength') end
      if changed then Appearance.apply(app) end
      I.SameLine(c)
      local hit,color=I.ColorEdit4(c,'##Highlight color',Appearance.to_widget_color(app.theme_state.colors.scale_highlight),I.ColorEditFlags_NoAlpha|I.ColorEditFlags_NoOptions|I.ColorEditFlags_NoInputs)
      if hit then Suite.set_color(reaper,app.theme_state,'scale_highlight',Appearance.from_widget_color(color)); Appearance.apply(app) end
    end
    I.Separator(c)
    local half=(width(app)-6*z)*.5
    local picked=false
    if card(app,'in_scale','In scale',nil,s.chord_diatonic,half,30*z) then s.chord_diatonic=true; s.chord_inversion=0; picked=true end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Build chords from the selected key and scale.') end
    I.SameLine(c,0,6*z)
    if card(app,'fixed','Fixed shape',nil,not s.chord_diatonic,half,30*z) then s.chord_diatonic=false; s.chord_inversion=0; picked=true end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Keep the selected chord intervals at any root.') end
    local intervals=Music.scales[s.scale_name]; local root=60+s.scale_root
    I.Spacing(c)
    if I.RadioButton(c,'Individual chords',not app.harmony_palettes) then app.harmony_palettes=false; picked=true end
    I.SameLine(c)
    if I.RadioButton(c,'Chord palettes',app.harmony_palettes==true) then app.harmony_palettes=true; picked=true end
    if app.harmony_palettes then
      app.harmony_palette=U.clamp(app.harmony_palette or 1,1,#Palettes.presets)
      local preset=Palettes.presets[app.harmony_palette]
      heading(app,'CHORD PALETTES')
      app.harmony_palette_group=Palettes.group_for(app.harmony_palette)
      local group=Palettes.groups[app.harmony_palette_group]
      I.SetNextItemWidth(c,width(app))
      if I.BeginCombo(c,'##palette_genre',group.name) then
        for index,value in ipairs(Palettes.groups) do
          if I.Selectable(c,value.name,index==app.harmony_palette_group) then
            app.harmony_palette_group=index; app.harmony_palette=value.indices[1]
            app.harmony_palette_chord=1; s.chord_inversion=0; picked=true
          end
        end
        I.EndCombo(c)
      end
      group=Palettes.groups[app.harmony_palette_group]
      preset=Palettes.presets[app.harmony_palette]
      I.SetNextItemWidth(c,width(app))
      if I.BeginCombo(c,'##chord_palette',preset.name) then
        for _,index in ipairs(group.indices) do
          local value=Palettes.presets[index]
          if I.Selectable(c,value.name,index==app.harmony_palette) then
            app.harmony_palette=index; app.harmony_palette_chord=1; s.chord_inversion=0; picked=true
          end
        end
        I.EndCombo(c)
      end
      preset=Palettes.presets[app.harmony_palette]
      I.TextWrapped(c,'Choose any order. Select a chord, then draw at its root note in the editor.')
      if s.chord_diatonic then
        I.TextDisabled(c,'Adapted to '..Music.roots[s.scale_root+1]..' '..s.scale_name)
      else
        I.TextDisabled(c,'Fixed shapes: '..Music.roots[s.scale_root+1]..' '..preset.scale..' palette')
      end
      app.harmony_palette_chord=U.clamp(app.harmony_palette_chord or 1,1,#preset.degrees)
      local cols=math.max(1,math.floor((width(app)+6*z)/(124*z+6*z)))
      local pw=(width(app)-(cols-1)*6*z)/cols
      for index in ipairs(preset.degrees) do
        if (index-1)%cols~=0 then I.SameLine(c,0,6*z) end
        local anchor,tones,_,outside=Palettes.resolve(s,preset,index)
        local label=Music.chord_label(tones,anchor)
        local clicked,hot=card(app,'palette_chord'..index,label,
          'Root '..Music.roots[anchor%12+1]..(outside and ' *' or ''),app.harmony_palette_chord==index,pw,52*z)
        if clicked then app.harmony_palette_chord=index; picked=true end
        if hot then I.SetTooltip(c,'Draw at '..U.pitch_name(anchor)..(outside and '\nContains notes outside the selected scale.' or '\nAll notes belong to the selected scale.')) end
      end
      root=Palettes.select(s,preset,app.harmony_palette_chord)
      local _,_,_,outside=Palettes.resolve(s,preset,app.harmony_palette_chord)
      if outside then I.TextWrapped(c,'* Contains notes outside '..Music.roots[s.scale_root+1]..' '..s.scale_name..'. Choose In scale to adapt.') end
      if s.chord_diatonic then I.TextWrapped(c,'In scale rebuilds each shape as a triad or seventh; some cards may become the same chord.') end
    elseif s.chord_diatonic then
      if I.RadioButton(c,'Triad',s.chord_size==3) then s.chord_size=3 end
      I.SameLine(c); if I.RadioButton(c,'Seventh',s.chord_size==4) then s.chord_size=4 end
      app.harmony_degree=U.clamp(app.harmony_degree or 1,1,#intervals)
      local cols=math.min(#intervals,7); local dw=(width(app)-(cols-1)*4*z)/cols
      local romans={'I','II','III','IV','V','VI','VII'}
      for index,interval in ipairs(intervals) do
        if (index-1)%cols~=0 then I.SameLine(c,0,4*z) end
        local anchor=60+s.scale_root+interval
        local tones=Music.diatonic_chord(s.scale_root,s.scale_name,anchor,s.chord_size,0)
        if card(app,'degree'..index,#intervals==7 and romans[index] or tostring(index),Music.chord_label(tones,anchor),app.harmony_degree==index,dw,52*z) then
          app.harmony_degree=index; picked=true
        end
      end
      root=root+intervals[app.harmony_degree]
    else
      picked=browser(app,Music.chord_groups,'harmony_chord_family','chord_name',false) or picked
    end
    local count=s.chord_diatonic and s.chord_size or #Music.chords[s.chord_name]
    s.chord_inversion=U.clamp(math.floor(s.chord_inversion or 0),0,count-1)
    heading(app,'INVERSION')
    local iw=(width(app)-(count-1)*4*z)/count
    for inversion=0,count-1 do
      if inversion>0 then I.SameLine(c,0,4*z) end
      local label=inversion==0 and 'Root' or tostring(inversion)..(({'st','nd','rd'})[inversion] or 'th')
      if card(app,'inversion'..inversion,label,nil,s.chord_inversion==inversion,iw,30*z) then s.chord_inversion=inversion; picked=true end
    end
    changed,s.chord_drag_length=I.Checkbox(c,'Drag to set chord length',s.chord_drag_length)
    I.Separator(c)
    local pitches=Music.chord_pitches(s,root); local names={}; for _,pitch in ipairs(pitches) do names[#names+1]=U.pitch_name(pitch) end
    I.TextColored(c,T.text,Music.chord_label(pitches,root)); I.SameLine(c); I.TextDisabled(c,table.concat(names,'  '))
    keyboard(app,pitches,root)
    if I.IsItemHovered(c) then I.SetTooltip(c,'Solid keys: chord tones. Tinted keys: selected scale. Changes affect new chords; draw at the root pitch in the roll.') end
    local signature=table.concat(pitches,',')..':'..tostring(s.chord_diatonic)..':'..s.chord_name
    if s.harmony_listen and (picked or app.harmony_signature and app.harmony_signature~=signature) then audition(app,pitches) end
    app.harmony_signature=signature
  end
  if visible then I.End(c) end
  I.PopStyleVar(c)
  if not app.chord_palette_open then stop_audition(app) end
end

return M
