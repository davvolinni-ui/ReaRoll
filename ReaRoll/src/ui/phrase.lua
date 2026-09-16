-- @noindex
local Selection=require 'src.selection'
local Controls=require 'src.ui.controls'
local M={}
function M.draw(app,docked)
  if not app.phrase_open then return end
  local I,c=app.ImGui,app.ctx
  local was_open=app.phrase_open
  local visible=true
  if not docked then
    I.SetNextWindowSize(c,320,590,I.Cond_FirstUseEver)
    local flags=app.phrase_control_hovered and I.WindowFlags_NoScrollWithMouse or 0
    visible,app.phrase_open=I.Begin(c,'ReaRoll / Phrase tools',app.phrase_open,flags)
  else
    I.TextColored(c,app.theme.header_icon or app.theme.note,'Phrase Tools')
    I.SameLine(c); if I.SmallButton(c,'x##close_phrase_panel') then app.phrase_open=false end
    I.Separator(c)
  end
  if visible then
    app.phrase_control_hovered=false
    local function number(target,key,default,step,lo,hi,label)
      local hovered=I.IsItemHovered(c)
      if hovered then app.phrase_control_hovered=true end
      return Controls.number(app,target,key,default,step,lo,hi,label)
    end
    local function choice(target,key,default,values,label)
      local hovered=I.IsItemHovered(c)
      if hovered then app.phrase_control_hovered=true end
      return Controls.choice(app,target,key,default,values,label)
    end
    local count=Selection.count(app.selection)
    local can_transform=count>0 and app.take and app.gesture==nil
    I.TextColored(c,app.theme.note,count..' notes selected')
    if count==0 then I.TextDisabled(c,'Select notes to enable actions.') end
    I.BeginDisabled(c,not can_transform)
    for i,entry in ipairs({{'Reverse','reverse'},{'Invert','invert'},{'Legato','legato'},{'Quantize','quantize'},{'Chop','chop'},{'Glue','glue'}}) do
      if (i-1)%3~=0 then I.SameLine(c) end
      if I.SmallButton(c,entry[1]..'##phrase_action') then app.transforms[entry[2]](app) end
    end
    if I.SmallButton(c,'Half##phrase_action') then app.transforms.scale_time(app,.5) end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Half duration') end
    I.SameLine(c); if I.SmallButton(c,'Double##phrase_action') then
      if not app.transforms.scale_time(app,2) then app.transform_notice='Expansion needs more room in the MIDI item.' end
    end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Double duration') end
    I.SameLine(c); if I.SmallButton(c,'Duplicate##phrase_action') then app.clipboard.duplicate(app) end
    I.EndDisabled(c)
    I.Separator(c); I.Text(c,'Strum / Flam preview')
    I.TextDisabled(c,'Adjust, audition, then Apply.')
    app.performance_preview=app.performance_preview or 'strum'; app.strum_direction=app.strum_direction or 1
    if I.RadioButton(c,'Strum',app.performance_preview=='strum') then app.transforms.cancel_preview(app); app.performance_preview='strum'; app.transforms.preview_strum(app,app.strum_direction) end
    I.SameLine(c); if I.RadioButton(c,'Flam',app.performance_preview=='flam') then app.transforms.cancel_preview(app); app.performance_preview='flam'; app.transforms.preview_flam(app) end
    local preview_changed=false
    if app.performance_preview=='strum' then
      I.SetNextItemWidth(c,-1)
      if I.BeginCombo(c,'##strum_direction',app.strum_direction>0 and 'Low to high' or 'High to low') then
        if I.Selectable(c,'Low to high',app.strum_direction>0) then app.strum_direction=1; preview_changed=true end
        if I.Selectable(c,'High to low',app.strum_direction<0) then app.strum_direction=-1; preview_changed=true end
        I.EndCombo(c)
      end
      preview_changed=choice(app,'strum_direction',1,{1,-1},'Strum direction') or preview_changed
      local changed; changed,app.settings.strum_qn=I.SliderDouble(c,'##strum_spacing',app.settings.strum_qn,0,.20,'Spacing  %.3f QN'); preview_changed=number(app.settings,'strum_qn',.03,.005,0,.20,'Strum spacing') or changed or preview_changed
      if preview_changed then app.transforms.preview_strum(app,app.strum_direction) end
    else
      local changed; changed,app.settings.flam_qn=I.SliderDouble(c,'##flam_delay',app.settings.flam_qn,.005,.20,'Delay  %.3f QN'); preview_changed=number(app.settings,'flam_qn',.04,.005,.005,.20,'Flam delay') or changed
      if preview_changed then app.transforms.preview_flam(app) end
    end
    I.BeginDisabled(c,not can_transform)
    if not app.transform_preview then if I.Button(c,'Start preview') then if app.performance_preview=='strum' then app.transforms.preview_strum(app,app.strum_direction) else app.transforms.preview_flam(app) end end
    else
      if I.SmallButton(c,'Apply') then app.transforms.commit_preview(app) end
      I.SameLine(c); if I.SmallButton(c,'Cancel') then app.transforms.cancel_preview(app) end
    end
    I.EndDisabled(c)
    I.Separator(c); I.Text(c,'Arpeggiator')
    app.arp_direction=app.arp_direction or 'up'; app.arp_gate=app.arp_gate or .85; app.arp_octaves=app.arp_octaves or 1; app.arp_swing=app.arp_swing or 0
    I.SetNextItemWidth(c,-1)
    if I.BeginCombo(c,'##arp_direction',app.arp_direction) then
      for _,name in ipairs({'up','down','updown'}) do if I.Selectable(c,name,name==app.arp_direction) then app.arp_direction=name end end
      I.EndCombo(c)
    end
    choice(app,'arp_direction','up',{'up','down','updown'},'Arpeggiator direction')
    local changed; changed,app.arp_gate=I.SliderDouble(c,'##arp_gate',app.arp_gate,.1,1,'Gate  %.2f')
    number(app,'arp_gate',.85,.02,.1,1,'Arpeggiator gate')
    changed,app.arp_octaves=I.SliderInt(c,'##arp_octaves',app.arp_octaves,1,4,'Octaves  %d')
    number(app,'arp_octaves',1,1,1,4,'Arpeggiator octaves')
    changed,app.arp_swing=I.SliderDouble(c,'##arp_swing',app.arp_swing,0,.75,'Swing  %.2f')
    number(app,'arp_swing',0,.02,0,.75,'Arpeggiator swing')
    I.BeginDisabled(c,not can_transform); if I.Button(c,'Arpeggiate') then app.transforms.arpeggiate(app,app.arp_direction,app.arp_gate,app.arp_octaves,app.arp_swing) end; I.EndDisabled(c)
    I.Separator(c); I.Text(c,'Velocity shape')
    app.ramp_first=app.ramp_first or 60; app.ramp_last=app.ramp_last or 110
    changed,app.ramp_first=I.SliderInt(c,'##ramp_start',app.ramp_first,1,127,'Start  %d')
    number(app,'ramp_first',60,1,1,127,'Velocity ramp start')
    changed,app.ramp_last=I.SliderInt(c,'##ramp_end',app.ramp_last,1,127,'End  %d')
    number(app,'ramp_last',110,1,1,127,'Velocity ramp end')
    app.velocity_compression=app.velocity_compression or .65
    changed,app.velocity_compression=I.SliderDouble(c,'##velocity_compression',app.velocity_compression,0,2,'Compression  %.2f')
    number(app,'velocity_compression',.65,.05,0,2,'Velocity compression')
    I.BeginDisabled(c,not can_transform)
    if I.Button(c,'Apply ramp') then app.transforms.velocity_ramp(app,app.ramp_first,app.ramp_last) end
    I.SameLine(c); if I.Button(c,'Humanize') then app.transforms.humanize(app) end
    if I.Button(c,'Compress velocity') then app.transforms.velocity_compress(app,app.velocity_compression,96) end
    app.random_time=app.random_time or 6; app.random_velocity=app.random_velocity or 5
    I.EndDisabled(c)
    changed,app.random_time=I.SliderInt(c,'##random_time',app.random_time,0,30,'Timing  %d%% grid')
    number(app,'random_time',6,1,0,30,'Random timing')
    changed,app.random_velocity=I.SliderInt(c,'##random_velocity',app.random_velocity,0,24,'Velocity  +/- %d')
    number(app,'random_velocity',5,1,0,24,'Random velocity')
    I.BeginDisabled(c,not can_transform)
    if I.Button(c,'Randomize selection') then app.transforms.randomize(app,app.random_time,app.random_velocity) end
    I.EndDisabled(c)
    I.Separator(c); I.Text(c,'Pitch')
    I.BeginDisabled(c,not can_transform)
    if I.SmallButton(c,'Degree -##pitch') then app.transforms.transpose_scale(app,-1) end
    I.SameLine(c); if I.SmallButton(c,'Degree +##pitch') then app.transforms.transpose_scale(app,1) end
    I.EndDisabled(c)
    if app.transform_notice then I.TextWrapped(c,app.transform_notice); if I.SmallButton(c,'Dismiss') then app.transform_notice=nil end end
  end
  if not docked and visible then I.End(c) end
  if was_open and not app.phrase_open then app.transforms.cancel_preview(app) end
end
return M
