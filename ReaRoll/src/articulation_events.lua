-- @noindex
local M={prefix=string.char(255,1)..'REAROLL_ART1\t'}
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)if #s%2~=0 or s:find('[^%da-f]')then return end;return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
function M.marker(entry,p,anchor)
 local events={}
 local function add(offset,msg)events[#events+1]=offset..':'..hex(msg)end
 if entry.bank_msb~=nil then add(0,string.char(0xB0|p.channel,0,entry.bank_msb));add(0,string.char(0xB0|p.channel,32,entry.bank_lsb))end
 if entry.kind=='note'then add(0,string.char(0x90|p.channel,entry.number,entry.value));add(p.e-p.s,string.char(0x80|p.channel,entry.number,0))
 else add(0,entry.kind=='cc'and string.char(0xB0|p.channel,entry.number,entry.value)or string.char(0xC0|p.channel,entry.number))end
 return M.prefix..p.channel..'\t'..hex(entry.name)..'\t'..(anchor-p.s)..'\t'..table.concat(events,',')..'\t'..hex(entry.group or 'Playing style')
end
function M.read(stream)
 local result={}
 for _,e in ipairs(stream.events)do if not e.deleted and e.msg:sub(1,#M.prefix)==M.prefix then
  local channel,name,offset,raw,group=e.msg:sub(#M.prefix+1):match('^(%d+)\t([%da-f]*)\t(%-?%d+)\t([^\t]+)\t?(.*)$')
  if channel and tonumber(channel)<16 then
   local row={event=e,channel=tonumber(channel),name=unhex(name),ppq=e.ppq,anchor=e.ppq+tonumber(offset),outputs={},group=group~=''and unhex(group)or 'Playing style'}
   for delay,message in raw:gmatch('(%-?%d+):([%da-f]+)')do local msg=unhex(message);if msg then row.outputs[#row.outputs+1]={ppq=e.ppq+tonumber(delay),msg=msg}end end
   if row.name and #row.outputs>0 then result[#result+1]=row end
  end
 end end
 table.sort(result,function(a,b)return a.ppq<b.ppq end);return result
end
function M.remove_at(stream,anchors,group)
 local remove={}
 for _,row in ipairs(M.read(stream))do if (not group or row.group==group)and anchors[row.channel] and math.abs(row.anchor-anchors[row.channel])<.5 then
  for _,output in ipairs(row.outputs)do
   local matches={}
   for _,e in ipairs(stream.events)do if not e.deleted and e.ppq==output.ppq and e.msg==output.msg then matches[#matches+1]=e end end
   if #matches~=1 then return false,'This articulation was edited externally. Its MIDI was preserved.'end
   remove[matches[1]]=true
  end
  remove[row.event]=true
 end end
 for i=#stream.notes,1,-1 do local n=stream.notes[i]
  if remove[n.on]or remove[n.off]then if not(remove[n.on]and remove[n.off])then return false,'The keyswitch was edited externally. Its MIDI was preserved.'end end
 end
 for i=#stream.notes,1,-1 do if remove[stream.notes[i].on]then stream:delete(i-1)end end
 for event in pairs(remove)do event.deleted=true;stream.dirty=true end
 return true
end
function M.current(stream,notes,group)
 local rows=M.read(stream);local common;local initialized=false
 for _,note in ipairs(notes)do
  local active
  for _,row in ipairs(rows)do if row.channel==note.chan and row.group==group and row.ppq<=note.s then active=row.name end end
  active=active or 'Unassigned'
  if initialized and active~=common then return 'Mixed' end
  common=active;initialized=true
 end
 return common or 'No notes selected'
end
return M
