-- @noindex
local Razor=require 'src.razor'
local Controller=require 'src.controller_razor'
local Areas=require 'src.controller_areas'
local M={}
local function expression_conflict(note,settings,controllers,with_pedal)
  local expression=require('src.slide_links').expression_settings(note,settings)
  if not expression then return false end
  for _,region in ipairs(controllers)do
    local lane=region.lane
    local owned=lane.pitch or not expression.expression_pitch_only and(lane.status==0xD0 or lane.cc==74)
    local master=settings.mpe_zone=='upper'and 15 or 0
    local pedal=not expression.expression_pitch_only and(lane.cc==64 or lane.cc==120 or lane.cc==121)and(region.channel==master or region.channel==note.chan)
    if owned and region.channel==note.chan or pedal and not with_pedal then return true end
  end
  return false
end
M.expression_conflict=expression_conflict
function M.note_areas(app)
  local out={};for _,area in ipairs(app.razor_areas or {})do if area.end_qn>area.start_qn then out[#out+1]=area end end
  if app.razor_area and app.razor_area.end_qn>app.razor_area.start_qn then out[#out+1]=app.razor_area end
  return out
end
function M.from_controller(app,controller,operation,delta,scale)
  local notes=M.note_areas(app)
  if #notes==0 then return false,'Select a note area to edit the mixed group.'end
  delta=delta or 0;scale=operation=='stretch'and scale or 1
  if not scale or scale<=0 or scale~=scale then return false,'The stretch must have a positive duration.'end
  local first=Razor.bounds(notes)
  -- Convert a controller-edge stretch into the same affine transform for
  -- the note group's anchor, rather than stretching each lane in place.
  local note_delta=delta+(first-controller.start_qn)*(scale-1)
  local ok,notice=M.apply(app,notes,controller,operation,note_delta,0,scale)
  if ok and operation~='delete'then
    app.razor_areas={};app.razor_area=nil
    for index,area in ipairs(notes)do
      local a={start_qn=controller.start_qn+(area.start_qn-controller.start_qn)*scale+delta,end_qn=controller.start_qn+(area.end_qn-controller.start_qn)*scale+delta,low=area.low,high=area.high,channel=area.channel}
      if index==#notes then app.razor_area=a else app.razor_areas[#app.razor_areas+1]=a end
    end
  end
  return ok,notice
end
function M.copy(app,areas)
  if app.multi_controller_parent then local ok,notice=require('src.multi_controller_razor').copy(app.multi_controller_parent,areas);app.razor_clipboard=app.multi_controller_parent.razor_clipboard;return ok,notice end
  if not app.take or reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'Select an available MIDI item before copying.'end
  if app.multi_edit_mode then return false,'Mixed clipboard currently supports ordinary MIDI in the active item.'end
  local controllers={}
  for _,area in ipairs(Areas.union(Areas.list(app)))do
    local controller,notice=Controller.capture(app,area)
    if not controller then return false,notice end
    controllers[#controllers+1]=controller
  end
  if #controllers==0 then return false,'Select a controller area first.'end
  -- Build detached note fragments first; do not replace a previous clipboard
  -- unless both note and controller captures succeed.
  local previous=app.razor_clipboard
  local sustained,reason=require('src.sustain_group').prepare(app,areas,Areas.union(Areas.list(app)),'capture',0,1)
  if sustained==false then return false,reason end
  local ok=Razor.copy(app,areas,{mixed=true,sustain=sustained~=nil})
  if not ok then return false,'Select a note area containing notes to copy.'end
  for _,n in ipairs(app.razor_clipboard.phrase.notes)do if expression_conflict(n.source,app.settings,Areas.list(app),sustained~=nil)then
    app.razor_clipboard=previous;return false,'Deselect the note expression and pedal controller areas before copying this mixed group.'
  end end
  app.razor_clipboard.controllers=controllers
  app.razor_clipboard.controller=controllers[#controllers]
  app.razor_clipboard.anchor=Razor.bounds(areas)
  if sustained then app.razor_clipboard.sustain_context=true;app.razor_clipboard.sustain_zone=app.settings.mpe_zone;app.razor_clipboard.sustain_members=app.settings.mpe_members end
  return true
end
function M.paste(app,clip,q,options)
  if app.multi_controller_parent then local ok,notice=require('src.multi_controller_razor').paste(app.multi_controller_parent,clip,q);app.razor_clipboard=app.multi_controller_parent.razor_clipboard;return ok,notice end
  if not app.take or app.edit.active or app.gesture or app.transform_preview or app.lane_tool_preview then return false,'Finish the active edit and select a MIDI item first.'end
  if app.multi_edit_mode then return false,'Mixed clipboard currently supports ordinary MIDI in the active item.'end
  if clip.sustain_context and(not app.settings.mpe_enabled or app.settings.mpe_zone~=clip.sustain_zone or app.settings.mpe_members~=clip.sustain_members)then return false,'Match the copied MPE zone and member count before pasting its shared pedal context.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The MIDI item is no longer available.'end
  if type(q)~='number' or q~=q or q==math.huge or q==-math.huge then return false,'Choose a valid paste time.'end
  local item=reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(app.take)
  if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'Unlock the destination item before pasting.'end
  if q<app.item_start_qn or q+clip.phrase.span>app.item_end_qn+1e-8 then return false,'The note area does not fit at the edit cursor.'end
  local plans={}
  for _,n in ipairs(clip.phrase.notes)do
    local s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+n.offset)+.5)
    local e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+n.offset+n.length)+.5)
    if e<=s then return false,'A pasted note would be shorter than one MIDI tick.'end
    plans[#plans+1]={source=n.source,s=s,e=e,expression=n.expression,offset=n.offset,sounding_end=n.sounding_length and math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+n.offset+n.sounding_length)+.5)}
  end
  if clip.mpe then
    local stream=require('src.note_events').read(app.take)
    if not stream then return false,'The destination MIDI is unavailable.'end
    local lifetime=require('src.voice_lifetime').index(stream,app.settings)
    for _,plan in ipairs(plans)do
      if #(plan.expression or {})>0 or app.settings.mpe_enabled and require('src.expression').member(plan.source.chan,app.settings)then
        for _,other in ipairs(stream.notes)do
          if other.chan==plan.source.chan and other.s<=(plan.sounding_end or plan.e)and lifetime(other)>plan.s then
            return false,'Paste would share an expression channel with another sounding note. Choose an empty time range.'
          end
        end
      end
    end
    if clip.sustain_context then
      local master=app.settings.mpe_zone=='upper'and 15 or 0;local delta=q-clip.anchor
      for _,controller in ipairs(clip.controllers or {clip.controller})do if controller.area.lane.cc==64 then
        local first=reaper.MIDI_GetPPQPosFromProjQN(app.take,controller.area.start_qn+delta);local last=reaper.MIDI_GetPPQPosFromProjQN(app.take,controller.area.end_qn+delta)
        for _,other in ipairs(stream.notes)do if(controller.area.channel==master or controller.area.channel==other.chan)and other.s<last and lifetime(other)>first then return false,'The pasted pedal would affect another sounding note.'end end
      end end
      for _,plan in ipairs(plans)do for _,event in ipairs(stream.events)do if require('src.expression').message(event,plan.source.chan)and event.ppq>=plan.s and event.ppq<=(plan.sounding_end or plan.e)then return false,'Recorded expression occupies the pedal-group destination.'end end end
    end
  end
  local delta=q-clip.anchor;local wanted={}
  local ok,notice=xpcall(function()
    if options and options.preview then app.edit:begin_preview(app.take)else app.edit:begin('ReaRoll: paste mixed razor',app.take)end
    for _,controller in ipairs(clip.controllers or {clip.controller})do
      local changed,reason=Controller.apply(app,controller.area,'copy',delta,1,{transaction=true,clip=controller,preserve_order=clip.sustain_context})
      if not changed then error(reason or 'The controller area cannot be pasted here.',0)end
    end
    local a=app.edit.active;a.allow_overlaps=true
    for _,p in ipairs(plans)do
      local index=a.stream:insert_fragment(p.source,p.s,p.e,p.source.pitch)
      if clip.sustain_context then local note=a.notes[index+1];note.on.order,note.off.order=p.source.on.order,p.source.off.order;note.on.original_ppq,note.off.original_ppq=p.s,p.e end
      a.touched[index]=true;a.changed=true;a.note_changed=true
      for point_index,point in ipairs(p.expression or {})do
        local ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q+p.offset+point.offset)+.5)
        local event={ppq=ppq,flags=point.flags,msg=point.msg,order=clip.sustain_context and point.order or point.offset==0 and(a.stream.notes[index+1].on.order-.5+point_index*.001)or #a.stream.events+1}
        a.stream.events[#a.stream.events+1]=event
        if point.shape then a.stream.events[#a.stream.events+1]={ppq=ppq,flags=point.shape.flags,msg=point.shape.msg,order=event.order+.1}end
      end
      wanted[#wanted+1]={s=p.s,e=p.e,pitch=p.source.pitch,vel=p.source.vel,chan=p.source.chan}
    end
    if clip.sustain_context then
      assert(a.stream:write(),'The sustained clipboard could not be written.')
      local actual=assert(require('src.note_events').read(app.take));local life=require('src.voice_lifetime').index(actual,app.settings)
      for _,p in ipairs(plans)do local found=false
        for _,n in ipairs(actual.notes)do if n.s==p.s and n.e==p.e and n.pitch==p.source.pitch and n.chan==p.source.chan then assert(life(n)==p.sounding_end,'The destination pedal context changes the pasted voice lifetime.');found=true;break end end
        assert(found,'A pasted sustained voice could not be verified.')
      end
    end
    if app.edit:finish()==false then error('The mixed paste could not be committed.',0)end
  end,function(err)return tostring(err)end)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,notice end
  app.cache:rebuild();app.cc_cache:invalidate();app:reselect_notes(wanted)
  app.razor_areas={};app.razor_area=nil
  for i,a in ipairs(clip.areas)do local region={start_qn=q+a.start_qn,end_qn=q+a.end_qn,low=a.low,high=a.high,channel=a.channel}
    if i==#clip.areas then app.razor_area=region else app.razor_areas[#app.razor_areas+1]=region end
  end
  local moved={};for _,controller in ipairs(clip.controllers or {clip.controller})do moved[#moved+1]=Areas.translate(controller.area,delta)end
  Areas.set(app,moved)
  app.mixed_razor=#clip.phrase.notes>0
  return true
end
function M.apply(app,areas,controller,operation,dq,dp,scale,settings)
  if not app.take or app.edit.active then return false,'Finish the current edit before editing mixed areas.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The source MIDI item is no longer available.'end
  if app.multi_edit_mode then return false,'Mixed areas currently edit the active item only.'end
  local item=reaper.GetMediaItemTake_Item and reaper.GetMediaItemTake_Item(app.take)
  if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'Unlock the item before editing mixed areas.'end
  areas=areas[1]and areas or {areas}
  if #areas==0 then return false,'Select a note area first.'end
  local first=Razor.bounds(areas)
  dq,dp=dq or 0,dp or 0;scale=operation=='stretch'and scale or 1
  if not scale or scale<=0 or scale~=scale then return false,'The stretch must have a positive duration.'end
  local controllers=Areas.union(Areas.list(app,controller))
  local sustained,sustain_notice=require('src.sustain_group').prepare(app,areas,controllers,operation,dq,scale)
  if sustained==false then return false,sustain_notice end
  if sustained then return require('src.sustain_group').apply(app,sustained,dp,settings and settings.preview)end
  -- Whole voices use the same expression-preserving path as note-only razor
  -- edits. A controller selection must not claim those events a second time.
  local ownership_stream=require('src.note_events').read(app.take);if not ownership_stream then return false,'The MIDI source is unavailable.'end
  for _,note in ipairs(ownership_stream.notes)do
    local a=reaper.MIDI_GetProjQNFromPPQPos(app.take,note.s)
    local b=reaper.MIDI_GetProjQNFromPPQPos(app.take,note.e)
    local spans=Razor.intervals(note,a,b,areas)
    local expression=require('src.slide_links').expression_settings(note,app.settings)
    if #spans>0 and expression then
      if #spans~=1 or spans[1].s>a+1e-9 or spans[1].e<b-1e-9 then
        return false,'Include the complete expression note to edit it with its curves.'
      end
      if expression_conflict(note,app.settings,controllers)then
        return false,'The note already carries its expression. Deselect its expression and pedal controller areas before editing the mixed group.'
      end
    end
  end
  local captures,destinations={},{}
  for index,region in ipairs(controllers)do
    local captured,reason=Controller.capture(app,region);if not captured then return false,reason end;captures[index]=captured
    if operation~='delete'then destinations[#destinations+1]=Areas.translate(region,dq+(region.start_qn-first)*(scale-1),scale)end
  end
  local options={transaction=true}
  local ok,notice=xpcall(function()
    if settings and settings.preview then app.edit:begin_preview(app.take)else app.edit:begin('ReaRoll: mixed razor '..operation,app.take)end
    local batch={}
    for index,region in ipairs(controllers)do
      local delta=dq+(region.start_qn-first)*(scale-1)
      local changed,reason=Controller.apply(app,region,operation,delta,scale,{transaction=true,clip=captures[index],batch=batch,destinations=destinations,sources=captures})
      if not changed then error(reason or 'Controller area could not be edited.',0)end
    end
    local changed,reason=Razor.apply(app,areas,operation,dq,dp,scale,options)
    if not changed then error(reason or 'The note destination is outside the item or pitch range.',0)end
    if app.edit:finish()==false then error('The mixed edit could not be committed.',0)end
  end,function(err)return tostring(err)end)
  if not ok then
    if app.edit.active then app.edit:cancel()end
    app.cache:invalidate();app.cc_cache:invalidate();return false,notice
  end
  app.cache:rebuild();app.cc_cache:invalidate()
  if options.wanted then app:reselect_notes(options.wanted)end
  if operation~='delete'then
    local moved={};for _,region in ipairs(controllers)do moved[#moved+1]=Areas.translate(region,dq+(region.start_qn-first)*(scale-1),scale)end
    Areas.set(app,moved,controller)
  end
  return true
end
return M
