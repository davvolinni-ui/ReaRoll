-- @noindex
-- Source-note text metadata owns only explicitly authored slide samples.
-- MIDI remains playable without ReaRoll; unrecognized/stale links never claim CCs.
local M={}
local tag='REAROLL_SLIDE '
local function finite(n)return type(n)=='number'and n==n and n>-math.huge and n<math.huge end
local function split(s,separator)local out={};for v in (s..separator):gmatch('(.-)'..separator)do out[#out+1]=v end;return out end
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)if #s%2~=0 or s:find('[^%x]')then return end;return(s:gsub('..',function(pair)return string.char(tonumber(pair,16))end))end
local function position(note,f)return math.floor(note.s+f*(note.e-note.s)+.5)end
local function relative(note,ppq)return(ppq-note.s)/math.max(1,note.e-note.s)end
local function number(n)return string.format('%.17g',n)end
function M.is_curve(event)
  return not event.deleted and event.msg:match('^..NOTE %d+ %d+ REAROLL_CURVE 1$')~=nil
end
function M.has_curve(note)
  for _,event in ipairs(note.notation or {})do if M.is_curve(event)then return true end end
  return false
end
function M.is_event(event)
  if event.deleted then return false end
  return M.is_curve(event)or event.msg:sub(1,2)==string.char(255,1)and event.msg:match('^..REAROLL_SLIDE %d+ %d+ ')~=nil or event.msg:sub(1,2)==string.char(255,15)and event.msg:match('^..NOTE %d+ %d+ REAROLL_SLIDE ')~=nil
end
function M.has(note)
  for _,event in ipairs(note.notation or {})do if M.is_event(event)then return true end end
  return false
