-- @noindex
local U=require 'src.util'
local Selection=require 'src.selection'
local Notes=require 'src.note_events'
local Controls=require 'src.ui.controls'
local Music=require 'src.music'
local M={}
local popup_names={'##lane_quantize','##lane_scale_quantize','##lane_legato','##lane_humanize','##lane_strum_flam','##lane_arp','##lane_pitch','##lane_velocity','##lane_shape_popup','##lane_more'}

function M.any_popup_open(app)
  local I,c=app.ImGui,app.ctx
  if not I.IsPopupOpen then return false end
  for _,name in ipairs(popup_names) do if I.IsPopupOpen(c,name) then return true end end
  return false
end

local function target(app)
  local s=app.settings; local id=s.lane_target
  if id=='velocity' then return {id='velocity',label='Velocity',maximum=127,minimum=1,note=true} end
  if id=='pitch' then return {id='pitch',label='Pitch Bend',maximum=16383,minimum=0,status=0xE0,pitch=true} end
  if id=='pressure' then return {id='pressure',label='Channel Pressure',maximum=127,minimum=0,status=0xD0} end
  if id=='program' then return {id='program',label='Program Change',maximum=127,minimum=0,status=0xC0,protected=true} end
  local cc=type(id)=='string' and id:match('^cc(%d+)$'); cc=tonumber(cc) or (id=='cc' and s.cc_number or nil)
  if cc then return {id='cc'..cc,label='CC '..cc,maximum=127,minimum=0,status=0xB0,cc=cc,switch=cc>=64 and cc<=69,discrete=cc>=96 and cc<=101,protected=(cc>=96 and cc<=101) or cc>=120} end
  return {id=tostring(id),label=tostring(id),maximum=127,minimum=0,protected=true}
end

function M.height(app)
  local I,c=app.ImGui,app.ctx
  -- Reserve the padded button row, including its bottom breathing room.
  return (I.GetFrameHeight and I.GetFrameHeight(c) or 24)+4
end

local function popup_header(app,title,detail)
  local I,c,T=app.ImGui,app.ctx,app.theme
  I.TextColored(c,T.accent,title)
  I.Spacing(c); I.TextWrapped(c,detail)
  local count=app.transform_preview and #app.transform_preview.originals or Selection.count(app.selection)
  I.TextDisabled(c,count>0 and ('LIVE PREVIEW  /  '..count..' selected notes') or 'Select notes to preview this tool.')
  I.Separator(c); I.Spacing(c)
end

local function preview_footer(app)
  local I,c,T=app.ImGui,app.ctx,app.theme
  I.Spacing(c); I.Separator(c); I.Spacing(c)
  -- A missing invalid flag is nil. ReaImGui treats nil as the optional
  -- disabled argument's default (true), so always pass a boolean here.
  I.BeginDisabled(c,not app.transform_preview or app.transform_preview.invalid==true)
  I.PushStyleColor(c,I.Col_Button,T.accent)
  if I.Button(c,'Apply',120,0) then app.transforms.commit_preview(app); app.lane_phrase_preview=nil; I.CloseCurrentPopup(c) end
  I.PopStyleColor(c); I.EndDisabled(c); I.SameLine(c)
  if I.Button(c,'Cancel',100,0) then app.transforms.cancel_preview(app); app.lane_phrase_preview=nil; I.CloseCurrentPopup(c) end
end

local function option_card(app,id,label,selected)
  local I,c,T=app.ImGui,app.ctx,app.theme
  I.PushStyleColor(c,I.Col_Button,selected and T.beat or T.panel2)
  local hit=I.Button(c,label..'##'..id,0,30)
  I.PopStyleColor(c)
  return hit
end

local function matching_event(def,e,channel)
  return e.chanmsg==def.status and (e.chan or 0)==channel and (not def.cc or e.msg2==def.cc)
end

local function generated_positions(first,last,step)
  local out={}; step=math.max(.000001,step); local q=math.ceil((first-.000001)/step)*step; local guard=0
  while q<=last+.000001 and guard<4096 do out[#out+1]=q; q=q+step; guard=guard+1 end
  return out
end
M.generated_positions=generated_positions

local function automatic_scope(app)
  local s=app.settings; local item_start=app.item_start_qn or s.start_qn; local item_end=app.item_end_qn or (s.start_qn+s.visible_qn)
  local range=app.lane_time_selection
  if range then return 'range',math.max(item_start,range.start_qn),math.min(item_end,range.end_qn) end
  local notes=Selection.list(app.selection,app.cache:get(false))
  if #notes>0 then
    local first,last=math.huge,-math.huge
    for _,n in ipairs(notes) do first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)); last=math.max(last,reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e or n.s)) end
    return 'notes',math.max(item_start,first),math.min(item_end,last),notes
  end
  return 'item',item_start,item_end
end

