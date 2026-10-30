-- @noindex
local U=require 'src.util'
local Music=require 'src.music'
local M={}
local Controls=require 'src.ui.controls'

local function blend(a,b,t)
  local out=255
  for _,shift in ipairs({8,16,24}) do out=out|(math.floor(((a>>shift)&255)*(1-t)+((b>>shift)&255)*t+.5)<<shift) end
  return out
end
local function scale(app) return U.clamp(app.settings.ui_scale or 1,.8,1.5) end
local function width(app) return math.max(1,(app.ImGui.GetContentRegionAvail(app.ctx))) end
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

function M.open(app)
  app.chord_palette_open=true; app.harmony_focus=true
end

function M.draw(app)
  if app.harmony_audition and (not app.chord_palette_open or reaper.time_precise()>=app.harmony_audition.until_time)then stop_audition(app)end
  if not app.chord_palette_open then return end
  local I,c,s=app.ImGui,app.ctx,app.settings;local z=scale(app)
  app.harmony_stamp=nil
  I.SetNextWindowSize(c,420*z,410*z,I.Cond_FirstUseEver)
  I.SetNextWindowSizeConstraints(c,320*z,260*z,1000*z,1000*z)
  if app.harmony_focus then I.SetNextWindowFocus(c);app.harmony_focus=nil end
  local visible;visible,app.chord_palette_open=I.Begin(c,'ReaRoll / Harmony',app.chord_palette_open)
  if visible then
    local available=width(app);local gap=8*z;local key_width=math.max(65*z,available*.25)
    I.TextColored(c,app.theme.accent,'KEY & SCALE')
    I.SetNextItemWidth(c,key_width)
    if I.BeginCombo(c,'##harmony_key',Music.roots[(s.scale_root or 0)+1])then
      for i,name in ipairs(Music.roots)do if I.Selectable(c,name,s.scale_root==i-1)then s.scale_root=i-1 end end;I.EndCombo(c)
    end
    Controls.number(app,s,'scale_root',0,1,0,11,'Key')
    I.SameLine(c,0,gap);I.SetNextItemWidth(c,available-key_width-gap)
    if I.BeginCombo(c,'##harmony_scale',s.scale_name)then
      for _,name in ipairs(Music.scale_order)do if I.Selectable(c,name,s.scale_name==name)then s.scale_name=name end end;I.EndCombo(c)
    end
    Controls.choice(app,s,'scale_name','Major',Music.scale_order,'Scale')
    I.Spacing(c)
    local half=(available-gap)*.5
    app.harmony_octave=app.harmony_octave or 0
    I.SetNextItemWidth(c,half)
    local changed;changed,app.harmony_octave=I.DragInt(c,'##harmony_octave',app.harmony_octave,.15,-3,3,'Octave %+d')
    app.harmony_octave=U.clamp(app.harmony_octave,-3,3)
    Controls.number(app,app,'harmony_octave',0,1,-3,3,'Octave')
    I.SameLine(c,0,gap);I.SetNextItemWidth(c,half)
    local inversions={'Root position','1st inversion','2nd inversion'}
    s.chord_inversion=U.clamp(s.chord_inversion or 0,0,2)
    if I.BeginCombo(c,'##harmony_inversion',inversions[s.chord_inversion+1])then
      for i,label in ipairs(inversions)do if I.Selectable(c,label,s.chord_inversion==i-1)then s.chord_inversion=i-1 end end;I.EndCombo(c)
    end
    Controls.number(app,s,'chord_inversion',0,1,0,2,'Inversion')
    I.Spacing(c);I.Separator(c);I.Spacing(c)
    I.TextWrapped(c,'Click to hear  /  Drag into the roll')
    local palette=false
    if I.BeginTabBar(c,'##harmony_tabs')then
      if I.BeginTabItem(c,'Chords')then app.harmony_palettes=false;I.EndTabItem(c)end
      if I.BeginTabItem(c,'Palettes')then app.harmony_palettes=true;I.EndTabItem(c)end
      I.EndTabBar(c)
    end
    local entries=require('src.harmony_library').entries(s,app.harmony_octave)
    if app.harmony_palettes then
      local choices=require('src.harmony_library').palettes(s,app.harmony_octave)
      local categories,seen={},{}
      for _,choice in ipairs(choices)do if not seen[choice.category]then categories[#categories+1]=choice.category;seen[choice.category]=true end end
      local category=seen[app.harmony_category]and app.harmony_category or categories[1]
      I.SetNextItemWidth(c,width(app))
      if I.BeginCombo(c,'##harmony_category',category or 'No matching palettes')then
        for _,name in ipairs(categories)do if I.Selectable(c,name,name==category)then category=name;app.harmony_category=name end end;I.EndCombo(c)
      end
      app.harmony_category=category
      Controls.choice(app,app,'harmony_category',categories[1],categories,'Category')
      category=app.harmony_category
      local filtered={};for _,choice in ipairs(choices)do if choice.category==category then filtered[#filtered+1]=choice end end
      choices=filtered
      local selected=choices[1]
      for _,choice in ipairs(choices)do if choice.index==app.harmony_palette then selected=choice end end
      I.SetNextItemWidth(c,width(app))
      if I.BeginCombo(c,'##harmony_palette',selected and selected.name or 'No matching palettes')then
        for _,choice in ipairs(choices)do if I.Selectable(c,choice.name,selected==choice)then app.harmony_palette=choice.index;selected=choice end end;I.EndCombo(c)
      end
      local ids={};for _,choice in ipairs(choices)do ids[#ids+1]=choice.index end
      app.harmony_palette=selected and selected.index or nil
      if #ids>0 and Controls.choice(app,app,'harmony_palette',ids[1],ids,'Palette')then
        for _,choice in ipairs(choices)do if choice.index==app.harmony_palette then selected=choice end end
      end
      entries=selected and selected.entries or {}
      I.TextWrapped(c,'Chords in '..Music.roots[s.scale_root+1]..' '..s.scale_name)
    end
    local cols=math.max(1,math.floor((width(app)+6*z)/(112*z+6*z)));local w=(width(app)-(cols-1)*6*z)/cols
    for index,entry in ipairs(entries)do
      if (index-1)%cols~=0 then I.SameLine(c,0,6*z)end
      local names={};for _,pitch in ipairs(entry.pitches)do names[#names+1]=Music.roots[pitch%12+1]end
      local clicked=card(app,'choice'..index,entry.label,table.concat(names,'  '),app.harmony_selected==entry.label,w,58*z)
      if clicked then app.harmony_selected=entry.label;audition(app,entry.pitches)end
      if I.BeginDragDropSource(c)then
        app.harmony_drag=entry.pitches
        I.SetDragDropPayload(c,'REAROLL_CHORD',table.concat(entry.pitches,','))
        I.Text(c,entry.label);I.EndDragDropSource(c)
      end
    end
    if app.harmony_notice then I.TextWrapped(c,app.harmony_notice)end
  end
  if visible then I.End(c)end
end
return M
