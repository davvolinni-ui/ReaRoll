-- @noindex
-- Neutral gaps retain target handles. Active cuts retain exact pitch data
-- as per-note curves, using the existing expression editor and transport.
local M={}
local function position(note,f)return math.floor(note.s+f*(note.e-note.s)+.5)end
local function relative(part,t)return(t-part.s)/(part.e-part.s)end
local function key(part)return part.s..':'..part.e end
function M.prepare(stream,note,plans,settings)
  local Links=require 'src.slide_links'
  local records,stale=Links.records(stream,note)
  if stale>0 or #records==0 and not Links.has_curve(note)then return nil,'The slide links changed outside ReaRoll. Edit or redraw their targets before splitting this note.'end
  local life=require('src.voice_lifetime').index(stream,settings)
  if life(note)~=note.e then return nil,'Include the complete sustain context before splitting a linked slide voice.'end
  for _,other in ipairs(stream.notes)do if other~=note and other.chan==note.chan and other.s<note.e and life(other)>note.s then
    return nil,'Splitting a shared-channel slide chord remains protected. Split an independent voice or remove its target first.'
  end end
  local parts={};for _,part in ipairs(plans)do parts[#parts+1]=part end
  table.sort(parts,function(a,b)return a.s<b.s end)
  local out={fragments={},events={},start=note.s};local cursor=note.s;local curves=Links.has_curve(note)
  for _,part in ipairs(parts)do
    if part.s~=cursor or part.e<=part.s or part.e>note.e or(part.pitch or note.pitch)~=note.pitch or part.end_index and part.end_index~=note.index then return nil,'A linked-slide split must retain the complete note, pitch and channel.'end
    out.fragments[key(part)]={};cursor=part.e
    if part.s>note.s then
      local previous
      for _,event in ipairs(stream.events)do if not event.deleted and #event.msg>=3 and event.msg:byte(1)==(224|note.chan)and event.ppq<=part.s then
        if not previous or event.ppq>previous.ppq or event.ppq==previous.ppq and event.order>previous.order then previous=event end
      end end
      if previous and(((previous.flags>>4)&15)~=0 or((previous.msg:byte(3)<<7)|previous.msg:byte(2))~=8192)then curves=true end
    end
  end
  if cursor~=note.e then return nil,'A linked-slide split must retain the complete original duration.'end
  for _,record in ipairs(records)do
    local first,last=position(note,record.first),position(note,record.last);local owner=false
    for _,part in ipairs(parts)do if first>=part.s and math.min(last,note.e)<=part.e then owner=true;break end end
    if not owner then curves=true end
  end
  if curves then
    out.curve=true
    local msg=string.char(255,15)..'NOTE '..note.chan..' '..note.pitch..' REAROLL_CURVE 1'
    for _,part in ipairs(parts)do out.fragments[key(part)]={msg}end
    return out
  end
  for _,record in ipairs(records)do
    local first,last=position(note,record.first),position(note,record.last);local owner
    for _,part in ipairs(parts)do if first>=part.s and math.min(last,note.e)<=part.e then owner=part;break end end
    if not owner then return nil,'Keep each slide target inside one note fragment. Place the split in a neutral gap between targets.'end
    local saved={id=record.id,first=relative(owner,first),last=relative(owner,last),delta=record.delta,range=record.range,linear=record.linear,curve=record.curve,points={},backup={}}
    local seen={}
    for _,point in ipairs(record.points)do
      local tick=point.time==1 and point.value==8192 and owner.e or position(note,point.time)
      if tick<owner.s or tick>owner.e then return nil,'The saved slide expression crosses this split.'end
      local identity=tick..':'..point.value
      if not seen[identity]then saved.points[#saved.points+1]={time=relative(owner,tick),value=point.value};seen[identity]=true end
    end
    for _,event in ipairs(record.backup)do
      local tick=position(note,event.time)
      if tick<owner.s or tick>owner.e then return nil,'The slide replacement backup crosses this split.'end
      saved.backup[#saved.backup+1]={time=relative(owner,tick),flags=event.flags,msg=event.msg}
    end
    local msg=Links.encode(note,saved)
    local candidate={ppq=owner.s,flags=0,msg=msg}
    if not Links.decode(candidate)then return nil,'The split would collapse this saved slide target. Use a wider note fragment.'end
    local entries=out.fragments[key(owner)];entries[#entries+1]=msg
    if owner.e<note.e and seen[owner.e..':8192']then
      out.events[#out.events+1]={ppq=owner.e,flags=note.muted and 2 or 0,msg=string.char(224|note.chan,0,64),order=-1000000000+#stream.events+#out.events}
    end
  end
  return out
end
function M.decorate(stream,note,plan)
  local entries=plan and plan.fragments[key(note)];if not entries then return end
  local Links=require 'src.slide_links'
  for _,event in ipairs(note.notation)do if Links.is_event(event)then event.deleted=true end end
  for _,msg in ipairs(entries)do local event={ppq=note.s,flags=0,msg=msg,order=#stream.events+1}
    stream.events[#stream.events+1]=event;note.notation[#note.notation+1]=event
  end
  if note.s>plan.start then
    for _,event in ipairs(stream.events)do if not event.deleted and event.ppq==note.s and require('src.expression').message(event,note.chan)then note.on.order=math.max(note.on.order,event.order+.5)end end
  end
  stream.dirty=true
end
return M
