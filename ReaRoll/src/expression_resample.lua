-- @noindex
-- Native tension curves cannot generally encode an arbitrary subcurve with one
-- new tension value. Convert only selected crossing segments to a bounded
-- linear representation, checked at every representable integer MIDI tick.
local M={}
local function copy(t)local out={};for k,v in pairs(t)do out[k]=v end;return out end
local function kind(e)return e.msg:byte(1)>>4 end
local function value(e)local k=kind(e);return k==14 and((e.msg:byte(3)<<7)|e.msg:byte(2))or k==13 and e.msg:byte(2)or e.msg:byte(3)end
local function message(e,v)
  local k=kind(e);if k==14 then return string.char(e.msg:byte(1),v&127,(v>>7)&127)end
  if k==13 then return string.char(e.msg:byte(1),v)end
  return string.char(e.msg:byte(1),e.msg:byte(2),v)
end
function M.prepare(stream,note,cuts,matcher)
  local E=require 'src.expression';local Curve=require 'src.midi_curve';local groups={}
  for index,event in ipairs(stream.events)do if (matcher or E.message)(event,note.chan)then
    local k=kind(event);local points=groups[k]or {};groups[k]=points
    local following=stream.events[index+1]
    points[#points+1]={time=event.ppq,value=value(event),flags=event.flags,event=event,shape=following and not following.deleted and following.ppq==event.ppq and following.msg:sub(1,7)==string.char(255,15)..'CCBZ 'and following or nil}
  end end
  local plan={changes={},insertions={},removed={},converted=false};local budget=0
  for k,points in pairs(groups)do
    table.sort(points,function(a,b)if a.time~=b.time then return a.time<b.time end;return a.event.order<b.event.order end)
    local segments={}
    local function mark(index)
      local shape=(points[index].flags>>4)&15;segments[index]=true
      -- A following native Bezier derives its tangent from a preceding Bezier.
      while shape==5 and points[index+1]and((points[index+1].flags>>4)&15)==5 and points[index+2]and points[index+2].time>points[index+1].time do index=index+1;segments[index]=true end
    end
    if not matcher and #cuts>0 then for i,p in ipairs(points)do if p.time==note.s and((p.flags>>4)&15)==5 and points[i+1]and points[i+1].time>p.time then mark(i)end end end
    for _,cut in ipairs(cuts)do
      local index;for i,p in ipairs(points)do if p.time<=cut then index=i else break end end
      if matcher and index and points[index+1]and points[index+1].time>cut and ((points[index+1].flags>>4)&15)==5 then
        -- Inserting a boundary can replace the outgoing tangent context of
        -- the preceding Bezier, even when the crossed segment is linear.
        local i=index-1
        if i>=1 and ((points[i].flags>>4)&15)==5 and points[i+1].time>points[i].time then mark(i)end
      end
      local a=index and points[index];local b=index and points[index+1]
      if a and b and b.time>cut then
        local shape=(a.flags>>4)&15
        if a.time<cut and shape>1 then
          if shape>5 then return nil,'This expression uses an unknown native curve shape.'end
          mark(index)
        elseif a.time==cut and shape==5 then mark(index)end
      end
    end
    -- REAPER's Bezier tangents depend on both surrounding shape flags.
    -- Close every affected neighbor before inserting any linear points.
    local changed=true
    while changed do
      changed=false
      local function add(index)
        if index>=1 and points[index+1]and((points[index].flags>>4)&15)==5 and not segments[index]then segments[index]=true;changed=true end
      end
      for index in pairs(segments)do
        if((points[index].flags>>4)&15)==5 then add(index+1);add(index-2)end
        if points[index+1]and((points[index+1].flags>>4)&15)==5 then add(index-1)end
      end
    end
    for index in pairs(segments)do
      local a,b=points[index],points[index+1]
      if a.time<note.s or b.time>note.e then return nil,matcher and 'The curve extends beyond this MIDI item. Enlarge the item or choose a boundary inside its complete curve context.'or 'The nonlinear curve crosses another voice boundary. Include a complete expression voice before splitting it.'end
      if b.time-a.time<1 then return nil,'The curve has no integer-tick interval to split.'end
      budget=budget+b.time-a.time
      if budget>65536 then return nil,'This split spans too much nonlinear expression for one edit. Use a shorter voice or split at existing points.'end
      local samples={};local keep={};local anchors={};local maximum=k==14 and 16383 or 127
      for tick=a.time,b.time do
        local exact=Curve.value(points,index,tick,0,maximum);if not exact then return nil,'The native curve could not be evaluated safely.'end
        samples[#samples+1]={time=tick,exact=exact,value=math.max(0,math.min(maximum,math.floor(exact+.5)))}
      end
      keep[1]=true;keep[#samples]=true
      for _,cut in ipairs(cuts)do if cut>a.time and cut<b.time then keep[cut-a.time+1]=true end end
      for i in pairs(keep)do anchors[#anchors+1]=i end;table.sort(anchors)
      local stack={};for i=1,#anchors-1 do stack[#stack+1]={anchors[i],anchors[i+1]}end
      while #stack>0 do
        local span=table.remove(stack);local first,last=samples[span[1]],samples[span[2]];local error,worst=.500001,nil
        for i=span[1]+1,span[2]-1 do local p=samples[i];local predicted=first.value+(last.value-first.value)*(p.time-first.time)/(last.time-first.time);local deviation=math.abs(predicted-p.exact)
          if deviation>error then error=deviation;worst=i end
        end
        if worst then keep[worst]=true;stack[#stack+1]={span[1],worst};stack[#stack+1]={worst,span[2]}end
      end
      local start=copy(a.event);start.flags=(start.flags&15)|16;plan.changes[a.event]=start
      if a.shape then plan.removed[a.shape]=true end
      for i,p in ipairs(samples)do if i>1 and i<#samples and keep[i]then
        plan.insertions[#plan.insertions+1]={ppq=p.time,flags=(a.flags&15)|16,msg=message(a.event,p.value),order=note.on.order-.25,controller_razor_batch=a.event.controller_razor_batch}
        if #plan.insertions>4096 then return nil,'This split requires too many expression points for one edit.'end
      end end
      plan.converted=true
    end
  end
  if not plan.converted then return stream,plan end
  local virtual={notes=stream.notes,events={}}
  for _,event in ipairs(stream.events)do if not plan.removed[event]then virtual.events[#virtual.events+1]=plan.changes[event]or event end end
  for _,event in ipairs(plan.insertions)do virtual.events[#virtual.events+1]=event end
  table.sort(virtual.events,function(a,b)if a.ppq~=b.ppq then return a.ppq<b.ppq end;return a.order<b.order end)
  return virtual,plan
end
function M.apply(stream,plan)
  if not plan or not plan.converted then return end
  for event,replacement in pairs(plan.changes)do event.flags=replacement.flags end
  for event in pairs(plan.removed)do event.deleted=true end
  for _,event in ipairs(plan.insertions)do stream.events[#stream.events+1]=event end
  stream.dirty=true
end
return M
