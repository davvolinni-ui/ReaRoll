-- @noindex
-- Source-focused ordinary controller gestures; exact raw snapshots own Cancel.
local Notes=require 'src.note_events'
local U=require 'src.util'
local M={}
local function copy_indices(source)local out={};for k,v in pairs(source or {})do out[k]=v end;return out end
local function selection_key(app,g)local context=app.controller_point_context;return g.key or g.selection_key or(context and context.take==g.take and context.ch==g.ch and context.key)end
local function value(event,lane)
  return lane.pitch and ((event.msg:byte(3)<<7)|event.msg:byte(2))or lane.status and event.msg:byte(2)or event.msg:byte(3)
end
local function message(lane,ch,v)
  v=U.clamp(math.floor(v+.5),0,lane.pitch and 16383 or 127)
  return lane.pitch and string.char(224|ch,v&127,(v>>7)&127)or lane.status and string.char(lane.status|ch,v,0)or string.char(176|ch,lane.cc,v)
end
local function matches(e,lane,ch)
  if #e.msg<2 or e.msg:byte(1)&15~=ch then return false end
  return lane.pitch and e.msg:byte(1)>>4==14 or lane.status and e.msg:byte(1)&240==lane.status or lane.cc and #e.msg>=3 and e.msg:byte(1)>>4==11 and e.msg:byte(2)==lane.cc
