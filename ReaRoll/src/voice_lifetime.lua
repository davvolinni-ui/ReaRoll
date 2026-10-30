-- @noindex
local M={}
function M.index(stream,settings)
  local master=settings and settings.mpe_zone=='upper'and 15 or 0
  local channels,cache={},{}
  for index,event in ipairs(stream.events)do if not event.deleted and #event.msg>=3 and event.msg:byte(1)>>4==11 then
    local channel,cc=event.msg:byte(1)&15,event.msg:byte(2)
    if cc==64 or cc==120 or cc==121 then
      local list=channels[channel]or {};channels[channel]=list;list[#list+1]={ppq=event.ppq,order=event.order or index,channel=channel,cc=cc,value=event.msg:byte(3)}
    end
  end end
  local function timeline(channel)
    if cache[channel]then return cache[channel]end
    local events={};for _,event in ipairs(channels[channel]or {})do events[#events+1]=event end
    if channel~=master then for _,event in ipairs(channels[master]or {})do events[#events+1]=event end end
    table.sort(events,function(a,b)if a.ppq~=b.ppq then return a.ppq<b.ppq end;return a.order<b.order end)
    local held,rows={},{};local kill=-math.huge
    for _,event in ipairs(events)do
      if event.cc==64 then held[event.channel]=event.value>=64 elseif event.cc==121 then held[event.channel]=false end
      if event.cc==120 then kill=event.ppq end
      local down=false;for _,value in pairs(held)do down=down or value end
      rows[#rows+1]={ppq=event.ppq,order=event.order,held=down,off=event.cc==120,kill=kill}
    end
    local release
    for index=#rows,1,-1 do if rows[index].off or not rows[index].held then release=index end;rows[index].release=release end
    cache[channel]=rows;return rows
  end
  return function(note)
    local rows=timeline(note.chan);local lo,hi=1,#rows;local order=note.off and note.off.order or math.huge
    while lo<=hi do local mid=(lo+hi)//2;local row=rows[mid]
      if row.ppq<note.e or row.ppq==note.e and row.order<=order then lo=mid+1 else hi=mid-1 end
    end
    local row=rows[hi]
    if not row or not row.held or row.kill>=note.s then return note.e end
    local next_row=rows[hi+1];local release=next_row and next_row.release
    return release and rows[release].ppq or math.huge
  end
end
function M.ending(stream,note,settings)return M.index(stream,settings)(note)end
return M
