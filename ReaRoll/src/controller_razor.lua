-- @noindex
local M={}
local function matches(event,lane,channel)
  local msg=event.msg
  if event.deleted or #msg<2 or msg:byte(1)&15~=channel then return false end
  local status=msg:byte(1)&0xF0
  return lane.pitch and status==0xE0 or lane.status==0xD0 and status==0xD0
    or lane.cc~=nil and status==0xB0 and #msg>=3 and msg:byte(2)==lane.cc
end
local function value(event,lane)
  if lane.pitch then return (event.msg:byte(3)<<7)|event.msg:byte(2)end
  return event.msg:byte(lane.status==0xD0 and 2 or 3)
end
local function message(lane,channel,v)
  v=math.max(0,math.min(lane.pitch and 16383 or 127,math.floor(v+.5)))
  if lane.pitch then return string.char(0xE0|channel,v&127,(v>>7)&127)end
  if lane.status==0xD0 then return string.char(0xD0|channel,v)end
  return string.char(0xB0|channel,lane.cc,v)
end
local function curve_points(app,stream,lane,channel)
  local points={}
  for index,event in ipairs(stream.events)do if matches(event,lane,channel)then
    local extra=stream.events[index+1]
    points[#points+1]={event=event,q=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq),value=value(event,lane),extra=extra and not extra.deleted and extra.ppq==event.ppq and extra.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and extra or nil}
  end end
  table.sort(points,function(a,b)if a.q~=b.q then return a.q<b.q end;return a.event.order<b.event.order end)
  return points
end
local function prepare_boundaries(app,stream,area,cuts)
  local ordered={notes=stream.notes,events={}}
  for _,event in ipairs(stream.events)do if not event.deleted then ordered.events[#ordered.events+1]=event end end
  table.sort(ordered.events,function(a,b)if a.ppq~=b.ppq then return a.ppq<b.ppq end;return a.order<b.order end)
  local ticks={};for _,q in ipairs(cuts)do ticks[#ticks+1]=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,q)+.5)end
  local note={s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)+.5),e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)+.5),chan=area.channel,on={order=-1000000}}
  return require('src.expression_resample').prepare(ordered,note,ticks,function(event)return matches(event,area.lane,area.channel)end)
