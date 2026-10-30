-- @noindex
local Selection=require 'src.selection'
local M={}
function M.draw(app)
  local I,c=app.ImGui,app.ctx
  local z=app.settings.ui_scale or 1
  local context=app.multi_controller_point_focus and app.controller_point_context
  I.Text(c,'Properties');I.Separator(c)
  local source=context and context.name or app.multi_edit_mode and tostring(#((app.multi_notes or {}).sources or {}))..' MIDI items'or app.take_name or ''
  local shown=source;local available=I.GetContentRegionAvail(c)
  if I.CalcTextSize(c,shown)>available then
    while #shown>0 and I.CalcTextSize(c,shown..'...')>available do local at=utf8.offset(shown,-1);shown=shown:sub(1,(at or #shown)-1)end
    shown=shown..'...'
  end
  I.TextDisabled(c,shown)
  if I.IsItemHovered(c)then I.SetTooltip(c,source)end
  if context then
    local Points=require 'src.controller_points';local points=Points.points(context.take,context.lane,context.ch)
    local selected=Points.selection(app,context.key,context.take);local count=0;local low,high=math.huge,-math.huge
    for _,point in ipairs(points)do if selected[point.index]then count=count+1;low=math.min(low,point.value);high=math.max(high,point.value)end end
    I.TextWrapped(c,context.lane.label..' / Ch '..(context.ch+1));I.Text(c,count..' selected point'..(count==1 and ''or 's'))
    if count>0 then
      local indices={};for _,point in ipairs(points)do if selected[point.index]then indices[#indices+1]=point.index..':'..point.value end end
      local signature=context.key..':'..table.concat(indices,',')
      local draft=app.inspector_controller_properties
      if not draft or draft.signature~=signature then draft={signature=signature,value=low,dirty={}};app.inspector_controller_properties=draft end
      local locked=app.gesture~=nil or app.controller_point_gesture~=nil or app.edit.active~=nil
      I.BeginDisabled(c,locked)
      require('src.ui.property_fields').number(app,draft,'value','Value',true,low~=high,'Set the value of the selected controller points.',0,context.lane.pitch and 16383 or 127)
      I.BeginDisabled(c,not draft.dirty.value or next(draft.invalid or {})~=nil)
      if I.Button(c,'Apply values',-1,0)then
        local ok,notice=Points.begin(app,context.take,context.lane,context.ch,'set_value',selected)
        if ok then ok,notice=Points.preview(app,0,draft.value);if ok then ok,notice=Points.finish(app)end end
        app.multi_controller_point_notice=notice
        if ok then app.inspector_controller_properties=nil end
      end
      I.EndDisabled(c);I.EndDisabled(c)
    else
      I.TextWrapped(c,'Select points in the controller lane.')
    end
    if app.multi_controller_point_notice then I.TextWrapped(c,app.multi_controller_point_notice)end
    return
  end
  if app.settings.scale_view_only and (app.scale_hidden_count or 0)>0 then I.TextWrapped(c,tostring(app.scale_hidden_count)..' out-of-scale notes are hidden. They remain in the MIDI item; selection tools can still include them.')end
  if app.settings.mode=='razor' and app.razor_focus=='controller' and app.controller_razor then
    local area=app.controller_razor
    I.Separator(c);I.Text(c,'Controller area: '..area.lane.short)
    if app.razor_area then
      local changed;changed,app.mixed_razor=I.Checkbox(c,'Include note and controller areas',app.mixed_razor==true)
    end
    app.controller_area_gain=app.controller_area_gain or 1;app.controller_area_pivot=app.controller_area_pivot or 0;app.controller_area_tilt=app.controller_area_tilt or 0
    local hit
    hit,app.controller_area_gain=I.SliderDouble(c,'Value scale',app.controller_area_gain,-2,2,'%.2fx')
    hit,app.controller_area_pivot=I.SliderDouble(c,'Pivot',app.controller_area_pivot,0,1,'%.2f')
    hit,app.controller_area_tilt=I.SliderDouble(c,'Tilt',app.controller_area_tilt,-1,1,'%.2f')
    I.BeginDisabled(c,app.controller_razor_drag~=nil)
    if I.Button(c,'Apply value scale / tilt') then
      local _,notice=require('src.controller_razor').apply(app,area,'values',0,1,{gain=app.controller_area_gain,pivot=app.controller_area_pivot,tilt=app.controller_area_tilt})
      app.controller_razor_notice=notice
    end
    if app.mixed_razor and app.razor_area then I.TextWrapped(c,'Mixed group enabled: Delete includes note areas and all controller areas. Value scale / tilt edits this controller only.')end
    if I.Button(c,app.mixed_razor and app.razor_area and 'Delete mixed contents' or 'Delete controller contents')then local _,notice=require('src.controller_razor').apply(app,area,'delete');app.controller_razor_notice=notice end
    I.EndDisabled(c)
    if app.controller_razor_notice then I.TextWrapped(c,app.controller_razor_notice)end
  end
  if app.settings.mode=='razor' and app.razor_focus~='controller' and app.razor_area then
    local area=app.razor_area
    I.Separator(c); I.Text(c,'Razor area')
    I.Text(c,string.format('Length: %.3g beats',area.end_qn-area.start_qn))
    I.Text(c,'Pitch: '..area.low..' - '..area.high)
    I.Text(c,area.channel==nil and 'Channels: all' or ('Channel: '..tostring(area.channel+1)))
    I.TextWrapped(c,'Crossing notes split at the area edges. Moves merge with destination notes.')
    if app.controller_razor then
      local hit;hit,app.mixed_razor=I.Checkbox(c,'Include controller areas',app.mixed_razor==true)
      I.Text(c,tostring(#require('src.controller_areas').list(app))..' controller areas')
      if app.mixed_razor then I.TextWrapped(c,'Moves, Copy/Cut/Paste, Duplicate, Delete and stretch include the controller area. Each edit uses one Undo.')end
    end
    I.BeginDisabled(c,app.razor_drag~=nil or app.gesture~=nil)
    local group={table.unpack(app.razor_areas or {})};group[#group+1]=area
    if #group>1 then I.Text(c,#group..' areas / overlaps processed once')end
    if I.Button(c,'Duplicate area') then
      local Razor=require 'src.razor';local first,last=Razor.bounds(group);local span=last-first
      if Razor.apply(app,group,'copy',span,0)then
        app.razor_areas={};for i,a in ipairs(group)do local moved={start_qn=a.start_qn+span,end_qn=a.end_qn+span,low=a.low,high=a.high,channel=a.channel}
          if i==#group then app.razor_area=moved else app.razor_areas[#app.razor_areas+1]=moved end
        end
      end
    end
    if I.Button(c,'Delete contents') then require('src.razor').apply(app,group,'delete') end
    if I.Button(c,'Clear area') then app.razor_area=nil;app.razor_areas={} end
    if app.razor_notice then I.TextWrapped(c,app.razor_notice)end
    I.EndDisabled(c)
  end
  local notes
  if app.multi_edit_mode then notes=require('src.multi_notes').chosen(app)
  else notes=Selection.list(app.selection,app.cache:get(false))end
  I.Separator(c)
  if #notes==0 then
    I.TextWrapped(c,'Select notes to inspect their properties.')
  else
    local lo,hi,vlo,vhi=127,0,127,0
    local channels={}; local channel_count=0; local muted=0
    for _,n in ipairs(notes) do
      lo,hi=math.min(lo,n.pitch),math.max(hi,n.pitch)
      vlo,vhi=math.min(vlo,n.vel),math.max(vhi,n.vel)
      if not channels[n.chan] then channels[n.chan]=true; channel_count=channel_count+1 end
      if n.muted then muted=muted+1 end
    end
    local U=require 'src.util'
    local pitches=lo==hi and U.pitch_name(lo)or U.pitch_name(lo)..' - '..U.pitch_name(hi)
    I.Text(c,tostring(#notes)..' note'..(#notes==1 and ''or 's')..' | '..pitches)
    if I.IsItemHovered(c)then I.SetTooltip(c,'MIDI pitches '..lo..' - '..hi..'; '..channel_count..' channel(s); '..muted..' muted. Only edited fields are applied.')end
    local Props=require 'src.selection_properties';local musical=Props.notes(app)
    local keys={};for _,n in ipairs(musical)do keys[#keys+1]=table.concat({n.key or n.id or n.index,n.s,n.e,n.pitch,n.vel,n.chan,tostring(n.muted)},':')end;table.sort(keys)
    local signature=table.concat(keys,'|');local draft=app.inspector_properties
    if not draft or draft.signature~=signature then
      app.inspector_properties_notice=nil
      local n=musical[1];draft={signature=signature,dirty={},start=#musical==1 and n.s or 0,length=#musical==1 and n.e-n.s or 0,pitch=#musical==1 and n.pitch or 0,velocity=n.vel,channel=n.chan+1,muted=n.muted};app.inspector_properties=draft
    end
    I.Separator(c)
    local single=#musical==1;local Fields=require 'src.ui.property_fields'
    local locked=app.gesture~=nil or app.transform_preview~=nil or app.edit.active~=nil or app.multi_notes and(app.multi_notes.transaction~=nil or app.multi_notes.paint~=nil or app.multi_notes.drag~=nil)or false
    I.BeginDisabled(c,locked)
    Fields.number(app,draft,'start',single and 'Start (beats)'or 'Move (beats)',false,false,single and 'Start position in project beats.'or 'Move every selected note by this many beats.')
    Fields.number(app,draft,'length',single and 'Length'or 'Length +/-',false,false,single and 'Note length in beats.'or 'Add or subtract this many beats from every selected note.',single and .0001 or nil)
    Fields.number(app,draft,'pitch',single and 'Pitch (MIDI)'or 'Transpose',true,false,single and 'MIDI note number.'or 'Transpose every selected note by this many semitones.',single and 0 or -127,127)
    Fields.number(app,draft,'velocity','Velocity',true,vlo~=vhi,'Set the velocity of all selected notes. An untouched Mixed field keeps the original velocities.',1,127)
    Fields.number(app,draft,'channel','Channel',true,channel_count>1,'Set the MIDI channel of all selected notes. An untouched Mixed field preserves every existing channel.',1,16)
    Fields.row(app,'Muted')
    local changed;changed,draft.muted=I.Checkbox(c,'##property_muted',draft.muted);if changed then draft.dirty.muted=true end
    I.SameLine(c);I.TextDisabled(c,muted>0 and muted<#notes and not draft.dirty.muted and 'Mixed'or draft.muted and 'On'or 'Off')
    if I.IsItemHovered(c)then I.SetTooltip(c,'Only changes mute state when edited. Mixed means some selected notes are muted.')end
    I.EndDisabled(c)
    local invalid={}
    for _,key in ipairs({'start','length','pitch','velocity','channel'})do if draft.invalid and draft.invalid[key]then invalid[#invalid+1]=key end end
    if #invalid>0 then I.TextWrapped(c,'Check: '..table.concat(invalid,', ')..'.')end
    local button_width=(I.GetContentRegionAvail(c)-6*z)*.5
    I.BeginDisabled(c,locked or next(draft.dirty)==nil or next(draft.invalid or {})~=nil)
    if I.Button(c,'Apply##properties',button_width,0)then
      local n=musical[1];local values={}
      if draft.dirty.start then values.move=single and draft.start-n.s or draft.start end
      if draft.dirty.length then values.length_delta=single and draft.length-(n.e-n.s)or draft.length end
      if draft.dirty.pitch then values.transpose=single and draft.pitch-n.pitch or draft.pitch end
      if draft.dirty.velocity then values.velocity=draft.velocity end
      if draft.dirty.channel then values.channel=draft.channel-1 end
      if draft.dirty.muted then values.muted=draft.muted end
      local ok,notice=Props.apply(app,values);app.inspector_properties_notice=notice;if ok then app.inspector_properties=nil end
    end
    I.EndDisabled(c)
    if I.IsItemHovered(c)then I.SetTooltip(c,'Apply only edited fields. Move, length changes and transpose are relative for multiple notes. Each untouched field keeps its existing values.')end
    I.SameLine(c,0,6*z)
    if I.Button(c,'Reset##properties',button_width,0)then app.inspector_properties=nil;app.inspector_properties_notice=nil end
    if app.inspector_properties_notice then I.TextWrapped(c,app.inspector_properties_notice)end
  end

end
return M