end
function M.encode(note,r)
  local points,backup={},{}
  for _,p in ipairs(r.points)do points[#points+1]=number(p.time)..','..p.value end
  for _,e in ipairs(r.backup)do backup[#backup+1]=number(e.time)..','..e.flags..','..hex(e.msg)end
  local fields={r.structural and '5'or r.domain_first and '4'or(r.last>1 and '3'or '2'),r.id,number(r.first),number(r.last),r.delta,r.range,r.linear and '1'or '0',table.concat(points,';'),table.concat(backup,';'),number(r.curve or 0)}
  if r.domain_first then fields[11]=number(r.domain_first);fields[12]=number(r.domain_last)end
  return string.char(255,1)..tag..note.chan..' '..note.pitch..' '..table.concat(fields,'|')
end
function M.decode(event)
  if not M.is_event(event)or #event.msg>131072 then return end
  local payload=event.msg:match('^..REAROLL_SLIDE %d+ %d+ (.*)$')or event.msg:match('^..NOTE %d+ %d+ REAROLL_SLIDE (.*)$');if not payload then return end
  local f=split(payload,'|');if not((#f==9 and f[1]=='1')or(#f==10 and(f[1]=='2'or f[1]=='3'))or(#f==12 and(f[1]=='4'or f[1]=='5')))or(f[7]~='0'and f[7]~='1')then return end
  local r={id=tonumber(f[2]),first=tonumber(f[3]),last=tonumber(f[4]),delta=tonumber(f[5]),range=tonumber(f[6]),linear=f[7]=='1',curve=tonumber(f[10]or '0'),points={},backup={},event=event}
  if not finite(r.id)or r.id%1~=0 or r.id<1 or r.id>2147483647 or not finite(r.first)or not finite(r.last)or (f[1]~='5'and(r.first<0 or r.first>=1)) or r.last>((f[1]=='3'or f[1]=='4'or f[1]=='5')and 1000000 or 1)or r.last<=r.first or not finite(r.delta)or r.delta%1~=0 or math.abs(r.delta)>127 or not finite(r.range)or r.range<1 or r.range>96 or not finite(r.curve)or math.abs(r.curve)>1 then return end
  local lo,hi=0,1
  if f[1]=='4'or f[1]=='5'then
    lo,hi=tonumber(f[11]),tonumber(f[12])
    if not finite(lo)or not finite(hi)or lo>0 or hi<1 or lo< -1000000 or hi>1000000 then return end
    r.domain_first,r.domain_last=lo,hi;r.structural=f[1]=='5'
    if r.first<lo or r.first>=hi then return end
  end
  for _,row in ipairs(split(f[8],';'))do
    local t,v=row:match('^([^,]+),([^,]+)$');t,v=tonumber(t),tonumber(v)
    if not finite(t)or t<lo or t>hi or not finite(v)or v%1~=0 or v<0 or v>16383 or #r.points>=130 then return end
    if not(t>=r.first-1e-12 and t<=r.last+1e-12)and not(v==8192 and(t==hi or r.structural))then return end
    r.points[#r.points+1]={time=t,value=v}
  end
  if #r.points<2 then return end
  if f[9]~=''then for _,row in ipairs(split(f[9],';'))do
    local t,flags,msg=row:match('^([^,]+),([^,]+),(%x+)$');t,flags,msg=tonumber(t),tonumber(flags),msg and unhex(msg)
    if not finite(t)or t<lo or t>hi or not finite(flags)or flags%1~=0 or flags<0 or flags>255 or not msg or #msg>512 or #r.backup>=2048 then return end
    if not(#msg>=3 and msg:byte(1)>>4==14 and msg:byte(2)<128 and msg:byte(3)<128)and msg:sub(1,7)~=string.char(255,15)..'CCBZ 'then return end
    r.backup[#r.backup+1]={time=t,flags=flags,msg=msg}
  end end
  return r
end
local function bend(e,n)return not e.deleted and #e.msg>=3 and e.msg:byte(1)==(224|n.chan)end
local function value(e)return(e.msg:byte(3)<<7)|e.msg:byte(2)end
function M.records(stream,note)
  if not M.has(note)then return {},0 end
  local records,stale={},0
  local buckets,pitch_events={},{}
  for _,e in ipairs(stream.events)do if bend(e,note)then local key=e.ppq..':'..value(e);local bucket=buckets[key]or {};buckets[key]=bucket;bucket[#bucket+1]=e;pitch_events[#pitch_events+1]=e end end
  for _,event in ipairs(note.notation or {})do if M.is_event(event)and not M.is_curve(event)then
    local r=M.decode(event)
    if r then
      local refs,used,expected={}, {},{}
      for _,p in ipairs(r.points)do
        local ppq=position(note,p.time);local match
        for _,e in ipairs(buckets[ppq..':'..p.value]or {})do if not used[e]and ((e.flags or 0)&240)==0 then match=e;break end end
        if not match then refs=nil;break end
        used[match]=true;refs[#refs+1]=match;expected[match]=true
      end
      if refs then
        local first,last=position(note,r.first),position(note,r.last)
        for _,e in ipairs(pitch_events)do if e.ppq>=first and e.ppq<=last and e.ppq<position(note,r.domain_last or 1)and not expected[e]then refs=nil;break end end
      end
      r.valid=refs~=nil;r.refs=refs
      records[#records+1]=r;if not r.valid then stale=stale+1 end
    else stale=stale+1 end
  end end
  table.sort(records,function(a,b)if a.first~=b.first then return a.first<b.first end;return a.id<b.id end)
  return records,stale
end
function M.attach(stream,note,plan,settings)
  local records=M.records(stream,note);local id=1
  for _,event in ipairs(note.notation or {})do if M.is_event(event)and not M.is_curve(event)and not M.decode(event)then event.deleted=true end end
  for _,r in ipairs(records)do id=math.max(id,r.id+1);if not r.valid then r.event.deleted=true end end
  local r={id=id,structural=M.structural(note),first=relative(note,plan.first),last=relative(note,plan.last),delta=plan.target-note.pitch,range=plan.range,linear=settings.slide_linear==true,curve=settings.slide_curve or 0,points={},backup={}}
  for _,p in ipairs(plan.points)do r.points[#r.points+1]={time=relative(note,p.ppq),value=p.value}end
  if plan.group_first and(r.structural or plan.group_first~=note.s or plan.ending~=note.e)then r.domain_first=relative(note,plan.group_first);r.domain_last=relative(note,plan.ending)end
  if plan.reset then r.points[#r.points+1]={time=relative(note,plan.ending),value=8192}end
  for _,e in ipairs(plan.remove)do r.backup[#r.backup+1]={time=relative(note,e.ppq),flags=e.flags or 0,msg=e.msg}end
  if #r.backup>2048 then return nil,'This replacement contains too much expression for a slide link. Edit it in the expression editor.'end
  local msg=M.encode(note,r);if #msg>131072 then return nil,'The slide link is too large.'end
  local event={ppq=note.s,flags=0,msg=msg,order=#stream.events+1}
  stream.events[#stream.events+1]=event;note.notation[#note.notation+1]=event;stream.dirty=true
  return r
end
function M.snapshot(stream,note)
  if not M.has(note)then return {}end
  local records=M.records(stream,note);local out={}
  for _,r in ipairs(records)do if r.valid then out[#out+1]=r end end
  return out
end
function M.remap(note,records,values,domain)
  local ns,ne=values.s or note.s,values.e or note.e;local span=math.max(1,note.e-note.s);local newspan=math.max(1,ne-ns)
  local function mapped(f)local old=position(note,f);local tick=domain and math.floor(domain.s+(old-domain.old_s)/math.max(1,domain.old_e-domain.old_s)*(domain.e-domain.s)+.5)or math.floor(ns+(old-note.s)/span*newspan+.5);return(tick-ns)/newspan end
  for _,r in ipairs(records)do
    r.first,r.last=mapped(r.first),mapped(r.last)
    if r.domain_first then r.domain_first,r.domain_last=mapped(r.domain_first),mapped(r.domain_last)end
    for i,p in ipairs(r.points)do p.time=mapped(p.time) end
    for _,e in ipairs(r.backup)do e.time=mapped(e.time);if values.chan~=nil and #e.msg>=3 and e.msg:byte(1)>>4==14 then e.msg=string.char(224|values.chan)..e.msg:sub(2)end end
    r.event.msg=M.encode(note,r)
  end
end
function M.edit_many(stream,note,changes,settings,item_end)
  local records,stale=M.records(stream,note);local structural=M.structural(note)
  if stale>0 then return false,'Expression changed outside this slide link. Its MIDI was preserved; redraw a target to establish a new link.'end
  local found={}
  for _,r in ipairs(records)do if changes[r.id]then found[r.id]=true end end
  for id in pairs(changes)do if id~='_insert'and not found[id]then return false,'The slide target is unavailable.'end end
  local range=settings.mpe_enabled and(settings.mpe_pitch_bend_range or 48)or(settings.pitch_bend_range or 2)
  for _,r in ipairs(records)do if r.range~=range then return false,'Match the saved slide bend range before editing its target.'end end
  -- Restore the pre-slide pitch data before regenerating the complete chain.
  local restored={}
  for _,r in ipairs(records)do
    for _,e in ipairs(r.refs)do
      -- A joined chain may contain the original neutral release between targets.
      -- Keep that boundary when regenerating a handle; it is part of the music.
      if r.structural and value(e)==8192 and e.ppq>position(note,r.last)and e.ppq<position(note,r.domain_last or 1)then
        local reset={ppq=e.ppq,flags=e.flags,msg=e.msg,order=e.order};stream.events[#stream.events+1]=reset;restored[reset]=true
      end
      e.deleted=true
    end;r.event.deleted=true
    for _,b in ipairs(r.backup)do
      local e={ppq=position(note,b.time),flags=b.flags,msg=b.msg,order=#stream.events+1};stream.events[#stream.events+1]=e;restored[e]=true
    end
  end
  for _,chosen in ipairs(records)do local change=changes[chosen.id];if change then
  if change.delete then chosen.removed=true else
    chosen.first=relative(note,change.first or position(note,chosen.first));chosen.last=relative(note,change.last or position(note,chosen.last));chosen.delta=change.target and(change.target-note.pitch)or chosen.delta
    if change.linear~=nil then chosen.linear=change.linear end
    if change.curve~=nil then if not finite(change.curve)or math.abs(change.curve)>1 then return false,'Invalid slide curve amount.'end;chosen.curve=change.curve end
  end
  end end
  local next_id=1;for _,r in ipairs(records)do next_id=math.max(next_id,r.id+1)end
  for _,target in ipairs(changes._insert or {})do
    if not finite(target.first)or not finite(target.last)or not finite(target.target)or not finite(target.curve or 0)or math.abs(target.curve or 0)>1 then return false,'Invalid copied slide target.'end
    records[#records+1]={id=next_id,structural=structural,first=relative(note,target.first),last=relative(note,target.last),delta=target.target-note.pitch,range=range,linear=target.linear==true,curve=target.curve or 0,backup={},points={}}
    next_id=next_id+1
  end
  table.sort(records,function(a,b)return a.first<b.first end)
  local previous
  for _,r in ipairs(records)do if not r.removed then
    if previous and previous.last>=r.first then return false,'Slide targets cannot overlap or share an endpoint. Leave a gap or edit the existing target.'end;previous=r
    local local_settings={};for k,v in pairs(settings)do local_settings[k]=v end;local_settings.slide_linear=r.linear;local_settings.slide_curve=r.curve or 0;local_settings.slide_structural=r.structural;local_settings.slide_domain_first=r.domain_first and position(note,r.domain_first);local_settings.slide_domain_last=r.domain_last and position(note,r.domain_last)
    local plan,notice=require('src.slide_draw').plan(stream,note,position(note,r.first),position(note,r.last),note.pitch+r.delta,local_settings,true,item_end)
    if not plan then return false,notice end
    for _,e in ipairs(plan.remove)do if not restored[e]then return false,'The new target would overwrite expression outside its saved slide data.'end end
    for _,e in ipairs(plan.remove)do e.deleted=true end
    local function add(ppq,v)local e={ppq=ppq,flags=note.muted and 2 or 0,msg=string.char(224|note.chan,v&127,(v>>7)&127),order=-1000000000+#stream.events};stream.events[#stream.events+1]=e end
    for _,p in ipairs(plan.points)do add(p.ppq,p.value)end;if plan.reset then add(plan.ending,8192)end
    r.points={};for _,p in ipairs(plan.points)do r.points[#r.points+1]={time=relative(note,p.ppq),value=p.value}end;if plan.reset then r.points[#r.points+1]={time=relative(note,plan.ending),value=8192}end
    r.domain_first,r.domain_last=nil,nil
    if plan.group_first and(r.structural or plan.group_first~=note.s or plan.ending~=note.e)then r.domain_first=relative(note,plan.group_first);r.domain_last=relative(note,plan.ending)end
    r.backup={};for _,e in ipairs(plan.remove)do r.backup[#r.backup+1]={time=relative(note,e.ppq),flags=e.flags,msg=e.msg}end
    local event={ppq=note.s,flags=0,msg=M.encode(note,r),order=#stream.events+1};stream.events[#stream.events+1]=event;note.notation[#note.notation+1]=event
  end end
  stream.dirty=true;return true
end
function M.edit(stream,note,id,change,settings)return M.edit_many(stream,note,{[id]=change},settings)end
function M.structural(note)
  for _,event in ipairs(note.notation or {})do local r=M.decode(event);if r and r.structural then return true end end
  return false
end
function M.domain(note)
  local first,last=note.s,note.e
  for _,event in ipairs(note.notation or {})do local r=M.decode(event);if r and r.domain_first then first=math.min(first,position(note,r.domain_first));last=math.max(last,position(note,r.domain_last))end end
  return first,last
end
function M.expression_settings(note,settings)
  if settings.mpe_enabled and require('src.expression').member(note.chan,settings)then return settings end
  if not M.has(note)then return nil end
  local out={};for k,v in pairs(settings)do out[k]=v end
  out.expression_all_channels=true;out.expression_pitch_only=true;local first,last=M.domain(note);if first~=note.s or last~=note.e then out.expression_start,out.expression_end=first,last end;return out
end
function M.selection_has(take,selected)
  local stream=require('src.note_events').read(take);if not stream then return false end
  for _,n in ipairs(selected)do local source=stream.notes[n.index+1];if source and M.has(source)then return true end end
  return false
end
function M.cohort(stream,note,selected)return require('src.shared_slide').cohort(stream,note,selected)end
function M.reset_curve_releases(stream,touched)
  local changed=false
  for _,note in ipairs(stream.notes)do if touched[note.index]and M.has_curve(note)then
    local follows=false
    for _,other in ipairs(stream.notes)do if other~=note and other.chan==note.chan and other.s<=note.e and other.e>note.e then follows=true;break end end
    if not follows then
      local ending
      for _,event in ipairs(stream.events)do if bend(event,note)and event.ppq==note.e and(not ending or event.order>ending.order)then ending=event end end
      if ending and value(ending)~=8192 then
        stream.events[#stream.events+1]={ppq=note.e,flags=note.muted and 2 or 0,msg=string.char(224|note.chan,0,64),order=#stream.events+1}
        stream.dirty=true;changed=true
      end
    end
  end end
  return changed
end
function M.remove_owned(stream,note,removed)
  if M.has_curve(note)then return require('src.expression').remove(stream,note,{expression_all_channels=true,expression_pitch_only=true})end
  local first,last=M.domain(note)
  for _,other in ipairs(stream.notes)do if other~=note and other.chan==note.chan and other.s<last and other.e>first and not(removed and removed[other.index])then return end end
  for _,r in ipairs(M.snapshot(stream,note))do for _,event in ipairs(r.refs)do
    local shared=false
    for _,other in ipairs(stream.notes)do if other~=note and other.chan==note.chan and (other.s==event.ppq or other.e==event.ppq)and not(removed and removed[other.index])then shared=true;break end end
    if not shared then event.deleted=true end
  end end
end
return M
