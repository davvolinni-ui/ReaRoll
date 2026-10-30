-- @noindex
local M={}
function M.insert(app,entry,use_selection,preview,replace,position)
  if app.multi_edit_mode then
    local Model=require 'src.multi_notes'
    if app.gesture or app.transform_preview or app.multi_notes.transaction then return false,'Finish the current edit first.'end
    if not use_selection then
      local take=app.multi_creation_take or app.take;local target
      for _,source in ipairs(Model.sources(app))do if source.take==take then target=source end end
      if not target or target.readonly then return false,target and target.reason or 'Choose an editable drawing target.'end
      local child=require('src.phrase_scope').child_app(app,take)
      local ok,notice=M.insert(child,entry,false,nil,replace,position);Model.refresh(app,true);return ok,notice
    end
    local ok,notice=Model.begin(app);if not ok then return false,notice end
    local group=app.multi_notes.transaction
    for _,part in ipairs(group.entries)do
      ok,notice=M.insert(part.child,entry,true,true,replace)
      part.after_raw=select(2,reaper.MIDI_GetAllEvts(part.take,''));part.expected_raw=part.after_raw;part.after_pairs=require('src.note_events').get_pairing_state(part.take)
      if not ok then Model.cancel(app);return false,notice end
      part.wanted={};for _,n in ipairs(group.items)do if n.source.take==part.take then part.wanted[#part.wanted+1]={take=part.take,s=n.s,pitch=n.pitch,chan=n.chan,vel=n.vel}end end
    end
    return Model.commit(app,'ReaRoll: articulation across MIDI items')
  end
  if type(entry)~='table' then return false,'Choose a saved articulation definition.'end
  if not app.take then return false,'Select a MIDI item first.'end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The MIDI item is no longer available.'end
  if reaper.GetMediaItemTake_Item and reaper.GetMediaItemInfo_Value then
    local item=reaper.GetMediaItemTake_Item(app.take)
    if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'The MIDI item is locked.'end
  end
  local check=require('src.instrument_map').new();check.articulations={entry}
  if not require('src.instrument_map').validate(check)then return false,'Invalid articulation definition.'end
  if app.transform_preview or app.lane_tool_preview or app.gesture or app.edit.active then return false,'Apply or cancel the current edit before inserting an articulation.'end
  local notes=app.cache:get(false);local selected=require('src.selection').list(app.selection,notes)
  local source=require('src.note_events').read(app.take)
  if not source then return false,'Could not read the MIDI item.'end
  local anchors={}
  if use_selection then
    if #selected==0 then return false,'Select target notes first.'end
    for _,n in ipairs(selected)do
      local ch=entry.channel<0 and n.chan or entry.channel
      local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)
      anchors[ch]=math.min(anchors[ch] or math.huge,q)
    end
  else
    if entry.channel<0 then return false,'Choose a fixed output channel to insert at the edit cursor.'end
    anchors[entry.channel]=position or reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())
  end
  local anchor_ticks={};for channel,q in pairs(anchors)do anchor_ticks[channel]=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q)+.5)end
  if replace then
    local ok,notice=require('src.articulation_events').remove_at(source,anchor_ticks,entry.group or 'Playing style');if not ok then return false,notice end
    notes=source.notes
  end
  local plan={}
  for channel,q in pairs(anchors)do
    local start=q-entry.lead;local ending=start+entry.length
    if start<app.item_start_qn-1e-8 or start>=app.item_end_qn or entry.kind=='note' and ending>app.item_end_qn+1e-8 then return false,'The articulation would extend outside the item. Reduce its lead or move the target notes.'end
    local s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,start)+.5)
    local e=math.max(s+1,math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,ending)+.5))
    local first=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)
    local last=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
    if s<first or s>=last or entry.kind=='note' and e>last then return false,'The articulation does not fit within the item at MIDI tick resolution.'end
    if entry.kind=='note' then for _,n in ipairs(notes)do if n.chan==channel and n.pitch==entry.number and n.s<e and n.e>s then return false,'The keyswitch overlaps an existing note on its output pitch and channel.'end end end
    if entry.kind~='note' then for _,event in ipairs(source.events)do if not event.deleted then
      local status=(entry.kind=='cc' and 0xB0 or 0xC0)|channel
      if event.ppq==s and event.msg:byte(1)==status and (entry.kind=='program' or event.msg:byte(2)==entry.number)then
        return false,'An event for this articulation parameter already exists at the target time and channel. Move or edit that event first.'
      end
      if entry.bank_msb~=nil and event.ppq==s and event.msg:byte(1)==(0xB0|channel)and (event.msg:byte(2)==0 or event.msg:byte(2)==32)then return false,'Bank select already exists at this time and channel. Move or edit it before inserting this patch.'end
    end end end
    plan[#plan+1]={channel=channel,s=s,e=e}
  end
  table.sort(plan,function(a,b)return a.channel<b.channel end)
  local ok,err=xpcall(function()
    app.edit:begin('ReaRoll: articulation '..entry.name,app.take,preview)
    if replace then local ok,notice=require('src.articulation_events').remove_at(app.edit.active.stream,anchor_ticks,entry.group or 'Playing style');assert(ok,notice)end
    for i,p in ipairs(plan)do
      if entry.kind=='note' then
        local good,index=app.edit:insert(app.take,p.s,p.e,entry.number,entry.value,p.channel,false,false);assert(good)
        app.edit.active.notes[index+1].on.order=-10000+i
      else
        local msg=entry.kind=='cc' and string.char(0xB0|p.channel,entry.number,entry.value) or string.char(0xC0|p.channel,entry.number)
        local stream=app.edit.active.stream
        if entry.bank_msb~=nil then
          stream.events[#stream.events+1]={ppq=p.s,flags=0,msg=string.char(0xB0|p.channel,0,entry.bank_msb),order=-20000+i*3}
          stream.events[#stream.events+1]={ppq=p.s,flags=0,msg=string.char(0xB0|p.channel,32,entry.bank_lsb),order=-20000+i*3+1}
        end
        stream.events[#stream.events+1]={ppq=p.s,flags=0,msg=msg,order=-10000+i}
        stream.dirty=true;app.edit.active.changed=true
      end
      if replace then
        local stream=app.edit.active.stream
        stream.events[#stream.events+1]={ppq=p.s,flags=0,msg=require('src.articulation_events').marker(entry,p,anchor_ticks[p.channel]),order=-30000+i}
        stream.dirty=true;app.edit.active.changed=true
      end
    end
    assert(app.edit:finish()~=false,app.expression_notice or 'Could not write articulation.')
  end,debug.traceback)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,err end
  app.cache:rebuild();app.cc_cache:invalidate()
  local Selection=require 'src.selection';Selection.clear(app.selection);local used={}
  for _,old in ipairs(selected)do for _,n in ipairs(app.cache.notes)do
    if not used[n] and n.s==old.s and n.e==old.e and n.pitch==old.pitch and n.chan==old.chan and n.vel==old.vel then Selection.add(app.selection,n.id);used[n]=true;break end
  end end
  return true
end
function M.remove_direction(app,channel,q,group)
  if not app.take or app.gesture or app.transform_preview or app.edit.active then return false,'Finish the current edit first.'end
  if not require('src.take').valid(app.take)then return false,'The MIDI item is no longer available.'end
  if reaper.GetMediaItemInfo_Value(require('src.take').item(app.take),'C_LOCK')~=0 then return false,'The MIDI item is locked.'end
  local ticks={[channel]=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q)+.5)}
  local source=require('src.note_events').read(app.take);if not source then return false,'Could not read MIDI.'end
  local ok,notice=require('src.articulation_events').remove_at(source,ticks,group);if not ok then return false,notice end
  app.edit:begin('ReaRoll: remove articulation change',app.take)
  ok,notice=require('src.articulation_events').remove_at(app.edit.active.stream,ticks,group)
  if not ok then app.edit:cancel();return false,notice end
  app.edit.active.changed=app.edit.active.stream.dirty
  ok=app.edit:finish();app.cache:rebuild();app.cc_cache:invalidate()
  return ok~=false,app.expression_notice
end
function M.move_direction(app,channel,from_q,to_q,group)
 if not app.take or app.gesture or app.transform_preview or app.edit.active then return false,'Finish the current edit first.'end
 local Take=require 'src.take';if not Take.valid(app.take)or reaper.GetMediaItemInfo_Value(Take.item(app.take),'C_LOCK')~=0 then return false,'Choose an unlocked MIDI item.'end
 local stream=require('src.note_events').read(app.take)
 local E=require 'src.articulation_events'
 local from=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,from_q)+.5)
 local target=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,to_q)+.5);local delta=target-from
 if delta==0 then return true end
 local selected
 for _,row in ipairs(E.read(stream))do if row.channel==channel and row.group==group then
  if row.anchor==target then return false,'There is already a change in this group at that time.'end
  if row.anchor==from then selected=row end
 end end
 if not selected then return false,'The articulation change is no longer available.'end
 local function moving_events(data)
  local row
  for _,candidate in ipairs(E.read(data))do if candidate.channel==channel and candidate.group==group and candidate.anchor==from then row=candidate;break end end
  if not row then return nil,'The articulation changed externally.'end
  local moving={[row.event]=true}
  for _,output in ipairs(row.outputs)do
   local found
   for _,e in ipairs(data.events)do if not e.deleted and e.ppq==output.ppq and e.msg==output.msg then
    if found then return nil,'The articulation output is ambiguous.'end;found=e
   end end
   if not found then return nil,'The articulation was edited externally.'end
   moving[found]=true
  end
  return moving
 end
 local moving,notice=moving_events(stream);if not moving then return false,notice end
 local first=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)
 local last=reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)
 for e in pairs(moving)do
  if e.ppq+delta<first or e.ppq+delta>last or e==selected.event and e.ppq+delta>=last then return false,'The change would extend outside the MIDI item.'end
  local status=e.msg:byte(1)
  if status&0xf0==0xb0 or status&0xf0==0xc0 then
   for _,other in ipairs(stream.events)do if not moving[other]and not other.deleted and other.ppq==e.ppq+delta and other.msg:byte(1)==status and(status&0xf0==0xc0 or other.msg:byte(2)==e.msg:byte(2))then return false,'A controller or program event already occupies the destination.'end end
  end
 end
 for _,n in ipairs(stream.notes)do if moving[n.on]then
  if not moving[n.off]then return false,'The keyswitch was edited externally.'end
  for _,other in ipairs(stream.notes)do if not moving[other.on]and n.chan==other.chan and n.pitch==other.pitch and n.s+delta<other.e and n.e+delta>other.s then return false,'The moved keyswitch would overlap another note.'end end
 end end
 app.edit:begin('ReaRoll: move articulation change',app.take)
 local data=app.edit.active.stream;local changes,message=moving_events(data)
 if not changes then app.edit:cancel();return false,message end
 for _,n in ipairs(data.notes)do if changes[n.on]then n.s=n.s+delta;n.e=n.e+delta end end
 for e in pairs(changes)do e.ppq=e.ppq+delta end
 data.dirty=true;app.edit.active.changed=true
 local ok=app.edit:finish();app.cache:rebuild();app.cc_cache:invalidate()
 return ok~=false,app.expression_notice
