-- @noindex
local Notes=require 'src.note_events'
local Model=require 'src.multi_notes'
local Multi=require 'src.multi_edit'
local Razor=require 'src.razor'
local Areas=require 'src.controller_areas'
local Controller=require 'src.controller_razor'
local Mixed=require 'src.mixed_razor'
local M={}
function M.controllers(app)
  local out={}
  for take,child in pairs(app.multi_controller_owners or {})do
    local regions=Areas.union(Areas.list(child))
    if #regions>0 then out[#out+1]={take=take,regions=regions,owner=child}end
  end
  table.sort(out,function(a,b)return tostring(a.take)<tostring(b.take)end)
  return out
end
function M.has(app)return #M.controllers(app)>0 end
function M.signature(app)
  local out={};for _,s in ipairs(Model.sources(app))do out[#out+1]=tostring(s.take)..':'..tostring(select(2,reaper.MIDI_GetHash(s.take,false,'')))..':'..s.start_qn..':'..s.end_qn..':'..tostring(s.readonly)..':'..tostring(s.rate)..':'..tostring(s.offset)end
  table.sort(out);return table.concat(out,'|')
end
local function regions_for(source,areas)
  local out={}
  for _,a in ipairs(areas)do local first,last=math.max(a.start_qn,source.start_qn),math.min(a.end_qn,source.end_qn)
    if last>first then out[#out+1]={start_qn=first,end_qn=last,low=a.low,high=a.high,channel=a.channel}end
  end
  return out
end
local function snapshot(take)
  local stream=Notes.read(take);if not stream then return nil end
  return {take=take,before_raw=stream.original_raw,before_pairs=Notes.get_pairing_state(take),expected_raw=stream.original_raw}
end
local function invalidate(app)
  app.cache:invalidate();app.cc_cache:invalidate();Model.refresh(app,true)
  for _,child in pairs(app.multi_controller_owners or {})do child.cache:invalidate();child.cc_cache:invalidate()end
end
function M.apply(app,areas,operation,delta,pitch,scale,anchor)
  if app.multi_controller_drag_signature and M.signature(app)~=app.multi_controller_drag_signature then return false,'A source changed during this drag; no group edit was applied.'end
  if app.gesture or app.edit.active or app.transform_preview or app.multi_notes.transaction or app.multi_notes.paint then return false,'Finish the current edit first.'end
  areas=areas or {};if areas.start_qn then areas={areas}end
  delta,pitch=delta or 0,pitch or 0;scale=operation=='stretch'and(scale or 1)or 1
  if scale<=0 or scale~=scale then return false,'Use a positive stretch duration.'end
  anchor=anchor or(#areas>0 and Razor.bounds(areas))
  local controllers=M.controllers(app);local by_take={};local sources={}
  for _,source in ipairs(Model.sources(app))do sources[source.take]=source end
  for _,group in ipairs(controllers)do
    local source=sources[group.take]
    if not source or source.readonly then return false,source and source.reason or 'A controller source left the editing scope.'end
    if group.owner.item_start_qn~=source.start_qn or group.owner.item_end_qn~=source.end_qn then return false,'A controller source was moved or resized. Select its areas again.'end
    by_take[group.take]=group
    anchor=anchor or group.regions[1].start_qn
  end
  if not anchor then return false,'Select an area first.'end
  local entries,plans,wanted={},{},{}
  local ok,notice=xpcall(function()
    -- Freeze all sources before touching any of them.
    for _,source in ipairs(Model.sources(app))do
      local regions=regions_for(source,areas);local controller=by_take[source.take];local hits=false
      local stream=assert(Notes.read(source.take),'A MIDI source is unavailable.')
      if not source.readonly then for _,n in ipairs(stream.notes)do
        if #Razor.intervals(n,reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(source.take,n.e),regions)>0 then hits=true;break end
      end end
      if hits or controller then
        local entry=assert(snapshot(source.take));entries[#entries+1]=entry
        local child=require('src.phrase_scope').child_app(app,source.take)
        child.mixed_razor=false;child.multi_controller_parent=nil;child.gesture=nil
        if controller then Areas.set(child,controller.regions)end
        plans[#plans+1]={child=child,source=source,entry=entry,notes=hits and regions or {},controllers=controller}
      end
    end
    assert(#plans>0,'No editable content intersects these areas.')
    for _,plan in ipairs(plans)do
      local child=plan.child;local changed,reason
      if #plan.notes>0 then
        local first=Razor.bounds(plan.notes);local shift=delta+(first-anchor)*(scale-1)
        if plan.controllers then changed,reason=Mixed.apply(child,plan.notes,child.controller_razor,operation,shift,pitch,scale,{preview=true})
        else
          child.edit:begin_preview(child.take);local options={transaction=true}
          changed,reason=Razor.apply(child,plan.notes,operation,shift,pitch,scale,options)
          if changed then changed=child.edit:finish()~=false;if options.wanted then child:reselect_notes(options.wanted)end end
        end
      else
        local active=child.controller_razor
        changed,reason=Controller.group(child,active,operation,delta+(active.start_qn-anchor)*(scale-1),scale,{preview=true})
      end
      assert(changed,reason or 'An area could not be edited.')
      local entry=plan.entry
      entry.after_raw=select(2,reaper.MIDI_GetAllEvts(child.take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(child.take)
      if #plan.notes>0 then for _,n in ipairs(require('src.selection').list(child.selection,child.cache:get(false)))do
        wanted[#wanted+1]={take=child.take,s=reaper.MIDI_GetProjQNFromPPQPos(child.take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}
      end end
    end
    local changed,message=Multi.commit(entries,'ReaRoll: '..operation..' note/controller areas across MIDI items');assert(changed,message)
  end,function(err)return tostring(err)end)
  if not ok then
    for _,plan in ipairs(plans)do if plan.child.edit.active then plan.child.edit:cancel()end end
    Multi.restore(entries);invalidate(app);return false,notice
  end
  if operation~='delete'then for _,group in ipairs(controllers)do
    local moved={};for _,region in ipairs(group.regions)do moved[#moved+1]=Areas.translate(region,delta+(region.start_qn-anchor)*(scale-1),scale)end
    Areas.set(group.owner,moved,group.owner.controller_razor)
  end end
  invalidate(app);if #areas>0 then Model.select_wanted(app,wanted)end
  return true
end
function M.from_controller(app,area,operation,delta,scale)
  if operation=='values'then return false,'Edit controller values in the active-item workspace.'end
  local areas=app.mixed_razor and Mixed.note_areas(app)or {}
  local ok,notice=M.apply(app,areas,operation,delta,0,scale,area.start_qn)
  if ok and operation~='delete'and #areas>0 then
    app.razor_areas={};app.razor_area=nil
    for index,a in ipairs(areas)do local region={start_qn=area.start_qn+(a.start_qn-area.start_qn)*(scale or 1)+(delta or 0),end_qn=area.start_qn+(a.end_qn-area.start_qn)*(scale or 1)+(delta or 0),low=a.low,high=a.high,channel=a.channel}
      if index==#areas then app.razor_area=region else app.razor_areas[#app.razor_areas+1]=region end
    end
  end
  return ok,notice
end
function M.copy(app,areas)
  local groups=M.controllers(app);if #groups==0 then return false,'Select controller areas first.'end
  local clips,sources,sustain_takes={},{},{}
  for _,source in ipairs(Model.sources(app))do sources[source.take]=source end
  for _,group in ipairs(groups)do
    local source=sources[group.take]
    if not source or source.readonly then return false,source and source.reason or 'A controller source left the editing scope.'end
    if group.owner.item_start_qn~=source.start_qn or group.owner.item_end_qn~=source.end_qn then return false,'A controller source was moved or resized. Select its areas again.'end
    if areas and #areas>0 then
      local child=require('src.phrase_scope').child_app(app,group.take)
      local plan,notice=require('src.sustain_group').prepare(child,regions_for(source,areas),group.regions,'capture',0,1)
      if plan==false then return false,notice end
      if plan then sustain_takes[group.take]=true end
    end
    for _,region in ipairs(group.regions)do
      local clip,reason=Controller.capture(group.owner,region);if not clip then return false,reason end
      for _,old in ipairs(clips)do if Areas.key(old.area)==Areas.key(clip.area)and old.area.start_qn<clip.area.end_qn and old.area.end_qn>clip.area.start_qn then return false,'Overlapping source controllers share a channel and parameter. Copy one source at a time.'end end
      clips[#clips+1]=clip
    end
  end
  local previous=app.razor_clipboard;local first,last=math.huge,-math.huge
  for _,clip in ipairs(clips)do first=math.min(first,clip.area.start_qn);last=math.max(last,clip.area.end_qn)end
  if areas and #areas>0 then
    local ok,notice=require('src.multi_razor').copy(app,areas,{sustain_by_take=sustain_takes});if not ok then return false,notice end
    for _,n in ipairs(app.razor_clipboard.phrase.notes)do for _,group in ipairs(groups)do
      if n.take==group.take and Mixed.expression_conflict(n.source,app.settings,group.regions,sustain_takes[group.take])then app.razor_clipboard=previous;return false,'Deselect the note expression controller areas before copying this mixed group.'end
    end end
  else app.razor_clipboard={phrase={span=last-first,notes={}},areas={},anchor=first,multi=true}end
  app.razor_clipboard.controllers=clips;app.razor_clipboard.controller=clips[#clips]
  if next(sustain_takes)then
    app.razor_clipboard.sustain_context=true;app.razor_clipboard.sustain_zone=app.settings.mpe_zone;app.razor_clipboard.sustain_members=app.settings.mpe_members
    -- Non-sustained companion sources still need an explicit expected lifetime.
    for _,n in ipairs(app.razor_clipboard.phrase.notes)do n.sounding_length=n.sounding_length or n.length end
  end
  return true
end
function M.paste(app,clip,q)
  if app.gesture or app.edit.active or app.transform_preview or app.multi_notes.transaction or app.multi_notes.paint then return false,'Finish the current edit first.'end
  local take=app.multi_creation_take or app.take;local source
  for _,s in ipairs(Model.sources(app))do if s.take==take then source=s;break end end
  if not source or source.readonly then return false,'Choose an editable drawing target for Paste.'end
  local entry=snapshot(take);if not entry then return false,'The drawing target is unavailable.'end
  local child=require('src.phrase_scope').child_app(app,take);child.multi_controller_parent=nil;child.gesture=nil
  local ok,notice=Mixed.paste(child,clip,q,{preview=true})
  if not ok then return false,notice end
  entry.after_raw=select(2,reaper.MIDI_GetAllEvts(take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(take)
  ok,notice=Multi.commit({entry},'ReaRoll: paste mixed areas into MIDI item')
  if not ok then Multi.restore({entry});invalidate(app);return false,notice end
  app.multi_controller_owners=app.multi_controller_owners or {}
  -- Paste selects its destination group, just as the single-item editor does.
  -- Leaving source areas selected would make the next Delete edit the sources.
  for _,previous in pairs(app.multi_controller_owners)do previous.controller_razor=nil;previous.controller_razor_areas={};previous.controller_razor_drag=nil end
  local owner=app.multi_controller_owners[take]or require('src.phrase_scope').child_app(app,take)
  owner.multi_controller_parent=app;app.multi_controller_owners[take]=owner
  Areas.set(owner,Areas.list(child));app.razor_area=child.razor_area;app.razor_areas=child.razor_areas;app.mixed_razor=#clip.phrase.notes>0
  app.multi_controller_take=take;app.multi_controller_focus=take
  local wanted={};for _,n in ipairs(require('src.selection').list(child.selection,child.cache:get(false)))do wanted[#wanted+1]={take=take,s=reaper.MIDI_GetProjQNFromPPQPos(take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end
  invalidate(app);if #clip.phrase.notes>0 then Model.select_wanted(app,wanted)end
  return true
end
return M
