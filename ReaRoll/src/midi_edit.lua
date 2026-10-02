-- @noindex
local Notes=require 'src.note_events'
local Edit={}; Edit.__index=Edit
function Edit.new(cache,selection,cc_cache)
  local self=setmetatable({cache=cache,selection=selection,cc_cache=cc_cache,active=nil},Edit)
  cache.edit=self; return self
end
function Edit:begin(name,take,preview)
  -- Never let a new user action silently join a stale transaction. This is
  -- especially destructive for repeated note/chord stamps because one Undo
  -- would otherwise remove every edit accumulated in the shared block.
  if self.active then self:finish() end
  local stream=assert(Notes.read(take),'ReaRoll could not read the MIDI events.')
  if not preview then reaper.Undo_BeginBlock2(0) end
  reaper.MIDI_DisableSort(take)
  self.active={name=name,take=take,preview=preview,changed=false,note_changed=false,stream=stream,notes=stream.notes,touched={}}
end
function Edit:begin_preview(take) self:begin(nil,take,true) end
function Edit:note_count(take)
  if self.active and self.active.take==take then return #self.active.notes end
  return #self.cache:get(false)
end
function Edit:touch() if self.active then self.active.changed=true end end
function Edit:set_properties(take,index,values)
  local a=self.active; if not a or a.take~=take then return false end
  local n=a.notes[index+1]; if not n then return false end
  local geometry=false
  for _,key in ipairs({'s','e','pitch','chan'}) do if values[key]~=nil and values[key]~=n[key] then geometry=true end end
  if not a.stream:set(index,values) then return false end
  if geometry then a.touched[index]=true end
  a.changed,a.note_changed=true,true; return true
end
local function enforce_note_policy(self,a)
  local app=self.app; if not app or not a.note_changed then return end
  local item_s=reaper.MIDI_GetPPQPosFromProjQN(a.take,app.item_start_qn); local item_e=reaper.MIDI_GetPPQPosFromProjQN(a.take,app.item_end_qn)
  for index in pairs(a.touched) do local n=a.notes[index+1]; if n then
    local ns=math.max(item_s,math.min(n.s,item_e-1)); local ne=math.max(ns+1,math.min(n.e,item_e))
    if ns~=n.s or ne~=n.e then a.stream:set(index,{s=ns,e=ne}); a.changed=true end
  end end
  if not app.settings.prevent_overlaps then return end
  local groups={}; for _,n in ipairs(a.notes) do local key=n.chan..':'..n.pitch; groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n end
  local deletes,deleted={},{}
  for _,group in pairs(groups) do
    -- The notes changed by this transaction own their new intervals. Resolve
    -- untouched neighbors around them, independent of drag direction.
    for _,winner in ipairs(group) do if a.touched[winner.index] and not deleted[winner.index] then
      for _,neighbor in ipairs(group) do if neighbor~=winner and not a.touched[neighbor.index] and not deleted[neighbor.index] and neighbor.e>winner.s and neighbor.s<winner.e then
        if neighbor.s<winner.s then
          if winner.s>neighbor.s+1 then a.stream:set(neighbor.index,{e=winner.s}); a.changed=true
          else deleted[neighbor.index]=true; deletes[#deletes+1]=neighbor.index end
        elseif neighbor.e>winner.e then
          if neighbor.e>winner.e+1 then a.stream:set(neighbor.index,{s=winner.e}); a.changed=true
          else deleted[neighbor.index]=true; deletes[#deletes+1]=neighbor.index end
        else deleted[neighbor.index]=true; deletes[#deletes+1]=neighbor.index end
      end end
    end
  end
  end
  table.sort(deletes,function(x,y)return x>y end); for _,index in ipairs(deletes) do if a.stream:delete(index) then a.changed=true end end
end
function Edit:flush()
  local a=self.active; if not a or not a.stream.dirty then return end
  assert(a.stream:write(),'ReaRoll could not write the MIDI events.')
end
function Edit:finish()
  if not self.active then return end
  local a=self.active; enforce_note_policy(self,a)
  if a.stream.dirty then self:flush() else reaper.MIDI_Sort(a.take) end
  if not a.preview then reaper.Undo_EndBlock2(0,a.name,a.changed and -1 or 0) end; self.active=nil
  self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end; reaper.UpdateArrange()
end
function Edit:cancel()
  if not self.active then return end
  local a=self.active; self:flush(); reaper.MIDI_Sort(a.take); if not a.preview then reaper.Undo_EndBlock2(0,a.name,0) end; self.active=nil; self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end
end
function Edit:insert(take,s,e,pitch,vel,chan,selected,muted)
  local a=self.active; if not a or a.take~=take then return false end
  local index=a.stream:insert(s,e,pitch,vel,chan,selected,muted)
  a.touched[index]=true; a.changed,a.note_changed=true,true; return true,index
end
function Edit:delete_indices(take,indices)
  local a=self.active; if not a or a.take~=take then return end
  table.sort(indices,function(a,b)return a>b end)
  for _,i in ipairs(indices) do if a.stream:delete(i) then
    local touched={}; for index in pairs(a.touched) do if index<i then touched[index]=true elseif index>i then touched[index-1]=true end end
    a.touched=touched; a.changed,a.note_changed=true,true
  end end
end
function Edit:delete_cc_indices(take,indices)
  table.sort(indices,function(a,b)return a>b end); for _,i in ipairs(indices) do if reaper.MIDI_DeleteCC(take,i) then self:touch() end end
end
function Edit:set(index,take,s,e,pitch,vel)
  return self:set_properties(take,index,{s=s,e=e,pitch=pitch,vel=vel})
end
function Edit:set_muted(take,index,muted)
  return self:set_properties(take,index,{muted=muted})
end
function Edit:insert_cc(take,ppq,chan,cc,value)
  local ok=reaper.MIDI_InsertCC(take,true,false,ppq,0xB0,chan,cc,value); if ok then self:touch() end; return ok
end
function Edit:set_cc(take,index,ppq,value)
  local ok=reaper.MIDI_SetCC(take,index,nil,nil,ppq,nil,nil,nil,value,true); if ok then self:touch() end; return ok
end
function Edit:insert_message(take,ppq,chan,status,value)
  value=math.max(0,math.min(127,math.floor(value+.5))); local ok=reaper.MIDI_InsertCC(take,true,false,ppq,status,chan,value,0); if ok then self:touch() end; return ok
end
function Edit:set_message(take,index,ppq,value)
  value=math.max(0,math.min(127,math.floor(value+.5))); local ok=reaper.MIDI_SetCC(take,index,nil,nil,ppq,nil,nil,value,0,true); if ok then self:touch() end; return ok
end
function Edit:insert_pitch(take,ppq,chan,value)
  value=math.max(0,math.min(16383,math.floor(value+.5))); local lsb=value&0x7F; local msb=(value>>7)&0x7F
  local ok=reaper.MIDI_InsertCC(take,true,false,ppq,0xE0,chan,lsb,msb); if ok then self:touch() end; return ok
end
function Edit:set_pitch(take,index,ppq,value)
  value=math.max(0,math.min(16383,math.floor(value+.5))); local lsb=value&0x7F; local msb=(value>>7)&0x7F
  local ok=reaper.MIDI_SetCC(take,index,nil,nil,ppq,nil,nil,lsb,msb,true); if ok then self:touch() end; return ok
end
return Edit
