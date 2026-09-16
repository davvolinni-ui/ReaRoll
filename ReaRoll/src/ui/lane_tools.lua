-- @noindex
local U=require 'src.util'
local Selection=require 'src.selection'
local Controls=require 'src.ui.controls'
local M={}
local popup_names={'##lane_quantize','##lane_legato','##lane_humanize','##lane_strum_flam','##lane_arp','##lane_pitch','##lane_velocity','##lane_shape_popup','##lane_more'}

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
  -- This row uses SmallButton, whose vertical frame padding is zero in
  -- Dear ImGui. Reserving GetFrameHeight left normal-button padding below it.
  return I.GetTextLineHeight and I.GetTextLineHeight(c) or 14
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
  for _,item in ipairs(items) do local index,value=item.index,values[item.index]
    if item.insert then
      local msg2,msg3
      if def.pitch then msg2,msg3=value&0x7F,(value>>7)&0x7F elseif def.status==0xD0 or def.status==0xC0 then msg2,msg3=value,0 else msg2,msg3=def.cc,value end
      reaper.MIDI_InsertCC(app.take,true,false,item.ppq,def.status,app.settings.channel or 0,msg2,msg3,true)
    elseif def.note then reaper.MIDI_SetNote(app.take,index,nil,nil,nil,nil,nil,nil,value,true)
    elseif def.pitch then reaper.MIDI_SetCC(app.take,index,nil,nil,nil,nil,nil,value&0x7F,(value>>7)&0x7F,true)
    elseif def.status==0xD0 or def.status==0xC0 then reaper.MIDI_SetCC(app.take,index,nil,nil,nil,nil,nil,value,0,true)
    else reaper.MIDI_SetCC(app.take,index,nil,nil,nil,nil,nil,nil,value,true) end
  end
end

local function delete_replaced_events(app,indices)
  table.sort(indices or {},function(a,b)return a>b end)
  for _,index in ipairs(indices or {}) do reaper.MIDI_DeleteCC(app.take,index) end
end

local function restore(app)
  local p=app.lane_tool_preview; if not p then return false end
  if p.take and reaper.ValidatePtr2(0,p.take,'MediaItem_Take*') then reaper.MIDI_SetAllEvts(p.take,p.raw); reaper.MIDI_Sort(p.take) end
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
    app.lane_tool_preview={take=app.take,raw=raw,signature=signature,resolution=resolution,items=items,deletes=deletes,def=def,mode=mode,undo_open=true}
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
  I.Text(c,'Editing: '..def.label..'  ·  Channel '..tostring((app.settings.channel or 0)+1)); I.Separator(c)
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
  if changed then preview(app,def,o.mode,o) end
  I.Separator(c); if I.Button(c,'Apply') then M.apply(app); I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then M.cancel(app); I.CloseCurrentPopup(c) end
  if not app.lane_tool_preview then I.SameLine(c); if I.SmallButton(c,'Preview') then preview(app,def,o.mode,o) end end
end

local function prepare_note_tool(app)
  if app.lane_tool_preview then M.cancel(app) end
  if app.transform_preview then app.transforms.cancel_preview(app) end
end

local function tool_button(app,label,id,tip,popup)
  local I,c=app.ImGui,app.ctx
  if I.SmallButton(c,label..'##lane_tool_'..id) then prepare_note_tool(app); I.OpenPopup(c,popup) end
  if I.IsItemHovered(c) then I.SetTooltip(c,tip) end
end