local function collect(app,def,resolution)
  local s=app.settings; local item_start=app.item_start_qn or s.start_qn; local item_end=app.item_end_qn or (s.start_qn+s.visible_qn)
  local scope,first,last,chosen_notes=automatic_scope(app); local out={}
  if last<first then return out end
  if def.note then
    for _,n in ipairs(app.cache:get(false)) do if (n.chan or 0)==(s.channel or 0) then
      local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)
      if q>=item_start and q<=item_end then out[#out+1]={index=n.index,ppq=n.s,qn=q,value=n.vel,id=n.id} end
    end end
  else
    for _,e in ipairs(app.cc_cache:get(false)) do if matching_event(def,e,s.channel or 0) then
      local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,e.ppq)
      if q>=item_start and q<=item_end then local value=def.pitch and ((e.msg3<<7)|e.msg2) or (def.status==0xD0 or def.status==0xC0) and e.msg2 or e.msg3; out[#out+1]={index=e.index,ppq=e.ppq,qn=q,value=value} end
    end end
  end
  local deletes={}
  if not def.note and not def.protected then
    for _,item in ipairs(out) do if item.qn>=first and item.qn<=last and not item.insert then deletes[#deletes+1]=item.index end end
    out={}
    for i,q in ipairs(generated_positions(first,math.max(first,last-.00001),resolution or .125)) do out[#out+1]={index=-i,ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,q),insert=true} end
  else
    local wanted={}; if scope=='notes' then for _,n in ipairs(chosen_notes) do wanted[n.id]=true end end
    local scoped={}; for _,item in ipairs(out) do if item.qn>=first and item.qn<=last and (scope~='notes' or wanted[item.id]) then scoped[#scoped+1]=item end end; out=scoped
  end
  table.sort(out,function(a,b)if a.ppq==b.ppq then return a.index<b.index end;return a.ppq<b.ppq end)
  return out,deletes
end

local function fraction(value)return value-math.floor(value) end
local function shaped_value(mode,options,t,index,count,position)
  if mode=='step' then return options.steps[(index-1)%#options.steps+1] end
  local value
  if mode=='curve' then
    if options.curve=='Ease in' then t=t*t elseif options.curve=='Ease out' then t=1-(1-t)^2 elseif options.curve=='S-curve' then t=t*t*(3-2*t) end
    value=options.first+(options.last-options.first)*t; return value
  end
  local u=t; local phase
  if options._sync_ppq and options._sync_ppq>0 and position then
    phase=fraction((position-(options._sync_origin_ppq or 0))/options._sync_ppq+(options.phase or 0))
  else
    if (options.freq_skew or 0)~=0 then u=u^(2^((options.freq_skew or 0)*2)) end
    phase=fraction(u*(options.cycles or 1)+(options.phase or 0))
  end
  if options.shape=='Triangle' then value=1-math.abs(phase*2-1)
  elseif options.shape=='Saw up' then value=phase
  elseif options.shape=='Saw down' then value=1-phase
  elseif options.shape=='Square' then value=phase<(options.pulse_width or .5) and 1 or 0
  else value=.5+.5*math.sin(phase*math.pi*2) end
  if (options.amp_skew or 0)~=0 then value=value^(2^((options.amp_skew or 0)*2)) end
  value=U.clamp(value+(options.tilt or 0)*(t-.5),0,1)
  return options.low+(options.high-options.low)*value
end

local function calculated(items,mode,options,def)
  local values={}; if #items==0 then return values end
  local first,last=items[1].ppq,items[#items].ppq; local onset_index,onset_count=0,0; local previous
  for _,item in ipairs(items) do if previous==nil or math.abs(item.ppq-previous)>.5 then onset_count=onset_count+1; previous=item.ppq end end
  previous=nil
  for _,item in ipairs(items) do
    if previous==nil or math.abs(item.ppq-previous)>.5 then onset_index=onset_index+1; previous=item.ppq end
    local t=last>first and (item.ppq-first)/(last-first) or 0
    local value=U.clamp(math.floor(shaped_value(mode,options,t,onset_index,onset_count,item.ppq)+.5),def.minimum,def.maximum)
    if def.switch then value=value>=64 and 127 or 0 end
    values[item.index]=value
  end
  return values
end
M.calculated=calculated

local function write_values(app,def,values,items)
  if def.note then app.edit:begin_preview(app.take) end
  for _,item in ipairs(items) do local index,value=item.index,values[item.index]
    if item.insert then
      local msg2,msg3
      if def.pitch then msg2,msg3=value&0x7F,(value>>7)&0x7F elseif def.status==0xD0 or def.status==0xC0 then msg2,msg3=value,0 else msg2,msg3=def.cc,value end
      reaper.MIDI_InsertCC(app.take,true,false,item.ppq,def.status,app.settings.channel or 0,msg2,msg3,true)
    elseif def.note then app.edit:set(index,app.take,nil,nil,nil,value)
    elseif def.pitch then reaper.MIDI_SetCC(app.take,index,nil,nil,nil,nil,nil,value&0x7F,(value>>7)&0x7F,true)
    elseif def.status==0xD0 or def.status==0xC0 then reaper.MIDI_SetCC(app.take,index,nil,nil,nil,nil,nil,value,0,true)
    else reaper.MIDI_SetCC(app.take,index,nil,nil,nil,nil,nil,nil,value,true) end
  end
  if def.note then app.edit:finish() end
end

local function delete_replaced_events(app,indices)
  table.sort(indices or {},function(a,b)return a>b end)
  for _,index in ipairs(indices or {}) do reaper.MIDI_DeleteCC(app.take,index) end
end

local function restore(app)
  local p=app.lane_tool_preview; if not p then return false end
  if p.take and reaper.ValidatePtr2(0,p.take,'MediaItem_Take*') then reaper.MIDI_SetAllEvts(p.take,p.raw); reaper.MIDI_Sort(p.take); Notes.set_pairing_state(p.take,p.pairing_state) end
  app.cache:invalidate(); app.cache:rebuild(); app.cc_cache:invalidate(); app.cc_cache:rebuild(); reaper.UpdateArrange()
  return true
end

local function chase_restored_controller(app,p)
  if not reaper.StuffMIDIMessage or not p or not p.def or p.def.note then return end
  local def=p.def; local channel=app.settings.channel or 0
  local qn
  if reaper.GetPlayState and (reaper.GetPlayState()&1)==1 and reaper.GetPlayPosition then qn=reaper.TimeMap2_timeToQN(0,reaper.GetPlayPosition())
  elseif reaper.GetCursorPosition then qn=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())
  else qn=app.item_start_qn or 0 end
  local ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,qn); local found=nil
  for _,e in ipairs(app.cc_cache:get(false)) do
    if matching_event(def,e,channel) and e.ppq<=ppq and (not found or e.ppq>found.ppq) then found=e end
  end
  local status=def.status|channel; local msg2,msg3
  if def.pitch then
    local value=found and ((found.msg3<<7)|found.msg2) or 8192; msg2,msg3=value&0x7F,(value>>7)&0x7F
  elseif def.status==0xD0 or def.status==0xC0 then msg2,msg3=found and found.msg2 or 0,0
  else
    local fallback=(def.cc==8 or def.cc==10) and 64 or 0
    msg2,msg3=def.cc,found and found.msg3 or fallback
  end
  reaper.StuffMIDIMessage(0,status,msg2,msg3)
end

function M.cancel(app,chase_audio)
  local p=app.lane_tool_preview; if not p then return false end
  restore(app); if p.undo_open then reaper.Undo_EndBlock2(0,'ReaRoll: cancel lane preview',0) end
  app.lane_tool_preview=nil
  -- Restoring the take does not by itself recall a CC already received by a
  -- plug-in.  While playing, seek to the current play position so REAPER
  -- chases the restored Pan/Expression/etc. state into the instrument.
  if chase_audio~=false and reaper.GetPlayState and reaper.GetPlayPosition and reaper.SetEditCurPos and (reaper.GetPlayState()&1)==1 then
    reaper.SetEditCurPos(reaper.GetPlayPosition(),false,true)
  end
  if chase_audio~=false then chase_restored_controller(app,p) end
  return true
end

local function preview(app,def,mode,options)
  if app.transform_preview then app.transforms.cancel_preview(app) end
  local scope,first,last=automatic_scope(app); local signature=def.id..':'..(app.settings.channel or 0)..':'..scope..':'..string.format('%.6f:%.6f',first,last); local resolution=options.resolution or .125
  if app.lane_tool_preview and app.lane_tool_preview.signature~=signature then M.cancel(app,false) end
  if app.lane_tool_preview and app.lane_tool_preview.resolution~=resolution then M.cancel(app,false) end
  if not app.lane_tool_preview then
    local ok,raw=reaper.MIDI_GetAllEvts(app.take,''); if not ok then return false end
    local items,deletes=collect(app,def,resolution); if #items==0 then app.transform_notice='No events are available for Shape in the current target.'; return false end
    reaper.Undo_BeginBlock2(0)
    app.lane_tool_preview={take=app.take,raw=raw,pairing_state=Notes.get_pairing_state(app.take),signature=signature,resolution=resolution,items=items,deletes=deletes,def=def,mode=mode,undo_open=true}
  end
  if mode=='lfo' and options.sync_qn then
    local origin=app.item_start_qn or 0; options._sync_origin_ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,origin)
    options._sync_ppq=math.abs(reaper.MIDI_GetPPQPosFromProjQN(app.take,origin+options.sync_qn)-options._sync_origin_ppq)
  end
  local p=app.lane_tool_preview; restore(app); p.mode=mode; p.options=options; p.values=calculated(p.items,mode,options,def); delete_replaced_events(app,p.deletes); write_values(app,def,p.values,p.items)
  reaper.MIDI_Sort(app.take); app.cache:invalidate(); app.cache:rebuild(); app.cc_cache:invalidate(); app.cc_cache:rebuild(); reaper.UpdateArrange(); return true
end
M.preview=preview

function M.apply(app)
  local p=app.lane_tool_preview; if not p then return false end
  restore(app); reaper.MIDI_DisableSort(app.take); delete_replaced_events(app,p.deletes); write_values(app,p.def,p.values,p.items); reaper.MIDI_Sort(app.take)
  if p.undo_open then reaper.Undo_EndBlock2(0,'ReaRoll: shape '..p.def.label,-1) end
  app.lane_tool_preview=nil; app.cache:invalidate(); app.cache:rebuild(); app.cc_cache:invalidate(); app.cc_cache:rebuild(); reaper.UpdateArrange(); return true
end

local function defaults(app,def)
  app.lane_shape_options=app.lane_shape_options or {}
  local o=app.lane_shape_options[def.id]
  if not o then
    local high=def.maximum; local low=def.note and 45 or math.floor(high*.2); local steps
    if def.note then steps={110,75,95,60}
    elseif def.pitch then steps={12288,7168,10240,8192}
    else steps={math.floor(high*.87),math.floor(high*.59),math.floor(high*.75),math.floor(high*.47)} end
    local default_steps={}; for i,value in ipairs(steps) do default_steps[i]=value end
    o={mode='curve',curve='Linear',resolution=.125,sync_qn=1,first=low,last=high,low=low,high=high,shape='Sine',phase=0,amp_skew=0,pulse_width=.5,cycles=1,freq_skew=0,tilt=0,steps=steps,default_steps=default_steps}
    app.lane_shape_options[def.id]=o
  end
  o.scope=nil; o.curve=o.curve or 'Linear'; o.resolution=o.resolution or .125; o.sync_qn=o.sync_qn or 1
  for i,value in ipairs(o.steps) do o.steps[i]=U.clamp(value,def.minimum,def.maximum) end
  return o
end

local function shape_popup(app,def)
  local I,c=app.ImGui,app.ctx; local o=defaults(app,def); local changed=false
  I.TextColored(c,app.theme.accent,'Shape / '..def.label)
  I.Spacing(c); I.TextDisabled(c,'LIVE PREVIEW  /  Channel '..tostring((app.settings.channel or 0)+1)); I.Separator(c)
  if def.protected then I.TextWrapped(c,'This MIDI message type is protected from generated automation. Choose Velocity, Pitch Bend, Pressure, or a normal CC lane.'); if I.Button(c,'Close') then I.CloseCurrentPopup(c) end; return end
  local scope=automatic_scope(app)
  I.TextDisabled(c,scope=='range' and 'Target: selected range' or scope=='notes' and 'Target: selected notes' or 'Target: entire MIDI item')
  for index,name in ipairs({'curve','lfo','step'}) do if index>1 then I.SameLine(c) end; if I.RadioButton(c,name:sub(1,1):upper()..name:sub(2),o.mode==name) then o.mode=name; changed=true end end
  I.Separator(c)
  if o.mode=='curve' then
    if I.BeginCombo(c,'Curve type##shape_curve_type',o.curve) then for _,name in ipairs({'Linear','Ease in','Ease out','S-curve'}) do if I.Selectable(c,name,o.curve==name) then o.curve=name; changed=true end end; I.EndCombo(c) end
    changed=Controls.choice(app,o,'curve','Linear',{'Linear','Ease in','Ease out','S-curve'},'Curve shape') or changed
    local hit; hit,o.first=I.SliderInt(c,'Start',o.first,def.minimum,def.maximum); changed=Controls.number(app,o,'first',def.note and 45 or math.floor(def.maximum*.2),1,def.minimum,def.maximum,'Shape start') or hit or changed
    hit,o.last=I.SliderInt(c,'End',o.last,def.minimum,def.maximum); changed=Controls.number(app,o,'last',def.maximum,1,def.minimum,def.maximum,'Shape end') or hit or changed
  elseif o.mode=='lfo' then
    if I.BeginCombo(c,'LFO shape',o.shape) then for _,shape in ipairs({'Sine','Triangle','Saw up','Saw down','Square'}) do if I.Selectable(c,shape,o.shape==shape) then o.shape=shape; changed=true end end; I.EndCombo(c) end
    changed=Controls.choice(app,o,'shape','Sine',{'Sine','Triangle','Saw up','Saw down','Square'},'LFO shape') or changed
    local rate_labels={[.25]='1/16 note',[.5]='1/8 note',[1]='1/4 note',[2]='1/2 note',[4]='4 QN',[8]='8 QN',[16]='16 QN'}
    if I.BeginCombo(c,'Rate##shape_sync_rate',rate_labels[o.sync_qn] or '1/4 note') then for _,rate in ipairs({.25,.5,1,2,4,8,16}) do if I.Selectable(c,rate_labels[rate],o.sync_qn==rate) then o.sync_qn=rate; changed=true end end; I.EndCombo(c) end
    changed=Controls.choice(app,o,'sync_qn',1,{.25,.5,1,2,4,8,16},'Tempo-synced LFO rate') or changed
    local hit; hit,o.low=I.SliderInt(c,'Minimum',o.low,def.minimum,def.maximum); changed=Controls.number(app,o,'low',def.note and 45 or math.floor(def.maximum*.2),1,def.minimum,def.maximum,'LFO minimum') or hit or changed
    hit,o.high=I.SliderInt(c,'Maximum',o.high,def.minimum,def.maximum); changed=Controls.number(app,o,'high',def.maximum,1,def.minimum,def.maximum,'LFO maximum') or hit or changed
    hit,o.phase=I.SliderDouble(c,'Phase',o.phase,0,1,'%.2f'); changed=Controls.number(app,o,'phase',0,.02,0,1,'LFO phase') or hit or changed
    hit,o.amp_skew=I.SliderDouble(c,'Amp skew',o.amp_skew,-1,1,'%.2f'); changed=Controls.number(app,o,'amp_skew',0,.05,-1,1,'Amplitude skew') or hit or changed
    if o.shape=='Square' then hit,o.pulse_width=I.SliderDouble(c,'Pulse width',o.pulse_width,.05,.95,'%.2f'); changed=Controls.number(app,o,'pulse_width',.5,.05,.05,.95,'Pulse width') or hit or changed end
    hit,o.tilt=I.SliderDouble(c,'Tilt',o.tilt,-1,1,'%.2f'); changed=Controls.number(app,o,'tilt',0,.05,-1,1,'LFO tilt') or hit or changed
  else
    I.TextDisabled(c,'Drag the bars. The pattern repeats by onset; chord notes share a step.')
    local count=math.max(1,#o.steps); local available=I.GetContentRegionAvail and select(1,I.GetContentRegionAvail(c)) or 320; local gap=4; local bar_w=math.max(14,(available-gap*(count-1))/count); local bar_h=112
    local row_x,row_y=I.GetCursorScreenPos(c); local d=I.GetWindowDrawList(c)
    for i,value in ipairs(o.steps) do
      if i>1 then I.SameLine(c,0,gap) end
      I.InvisibleButton(c,'##lane_step_bar_'..i,bar_w,bar_h)
      local bx1,by1=I.GetItemRectMin(c); local bx2,by2=I.GetItemRectMax(c); local active=I.IsItemActive(c); local hovered=I.IsItemHovered(c)
      if active and I.IsMouseDown(c,I.MouseButton_Left) then local _,my=I.GetMousePos(c); local next_value=U.clamp(math.floor(def.minimum+(by2-U.clamp(my,by1,by2))/math.max(1,by2-by1)*(def.maximum-def.minimum)+.5),def.minimum,def.maximum); if next_value~=o.steps[i] then o.steps[i]=next_value; changed=true end end
      changed=Controls.number(app,o.steps,i,(o.default_steps and o.default_steps[i]) or value,1,def.minimum,def.maximum,'Step '..i) or changed
      I.DrawList_AddRectFilled(d,bx1,by1,bx2,by2,app.theme.lane_bg or app.theme.row,3); local fill_y=by2-(o.steps[i]-def.minimum)/math.max(1,def.maximum-def.minimum)*(by2-by1); I.DrawList_AddRectFilled(d,bx1+2,fill_y,bx2-2,by2-2,app.theme.velocity or app.theme.accent,2); I.DrawList_AddRect(d,bx1,by1,bx2,by2,hovered and app.theme.selected_edge or app.theme.grid,3); I.DrawList_AddText(d,bx1+5,by1+4,app.theme.text,tostring(o.steps[i]))
    end
    if I.SmallButton(c,'+ Step') and #o.steps<16 then o.steps[#o.steps+1]=o.steps[#o.steps] or math.floor(def.maximum*.75); changed=true end
    I.SameLine(c); if I.SmallButton(c,'- Step') and #o.steps>1 then table.remove(o.steps); changed=true end
    I.SameLine(c); if I.SmallButton(c,'Rotate') then table.insert(o.steps,1,table.remove(o.steps)); changed=true end
    I.SameLine(c); if I.SmallButton(c,'Reverse') then local reversed={}; for i=#o.steps,1,-1 do reversed[#reversed+1]=o.steps[i] end; o.steps=reversed; changed=true end
  end
  if not def.note then
    local density_labels={[.25]='1/16', [.125]='1/32', [.0625]='1/64', [.03125]='1/128'}
    if I.BeginCombo(c,'Point density',density_labels[o.resolution] or '1/32') then for _,value in ipairs({.25,.125,.0625,.03125}) do if I.Selectable(c,density_labels[value],o.resolution==value) then o.resolution=value; changed=true end end; I.EndCombo(c) end
    changed=Controls.choice(app,o,'resolution',.125,{.25,.125,.0625,.03125},'Automation point density') or changed
  end
  if o.mode=='lfo' then local origin=app.item_start_qn or 0; o._sync_origin_ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,origin); o._sync_ppq=math.abs(reaper.MIDI_GetPPQPosFromProjQN(app.take,origin+o.sync_qn)-o._sync_origin_ppq) end
  if o.mode~='step' then
    local preview_w=I.GetContentRegionAvail and select(1,I.GetContentRegionAvail(c)) or 320; preview_w=math.max(120,preview_w)
    I.InvisibleButton(c,'##shape_visual',preview_w,64)
    local x1,y1=I.GetItemRectMin(c); local x2,y2=I.GetItemRectMax(c); local d=I.GetWindowDrawList(c)
    I.DrawList_AddRectFilled(d,x1,y1,x2,y2,app.theme.lane_bg or app.theme.row,4); I.DrawList_AddRect(d,x1,y1,x2,y2,app.theme.grid,4)
    local lastx,lasty
    for i=0,48 do local t=i/48; local position=(o._sync_origin_ppq or 0)+t*(o._sync_ppq or 1)*2; local value=shaped_value(o.mode,o,t,1,1,position); local px=x1+3+t*(x2-x1-6); local py=y2-3-(value-def.minimum)/math.max(1,def.maximum-def.minimum)*(y2-y1-6); if lastx then I.DrawList_AddLine(d,lastx,lasty,px,py,app.theme.velocity or app.theme.accent,2) end; lastx,lasty=px,py end
    if I.IsItemHovered(c) then I.SetTooltip(c,'Preview of the value shape. LFO rate is synchronized in musical quarter-note time and anchored to the MIDI item start.') end
  end
  if changed or not app.lane_tool_preview then preview(app,def,o.mode,o) end
  I.Spacing(c); I.Separator(c); I.Spacing(c)
  I.BeginDisabled(c,not app.lane_tool_preview); I.PushStyleColor(c,I.Col_Button,app.theme.accent)
  if I.Button(c,'Apply',120,0) then M.apply(app); I.CloseCurrentPopup(c) end
  I.PopStyleColor(c); I.EndDisabled(c); I.SameLine(c)
  if I.Button(c,'Cancel',100,0) then M.cancel(app); I.CloseCurrentPopup(c) end
end

local function prepare_note_tool(app)
  if app.lane_tool_preview then M.cancel(app) end
  if app.transform_preview then app.transforms.cancel_preview(app) end
end

local function tool_button(app,label,id,tip,popup)
  local I,c=app.ImGui,app.ctx
  local active=I.IsPopupOpen and I.IsPopupOpen(c,popup)
  I.PushStyleColor(c,I.Col_Button,active and app.theme.beat or app.theme.panel2)
  I.PushStyleColor(c,I.Col_Border,active and app.theme.accent or app.theme.grid)
  if I.Button(c,label..'##lane_tool_'..id) then prepare_note_tool(app); I.OpenPopup(c,popup) end
  I.PopStyleColor(c,2)
  if I.IsItemHovered(c) then I.SetTooltip(c,tip) end
end

local function note_tool_popups(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  I.PushStyleVar(c,I.StyleVar_WindowPadding,16,14)
  I.PushStyleVar(c,I.StyleVar_ItemSpacing,8,8)
  I.PushStyleVar(c,I.StyleVar_FrameRounding,5)
  I.PushStyleVar(c,I.StyleVar_FrameBorderSize,1)
  local function begin_popup(name)
    I.SetNextWindowSize(c,420,0,I.Cond_Appearing)
    if name=='##lane_arp' and I.SetNextWindowSizeConstraints then I.SetNextWindowSizeConstraints(c,420,0,560,600) end
    return I.BeginPopup(c,name,name=='##lane_arp' and I.WindowFlags_NoScrollWithMouse or 0)
  end
  if begin_popup('##lane_scale_quantize') then
    popup_header(app,'Scale quantize','Move existing notes into Harmony\'s key and scale without changing their timing.')
    local changed=false
    I.SetNextItemWidth(c,110)
    if I.BeginCombo(c,'Key',Music.roots[s.scale_root+1]) then
      for pc=0,11 do if I.Selectable(c,Music.roots[pc+1],s.scale_root==pc) then s.scale_root=pc; changed=true end end
      I.EndCombo(c)
    end
    I.SetNextItemWidth(c,260)
    if I.BeginCombo(c,'Scale',s.scale_name) then
      for _,group in ipairs(Music.scale_groups) do
        I.TextDisabled(c,group[1])
        for _,name in ipairs(group[2]) do if I.Selectable(c,name,s.scale_name==name) then s.scale_name=name; changed=true end end
      end
      I.EndCombo(c)
    end
    app.lane_scale_direction=app.lane_scale_direction or 0
    I.Spacing(c)
    for index,entry in ipairs({{'Nearest',0},{'Down',-1},{'Up',1}}) do
      if index>1 then I.SameLine(c) end
      if option_card(app,'scale_direction'..index,entry[1],app.lane_scale_direction==entry[2]) then app.lane_scale_direction=entry[2]; changed=true end
    end
    I.TextDisabled(c,'In-scale notes stay put. Nearest breaks ties upward.')
    if changed or not app.transform_preview then app.transforms.preview_scale_quantize(app,app.lane_scale_direction) end
    preview_footer(app); I.EndPopup(c)
  end
  if begin_popup('##lane_quantize') then
    if app.lane_quantize_ends==nil then app.lane_quantize_ends=false end; app.lane_quantize_step=app.lane_quantize_step or s.grid_qn; app.lane_quantize_strength=app.lane_quantize_strength or 100
    popup_header(app,'Timing quantize','Tighten note starts to the grid. Adjust strength for a lighter touch.'); local changed=false
    local labels={[1]='1/4',[.5]='1/8',[.25]='1/16',[.125]='1/32',[.0625]='1/64'}
    for index,step in ipairs({1,.5,.25,.125,.0625}) do
      if index>1 then I.SameLine(c) end
      if option_card(app,'quantize_grid'..index,labels[step],app.lane_quantize_step==step) then app.lane_quantize_step=step; changed=true end
    end
    changed=Controls.choice(app,app,'lane_quantize_step',s.grid_qn,{1,.5,.25,.125,.0625},'Quantize grid') or changed
    local hit; hit,app.lane_quantize_strength=I.SliderInt(c,'Strength',app.lane_quantize_strength,0,100,'%d%%'); changed=Controls.number(app,app,'lane_quantize_strength',100,5,0,100,'Quantize strength') or hit or changed
    hit,app.lane_quantize_ends=I.Checkbox(c,'Quantize note ends',app.lane_quantize_ends); changed=Controls.toggle(app,app,'lane_quantize_ends',false,'Quantize note ends') or hit or changed
    if changed or not app.transform_preview then app.transforms.preview_quantize(app,app.lane_quantize_ends,app.lane_quantize_step,app.lane_quantize_strength) end
    preview_footer(app); I.EndPopup(c)
  end
  if begin_popup('##lane_legato') then
    app.legato_release_qn=app.legato_release_qn or 0; app.legato_target=app.legato_target or 'same_pitch'
    popup_header(app,'Legato','Connect notes smoothly, with an optional release gap.'); local changed=false
    if I.BeginCombo(c,'Connect',app.legato_target=='next_onset' and 'Next selected onset (chords)' or 'Next note of same pitch') then
      if I.Selectable(c,'Next note of same pitch',app.legato_target=='same_pitch') then app.legato_target='same_pitch'; changed=true end
      if I.Selectable(c,'Next selected onset (chords)',app.legato_target=='next_onset') then app.legato_target='next_onset'; changed=true end
      I.EndCombo(c)
    end
    changed=Controls.choice(app,app,'legato_target','same_pitch',{'same_pitch','next_onset'},'Legato connection rule') or changed
    I.TextDisabled(c,app.legato_target=='next_onset' and 'Every note in a chord reaches the next chord or melodic onset.' or 'Each pitch is treated as its own repeated-note voice.')
    local hit; hit,app.legato_release_qn=I.SliderDouble(c,'Release gap',app.legato_release_qn,0,.25,'%.3f QN'); changed=Controls.number(app,app,'legato_release_qn',0,.01,0,.25,'Legato release gap') or hit or changed
    if I.IsItemHovered(c) then I.SetTooltip(c,'Zero makes notes touch. Increase this to leave a short release gap before the next onset.') end
    local all_pitches=app.legato_target=='next_onset'
    if changed or not app.transform_preview then app.transforms.preview_legato(app,-app.legato_release_qn,all_pitches) end
    preview_footer(app); I.EndPopup(c)
  end
  if begin_popup('##lane_humanize') then
    app.human_timing_bias=app.human_timing_bias or 0; if app.human_preserve_chords==nil then app.human_preserve_chords=true end
    popup_header(app,'Humanize','Add controlled timing and velocity variation.'); local changed=false; local hit
    hit,s.human_time=I.SliderInt(c,'Timing',s.human_time,0,50,'%d%% grid'); changed=Controls.number(app,s,'human_time',8,1,0,50,'Humanize timing') or hit or changed
    hit,s.human_velocity=I.SliderInt(c,'Velocity',s.human_velocity,0,40,'+/- %d'); changed=Controls.number(app,s,'human_velocity',6,1,0,40,'Humanize velocity') or hit or changed
    hit,app.human_timing_bias=I.SliderInt(c,'Timing bias',app.human_timing_bias,-100,100,'%+d%%'); changed=Controls.number(app,app,'human_timing_bias',0,5,-100,100,'Humanize timing bias') or hit or changed
    hit,app.human_preserve_chords=I.Checkbox(c,'Keep chord notes together',app.human_preserve_chords); changed=Controls.toggle(app,app,'human_preserve_chords',true,'Preserve chord timing') or hit or changed
    if changed or not app.transform_preview then app.transforms.preview_humanize(app,s.human_time,s.human_velocity,app.human_timing_bias,app.human_preserve_chords) end
    preview_footer(app); I.EndPopup(c)
  end
  if begin_popup('##lane_strum_flam') then
    app.performance_preview=app.performance_preview or 'strum'; app.strum_direction=app.strum_direction or 1
    popup_header(app,'Strum / Flam','Spread chord attacks or add a second hit.'); local changed=false
    if I.RadioButton(c,'Strum',app.performance_preview=='strum') then app.transforms.cancel_preview(app); app.performance_preview='strum'; changed=true end
    I.SameLine(c); if I.RadioButton(c,'Flam',app.performance_preview=='flam') then app.transforms.cancel_preview(app); app.performance_preview='flam'; changed=true end
    if app.performance_preview=='strum' then
      if I.RadioButton(c,'Low to high',app.strum_direction>0) then app.strum_direction=1; changed=true end; I.SameLine(c)
      if I.RadioButton(c,'High to low',app.strum_direction<0) then app.strum_direction=-1; changed=true end
      local hit; hit,s.strum_qn=I.SliderDouble(c,'Spacing',s.strum_qn,0,.20,'%.3f QN'); changed=Controls.number(app,s,'strum_qn',.03,.005,0,.20,'Strum spacing') or hit or changed
    else local hit; hit,s.flam_qn=I.SliderDouble(c,'Delay',s.flam_qn,.005,.20,'%.3f QN'); changed=Controls.number(app,s,'flam_qn',.04,.005,.005,.20,'Flam delay') or hit or changed end
    if changed or not app.transform_preview then if app.performance_preview=='strum' then app.transforms.preview_strum(app,app.strum_direction) else app.transforms.preview_flam(app) end; app.lane_phrase_preview=true end
    preview_footer(app)
    I.EndPopup(c)
  end
  if begin_popup('##lane_arp') then
    app.control_wheel_consumed=false
    local Arp=require 'src.arpeggiator'
    app.arp_direction=app.arp_direction or 'up'; app.arp_gate=app.arp_gate or .85; app.arp_octaves=app.arp_octaves or 1; app.arp_swing=app.arp_swing or 0
    app.arp_rhythm=app.arp_rhythm or '11111111'; app.arp_accent=app.arp_accent or 0
    if app.arp_restart==nil then app.arp_restart=true end
    popup_header(app,'Arpeggiator','Follow your chords. Find a groove. Shape the movement.')
    local changed=false
    local preset_names={}; for _,preset in ipairs(Arp.presets) do preset_names[#preset_names+1]=preset.name end
    local function load_preset(name)
      for _,preset in ipairs(Arp.presets) do if preset.name==name then
        app.arp_preset=preset.name; app.arp_direction=preset.pattern; app.arp_rate=preset.rate
        app.arp_gate=preset.gate; app.arp_octaves=preset.octaves; app.arp_swing=preset.swing
        app.arp_rhythm=preset.rhythm; app.arp_accent=preset.accent; return
      end end
    end
    local preset_open=I.BeginCombo(c,'Starting point',app.arp_preset or 'Custom')
    if not preset_open and Controls.choice(app,app,'arp_preset',preset_names[1],preset_names,'Starting point') then load_preset(app.arp_preset); changed=true end
    if preset_open then
      for _,preset in ipairs(Arp.presets) do
        if I.Selectable(c,preset.name,app.arp_preset==preset.name) then
          app.arp_preset=preset.name; app.arp_direction=preset.pattern; app.arp_rate=preset.rate
          app.arp_gate=preset.gate; app.arp_octaves=preset.octaves; app.arp_swing=preset.swing
          app.arp_rhythm=preset.rhythm; app.arp_accent=preset.accent; changed=true
        end
      end
      I.EndCombo(c)
    end
    I.Spacing(c); I.TextColored(c,app.theme.accent,'MOVEMENT')
    local labels={'Rise','Fall','Bounce up','Bounce down','Outside in','Inside out','Random'}
    for i,name in ipairs(Arp.patterns) do
      if i%3~=1 then I.SameLine(c) end
      if option_card(app,'arp_pattern_'..name,labels[i],app.arp_direction==name) then app.arp_direction=name; changed=true end
    end
    local hit; hit,app.arp_octaves=I.SliderInt(c,'Octave range',app.arp_octaves,1,4,'%d'); changed=Controls.number(app,app,'arp_octaves',1,1,1,4,'Octave range') or hit or changed
    hit,app.arp_restart=I.Checkbox(c,'Restart pattern when chord changes',app.arp_restart); changed=hit or changed
    I.Spacing(c); I.Separator(c); I.Spacing(c); I.TextColored(c,app.theme.accent,'GROOVE')
    local rates={{'Grid',0},{'1/8',.5},{'1/16',.25},{'1/32',.125},{'1/8 triplet',1/3},{'1/16 triplet',1/6}}
    app.arp_rate=app.arp_rate or 0
    for i,entry in ipairs(rates) do
      if i%3~=1 then I.SameLine(c) end
      if option_card(app,'arp_rate_'..i,entry[1],(app.arp_rate or 0)==entry[2]) then app.arp_rate=entry[2]; changed=true end
    end
    local rhythm_name='Straight'; for _,entry in ipairs(Arp.rhythms) do if entry[2]==app.arp_rhythm then rhythm_name=entry[1] end end
    local rhythm_open=I.BeginCombo(c,'Rhythm',rhythm_name)
    if not rhythm_open then changed=Controls.choice(app,app,'arp_rhythm','11111111',{'11111111','01010101','10010010','10111010','11010110'},'Rhythm') or changed end
    if rhythm_open then
      for _,entry in ipairs(Arp.rhythms) do if I.Selectable(c,entry[1],app.arp_rhythm==entry[2]) then app.arp_rhythm=entry[2]; changed=true end end
      I.EndCombo(c)
    end
    for i=1,8 do
      if i>1 then I.SameLine(c) end
      local on=app.arp_rhythm:sub(i,i)=='1'
      if option_card(app,'arp_step_'..i,on and tostring(i) or '-',on) then app.arp_rhythm=app.arp_rhythm:sub(1,i-1)..(on and '0' or '1')..app.arp_rhythm:sub(i+1); changed=true end
    end
    I.TextDisabled(c,'Tap steps to add rests. Accent lands every four steps.')
    hit,app.arp_gate=I.SliderDouble(c,'Note length',app.arp_gate,.1,1,'%.2f'); changed=Controls.number(app,app,'arp_gate',.85,.02,.1,1,'Note length') or hit or changed
    hit,app.arp_swing=I.SliderDouble(c,'Swing',app.arp_swing,0,.75,'%.2f'); changed=Controls.number(app,app,'arp_swing',0,.02,0,.75,'Swing') or hit or changed
    hit,app.arp_accent=I.SliderInt(c,'Accent',app.arp_accent,0,40,'%d'); changed=Controls.number(app,app,'arp_accent',0,1,0,40,'Accent') or hit or changed
    if app.arp_direction=='random' and I.Button(c,'New variation') then app.arp_seed=(app.arp_seed or 1)+1; changed=true end
    if changed or not app.transform_preview then
      app.transforms.preview_arpeggiate(app,app.arp_direction,app.arp_gate,app.arp_octaves,app.arp_swing,{rate=(app.arp_rate and app.arp_rate>0) and app.arp_rate or s.grid_qn,rhythm=app.arp_rhythm,accent=app.arp_accent,restart=app.arp_restart,seed=app.arp_seed or 1})
    end
    if app.transform_notice then I.TextWrapped(c,app.transform_notice) end
    if app.transform_preview and app.transform_preview.kind=='arp' then I.TextDisabled(c,tostring(app.transform_preview.generated_count or 0)..' notes in preview') end
    preview_footer(app)
    -- Native window scrolling runs before widgets claim the wheel. Route it
    -- here instead, after settings have had the opportunity to consume it.
    if not app.control_wheel_consumed and I.IsWindowHovered(c) and not I.IsAnyItemActive(c) then
      local wheel=I.GetMouseWheel(c)
      if wheel~=0 then I.SetScrollY(c,math.max(0,I.GetScrollY(c)-wheel*I.GetTextLineHeight(c)*3)) end
    end
    I.EndPopup(c)
  end
  if begin_popup('##lane_velocity') then
    app.velocity_tool_mode=app.velocity_tool_mode or 'ramp'; app.velocity_set=app.velocity_set or 100; app.velocity_scale=app.velocity_scale or 1; app.velocity_pivot=app.velocity_pivot or 96; app.velocity_first=app.velocity_first or 60; app.velocity_last=app.velocity_last or 110
    popup_header(app,'Velocity','Shape the dynamics of your selected notes.'); local changed=false
    for i,entry in ipairs({{'Set','set'},{'Ramp','ramp'},{'Compress / Expand','scale'}}) do if i>1 then I.SameLine(c) end; if I.RadioButton(c,entry[1]..'##velocity_mode_'..entry[2],app.velocity_tool_mode==entry[2]) then app.velocity_tool_mode=entry[2]; changed=true end end
    local hit
    if app.velocity_tool_mode=='set' then hit,app.velocity_set=I.SliderInt(c,'Level',app.velocity_set,1,127); changed=Controls.number(app,app,'velocity_set',100,1,1,127,'Velocity level') or hit or changed
    elseif app.velocity_tool_mode=='ramp' then hit,app.velocity_first=I.SliderInt(c,'Start',app.velocity_first,1,127); changed=Controls.number(app,app,'velocity_first',60,1,1,127,'Ramp start') or hit or changed; hit,app.velocity_last=I.SliderInt(c,'End',app.velocity_last,1,127); changed=Controls.number(app,app,'velocity_last',110,1,1,127,'Ramp end') or hit or changed
    else hit,app.velocity_scale=I.SliderDouble(c,'Amount',app.velocity_scale,0,2,'%.2fx'); changed=Controls.number(app,app,'velocity_scale',1,.05,0,2,'Velocity compression or expansion') or hit or changed; hit,app.velocity_pivot=I.SliderInt(c,'Pivot',app.velocity_pivot,1,127); changed=Controls.number(app,app,'velocity_pivot',96,1,1,127,'Velocity pivot') or hit or changed end
    if changed or not app.transform_preview then app.transforms.preview_velocity(app,app.velocity_tool_mode,app.velocity_set,app.velocity_scale,app.velocity_pivot,app.velocity_first,app.velocity_last) end
    preview_footer(app)
    I.EndPopup(c)
  end
  if begin_popup('##lane_pitch') then
    popup_header(app,'Pitch','Transpose the selection. Changes preview from the original notes.')
    app.lane_pitch_amount=app.lane_pitch_amount or 0
    local changed=false
    if option_card(app,'pitch_semitones','Semitones',not app.lane_pitch_in_scale) then app.lane_pitch_in_scale=false; changed=true end
    I.SameLine(c)
    if option_card(app,'pitch_degrees','Scale degrees',app.lane_pitch_in_scale==true) then app.lane_pitch_in_scale=true; changed=true end
    if app.lane_pitch_in_scale then I.TextDisabled(c,Music.roots[s.scale_root+1]..' '..s.scale_name) end
    local hit; hit,app.lane_pitch_amount=I.SliderInt(c,'Amount',app.lane_pitch_amount,-24,24,'%+d')
    changed=Controls.number(app,app,'lane_pitch_amount',0,1,-24,24,'Pitch offset') or hit or changed
    for index,amount in ipairs({-12,-1,0,1,12}) do
      if index>1 then I.SameLine(c) end
      if option_card(app,'pitch_offset'..index,amount==0 and 'Reset' or string.format('%+d',amount),app.lane_pitch_amount==amount) then app.lane_pitch_amount=amount; changed=true end
    end
    if changed or not app.transform_preview then app.transforms.preview_pitch(app,app.lane_pitch_amount,app.lane_pitch_in_scale) end
    preview_footer(app); I.EndPopup(c)
  end
  if begin_popup('##lane_more') then
    for _,entry in ipairs(app.lane_hidden_tools or {}) do
      if I.MenuItem(c,entry[1]) then prepare_note_tool(app); app.lane_open_popup=entry[4] end
    end
    if #(app.lane_hidden_tools or {})>0 then I.Separator(c) end
    I.TextDisabled(c,'Phrase actions'); I.Separator(c); I.BeginDisabled(c,Selection.count(app.selection)==0)
    for _,entry in ipairs({{'Reverse','reverse'},{'Invert','invert'},{'Chop to grid','chop'},{'Glue touching','glue'}}) do if I.MenuItem(c,entry[1]) then app.transforms[entry[2]](app) end end
    if I.MenuItem(c,'Half time') then app.transforms.scale_time(app,.5) end
    if I.MenuItem(c,'Double time') then app.transforms.scale_time(app,2) end
    if I.MenuItem(c,'Duplicate') then app.clipboard.duplicate(app) end
    I.EndDisabled(c); I.EndPopup(c)
  end
  I.PopStyleVar(c,4)
end

function M.draw(app,x,y,width,height)
  local I,c,T=app.ImGui,app.ctx,app.theme; local def=target(app)
  local scope,first,last=automatic_scope(app); local signature=def.id..':'..(app.settings.channel or 0)..':'..scope..':'..string.format('%.6f:%.6f',first,last)
  if app.lane_tool_preview and app.lane_tool_preview.signature~=signature then M.cancel(app,false) end
  local drawlist=I.GetWindowDrawList(c)
  I.DrawList_AddRectFilled(drawlist,x-3,y-2,x+width+3,y+height-1,T.panel,6)
  I.PushStyleColor(c,I.Col_Button,T.panel2)
  local labels={{'Timing','quantize','Quantize note timing / automatic preview','##lane_quantize'},{'Scale','scale_quantize','Quantize existing pitches to Harmony\'s key and scale','##lane_scale_quantize'},{'Legato','legato','Legato with options','##lane_legato'},{'Humanize','humanize','Humanize timing and velocity','##lane_humanize'},{'Strum','strum','Strum / Flam live preview','##lane_strum_flam'},{'Arp','arp','Arpeggiator','##lane_arp'},{'Velocity','velocity','Set, ramp, compress or expand velocity','##lane_velocity'},{'Pitch','pitch','Semitone and scale-degree transpose','##lane_pitch'}}
  local select_label='Select All'; local total=(I.CalcTextSize and select(1,I.CalcTextSize(c,select_label)) or #select_label*7)+18+6
  for _,entry in ipairs(labels) do total=total+(I.CalcTextSize and select(1,I.CalcTextSize(c,entry[1])) or #entry[1]*7)+18 end
  total=total+(I.CalcTextSize and select(1,I.CalcTextSize(c,'Shape')) or 35)+18+(I.CalcTextSize and select(1,I.CalcTextSize(c,'More')) or 28)+18+#labels*6+6
  I.SetCursorScreenPos(c,x+math.max(0,(width-total)*.5),y)
  I.PushStyleVar(c,I.StyleVar_FrameRounding,5)
  I.PushStyleVar(c,I.StyleVar_FrameBorderSize,1)
  if I.Button(c,select_label..'##lane_select_all') then if app.controller_selection_active and app.controller_lane then app.clipboard.select_all_cc(app,app.controller_lane,true) else for _,n in ipairs(app.cache:get(false)) do Selection.add(app.selection,n.id) end end end
  if I.IsItemHovered(c) then I.SetTooltip(c,app.controller_selection_active and 'Select all points in the active controller lane.' or 'Select all notes in ReaRoll\nThis does not replace REAPER\'s native MIDI-editor selection.') end
  app.lane_hidden_tools={}
  for _,entry in ipairs(labels) do
    local current=I.GetItemRectMax(c)
    local needed=I.CalcTextSize(c,entry[1])+24
    if current+needed<x+width-150 or entry[2]=='quantize' or entry[2]=='scale_quantize' then
      I.SameLine(c); tool_button(app,entry[1],entry[2],entry[3],entry[4])
    else app.lane_hidden_tools[#app.lane_hidden_tools+1]=entry end
  end
  I.SameLine(c)
  if I.Button(c,'Shape##lane_shape') then prepare_note_tool(app); I.OpenPopup(c,'##lane_shape_popup') end
  if I.IsItemHovered(c) then I.SetTooltip(c,def.protected and ('Shape is unavailable for protected '..def.label..' messages.') or ('Shape '..def.label..': Curve, LFO and repeating Step')) end
  I.SameLine(c); tool_button(app,'More','more','More phrase actions','##lane_more')
  I.PopStyleVar(c,2)
  I.PopStyleColor(c)
  if app.lane_open_popup then I.OpenPopup(c,app.lane_open_popup); app.lane_open_popup=nil end
  I.SetNextWindowSize(c,430,0,I.Cond_Appearing)
  local shape_open=I.BeginPopup(c,'##lane_shape_popup')
  if shape_open then shape_popup(app,def); I.EndPopup(c) elseif app.lane_tool_preview then M.cancel(app) end
  note_tool_popups(app)
  if app.lane_phrase_preview and I.IsPopupOpen and not I.IsPopupOpen(c,'##lane_strum_flam') then app.transforms.cancel_preview(app); app.lane_phrase_preview=nil end
  if app.transform_preview and I.IsPopupOpen then
    local popup_for={quantize='##lane_quantize',scale_quantize='##lane_scale_quantize',pitch='##lane_pitch',legato='##lane_legato',humanize='##lane_humanize',arp='##lane_arp',velocity='##lane_velocity',strum='##lane_strum_flam',flam='##lane_strum_flam'}
    local popup=popup_for[app.transform_preview.kind]
    if popup and not I.IsPopupOpen(c,popup) then app.transforms.cancel_preview(app); app.lane_phrase_preview=nil end
  end
end

return M
