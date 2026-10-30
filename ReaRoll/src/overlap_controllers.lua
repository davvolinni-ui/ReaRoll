-- @noindex
local M={}
function M.edit(edit,index,ppq,msg,kind,value)
  local a=edit.active
  if not a or not a.stream.overlap_config then return nil end
  local event
  if index~=nil then
    a.overlap_cc_map=a.overlap_cc_map or {}
    event=a.overlap_cc_map[index]
    if not event then
      local pos,time,cc=1,0,-1
      while pos<=#a.original_raw do
        local delta,flags,data,nextpos=string.unpack('i4Bs4',a.original_raw,pos);pos=nextpos;time=time+delta
        local status=#data>0 and data:byte(1)>>4 or 0
        if status>=10 and status<=14 then
          cc=cc+1
          if cc==index then
            for _,candidate in ipairs(a.stream.events)do if candidate.ppq==time and candidate.msg==data then event=candidate;break end end
            break
          end
        end
      end
      if not event then
        if edit.app then edit.app.expression_notice='Generated glide pitch is controlled by the note overlap. Edit the notes instead.'end
        return false
      end
      a.overlap_cc_map[index]=event
    end
  else
    event={ppq=ppq,flags=1,msg=msg,order=#a.stream.events+1};a.stream.events[#a.stream.events+1]=event
  end
  if kind=='delete'then event.deleted=true
  elseif kind=='cc'then event.msg=event.msg:sub(1,2)..string.char(value)
  elseif kind=='message'then event.msg=event.msg:sub(1,1)..string.char(value,0)
  elseif kind=='pitch'then event.msg=event.msg:sub(1,1)..string.char(value&127,(value>>7)&127)end
  if ppq then event.ppq=ppq end
  a.stream.dirty=true;edit:touch();return true
end
return M