local function note_tool_popups(app)
  local I,c,s=app.ImGui,app.ctx,app.settings
  if I.BeginPopup(c,'##lane_quantize') then
    if app.lane_quantize_ends==nil then app.lane_quantize_ends=false end; app.lane_quantize_step=app.lane_quantize_step or s.grid_qn; app.lane_quantize_strength=app.lane_quantize_strength or 100
    I.Text(c,'Quantize'); I.Separator(c); local changed=false
    local labels={[1]='1/4',[.5]='1/8',[.25]='1/16',[.125]='1/32',[.0625]='1/64'}
    if I.BeginCombo(c,'Grid',labels[app.lane_quantize_step] or 'Current') then for _,step in ipairs({1,.5,.25,.125,.0625}) do if I.Selectable(c,labels[step],app.lane_quantize_step==step) then app.lane_quantize_step=step; changed=true end end; I.EndCombo(c) end
    changed=Controls.choice(app,app,'lane_quantize_step',s.grid_qn,{1,.5,.25,.125,.0625},'Quantize grid') or changed
    local hit; hit,app.lane_quantize_strength=I.SliderInt(c,'Strength',app.lane_quantize_strength,0,100,'%d%%'); changed=Controls.number(app,app,'lane_quantize_strength',100,5,0,100,'Quantize strength') or hit or changed
    hit,app.lane_quantize_ends=I.Checkbox(c,'Quantize note ends',app.lane_quantize_ends); changed=Controls.toggle(app,app,'lane_quantize_ends',false,'Quantize note ends') or hit or changed
    if changed then app.transforms.preview_quantize(app,app.lane_quantize_ends,app.lane_quantize_step,app.lane_quantize_strength) end
    I.BeginDisabled(c,Selection.count(app.selection)==0); if app.transform_preview then if I.Button(c,'Apply') then app.transforms.commit_preview(app); I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then app.transforms.cancel_preview(app); I.CloseCurrentPopup(c) end else if I.Button(c,'Preview') then app.transforms.preview_quantize(app,app.lane_quantize_ends,app.lane_quantize_step,app.lane_quantize_strength) end end; I.EndDisabled(c); I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_legato') then
    app.legato_release_qn=app.legato_release_qn or 0; app.legato_target=app.legato_target or 'same_pitch'
    I.Text(c,'Legato'); I.Separator(c); local changed=false
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
    if changed then app.transforms.preview_legato(app,-app.legato_release_qn,all_pitches) end
    I.BeginDisabled(c,Selection.count(app.selection)==0); if app.transform_preview then if I.Button(c,'Apply') then app.transforms.commit_preview(app); I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then app.transforms.cancel_preview(app); I.CloseCurrentPopup(c) end else if I.Button(c,'Preview') then app.transforms.preview_legato(app,-app.legato_release_qn,all_pitches) end end; I.EndDisabled(c); I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_humanize') then
    app.human_timing_bias=app.human_timing_bias or 0; if app.human_preserve_chords==nil then app.human_preserve_chords=true end
    I.Text(c,'Humanize'); I.Separator(c); local changed=false; local hit
    hit,s.human_time=I.SliderInt(c,'Timing',s.human_time,0,50,'%d%% grid'); changed=Controls.number(app,s,'human_time',8,1,0,50,'Humanize timing') or hit or changed
    hit,s.human_velocity=I.SliderInt(c,'Velocity',s.human_velocity,0,40,'+/- %d'); changed=Controls.number(app,s,'human_velocity',6,1,0,40,'Humanize velocity') or hit or changed
    hit,app.human_timing_bias=I.SliderInt(c,'Timing bias',app.human_timing_bias,-100,100,'%+d%%'); changed=Controls.number(app,app,'human_timing_bias',0,5,-100,100,'Humanize timing bias') or hit or changed
    hit,app.human_preserve_chords=I.Checkbox(c,'Keep chord notes together',app.human_preserve_chords); changed=Controls.toggle(app,app,'human_preserve_chords',true,'Preserve chord timing') or hit or changed
    if changed then app.transforms.preview_humanize(app,s.human_time,s.human_velocity,app.human_timing_bias,app.human_preserve_chords) end
    I.BeginDisabled(c,Selection.count(app.selection)==0); if app.transform_preview then if I.Button(c,'Apply') then app.transforms.commit_preview(app); I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then app.transforms.cancel_preview(app); I.CloseCurrentPopup(c) end else if I.Button(c,'Preview') then app.transforms.preview_humanize(app,s.human_time,s.human_velocity,app.human_timing_bias,app.human_preserve_chords) end end; I.EndDisabled(c); I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_strum_flam') then
    app.performance_preview=app.performance_preview or 'strum'; app.strum_direction=app.strum_direction or 1
    I.Text(c,'Strum / Flam'); I.Separator(c); local changed=false
    if I.RadioButton(c,'Strum',app.performance_preview=='strum') then app.transforms.cancel_preview(app); app.performance_preview='strum'; changed=true end
    I.SameLine(c); if I.RadioButton(c,'Flam',app.performance_preview=='flam') then app.transforms.cancel_preview(app); app.performance_preview='flam'; changed=true end
    if app.performance_preview=='strum' then
      if I.RadioButton(c,'Low to high',app.strum_direction>0) then app.strum_direction=1; changed=true end; I.SameLine(c)
      if I.RadioButton(c,'High to low',app.strum_direction<0) then app.strum_direction=-1; changed=true end
      local hit; hit,s.strum_qn=I.SliderDouble(c,'Spacing',s.strum_qn,0,.20,'%.3f QN'); changed=Controls.number(app,s,'strum_qn',.03,.005,0,.20,'Strum spacing') or hit or changed
    else local hit; hit,s.flam_qn=I.SliderDouble(c,'Delay',s.flam_qn,.005,.20,'%.3f QN'); changed=Controls.number(app,s,'flam_qn',.04,.005,.005,.20,'Flam delay') or hit or changed end
    if changed then if app.performance_preview=='strum' then app.transforms.preview_strum(app,app.strum_direction) else app.transforms.preview_flam(app) end; app.lane_phrase_preview=true end
    if not app.transform_preview then if I.Button(c,'Preview') then if app.performance_preview=='strum' then app.transforms.preview_strum(app,app.strum_direction) else app.transforms.preview_flam(app) end; app.lane_phrase_preview=true end
    else if I.Button(c,'Apply') then app.transforms.commit_preview(app); app.lane_phrase_preview=nil; I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then app.transforms.cancel_preview(app); app.lane_phrase_preview=nil; I.CloseCurrentPopup(c) end end
    I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_arp') then
    app.arp_direction=app.arp_direction or 'up'; app.arp_gate=app.arp_gate or .85; app.arp_octaves=app.arp_octaves or 1; app.arp_swing=app.arp_swing or 0
    I.Text(c,'Arpeggiator'); I.Separator(c)
    local changed=false
    if I.BeginCombo(c,'Direction',app.arp_direction) then for _,name in ipairs({'up','down','updown'}) do if I.Selectable(c,name,app.arp_direction==name) then app.arp_direction=name; changed=true end end; I.EndCombo(c) end
    changed=Controls.choice(app,app,'arp_direction','up',{'up','down','updown'},'Arpeggiator direction') or changed
    local hit; hit,app.arp_gate=I.SliderDouble(c,'Gate',app.arp_gate,.1,1,'%.2f'); changed=Controls.number(app,app,'arp_gate',.85,.02,.1,1,'Arpeggiator gate') or hit or changed
    hit,app.arp_octaves=I.SliderInt(c,'Octaves',app.arp_octaves,1,4,'%d'); changed=Controls.number(app,app,'arp_octaves',1,1,1,4,'Arpeggiator octaves') or hit or changed
    hit,app.arp_swing=I.SliderDouble(c,'Swing',app.arp_swing,0,.75,'%.2f'); changed=Controls.number(app,app,'arp_swing',0,.02,0,.75,'Arpeggiator swing') or hit or changed
    if changed then app.transforms.preview_arpeggiate(app,app.arp_direction,app.arp_gate,app.arp_octaves,app.arp_swing) end
    I.BeginDisabled(c,Selection.count(app.selection)==0); if app.transform_preview then if I.Button(c,'Apply') then app.transforms.commit_preview(app); I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then app.transforms.cancel_preview(app); I.CloseCurrentPopup(c) end else if I.Button(c,'Preview') then app.transforms.preview_arpeggiate(app,app.arp_direction,app.arp_gate,app.arp_octaves,app.arp_swing) end end; I.EndDisabled(c); I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_velocity') then
    app.velocity_tool_mode=app.velocity_tool_mode or 'ramp'; app.velocity_set=app.velocity_set or 100; app.velocity_scale=app.velocity_scale or 1; app.velocity_pivot=app.velocity_pivot or 96; app.velocity_first=app.velocity_first or 60; app.velocity_last=app.velocity_last or 110
    I.Text(c,'Velocity'); I.Separator(c); local changed=false
    for i,entry in ipairs({{'Set','set'},{'Ramp','ramp'},{'Compress / Expand','scale'}}) do if i>1 then I.SameLine(c) end; if I.RadioButton(c,entry[1]..'##velocity_mode_'..entry[2],app.velocity_tool_mode==entry[2]) then app.velocity_tool_mode=entry[2]; changed=true end end
    local hit
    if app.velocity_tool_mode=='set' then hit,app.velocity_set=I.SliderInt(c,'Level',app.velocity_set,1,127); changed=Controls.number(app,app,'velocity_set',100,1,1,127,'Velocity level') or hit or changed
    elseif app.velocity_tool_mode=='ramp' then hit,app.velocity_first=I.SliderInt(c,'Start',app.velocity_first,1,127); changed=Controls.number(app,app,'velocity_first',60,1,1,127,'Ramp start') or hit or changed; hit,app.velocity_last=I.SliderInt(c,'End',app.velocity_last,1,127); changed=Controls.number(app,app,'velocity_last',110,1,1,127,'Ramp end') or hit or changed
    else hit,app.velocity_scale=I.SliderDouble(c,'Amount',app.velocity_scale,0,2,'%.2fx'); changed=Controls.number(app,app,'velocity_scale',1,.05,0,2,'Velocity compression or expansion') or hit or changed; hit,app.velocity_pivot=I.SliderInt(c,'Pivot',app.velocity_pivot,1,127); changed=Controls.number(app,app,'velocity_pivot',96,1,1,127,'Velocity pivot') or hit or changed end
    if changed then app.transforms.preview_velocity(app,app.velocity_tool_mode,app.velocity_set,app.velocity_scale,app.velocity_pivot,app.velocity_first,app.velocity_last) end
    if app.transform_preview then if I.Button(c,'Apply') then app.transforms.commit_preview(app); I.CloseCurrentPopup(c) end; I.SameLine(c); if I.Button(c,'Cancel') then app.transforms.cancel_preview(app); I.CloseCurrentPopup(c) end else if I.Button(c,'Preview') then app.transforms.preview_velocity(app,app.velocity_tool_mode,app.velocity_set,app.velocity_scale,app.velocity_pivot,app.velocity_first,app.velocity_last) end end
    I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_pitch') then
    I.Text(c,'Pitch'); I.Separator(c); I.BeginDisabled(c,Selection.count(app.selection)==0)
    for i,entry in ipairs({{'-12',-12},{'-1',-1},{'+1',1},{'+12',12}}) do if i>1 then I.SameLine(c) end; if I.Button(c,entry[1]) then app.transforms.transpose(app,entry[2]) end end
    if I.Button(c,'Scale degree -') then app.transforms.transpose_scale(app,-1) end; I.SameLine(c); if I.Button(c,'Scale degree +') then app.transforms.transpose_scale(app,1) end
    I.EndDisabled(c); I.EndPopup(c)
  end
  if I.BeginPopup(c,'##lane_more') then
    I.TextDisabled(c,'Phrase actions'); I.Separator(c); I.BeginDisabled(c,Selection.count(app.selection)==0)
    for _,entry in ipairs({{'Reverse','reverse'},{'Invert','invert'},{'Chop to grid','chop'},{'Glue touching','glue'}}) do if I.MenuItem(c,entry[1]) then app.transforms[entry[2]](app) end end
    if I.MenuItem(c,'Half time') then app.transforms.scale_time(app,.5) end
    if I.MenuItem(c,'Double time') then app.transforms.scale_time(app,2) end
    if I.MenuItem(c,'Duplicate') then app.clipboard.duplicate(app) end
    I.EndDisabled(c); I.EndPopup(c)
  end
