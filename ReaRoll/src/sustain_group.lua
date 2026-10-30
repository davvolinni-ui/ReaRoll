-- @noindex
-- Shared pedals move only as explicitly selected controller areas together
-- with every affected voice. No individual-note gesture reallocates a pedal.
local Notes=require 'src.note_events'
local Razor=require 'src.razor'
local E=require 'src.expression'
local Controller=require 'src.controller_razor'
local Areas=require 'src.controller_areas'
local M={}
local function qn(app,p)return reaper.MIDI_GetProjQNFromPPQPos(app.take,p)end
local function covers(note,first,last,areas)
  local spans=Razor.intervals(note,first,last,areas)
  return #spans==1 and spans[1].s<=first+1e-9 and spans[1].e>=last-1e-9
end
function M.prepare(app,areas,controllers,operation,delta,scale)
  if not app.settings.mpe_enabled then return nil end
  local stream=Notes.read(app.take);if not stream then return false,'The MIDI source is unavailable.'end
  local life=require('src.voice_lifetime').index(stream,app.settings)
  local selected,has_tail={},false
  for _,note in ipairs(stream.notes)do
    local first,last=qn(app,note.s),qn(app,note.e)
    if #Razor.intervals(note,first,last,areas)>0 then
      selected[note.index]=true
      if E.member(note.chan,app.settings)and life(note)>note.e then has_tail=true end
    end
  end
  if not has_tail then return nil end
  local anchor=Razor.bounds(areas);local master=app.settings.mpe_zone=='upper'and 15 or 0
  local pedals={};local captures={}
  for index,region in ipairs(controllers)do
    local clip,notice=Controller.capture(app,region);if not clip then return false,notice end;captures[index]=clip
    if region.lane.cc==64 then
      if clip.points[1].value>=64 or clip.points[#clip.points].value>=64 then return false,'Include a complete pedal cycle, with the pedal released at both area edges.'end
      pedals[#pedals+1]=region
    end
  end
  if #pedals==0 then return false,'Include the complete sustain controller area and all affected notes in this mixed group.'end
  local function transformed(q)return anchor+(q-anchor)*scale+delta end
  local plans={}
  for _,note in ipairs(stream.notes)do
    local ending=life(note);local first,last=qn(app,note.s),qn(app,note.e)
    if selected[note.index]then
      if ending==math.huge then return false,'A held voice has no recorded pedal release. Include its release before editing this group.'end
      if not covers(note,first,qn(app,ending),areas)then return false,'Include each complete note and its sustained tail in the note areas.'end
      if ending>note.e then
        local controlled=false
        for _,region in ipairs(pedals)do if(region.channel==master or region.channel==note.chan)and region.start_qn<=first and region.end_qn>=qn(app,ending)then controlled=true end end
        if not controlled then return false,'Include the full pedal cycle controlling each sustained voice.'end
      end
      local destination={s=transformed(first),e=transformed(last),ending=transformed(qn(app,ending)),pitch=note.pitch,index=note.index,chan=note.chan}
      if operation~='delete'and(destination.s<app.item_start_qn-1e-8 or destination.ending>app.item_end_qn+1e-8)then return false,'The complete sustained voice does not fit in the destination item.'end
      plans[#plans+1]=destination
    end
    for _,region in ipairs(pedals)do if region.channel==master or region.channel==note.chan then
      if first<region.end_qn and qn(app,ending)>region.start_qn and not selected[note.index]then return false,'The pedal area also controls an unselected voice. Include every affected note.'end
      if operation~='delete'and(operation=='copy'or not selected[note.index])and first<transformed(region.end_qn)and qn(app,ending)>transformed(region.start_qn)then return false,'The destination pedal would affect another sounding note.'end
    end end
  end
  for _,plan in ipairs(plans)do if operation~='delete'then for _,note in ipairs(stream.notes)do
    if(operation=='copy'or not selected[note.index])and note.chan==plan.chan and qn(app,note.s)<plan.ending and qn(app,life(note))>plan.s then return false,'A destination member channel is occupied.'end
  end end end
  local source_events={}
  for _,p in ipairs(plans)do
    local owned,notice=E.capture(stream,stream.notes[p.index+1],app.settings);if not owned then return false,notice end
    for _,entry in ipairs(owned)do if not entry.synthetic then source_events[entry.event]=true;if entry.shape then source_events[entry.shape]=true end end end
  end
  if operation~='delete'then for _,p in ipairs(plans)do for _,event in ipairs(stream.events)do
    if E.message(event,p.chan)and qn(app,event.ppq)>=p.s and qn(app,event.ppq)<=p.ending and(operation=='copy'or not source_events[event])then return false,'Recorded expression already occupies the destination member channel.'end
  end end end
  return {raw=stream.original_raw,plans=plans,selected=selected,captures=captures,controllers=controllers,operation=operation,anchor=anchor,delta=delta,scale=scale}
end
function M.apply(app,plan,pitch_delta,preview)
  if pitch_delta~=0 then for _,p in ipairs(plan.plans)do if p.pitch+pitch_delta<0 or p.pitch+pitch_delta>127 then return false,'The chord would exceed the MIDI pitch range.'end end end
  local ok,notice=xpcall(function()
    assert(select(2,reaper.MIDI_GetAllEvts(app.take,''))==plan.raw,'The MIDI changed before this group could be edited.')
    if preview then app.edit:begin_preview(app.take)else app.edit:begin('ReaRoll: '..plan.operation..' sustained note/controller group',app.take)end
    local active=app.edit.active;active.allow_overlaps=true;active.preserve_source_bounds=true
    local owned={};local wanted={};local expected={};local copied={};local deletes={}
    for _,p in ipairs(plan.plans)do local n=active.notes[p.index+1]
      local events,message=E.capture(active.stream,n,app.settings);assert(events,message);owned[p.index]=events
      for _,entry in ipairs(events)do entry.old_ppq=entry.event.ppq end
    end
    local function mapped(ppq)
      local q=plan.anchor+(qn(app,ppq)-plan.anchor)*plan.scale+plan.delta
      return math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q)+.5)
    end
    local destinations={}
    for _,region in ipairs(plan.controllers)do if plan.operation~='delete'then destinations[#destinations+1]=Areas.translate(region,plan.delta+(region.start_qn-plan.anchor)*(plan.scale-1),plan.scale)end end
    local batch={}
    for i,region in ipairs(plan.controllers)do
      assert(not(region.lane.pitch or region.lane.status==0xD0 or region.lane.cc==74),'Deselect expression controller areas; each voice carries its own expression.')
      local changed,message=Controller.apply(app,region,plan.operation,plan.delta+(region.start_qn-plan.anchor)*(plan.scale-1),plan.scale,{transaction=true,clip=plan.captures[i],batch=batch,destinations=destinations,preserve_order=true});assert(changed,message)
    end
    for _,p in ipairs(plan.plans)do
      local n=active.notes[p.index+1];local index=n.index
      local s,e=mapped(n.s),mapped(n.e)
      if plan.operation=='copy'then index=active.stream:insert_fragment(n,s,e,n.pitch+pitch_delta)
      elseif plan.operation=='delete'then deletes[#deletes+1]=index
      else active.stream:set(index,{s=s,e=e,pitch=n.pitch+pitch_delta})end
      if plan.operation~='delete'then local moved=active.notes[index+1]
        moved.on.order,moved.off.order=n.on.order,n.off.order
        moved.on.original_ppq,moved.off.original_ppq=moved.on.ppq,moved.off.ppq
      end
      for _,entry in ipairs(owned[p.index])do
        local event=entry.event
        if plan.operation=='delete'then if not entry.shared and not entry.synthetic then event.deleted=true;if entry.shape then entry.shape.deleted=true end end
        else
          local destination=mapped(entry.old_ppq);local key=tostring(entry.event)
          if not copied[key]then
            copied[key]=true
            if plan.operation=='copy'or entry.shared or entry.synthetic then
              local clone={};for k,v in pairs(event)do clone[k]=v end;event=clone;event.order=event.order or #active.stream.events+1;active.stream.events[#active.stream.events+1]=event
            end
            event.ppq=destination
            if entry.shape then local shape=entry.shape
              if plan.operation=='copy'or entry.shared then local clone={};for k,v in pairs(shape)do clone[k]=v end;shape=clone;shape.order=event.order+.1;active.stream.events[#active.stream.events+1]=shape end
              shape.ppq=destination
            end
          end
        end
      end
      if plan.operation~='delete'then
        active.touched[index]=true;wanted[#wanted+1]={s=s,e=e,pitch=p.pitch+pitch_delta,chan=p.chan,vel=n.vel}
        expected[#expected+1]={s=s,e=e,pitch=p.pitch+pitch_delta,chan=p.chan,ending=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,p.ending)+.5)}
      end
    end
    table.sort(deletes,function(a,b)return a>b end);for _,index in ipairs(deletes)do active.stream:delete(index)end
    active.changed,active.note_changed,active.stream.dirty=true,true,true
    -- Validate actual serialized same-tick ordering, not an in-memory plan.
    assert(active.stream:write(),'The sustained group could not be written.')
    local actual=assert(Notes.read(app.take));local life=require('src.voice_lifetime').index(actual,app.settings)
    for _,p in ipairs(expected)do local found=false
      for _,n in ipairs(actual.notes)do if n.s==p.s and n.e==p.e and n.pitch==p.pitch and n.chan==p.chan then
        assert(life(n)==p.ending,'The destination pedal context changes this voice lifetime; the group was cancelled.');found=true;break
      end end
      assert(found,'A destination voice could not be verified.')
    end
    assert(app.edit:finish()~=false,'The sustained group could not be committed.')
    app.cache:rebuild();app.cc_cache:invalidate();app:reselect_notes(wanted)
    if plan.operation~='delete'then Areas.set(app,destinations,app.controller_razor)end
  end,function(err)return tostring(err)end)
  if not ok then if app.edit.active then app.edit:cancel()end;app.cache:invalidate();app.cc_cache:invalidate();return false,notice end
  return true
end
return M
