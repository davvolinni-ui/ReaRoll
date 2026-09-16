-- @noindex
local Edit={}; Edit.__index=Edit
function Edit.new(cache,selection,cc_cache) return setmetatable({cache=cache,selection=selection,cc_cache=cc_cache,active=nil},Edit) end
local function clone_note(n) return {index=n.index,s=n.s,e=n.e,chan=n.chan or 0,pitch=n.pitch,vel=n.vel,muted=n.muted,selected=n.selected} end
function Edit:begin(name,take)
  -- Never let a new user action silently join a stale transaction. This is
  -- especially destructive for repeated note/chord stamps because one Undo
  -- would otherwise remove every edit accumulated in the shared block.
  if self.active then self:finish() end
  local notes={}; for _,n in ipairs(self.cache.notes or {}) do notes[n.index]=clone_note(n) end
  reaper.Undo_BeginBlock2(0); reaper.MIDI_DisableSort(take); self.active={name=name,take=take,changed=false,note_changed=false,notes=notes,touched={}}
end
function Edit:touch() if self.active then self.active.changed=true end end
function Edit:track_note(index,values)
  local a=self.active; if not a or index==nil then return end
  local n=a.notes[index]; if not n then return end
  for key,value in pairs(values or {}) do if value~=nil then n[key]=value end end
  a.touched[index]=true; a.note_changed=true
end
local function enforce_note_policy(self,a)
  local app=self.app; if not app or not a.note_changed then return end
  local item_s=reaper.MIDI_GetPPQPosFromProjQN(a.take,app.item_start_qn); local item_e=reaper.MIDI_GetPPQPosFromProjQN(a.take,app.item_end_qn)
  for index in pairs(a.touched) do local n=a.notes[index]; if n then
    local ns=math.max(item_s,math.min(n.s,item_e-1)); local ne=math.max(ns+1,math.min(n.e,item_e))
    if ns~=n.s or ne~=n.e then reaper.MIDI_SetNote(a.take,index,nil,nil,ns,ne,nil,nil,nil,true); n.s,n.e=ns,ne; a.changed=true end
  end end
  if not app.settings.prevent_overlaps then return end
  local groups={}; for _,n in pairs(a.notes) do local key=n.chan..':'..n.pitch; groups[key]=groups[key] or {}; groups[key][#groups[key]+1]=n end
  local deletes,deleted={},{}
  for _,group in pairs(groups) do
    -- The notes changed by this transaction own their new intervals. Resolve
    -- untouched neighbors around them, independent of drag direction.
    for _,winner in ipairs(group) do if a.touched[winner.index] and not deleted[winner.index] then
      for _,neighbor in ipairs(group) do if neighbor~=winner and not a.touched[neighbor.index] and not deleted[neighbor.index] and neighbor.e>winner.s and neighbor.s<winner.e then
        if neighbor.s<winner.s then
          if winner.s>neighbor.s+1 then reaper.MIDI_SetNote(a.take,neighbor.index,nil,nil,nil,winner.s,nil,nil,nil,true); neighbor.e=winner.s; a.changed=true
          else deleted[neighbor.index]=true; deletes[#deletes+1]=neighbor.index end
        elseif neighbor.e>winner.e then
          if neighbor.e>winner.e+1 then reaper.MIDI_SetNote(a.take,neighbor.index,nil,nil,winner.e,nil,nil,nil,nil,true); neighbor.s=winner.e; a.changed=true
          else deleted[neighbor.index]=true; deletes[#deletes+1]=neighbor.index end
        else deleted[neighbor.index]=true; deletes[#deletes+1]=neighbor.index end
      end end
    end
  end
  end
  table.sort(deletes,function(x,y)return x>y end); for _,index in ipairs(deletes) do if reaper.MIDI_DeleteNote(a.take,index) then a.changed=true end end
end
function Edit:finish()
  if not self.active then return end
  local a=self.active; enforce_note_policy(self,a); reaper.MIDI_Sort(a.take)
  reaper.Undo_EndBlock2(0,a.name,a.changed and -1 or 0); self.active=nil
  self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end; reaper.UpdateArrange()
end
function Edit:cancel()
  if not self.active then return end
  local a=self.active; reaper.MIDI_Sort(a.take); reaper.Undo_EndBlock2(0,a.name,0); self.active=nil; self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end
end
function Edit:insert(take,s,e,pitch,vel,chan,selected,muted)
  local _,index=reaper.MIDI_CountEvts(take); local ok=reaper.MIDI_InsertNote(take,selected~=false,muted or false,s,e,chan or 0,pitch,vel,self.active~=nil)
  if ok then self:touch(); if self.active then self.active.notes[index]={index=index,s=s,e=e,chan=chan or 0,pitch=pitch,vel=vel,muted=muted or false,selected=selected~=false}; self.active.touched[index]=true; self.active.note_changed=true end end; return ok
end
function Edit:delete_indices(take,indices)
  table.sort(indices,function(a,b)return a>b end)
  for _,i in ipairs(indices) do if reaper.MIDI_DeleteNote(take,i) then
    self:touch(); local a=self.active; if a then local notes,touched={},{}; for index,n in pairs(a.notes) do if index<i then notes[index]=n; if a.touched[index] then touched[index]=true end elseif index>i then n.index=index-1; notes[index-1]=n; if a.touched[index] then touched[index-1]=true end end end; a.notes,a.touched=notes,touched; a.note_changed=true end
  end end
end
function Edit:delete_cc_indices(take,indices)
  table.sort(indices,function(a,b)return a>b end); for _,i in ipairs(indices) do if reaper.MIDI_DeleteCC(take,i) then self:touch() end end
end
function Edit:set(index,take,s,e,pitch,vel)
  local ok=reaper.MIDI_SetNote(take,index,nil,nil,s,e,nil,pitch,vel,true); if ok then self:touch(); self:track_note(index,{s=s,e=e,pitch=pitch,vel=vel}) end; return ok
end
function Edit:set_muted(take,index,muted)
  local ok=reaper.MIDI_SetNote(take,index,nil,muted,nil,nil,nil,nil,nil,true); if ok then self:touch(); self:track_note(index,{muted=muted}) end; return ok
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