end

function M.draw(app,x,y,width,height)
  local I,c,T=app.ImGui,app.ctx,app.theme; local def=target(app)
  local scope,first,last=automatic_scope(app); local signature=def.id..':'..(app.settings.channel or 0)..':'..scope..':'..string.format('%.6f:%.6f',first,last)
  if app.lane_tool_preview and app.lane_tool_preview.signature~=signature then M.cancel(app,false) end
  I.PushStyleColor(c,I.Col_Button,T.panel2)
  local labels={{'Quantize','quantize','Quantize with options','##lane_quantize'},{'Legato','legato','Legato with options','##lane_legato'},{'Humanize','humanize','Humanize timing and velocity','##lane_humanize'},{'Strum / Flam','strum','Strum / Flam live preview','##lane_strum_flam'},{'Arp','arp','Arpeggiator','##lane_arp'},{'Velocity','velocity','Set, ramp, compress or expand velocity','##lane_velocity'},{'Pitch','pitch','Semitone, octave and scale pitch tools','##lane_pitch'}}
  local select_label='Select All'; local total=(I.CalcTextSize and select(1,I.CalcTextSize(c,select_label)) or #select_label*7)+18+6
  for _,entry in ipairs(labels) do total=total+(I.CalcTextSize and select(1,I.CalcTextSize(c,entry[1])) or #entry[1]*7)+18 end
  total=total+(I.CalcTextSize and select(1,I.CalcTextSize(c,'Shape')) or 35)+18+(I.CalcTextSize and select(1,I.CalcTextSize(c,'More')) or 28)+18+#labels*6+6
  I.SetCursorScreenPos(c,x+math.max(0,(width-total)*.5),y)
  if I.SmallButton(c,select_label..'##lane_select_all') then if app.controller_selection_active and app.controller_lane then app.clipboard.select_all_cc(app,app.controller_lane,true) else for _,n in ipairs(app.cache:get(false)) do Selection.add(app.selection,n.id) end end end
  if I.IsItemHovered(c) then I.SetTooltip(c,app.controller_selection_active and 'Select all points in the active controller lane.' or 'Select all notes in ReaRoll\nThis does not replace REAPER\'s native MIDI-editor selection.') end
  for _,entry in ipairs(labels) do I.SameLine(c); tool_button(app,entry[1],entry[2],entry[3],entry[4]) end
  I.SameLine(c)
  if I.SmallButton(c,'Shape##lane_shape') then if app.transform_preview then app.transforms.cancel_preview(app) end; I.OpenPopup(c,'##lane_shape_popup') end
  if I.IsItemHovered(c) then I.SetTooltip(c,def.protected and ('Shape is unavailable for protected '..def.label..' messages.') or ('Shape '..def.label..': Curve, LFO and repeating Step')) end
  I.SameLine(c); tool_button(app,'More','more','More phrase actions','##lane_more')
  I.PopStyleColor(c)
  I.SetNextWindowSize(c,430,330,I.Cond_FirstUseEver)
  local shape_open=I.BeginPopup(c,'##lane_shape_popup')
  if shape_open then shape_popup(app,def); I.EndPopup(c) elseif app.lane_tool_preview then M.cancel(app) end
  note_tool_popups(app)
  if app.lane_phrase_preview and I.IsPopupOpen and not I.IsPopupOpen(c,'##lane_strum_flam') then app.transforms.cancel_preview(app); app.lane_phrase_preview=nil end
  if app.transform_preview and I.IsPopupOpen then
    local popup_for={quantize='##lane_quantize',legato='##lane_legato',humanize='##lane_humanize',arp='##lane_arp',velocity='##lane_velocity',strum='##lane_strum_flam',flam='##lane_strum_flam'}
    local popup=popup_for[app.transform_preview.kind]
    if popup and not I.IsPopupOpen(c,popup) then app.transforms.cancel_preview(app); app.lane_phrase_preview=nil end
  end
end

return M