end
function M.assign_notes(app,entry,preview,clear)
 if app.multi_edit_mode then
  local Model=require 'src.multi_notes';local ok,notice=Model.begin(app);if not ok then return false,notice end
  local group=app.multi_notes.transaction
  for _,part in ipairs(group.entries)do
   ok,notice=M.assign_notes(part.child,entry,true,clear)
   part.after_raw=select(2,reaper.MIDI_GetAllEvts(part.take,''));part.expected_raw=part.after_raw;part.after_pairs=require('src.note_events').get_pairing_state(part.take)
   if not ok then Model.cancel(app);return false,notice end
   part.wanted={};for _,n in ipairs(group.items)do if n.source.take==part.take then part.wanted[#part.wanted+1]={take=part.take,s=n.s,pitch=n.pitch,chan=n.chan,vel=n.vel}end end
  end
  return Model.commit(app,'ReaRoll: assign note articulations')
 end
 if app.gesture or app.transform_preview or app.lane_tool_preview or app.edit.active then return false,'Finish the current edit first.'end
 local Take=require 'src.take';if not Take.valid(app.take)or reaper.GetMediaItemInfo_Value(Take.item(app.take),'C_LOCK')~=0 then return false,'Choose an unlocked MIDI item.'end
 local selected=require('src.selection').list(app.selection,app.cache:get(false));if #selected==0 then return false,'Select notes first.'end
 local map=app.instrument_map;local default
 for _,candidate in ipairs(map and map.articulations or {})do if (candidate.group or 'Playing style')==(entry.group or 'Playing style')then default=candidate;break end end
 if not default then return false,'Load an instrument map first.'end
 local check=require('src.instrument_map').new();check.articulations={entry,default}
 if not require('src.instrument_map').validate(check)then return false,'Invalid articulation map.'end
 app.edit:begin('ReaRoll: assign '..entry.name,app.take,preview)
 local stream=app.edit.active.stream
 for _,cached in ipairs(selected)do
  local note=stream.notes[cached.index+1]
  for _,other in ipairs(stream.notes)do if other~=note and other.s==note.s and other.chan==note.chan and other.pitch==note.pitch then app.edit:cancel();return false,'Identical overlapping notes cannot carry separate articulation assignments.'end end
  if clear then
    local old=require('src.note_articulations').get(note)[entry.group or 'Playing style'];if old then old.event.deleted=true;stream.dirty=true end
  else require('src.note_articulations').bind(stream,note,entry,default)end
 end
 app.edit.active.changed=true
 local ok=app.edit:finish();app.cache:rebuild();app.cc_cache:invalidate()
 return ok~=false,app.expression_notice
end
return M
