-- @noindex
-- Structural edits preserve the channel's existing pitch timeline. One
-- fragment retains the target chain and its complete shared ownership domain.
local M={}
local function key(p)return p.s..':'..p.e end
function M.prepare(stream,selected,plans,settings)
  local out={handled={},fragments={}}
  if not plans then return out end
  local Links=require 'src.slide_links';local Shared=require 'src.shared_slide'
  local life=require('src.voice_lifetime').index(stream,settings)
  for index in pairs(selected)do
    local note=stream.notes[index+1]
    if note and Links.has(note)and not Links.has_curve(note)then
      local parts={};for _,p in ipairs(plans)do if p.source_index==index then parts[#parts+1]=p end end
      table.sort(parts,function(a,b)return a.s<b.s end)
      local members,first,last=Shared.members(stream,note);local shared=false
      for id in pairs(members)do if id~=index then shared=true end end
      local anchor
      if #parts>1 and shared and not settings.mpe_enabled then
        local cursor=note.s
        for _,p in ipairs(parts)do
          if p.s~=cursor or p.e<=p.s or p.e>note.e or(p.pitch or note.pitch)~=note.pitch then return nil,'A slide split must retain the complete note, pitch and channel.'end
          cursor=p.e
        end
        if cursor~=note.e then return nil,'A slide split must retain the complete original duration.'end
        anchor=parts[1]
      else
        for _,p in ipairs(plans)do
          local source=stream.notes[(p.source_index or -1)+1]
          if source and source.chan==note.chan and(p.pitch or source.pitch)==note.pitch and p.s<=note.s and p.e>=note.e and(p.s<note.s or p.e>note.e)then
            local chain={};for id in pairs(selected)do local n=stream.notes[id+1];if n and n.chan==note.chan and n.pitch==note.pitch and n.s>=p.s and n.e<=p.e then chain[#chain+1]=n end end
            table.sort(chain,function(a,b)return a.s<b.s end)
            local cursor=p.s
            for _,n in ipairs(chain)do if n.s~=cursor or n.muted~=source.muted or life(n)~=n.e then return nil,'Join complete adjacent slide notes with matching mute state and released sustain.'end;cursor=n.e end
            if cursor~=p.e then return nil,'Join complete adjacent slide notes without gaps.'end
            anchor=p;break
          end
        end
      end
      if anchor then
        for id in pairs(members)do if life(stream.notes[id+1])~=stream.notes[id+1].e then return nil,'Release the shared sustain before restructuring this slide group.'end end
        local records,stale=Links.records(stream,note)
        if stale>0 or #records==0 then return nil,'The slide pitch data changed externally. Redraw its target before restructuring it.'end
        first,last=math.min(first,anchor.s),math.max(last,anchor.e)
        local target=stream.notes[anchor.source_index+1]
        local decoration=out.fragments[anchor.source_index]or {fragments={},events={},start=target.s}
        out.fragments[anchor.source_index]=decoration
        for _,p in ipairs(parts)do decoration.fragments[key(p)]=decoration.fragments[key(p)]or {}end
        local entries=decoration.fragments[key(anchor)]or {};decoration.fragments[key(anchor)]=entries
        local function relative(f)return(note.s+f*(note.e-note.s)-anchor.s)/(anchor.e-anchor.s)end
        for _,r in ipairs(records)do
          local saved={id=#entries+1,first=relative(r.first),last=relative(r.last),delta=r.delta,range=r.range,linear=r.linear,curve=r.curve,structural=true,domain_first=(first-anchor.s)/(anchor.e-anchor.s),domain_last=(last-anchor.s)/(anchor.e-anchor.s),points={},backup={}}
          for _,p in ipairs(r.points)do saved.points[#saved.points+1]={time=relative(p.time),value=p.value}end
          for _,e in ipairs(r.backup)do saved.backup[#saved.backup+1]={time=relative(e.time),flags=e.flags,msg=e.msg}end
          local msg=Links.encode(target,saved)
          if not Links.decode({msg=msg})then return nil,'This fragment is too short to retain the slide chain. Use a wider cut.'end
          entries[#entries+1]=msg
        end
        out.handled[index]=true
      end
    end
  end
  return out
end
return M