end
local function remember(app,key,raw,selection)
  if not key then return end
  app.controller_point_selection=app.controller_point_selection or {};app.controller_point_selection[key]=copy_indices(selection)
  app.controller_point_selection_raw=app.controller_point_selection_raw or {};app.controller_point_selection_raw[key]=raw
  app.controller_point_selection_history=app.controller_point_selection_history or {}
  local history=app.controller_point_selection_history[key]or {order={},values={}};app.controller_point_selection_history[key]=history
  if not history.values[raw]then history.order[#history.order+1]=raw end
  history.values[raw]=copy_indices(selection)
  while #history.order>32 do local old=table.remove(history.order,1);history.values[old]=nil end
end
function M.selection(app,key,take)
  app.controller_point_selection=app.controller_point_selection or {};app.controller_point_selection_raw=app.controller_point_selection_raw or {}
  if not require('src.take').valid(take)then app.controller_point_selection[key]={};return app.controller_point_selection[key]end
  local ok,raw=reaper.MIDI_GetAllEvts(take,'');if not ok then app.controller_point_selection[key]={};return app.controller_point_selection[key]end
  local previous=app.controller_point_selection_raw[key]
  if previous and previous~=raw then
    local history=(app.controller_point_selection_history or {})[key]
    app.controller_point_selection[key]=copy_indices(history and history.values[raw])
  end
  app.controller_point_selection_raw[key]=raw
  app.controller_point_selection[key]=app.controller_point_selection[key]or {};return app.controller_point_selection[key]
end
function M.points(take,lane,ch)
  if not require('src.take').valid(take)then return {}end
  local stream=Notes.read(take);local out={};if not stream then return out end
  for index,e in ipairs(stream.events)do if matches(e,lane,ch)then
    local next_event=stream.events[index+1]
    out[#out+1]={index=index,ppq=e.ppq,value=value(e,lane),selected=e.flags&1~=0,flags=e.flags,shape=next_event and next_event.ppq==e.ppq and next_event.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and index+1 or nil}
  end end
  return out
end
function M.copy(take,lane,ch,indices)
  local stream=Notes.read(take);if not stream then return nil,'Could not read the source.'end
  local out={points={},lane=lane,ch=ch};local first=math.huge
  for _,p in ipairs(M.points(take,lane,ch))do if indices[p.index]then first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(take,p.ppq))end end
  if first==math.huge then return nil,'Select controller points first.'end
  for _,p in ipairs(M.points(take,lane,ch))do if indices[p.index]then
    out.points[#out.points+1]={time=reaper.MIDI_GetProjQNFromPPQPos(take,p.ppq)-first,value=p.value,flags=p.flags,shape=p.shape and {msg=stream.events[p.shape].msg,flags=stream.events[p.shape].flags}or nil}
  end end
  return out
end
local function source(app,take)
  for _,s in ipairs(require('src.multi_notes').sources(app))do if s.take==take then return s end end
end
local function valid(app,g)
  local s=source(app,g.take)
  if not s or s.readonly or s.start_qn~=g.source.start_qn or s.end_qn~=g.source.end_qn or s.rate~=g.source.rate or s.offset~=g.source.offset then return false,'The controller source changed or became read-only.'end
  local ok,raw=reaper.MIDI_GetAllEvts(g.take,'')
  if not ok or raw~=g.entry.expected_raw then return false,'The controller source changed externally; its edit was preserved.'end
  return true
end
function M.check(app)
  local context=app.controller_point_context
  if context and(not app.multi_edit_mode or not app.settings.lane_open or app.expression_editor_open or app.settings.mode=='razor'or not source(app,context.take))then
    app.multi_controller_point_focus=nil;app.controller_point_context=nil;app.controller_point_focus_key=nil
  end
  local g=app.controller_point_gesture;if not g then return true end
  local ok,notice=valid(app,g)
  if not app.multi_edit_mode or not app.settings.lane_open or app.expression_editor_open or app.settings.mode=='razor'then ok=false;notice='The controller view changed; its edit was cancelled.'end
  if not ok then if g.operation=='generate'then app.multi_shape_blocked=true end;M.cancel(app);app.multi_controller_point_notice=notice end
  return ok
end
function M.cancel(app)
  local g=app.controller_point_gesture;if not g then return end
  local restored=require('src.multi_edit').restore({g.entry})
  local key=selection_key(app,g);if key then app.controller_point_selection=app.controller_point_selection or {};app.controller_point_selection[key]=restored and copy_indices(g.before_selection)or {};if restored then remember(app,key,g.entry.before_raw,g.before_selection)end end
  app.controller_point_gesture=nil
  if app.gesture and app.gesture.kind=='controller_points'then app.gesture=nil end
  app.cc_cache:invalidate();app.cache:invalidate()
end
function M.begin(app,take,lane,ch,operation,indices,expected_raw)
  if app.gesture or app.transform_preview or app.multi_notes.transaction or app.multi_notes.paint then return false,'Finish the current edit first.'end
  local s=source(app,take);if not s or s.readonly then return false,s and s.reason or 'Choose an editable controller source.'end
  if(operation=='draw'or operation=='generate')and lane.protected then return false,'Drawing is disabled for this protected controller type.'end
  local stream=Notes.read(take);if not stream then return false,'Could not read the controller source.'end
  if expected_raw and stream.original_raw~=expected_raw then return false,'The controller source changed since the points were selected.'end
  local entry={take=take,before_raw=stream.original_raw,expected_raw=stream.original_raw,before_pairs=Notes.get_pairing_state(take)}
  local g={take=take,source=s,lane=lane,ch=ch,operation=operation,entry=entry,points=M.points(take,lane,ch),indices=indices or {},drawn={}}
  g.selection_key=selection_key(app,g);g.before_selection=copy_indices(g.selection_key and(app.controller_point_selection or {})[g.selection_key]or indices)
  app.controller_point_gesture=g;app.gesture={kind='controller_points'};return true
end
function M.preview(app,dq,dv)
  local g=app.controller_point_gesture;if not g then return false end
  local ok,notice=valid(app,g);if not ok then M.cancel(app);return false,notice end
  local stream=Notes.read(g.take,g.entry.before_raw);if not stream then M.cancel(app);return false,'Could not read the gesture snapshot.'end
  local maximum=g.lane.pitch and 16383 or 127
  local selected={}
  if g.operation~='copy'and g.operation~='paste'and g.operation~='draw'and g.operation~='generate'then for _,p in ipairs(g.points)do if g.before_selection[p.index]or g.indices[p.index]then selected[stream.events[p.index]]=true end end end
  if g.operation=='generate'then
    local o=g.generator;if not o or o.first<g.source.start_qn or o.last>g.source.end_qn or o.last<o.first or o.resolution<=0 then return false,'Choose a valid generator range and density.'end
    if (o.last-o.first)/o.resolution>4096 then return false,'The generator would create too many points.'end
    local boundary={};local original={}
    for _,p in ipairs(g.points)do original[#original+1]={q=reaper.MIDI_GetProjQNFromPPQPos(g.take,p.ppq),value=p.value,event={flags=p.flags,order=p.index}}end
    table.sort(original,function(a,b)if a.q~=b.q then return a.q<b.q end;return a.event.order<b.event.order end)
    local fallback=g.lane.pitch and 8192 or g.lane.status==0xD0 and 0 or nil
    local controller=require 'src.controller_razor'
    if o.first>g.source.start_qn+1e-9 then local v,shape=controller.sample(original,o.first,fallback);if v==nil then return false,shape end;boundary.first=v end
    if o.last<g.source.end_qn-1e-9 then local v,shape=controller.sample(original,o.last,fallback);if v==nil then return false,shape end;boundary.last=v;boundary.last_shape=shape end
    local items={};local tools=require 'src.ui.lane_tools'
    for index,q in ipairs(tools.generated_positions(o.first,math.max(o.first,o.last-.00001),o.resolution))do items[#items+1]={index=index,ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(g.take,q)+.5)}end
    local values=tools.calculated(items,o.mode,o.options,o.def)
    for _,p in ipairs(g.points)do local q=reaper.MIDI_GetProjQNFromPPQPos(g.take,p.ppq);if q>=o.first and q<=o.last then stream.events[p.index].deleted=true;if p.shape then stream.events[p.shape].deleted=true end end end
    if boundary.first then stream.events[#stream.events+1]={ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(g.take,o.first)+.5),flags=0,msg=message(g.lane,g.ch,boundary.first),order=#stream.events+1}end
    for _,p in ipairs(items)do
      local added={ppq=p.ppq,flags=(g.lane.switch or o.mode=='step')and 0 or 16,msg=message(g.lane,g.ch,values[p.index]),order=#stream.events+1}
      stream.events[#stream.events+1]=added;selected[added]=true
    end
    if boundary.last and #items>0 then
      local ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(g.take,o.last)+.5)
      local added={ppq=ppq,flags=0,msg=message(g.lane,g.ch,values[items[#items].index]),order=#stream.events+1};stream.events[#stream.events+1]=added;selected[added]=true
      stream.events[#stream.events+1]={ppq=ppq,flags=(boundary.last_shape or 0)<<4,msg=message(g.lane,g.ch,boundary.last),order=#stream.events+1}
    end
  elseif g.operation=='paste'then
    for _,p in ipairs(g.clip.points)do
      local q=g.paste_q+p.time
      if q<g.source.start_qn or q>g.source.end_qn then return false,'The pasted points would leave the target item.'end
      local ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(g.take,q)+.5)
      local order=#stream.events+1
      local added={ppq=ppq,flags=p.flags,msg=message(g.lane,g.ch,p.value),order=order};stream.events[#stream.events+1]=added;selected[added]=true
      if p.shape then stream.events[#stream.events+1]={ppq=ppq,flags=p.shape.flags,msg=p.shape.msg,order=order+.1}end
    end
  elseif g.operation=='draw'then
    for ppq,v in pairs(g.drawn)do
      local found
      for _,p in ipairs(g.points)do if p.ppq==ppq then found=p;break end end
      if found then stream.events[found.index].msg=message(g.lane,g.ch,v);selected[stream.events[found.index]]=true
      else local added={ppq=ppq,flags=0,msg=message(g.lane,g.ch,v),order=#stream.events+1};stream.events[#stream.events+1]=added;selected[added]=true end
    end
  else
    for _,p in ipairs(g.points)do if g.indices[p.index]then
      local e=stream.events[p.index];local q=reaper.MIDI_GetProjQNFromPPQPos(g.take,p.ppq)+(g.operation=='shape'and 0 or dq or 0)
      if q<g.source.start_qn or q>g.source.end_qn then return false,'The controller points would leave their source item.'end
      if g.operation=='delete'then e.deleted=true;if p.shape then stream.events[p.shape].deleted=true end
      elseif g.operation=='shape'then
        local shape=math.floor(dq or 1);if(g.lane.switch or g.lane.discrete)and shape~=0 then return false,'Switch and discrete controllers use square transitions.'end;if shape<0 or shape>5 then return false,'Choose a supported controller shape.'end
        e.flags=(e.flags&15)|(shape<<4)
        if p.shape then stream.events[p.shape].deleted=true end
        if shape==5 then
          stream.events[#stream.events+1]={ppq=e.ppq,flags=0,msg=string.char(255,15)..'CCBZ '..string.char(0)..string.pack('f',U.clamp(dv or 0,-1,1)),order=e.order+.1}
        end
      else
        local v=U.clamp(g.operation=='set_value'and(dv or p.value)or p.value+(dv or 0),0,maximum);if g.lane.switch then v=v>=64 and 127 or 0 end
        local ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(g.take,q)+.5)
        if g.operation=='copy'then
          local clone={ppq=ppq,flags=e.flags,msg=message(g.lane,g.ch,v),order=#stream.events+1};stream.events[#stream.events+1]=clone;selected[clone]=true
          if p.shape then local shape=stream.events[p.shape];stream.events[#stream.events+1]={ppq=ppq,flags=shape.flags,msg=shape.msg,order=clone.order+.1}end
        else e.ppq=ppq;e.msg=message(g.lane,g.ch,v);if p.shape then stream.events[p.shape].ppq=ppq end end
      end
    end end
  end
  stream.dirty=true
  if not stream:write()then g.entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(g.take,''));M.cancel(app);return false,'Could not write the controller preview.'end
  g.result_selection={};for event in pairs(selected)do if not event.deleted and event.written_index then g.result_selection[event.written_index]=true end end
  g.entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(g.take,''));g.entry.after_raw=g.entry.expected_raw;g.entry.after_pairs=Notes.get_pairing_state(g.take)
  local key=selection_key(app,g);if key then app.controller_point_selection=app.controller_point_selection or {};app.controller_point_selection[key]=copy_indices(g.result_selection);app.controller_point_selection_raw=app.controller_point_selection_raw or {};app.controller_point_selection_raw[key]=g.entry.expected_raw end
  app.cc_cache:invalidate();return true
end
function M.draw_point(app,q,v,spacing)
  local g=app.controller_point_gesture;if not g then return false end
  q=U.clamp(q,g.source.start_qn,g.source.end_qn);v=U.clamp(math.floor(v+.5),0,g.lane.pitch and 16383 or 127)
  if g.lane.switch then v=v>=64 and 127 or 0 end
  spacing=spacing or app.settings.grid_qn or .25
  if type(spacing)~='number'or spacing~=spacing or spacing<=0 then return false,'Choose a valid controller drawing density.'end
  local steps=g.last_draw_q and not(g.lane.switch or g.lane.discrete)and math.max(1,math.ceil(math.abs(q-g.last_draw_q)/spacing-1e-9))or 1
  if steps>4096 then return false,'The stroke spans too many controller points. Zoom in or increase the grid.'end
  for index=1,steps do
    local ratio=index/steps;local time=g.last_draw_q and(g.last_draw_q+(q-g.last_draw_q)*ratio)or q
    local current=g.last_draw_value and math.floor(g.last_draw_value+(v-g.last_draw_value)*ratio+.5)or v
    g.drawn[math.floor(reaper.MIDI_GetPPQPosFromProjQN(g.take,time)+.5)]=current
  end
  local ok,notice=M.preview(app);if ok then g.last_draw_q=q;g.last_draw_value=v end;return ok,notice
end
function M.finish(app)
  local g=app.controller_point_gesture;if not g then return false end
  local ok,notice=valid(app,g);if not ok then M.cancel(app);return false,notice end
  if not g.entry.after_raw or g.entry.after_raw==g.entry.before_raw then M.cancel(app);return true end
  ok,notice=require('src.multi_edit').commit({g.entry},'ReaRoll: controller points')
  if not ok then M.cancel(app);return false,notice end
  local key=selection_key(app,g);if key then remember(app,key,g.entry.before_raw,g.before_selection);remember(app,key,g.entry.after_raw,g.result_selection)end
  app.controller_point_gesture=nil;app.gesture=nil;app.cc_cache:invalidate();app.cache:invalidate();require('src.multi_notes').refresh(app,true)
  return true,nil,g.result_selection
end
function M.paste(app,take,lane,ch,clip,q)
  if not clip or clip.ch~=ch or clip.lane.cc~=lane.cc or clip.lane.pitch~=lane.pitch or clip.lane.status~=lane.status then return false,'Choose the copied controller parameter and channel before pasting.'end
  local ok,notice=M.begin(app,take,lane,ch,'paste');if not ok then return false,notice end
  app.controller_point_gesture.clip=clip;app.controller_point_gesture.paste_q=q
  ok,notice=M.preview(app)
  if not ok then M.cancel(app);return false,notice end
  return M.finish(app)
end
return M
