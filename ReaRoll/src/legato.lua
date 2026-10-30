-- @noindex
local M={}
-- Each MIDI channel is a separate voice domain. Chord notes share the next
-- strictly later onset; simultaneous notes never connect to each other.
function M.targets(notes,all_pitches,offset,limit)
  local groups,out={},{}
  for _,n in ipairs(notes)do
    local key=tostring(n.chan or 0)..':'..(all_pitches and '*' or tostring(n.pitch))
    groups[key]=groups[key] or {};groups[key][#groups[key]+1]=n
  end
  for _,group in pairs(groups)do
    table.sort(group,function(a,b)if a.s~=b.s then return a.s<b.s end;return a.index<b.index end)
    for i,n in ipairs(group)do
      for j=i+1,#group do if group[j].s>n.s then
        out[#out+1]={note=n,ending=math.max(n.s+1,math.min(limit,group[j].s+(offset or 0)))};break
      end end
    end
  end
  return out
end
return M
