-- @noindex
-- Preserve complete adjacent joins and bounded-precision expression splits.
-- Shared pedals/chord slides and cross-voice ownership stay guarded.
local M={}
function M.partition(stream,note,plans,settings)
  local E=require 'src.expression';local Life=require 'src.voice_lifetime'
  local sorted={};for _,p in ipairs(plans)do sorted[#sorted+1]=p end
  table.sort(sorted,function(a,b)return a.s<b.s end)
  local cursor=note.s;local boundaries={};local life=Life.index(stream,settings)
  if life(note)~=note.e then return nil,'Include the full shared pedal context before splitting a sustained voice.'end
  local cuts={};for _,p in ipairs(sorted)do if p.s>note.s then cuts[#cuts+1]=p.s end end
  local virtual,resample=require('src.expression_resample').prepare(stream,note,cuts)
  if not virtual then return nil,resample end
  boundaries.resamples={resample}
  for _,p in ipairs(sorted)do
    if p.s~=cursor or p.e<=p.s or p.e>note.e or (p.pitch or note.pitch)~=note.pitch or p.end_index and p.end_index~=note.index then return nil,'Expression splits must partition the complete original note without changing its pitch or channel.'end
    local fragment={s=p.s,e=p.e,chan=note.chan,pitch=note.pitch,on=note.on,off=note.off}
    if life(fragment)~=p.e then return nil,'A split would change the pedal-held lifetime of this voice.'end
    local owned,notice=E.capture(virtual,fragment,settings,{[note.index]=true})
    if not owned then return nil,notice end
    if p.s>note.s then for _,entry in ipairs(owned)do if entry.synthetic then
      local event={};for k,v in pairs(entry.event)do event[k]=v end
      event.order=note.on.order-.25;boundaries[#boundaries+1]=event
    end end end
    cursor=p.e
  end
  if cursor~=note.e then return nil,'Expression splits must retain the complete original duration.'end
  return boundaries
end
function M.add_boundaries(stream,boundaries)
  for _,plan in ipairs(boundaries and boundaries.resamples or {})do require('src.expression_resample').apply(stream,plan)end
  for _,event in ipairs(boundaries or {})do stream.events[#stream.events+1]=event;stream.dirty=true end
end
function M.decorate(stream,note,source_index,boundaries)
  require('src.slide_partition').decorate(stream,note,boundaries and boundaries.slide_fragments and boundaries.slide_fragments[source_index])
  if boundaries and boundaries.original_starts[source_index]and note.s>boundaries.original_starts[source_index]then
    for _,event in ipairs(stream.events)do if not event.deleted and event.ppq==note.s and require('src.expression').message(event,note.chan)then note.on.order=math.max(note.on.order,event.order+.5)end end
  end
end
function M.validate(stream,indices,plans,settings)
  local E=require 'src.expression';local Links=require 'src.slide_links'
  local selected={};for _,index in ipairs(indices)do selected[index]=true end
  local shared,reason=require('src.slide_structure').prepare(stream,selected,plans,settings)
  if not shared then return false,reason end
  local boundaries={slide_fragments=shared.fragments,original_starts={}}
  local protected={};boundaries.expression_sources=protected;local protected_settings={};local life=require('src.voice_lifetime').index(stream,settings)
  for _,index in ipairs(indices)do local n=stream.notes[index+1]
    if n then boundaries.original_starts[index]=n.s end
    if n and Links.has(n)and not shared.handled[index]then
      local parts={};for _,part in ipairs(plans or {})do if part.source_index==index then parts[#parts+1]=part end end
      if #parts>1 then
        local split,notice=require('src.slide_partition').prepare(stream,n,parts,settings)
        if not split then return false,notice end
        boundaries.slide_fragments[index]=split
        if split.curve then
          boundaries.curve_split=true;protected[index]=true;protected_settings[index]=Links.expression_settings(n,settings)
        end
        for _,event in ipairs(split.events)do boundaries[#boundaries+1]=event end
      elseif Links.has_curve(n)and #Links.records(stream,n)==0 then
        protected[index]=true;protected_settings[index]=Links.expression_settings(n,settings)
      elseif not(#parts==1 and parts[1].s==n.s and parts[1].e==n.e and(parts[1].pitch or n.pitch)==n.pitch)then return false,'Remove the linked slide targets before joining these notes.'end
    end
    if n and settings.mpe_enabled and E.member(n.chan,settings)then protected[index]=true end
  end
  if not next(protected)then return true,nil,boundaries end
  if not plans then return false,'Expression voices can only be joined as complete adjacent notes; splitting remains protected.'end
  local used={};local partitioned={}
  for index in pairs(protected)do
    local parts={};for _,p in ipairs(plans)do if p.source_index==index then parts[#parts+1]=p end end
    if #parts>1 then
      local points,notice=M.partition(stream,stream.notes[index+1],parts,protected_settings[index]or settings)
      if not points then return false,notice end
      partitioned[index]=true;used[index]=true
      for _,event in ipairs(points)do boundaries[#boundaries+1]=event end
      boundaries.resamples=boundaries.resamples or {};for _,plan in ipairs(points.resamples or {})do boundaries.resamples[#boundaries.resamples+1]=plan end
    end
  end
  for _,p in ipairs(plans)do
    local first=stream.notes[(p.source_index or -1)+1]
    if first and protected[first.index]and not partitioned[first.index]then
      if p.s==first.s and p.e==first.e and (p.pitch or first.pitch)==first.pitch and not used[first.index]then used[first.index]=true
      else
      local chain={}
      for _,n in ipairs(stream.notes)do if selected[n.index]and n.chan==first.chan and n.pitch==first.pitch and n.s>=p.s and n.e<=p.e then chain[#chain+1]=n end end
      table.sort(chain,function(a,b)return a.s<b.s end)
      if #chain<2 or chain[1]~=first or first.s~=p.s or chain[#chain].e~=p.e or (p.pitch or first.pitch)~=first.pitch then return false,'Include complete adjacent notes of the same pitch and channel to join expression.'end
      for i,n in ipairs(chain)do
        if used[n.index]or n.muted~=first.muted or life(n)~=n.e or i>1 and chain[i-1].e~=n.s then return false,'Joining requires adjacent voices with matching mute state and no sustained tail.'end
        for _,other in ipairs(stream.notes)do if other~=n and other.chan==n.chan and other.s<n.e and life(other)>n.s then return false,'Another voice shares this expression channel.'end end
        used[n.index]=true
      end
      end
    end
  end
  for index in pairs(protected)do if not used[index]then return false,'The edit would split or discard part of an expression voice.'end end
  return true,boundaries.curve_split and 'Slide split: pitch data retained on each note fragment. Edit it as a pitch curve.'or nil,boundaries
end
return M