end
function M.sample(points,q,default)
  local previous,next_point,previous_index
  for index,point in ipairs(points)do if point.q<=q then previous=point;previous_index=index else next_point=point;break end end
  if not previous then
    if default==nil then return nil,'No earlier controller value is available at this edge. Add a boundary point before editing this area.'end
    return default,0
  end
  local shape=(previous.event.flags>>4)&15
  if shape>=2 and shape<=4 and (q==previous.q or not next_point)then
    -- These native shapes depend only on their two endpoints. An exact
    -- boundary preserves them, unless nearby Bezier tangents use this context.
    for index=math.max(1,previous_index-2),math.min(#points,previous_index+2)do
      if ((points[index].event.flags>>4)&15)==5 then return nil,'This boundary affects a neighboring Bezier tangent. Use a square or linear boundary away from that curve.'end
    end
    return previous.value,shape
  end
  if shape>1 then return nil,'Place the area edge on an existing smooth/fast/slow point, or use a square or linear boundary. Bezier boundaries remain protected.'end
  if not next_point or q==previous.q or shape==0 then return previous.value,shape end
  if shape~=1 then return nil,'An area boundary crosses a shaped curve. Place the edge on a point or use a square/linear boundary segment.' end
  return previous.value+(next_point.value-previous.value)*(q-previous.q)/(next_point.q-previous.q),shape
end
function M.apply(app,area,operation,delta,scale,options)
  if app.multi_controller_parent and not(options and options.transaction)then return require('src.multi_controller_razor').from_controller(app.multi_controller_parent,area,operation,delta,scale)end
  if app.mixed_razor and app.razor_area and operation~='values' and not (options and options.transaction)then
    return require('src.mixed_razor').from_controller(app,area,operation,delta,scale)
  end
  if not(options and options.transaction)and operation~='values'and #require('src.controller_areas').list(app,area)>1 then return M.group(app,area,operation,delta,scale)end
  if not(options and options.transaction)and(app.edit.active or app.gesture or app.transform_preview)then return false,'Finish the active edit first.'end
  if not app.take or reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false,'The MIDI item is unavailable.'end
  if reaper.GetMediaItemTake_Item and reaper.GetMediaItemInfo_Value then
    local item=reaper.GetMediaItemTake_Item(app.take)
    if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'Unlock the MIDI item before editing controller areas.'end
  end
  assert(operation=='move' or operation=='copy' or operation=='delete' or operation=='stretch' or operation=='values','Invalid controller-area operation')
  local lane=area and area.lane
  if not lane or lane.protected or lane.discrete or lane.status==0xC0 then return false,'This parameter does not support continuous controller areas.'end
  delta,scale=delta or 0,scale or 1
  if area.end_qn<=area.start_qn or scale<=0 or scale~=scale then return false,'The area has no duration.'end
  local destination_start=area.start_qn+delta
  local destination_end=destination_start+(area.end_qn-area.start_qn)*scale
  if operation~='delete' and (destination_start<app.item_start_qn-1e-8 or destination_end>app.item_end_qn+1e-8) then return false,'The destination extends beyond the active item.'end
  local stream=require('src.note_events').read(app.take);if not stream then return false,'Cannot read the controller data.'end
  local cuts={}
  if operation~='copy'then cuts[#cuts+1]=area.start_qn;cuts[#cuts+1]=area.end_qn end
  if operation~='delete'then cuts[#cuts+1]=destination_start;cuts[#cuts+1]=destination_end end
  local virtual,conversion=prepare_boundaries(app,stream,area,cuts)
  if not virtual then return false,conversion end
  local points=curve_points(app,virtual,lane,area.channel)
  options=options or {}
  local destination_points=points
  if options.clip then points=options.clip.points end
  if #points==0 then return true end
  if operation=='values' and (options.tilt or 0)~=0 then
    for _,p in ipairs(points)do if p.q>=area.start_qn and p.q<=area.end_qn and ((p.event.flags>>4)&15)>1 then return false,'Tilt requires square or linear points inside the area.'end end
  end
  local default=lane.pitch and 8192 or(lane.status==0xD0 or lane.cc==64)and 0 or nil
  local source_first,first_shape=M.sample(points,area.start_qn,default)
  local source_last,last_shape=M.sample(points,area.end_qn,default)
  if (source_first==nil or source_last==nil)and operation=='copy'and not options.clip then
    local clip,notice=M.capture(app,area)
    if not clip then return false,notice end
    points=clip.points
    source_first,first_shape=M.sample(points,area.start_qn,default)
    source_last,last_shape=M.sample(points,area.end_qn,default)
  end
  if not source_first then return false,first_shape end;if not source_last then return false,last_shape end
  local dest_first,dest_shape,dest_last,dest_end_shape
  if operation~='delete' then
    dest_first,dest_shape=M.sample(destination_points,destination_start,default)
    dest_last,dest_end_shape=M.sample(destination_points,destination_end,default)
    if not dest_first then return false,dest_shape end;if not dest_last then return false,dest_end_shape end
  end
  if operation~='copy'and operation~='delete'then
    local sources=options.sources or {options.clip or {area=area,points={{value=source_first}}}}
    local function cleared(q,v,shape)
      for _,clip in ipairs(sources)do local region=clip.area
        if require('src.controller_areas').key(region)==require('src.controller_areas').key(area)and q>=region.start_qn-1e-8 and q<region.end_qn-1e-8 then return clip.points[1].value,0 end
      end
      return v,shape
    end
    dest_first,dest_shape=cleared(destination_start,dest_first,dest_shape)
    dest_last,dest_end_shape=cleared(destination_end,dest_last,dest_end_shape)
  end
  local generated={}
  local function covered(q)
    for _,other in ipairs(options.destinations or {})do if require('src.controller_areas').key(other)==require('src.controller_areas').key(area)and q>=other.start_qn and q<=other.end_qn then return true end end
    return false
  end
  local function transformed(q,v)
    if operation~='values' then return v end
    local maximum=lane.pitch and 16383 or 127
    local pivot=(options.pivot or 0)*maximum
    local t=(q-area.start_qn)/(area.end_qn-area.start_qn)
    return (v-pivot)*(options.gain or 1)+pivot+(options.tilt or 0)*maximum*(t-.5)
  end
  local function point(q,v,shape,priority)
    generated[#generated+1]={q=q,msg=message(lane,area.channel,v),flags=(shape or 0)<<4,priority=priority or 0}
  end
  if operation~='copy' then
    if operation=='delete' or not covered(area.start_qn)and(area.start_qn<destination_start or area.start_qn>destination_end)then point(area.start_qn,options.clip and options.clip.pedal_cycle and options.clip.points[1].value or source_first,0,0)end
    if operation=='delete' or not covered(area.end_qn)and(area.end_qn<destination_start or area.end_qn>destination_end)then point(area.end_qn,source_last,last_shape,0)end
  end
  if operation~='delete' then
    -- Two events at an edge preserve the outside segment and deliberately
    -- switch to/from the pasted curve at that exact boundary.
    point(destination_start,dest_first,0,1)
    point(destination_start,transformed(area.start_qn,source_first),first_shape,2)
    for _,p in ipairs(points)do if p.q>area.start_qn and p.q<area.end_qn then
      local q=destination_start+(p.q-area.start_qn)*scale
      generated[#generated+1]={q=q,msg=operation=='values' and message(lane,area.channel,transformed(p.q,p.value)) or p.event.msg,flags=p.event.flags,extra=p.extra and p.extra.msg,extra_flags=p.extra and p.extra.flags,priority=2,source_order=options.preserve_order and p.event.order}
    end end
    point(destination_end,transformed(area.end_qn,source_last),0,2)
    point(destination_end,dest_last,dest_end_shape,3)
  end
  local committed,failure=xpcall(function()
  if not options.transaction then app.edit:begin('ReaRoll: controller razor '..operation,app.take)end
  local a=app.edit.active
  if conversion.converted then
    local live,plan=prepare_boundaries(app,a.stream,area,cuts);assert(live,plan)
    require('src.expression_resample').apply(a.stream,plan)
  end
  -- Replace only the chosen parameter/channel in the source/destination spans.
  -- Preserve all other MIDI, including note pairs and unrelated CC curves.
  for index,event in ipairs(a.stream.events)do if matches(event,lane,area.channel)and(not options.batch or event.controller_razor_batch~=options.batch)then
    local q=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq)
    local source=operation~='copy' and q>=area.start_qn and q<=area.end_qn
    local destination=operation~='delete' and q>=destination_start and q<=destination_end
    if source or destination then
      event.deleted=true;local following=a.stream.events[index+1]
      if following and following.msg:sub(1,7)==string.char(0xFF,0x0F)..'CCBZ ' then following.deleted=true end
    end
  end end
  table.sort(generated,function(x,y)if x.q~=y.q then return x.q<y.q end;return x.priority<y.priority end)
  for index,p in ipairs(generated)do
    local ppq=reaper.MIDI_GetPPQPosFromProjQN(app.take,p.q)
    -- Append orders must remain below the next inserted note's order. Reserving
    -- two numeric slots per point left holes that placed later controller
    -- initializers after a same-tick note-on, changing after native Redo.
    local order=p.source_order or #a.stream.events+1
    a.stream.events[#a.stream.events+1]={ppq=math.floor(ppq+.5),flags=p.flags,msg=p.msg,order=order,controller_razor_batch=options.batch}
    if p.extra then a.stream.events[#a.stream.events+1]={ppq=math.floor(ppq+.5),flags=p.extra_flags or 0,msg=p.extra,order=order+.1}end
  end
  a.changed=true;a.stream.dirty=true;if not options.transaction then app.edit:finish()end
  end,debug.traceback)
  if not committed then
    if app.edit.active then app.edit:cancel()end
    return false,'The controller edit failed and was cancelled: '..tostring(failure)
  end
  app.cc_cache:invalidate();return true
end
function M.group(app,anchor,operation,delta,scale,options)
  local Areas=require 'src.controller_areas';local regions=Areas.union(Areas.list(app,anchor))
  if app.edit.active or app.gesture or app.transform_preview then return false,'Finish the active edit first.'end
  if not require('src.take').valid(app.take)then return false,'The MIDI item is unavailable.'end
  if reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(app.take),'C_LOCK')~=0 then return false,'Unlock the MIDI item before editing controller areas.'end
  delta=delta or 0;scale=operation=='stretch'and(scale or 1)or 1
  local plans,destinations,captures={},{},{}
  for _,region in ipairs(regions)do
    local clip,notice=M.capture(app,region);if not clip then return false,notice end
    local shift=delta+(region.start_qn-anchor.start_qn)*(scale-1)
    plans[#plans+1]={region=region,clip=clip,delta=shift};captures[#captures+1]=clip
    if operation~='delete'then destinations[#destinations+1]=Areas.translate(region,shift,scale)end
  end
  local ok,notice=xpcall(function()
    if options and options.preview then app.edit:begin_preview(app.take)else app.edit:begin('ReaRoll: controller razor group '..operation,app.take)end
    local batch={}
    for _,plan in ipairs(plans)do local changed,reason=M.apply(app,plan.region,operation,plan.delta,scale,{transaction=true,clip=plan.clip,batch=batch,destinations=destinations,sources=captures});assert(changed,reason)end
    assert(app.edit:finish()~=false,'The group could not be committed.')
  end,function(err)return tostring(err)end)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,notice end
  if operation~='delete'then Areas.set(app,destinations,anchor)end
  app.cc_cache:invalidate();return true
end
function M.copy(app)
  local clips={};local first,last=math.huge,-math.huge
  for _,area in ipairs(require('src.controller_areas').union(require('src.controller_areas').list(app)))do
    local clip,notice=M.capture(app,area);if not clip then return false,notice end
    clips[#clips+1]=clip;first=math.min(first,area.start_qn);last=math.max(last,area.end_qn)
  end
  if #clips==0 then return false,'Select a controller area first.'end
  app.razor_clipboard={phrase={notes={},span=last-first},areas={},anchor=first,controllers=clips,controller=clips[#clips]}
  return true
end
function M.capture(app,area)
  if not area or area.end_qn<=area.start_qn then return nil,'Select a controller area with positive duration.'end
  local lane=area.lane
  if not lane or lane.protected or lane.discrete or lane.status==0xC0 then return nil,'Select a continuous controller area.'end
  local stream=require('src.note_events').read(app.take)
  if not stream then return nil,'Cannot read the controller data.'end
  local points={}
  for index,event in ipairs(stream.events)do if matches(event,lane,area.channel)then
    local extra=stream.events[index+1]
    points[#points+1]={q=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq),value=value(event,lane),event={msg=event.msg,flags=event.flags,order=event.order},extra=extra and extra.ppq==event.ppq and extra.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and {msg=extra.msg,flags=extra.flags}or nil}
  end end
  table.sort(points,function(a,b)if a.q~=b.q then return a.q<b.q end;return a.event.order<b.event.order end)
  local default=lane.pitch and 8192 or(lane.status==0xD0 or lane.cc==64)and 0 or nil
  local first,shape=M.sample(points,area.start_qn,default)
  local last,last_shape=M.sample(points,area.end_qn,default)
  local resampled=false
  if first==nil or last==nil then
    local first_ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_start_qn)+.5)
    local last_ppq=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,app.item_end_qn)+.5)
    local cuts={math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,area.start_qn)+.5),math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,area.end_qn)+.5)}
    local virtual,plan=require('src.expression_resample').prepare(stream,{s=first_ppq,e=last_ppq,chan=area.channel,on={order=-1000000}},cuts,function(event)return matches(event,lane,area.channel)end)
    if not virtual then return nil,plan end
    if plan.converted then
      points={}
      for index,event in ipairs(virtual.events)do if matches(event,lane,area.channel)then
        local extra=virtual.events[index+1]
        points[#points+1]={q=reaper.MIDI_GetProjQNFromPPQPos(app.take,event.ppq),value=value(event,lane),event={msg=event.msg,flags=event.flags,order=event.order},extra=extra and extra.ppq==event.ppq and extra.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and {msg=extra.msg,flags=extra.flags}or nil}
      end end
      table.sort(points,function(a,b)if a.q~=b.q then return a.q<b.q end;return a.event.order<b.event.order end)
      first,shape=M.sample(points,area.start_qn,default)
      last,last_shape=M.sample(points,area.end_qn,default)
      resampled=true
    end
  end
  if first==nil then return nil,shape end;if last==nil then return nil,last_shape end
  local pedal_cycle=area.pedal_cycle and lane.cc==64
  local outside=first
  if pedal_cycle then
    local earlier={};for _,p in ipairs(points)do if p.q<area.start_qn then earlier[#earlier+1]=p end end
    outside=select(1,M.sample(earlier,area.start_qn,0))
    if outside==nil or outside>=64 or last>=64 then return nil,'Include the full recorded pedal cycle with released outside boundaries.'end
  end
  local out={{q=area.start_qn,value=outside,event={flags=(pedal_cycle and 0 or shape)<<4,msg=message(lane,area.channel,outside)}}}
  for _,p in ipairs(points)do if(p.q>area.start_qn or pedal_cycle and p.q==area.start_qn)and p.q<area.end_qn then out[#out+1]=p end end
  out[#out+1]={q=area.end_qn,value=last,event={flags=last_shape<<4,msg=message(lane,area.channel,last)}}
  local saved_lane={};for k,v in pairs(lane)do saved_lane[k]=v end
  return {points=out,resampled=resampled,pedal_cycle=pedal_cycle,area={pedal_cycle=pedal_cycle,start_qn=area.start_qn,end_qn=area.end_qn,lane=saved_lane,channel=area.channel}}
end
return M
