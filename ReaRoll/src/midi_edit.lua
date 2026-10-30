-- @noindex
local Notes=require 'src.note_events'
local Edit={}; Edit.__index=Edit
function Edit.new(cache,selection,cc_cache)
  local self=setmetatable({cache=cache,selection=selection,cc_cache=cc_cache,active=nil},Edit)
  cache.edit=self; return self
end
function Edit:begin(name,take,preview)
  -- A new action closes the previous transaction instead of joining it.
  -- Its complete before/after data is captured synchronously at finish.
  if self.active then self:finish() end
  local stream=assert(Notes.read(take),'ReaRoll could not read the MIDI events.')
  local selected={}
  for id,value in pairs(self.selection.ids or {}) do selected[id]=value end
  local pairing_state=Notes.get_pairing_state(take)
  reaper.MIDI_DisableSort(take)
  self.active={name=name,take=take,preview=preview,changed=false,note_changed=false,stream=stream,notes=stream.notes,touched={},original_raw=stream.original_raw,pairing_state=pairing_state,original_selection=selected}
end
function Edit:begin_preview(take) self:begin(nil,take,true) end
function Edit:note_count(take)
  if self.active and self.active.take==take then return #self.active.notes end
  return #self.cache:get(false)
end
function Edit:touch() if self.active then self.active.changed=true end end
function Edit:set_properties(take,index,values)
  local a=self.active; if not a or a.take~=take then return false end
  if a.collecting then
    local target=a.collecting[index]or {};a.collecting[index]=target
    for k,v in pairs(values)do target[k]=v end
    return true
  end
  local n=a.notes[index+1]; if not n then return false end
  if not a.expression_batch and self.app and self.app.settings.cc_follows_notes==true and not(a.drawn_indices and a.drawn_indices[index])and(values.s~=nil or values.e~=nil or values.chan~=nil)then
    return self:set_group(take,{{index=index,values=values}})
  end
  local geometry=false
  for _,key in ipairs({'s','e','pitch','chan'}) do if values[key]~=nil and values[key]~=n[key] then geometry=true end end
  local Links=require 'src.slide_links'
  local expression_settings=not a.stream.overlap_config and self.app and Links.expression_settings(n,self.app.settings)
  if geometry and self.app and not self.app.settings.mpe_enabled and not a.expression_batch and((values.s or n.s)~=n.s or(values.e or n.e)~=n.e or(values.chan or n.chan)~=n.chan)then
    for _,reference in ipairs(a.notes)do local first,last=Links.domain(reference);if reference~=n and Links.has(reference)and reference.chan==n.chan and first<n.e and last>n.s then
      local target={s=values.s or n.s,e=values.e or n.e,chan=values.chan or n.chan}
      if not require('src.shared_slide').within(reference,target)then self.app.expression_notice='Keep this note within its shared-slide reference, or move the complete group.';a.expression_failed=true;return false end
    end end
  end
  if geometry and expression_settings then
    local linked,stale=Links.records(a.stream,n)
    if not self.app.settings.mpe_enabled and stale>0 then self.app.expression_notice='Pitch expression changed outside its slide links. Edit or redraw the target before moving this source note.';a.expression_failed=true;return false end
    local valid={};for _,record in ipairs(linked)do if record.valid then valid[#valid+1]=record end end;linked=valid
    if not a.preserve_source_bounds then
      local first=reaper.MIDI_GetPPQPosFromProjQN(a.take,self.app.item_start_qn)
      local last=reaper.MIDI_GetPPQPosFromProjQN(a.take,self.app.item_end_qn)
      values.s=math.floor(math.max(first,math.min(values.s or n.s,last-1))+.5)
      values.e=math.floor(math.max(values.s+1,math.min(values.e or n.e,last))+.5)
    end
    local drawing=a.drawn_indices and a.drawn_indices[index]
    if drawing then
      local channel,notice=require('src.mpe_assign').draw_channel(a.stream,n,values.s or n.s,values.e or n.e,expression_settings)
      if channel==nil then self.app.expression_notice=notice;return false end
      values.chan=channel
    end
    local ok,notice=require('src.expression').follow(a.stream,n,values,expression_settings,a.expression_batch)
    self.app.expression_notice=notice
    if not ok then if not drawing then a.expression_failed=true end;return false end
    Links.remap(n,linked,values,a.expression_batch and a.expression_batch.domains[n.index])
  end
  if values.muted~=nil and values.muted~=n.muted then for _,r in ipairs(Links.snapshot(a.stream,n))do for _,event in ipairs(r.refs)do event.flags=((event.flags or 0)&~2)|(values.muted and 2 or 0)end end end
  if not a.stream:set(index,values) then return false end
  if geometry then a.touched[index]=true end
  a.changed,a.note_changed=true,true; return true
end
local function copy_table(value,seen)
  if type(value)~='table'then return value end
  seen=seen or {};if seen[value]then return seen[value]end
  local out={};seen[value]=out
  for k,v in pairs(value)do out[copy_table(k,seen)]=copy_table(v,seen)end
  return setmetatable(out,getmetatable(value))
end
-- Resize the whole new chord atomically. A temporarily unavailable length
-- keeps the last valid draft, rather than poisoning and cancelling the insert.
function Edit:resize_draw(take,indices,ending)
  local a=self.active;if not a or a.take~=take then return false end
  local snapshot=#indices>1 and copy_table(a.stream)
  local touched=snapshot and copy_table(a.touched)
  local changed,note_changed,failed=a.changed,a.note_changed,a.expression_failed
  for _,index in ipairs(indices)do if not self:set_properties(take,index,{e=ending})then
    if snapshot then a.stream=snapshot;a.notes=snapshot.notes;a.touched=touched end
    a.changed,a.note_changed,a.expression_failed=changed,note_changed,failed
    return false
  end end
  return true
end
function Edit:structural_guard(indices,plans)
  local active=self.active;if not active then return false end
  local ok,notice,boundaries=require('src.expression_structure').validate(active.stream,indices,plans,self.app and self.app.settings or {})
  if self.app then self.app.expression_notice=notice end
  if not ok then active.expression_failed=true end
  active.structure_boundaries=ok and boundaries or nil
  if ok and boundaries and boundaries.curve_split and self.app then self.app.settings.note_expression_overlay=true end
  return ok
end
function Edit:begin_group()
  assert(self.active,'A note group needs an edit transaction.')
  self.active.collecting={}
end
function Edit:end_group()
  local a=self.active;if not a or not a.collecting then return false end
  local changes={};for index,values in pairs(a.collecting)do changes[#changes+1]={index=index,values=values}end
  a.collecting=nil;table.sort(changes,function(x,y)return x.index<y.index end)
  return self:set_group(a.take,changes)
end
function Edit:check_group_source()
  local a=self.active;if not a then return false end
  local valid=not reaper.ValidatePtr2 or reaper.ValidatePtr2(0,a.take,'MediaItem_Take*')
  local ok,raw;if valid then ok,raw=reaper.MIDI_GetAllEvts(a.take,'')end
  if not ok or raw~=(a.expected_raw or a.original_raw)then
    self.active=nil;self.cache:invalidate();if self.cc_cache then self.cc_cache:invalidate()end
    if self.app then self.app.gesture=nil;self.app.expression_notice='The MIDI changed outside this drag. That edit was preserved.'end
    return false
  end
  return true
end
function Edit:set_group(take,changes,reset)
  local a=self.active;if not a or a.take~=take then return false end
  if reset then
    if not self:check_group_source()then return false end
    if not a.group_baseline then a.group_baseline=copy_table(a.stream);a.group_initial={changed=a.changed,note_changed=a.note_changed,touched=copy_table(a.touched)}end
    a.stream=copy_table(a.group_baseline);a.stream.dirty=true;a.notes=a.stream.notes
    a.changed=a.group_initial.changed;a.note_changed=a.group_initial.note_changed;a.touched=copy_table(a.group_initial.touched)
  end
  a.expression_failed=nil
  local batch={owned={},destinations={},copies={},metadata={},originals={},groups={},domains={}};local E=require 'src.expression';local Links=require 'src.slide_links'
  local linked_references={}
  if self.app and not self.app.settings.mpe_enabled then for _,n in ipairs(a.notes)do if Links.has(n)then linked_references[#linked_references+1]=n end end end
  local lifetime=require('src.voice_lifetime').index(a.stream,self.app and self.app.settings)
  for _,note in ipairs(a.notes)do batch.originals[note.index]={s=note.s,e=note.e,sounding_end=lifetime(note),chan=note.chan}end
  for _,change in ipairs(changes)do local note=a.notes[change.index+1];if not note then a.expression_failed=true;return false end
    local values=change.values
    local settings=not a.stream.overlap_config and self.app and Links.expression_settings(note,self.app.settings)
    if settings and not a.preserve_source_bounds then
      local first=reaper.MIDI_GetPPQPosFromProjQN(take,self.app.item_start_qn);local last=reaper.MIDI_GetPPQPosFromProjQN(take,self.app.item_end_qn)
      values.s=math.floor(math.max(first,math.min(values.s or note.s,last-1))+.5)
      values.e=math.floor(math.max(values.s+1,math.min(values.e or note.e,last))+.5)
    end
    batch.destinations[change.index]={s=math.floor((values.s or note.s)+.5),e=math.floor((values.e or note.e)+.5),chan=values.chan or note.chan}
    local destination=batch.destinations[change.index]
    if destination.s==note.s and destination.e==note.e and destination.chan==note.chan then destination.sounding_end=batch.originals[note.index].sounding_end end
  end
  for _,change in ipairs(changes)do
    local note=a.notes[change.index+1];local destination=batch.destinations[note.index]
    local settings=not a.stream.overlap_config and self.app and Links.expression_settings(note,self.app.settings)
    if self.app and not self.app.settings.mpe_enabled and(destination.s~=note.s or destination.e~=note.e or destination.chan~=note.chan)then
      for _,reference in ipairs(linked_references)do local first,last=Links.domain(reference);if reference~=note and reference.chan==note.chan and first<note.e and last>note.s then
        local together=batch.destinations[reference.index]
        if not(together and require('src.shared_slide').mapped(reference,together,note,destination)or not together and require('src.shared_slide').within(reference,destination))then
          self.app.expression_notice='Move or resize every note in this shared-channel slide chord together.';a.expression_failed=true;return false
        end
      end end
    end
    if settings and not self.app.settings.mpe_enabled and Links.has(note)and(destination.s~=note.s or destination.e~=note.e or destination.chan~=note.chan)then
      local selected={};for index in pairs(batch.destinations)do selected[index]=true end
      local cohort,notice=Links.cohort(a.stream,note,selected)
      if not cohort then self.app.expression_notice=notice;a.expression_failed=true;return false end
      for index in pairs(cohort)do
        if not require('src.shared_slide').mapped(note,destination,a.notes[index+1],batch.destinations[index])then
          self.app.expression_notice='Move or scale the entire shared-channel slide group together, preserving relative timing.';a.expression_failed=true;return false
        end
      end
      if next(cohort)then
        batch.groups[note.index]=cohort
        local first,last=Links.domain(note)
        if first~=note.s or last~=note.e then
          local ns,ne=destination.s,destination.e
          for index in pairs(cohort)do local target=batch.destinations[index];ns=math.min(ns,target.s);ne=math.max(ne,target.e)end
          batch.domains[note.index]={old_s=first,old_e=last,s=ns,e=ne}
          for _,r in ipairs(Links.snapshot(a.stream,note))do
            local start=math.floor(ns+(note.s+r.first*(note.e-note.s)-first)/math.max(1,last-first)*(ne-ns)+.5)
            if not r.structural and(start<destination.s or start>=destination.e-1)then self.app.expression_notice='This resize would move a slide target outside its reference note. Move its target or resize the complete phrase proportionally.';a.expression_failed=true;return false end
          end
        end
      end
    end
    if settings and(destination.s~=note.s or destination.e~=note.e or destination.chan~=note.chan)and not E.release_only(a.stream,note,change.values,settings)then
      local owned,notice=E.capture(a.stream,note,settings,batch.groups[note.index])
      if not owned then self.app.expression_notice=notice;a.expression_failed=true;return false end
      batch.owned[note.index]=owned
    end
  end
  -- Ordinary CCs and shared sustain are assigned once, before voices move.
  local follow,notice=require('src.cc_follow').prepare(a.stream,changes,self.app and self.app.settings,false)
  if follow==false then self.app.expression_notice=notice;a.expression_failed=true;return false end
  if follow then
    local ok,message=require('src.cc_follow').bounds(self.app,follow)
    if not ok then self.app.expression_notice=message;a.expression_failed=true;return false end
    batch.cc_follow=follow
    for index,destination in pairs(batch.destinations)do destination.sounding_end=follow.destinations[index].sounding_end end
    require('src.cc_follow').apply(follow)
  end
  -- Ownership is frozen before any member-channel note or curve moves.
  a.expression_batch=batch
  for _,change in ipairs(changes)do
    local note=a.notes[change.index+1];local values=change.values;local changed=false
    for k,v in pairs(values)do if note[k]~=v then changed=true;break end end
    if changed and not self:set_properties(take,change.index,values)then a.expression_batch=nil;a.expression_failed=true;return false end
  end
  for event in pairs(batch.copies)do
    local retain=false
    for _,note in ipairs(a.notes)do
      -- Use baseline geometry for ownership tests; current notes may be moved.
      local original=batch.originals[note.index]
      if original.chan==(event.msg:byte(1)&15)and(original.s==event.ppq or original.sounding_end==event.ppq)then
        local destination=batch.destinations[note.index]
        if not destination or destination.s==original.s and destination.e==original.e and destination.chan==original.chan then retain=true end
      end
    end
    if not retain then event.deleted=true
      for _,owned in pairs(batch.owned)do for _,entry in ipairs(owned)do if entry.event==event and entry.shape then entry.shape.deleted=true end end end
    end
  end
  if follow then
    if #follow.events>0 then a.changed=true end
    for index,destination in pairs(follow.destinations)do local note=a.notes[index+1];local original=batch.originals[index]
      if destination.s~=original.s or destination.e~=original.e or destination.chan~=original.chan then
        note.on.original_ppq,note.off.original_ppq=note.s,note.e;note.on.order,note.off.order=follow.order_base+note.on.order,follow.order_base+note.off.order
      end
    end
  end
  a.expression_batch=nil;return true
end
local function enforce_note_policy(self,a)
  local app=self.app; if not app or not a.note_changed then return end
  local item_s=reaper.MIDI_GetPPQPosFromProjQN(a.take,app.item_start_qn); local item_e=reaper.MIDI_GetPPQPosFromProjQN(a.take,app.item_end_qn)
  for index in pairs(a.touched) do local n=a.notes[index+1]; if n and not a.preserve_source_bounds then
    local ns=math.max(item_s,math.min(n.s,item_e-1)); local ne=math.max(ns+1,math.min(n.e,item_e))
    if ns~=n.s or ne~=n.e then a.stream:set(index,{s=ns,e=ne}); a.changed=true end
  end end
  if a.stream.overlap_config or a.allow_overlaps or not app.settings.prevent_overlaps then return end
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
function Edit:flush(commit)
  local a=self.active; if not a or a.expression_failed or not a.stream.dirty then return end
  local ok,notice=a.stream:write()
  if not ok then
    if a.stream.overlap_config or a.stream.overlap_error then
      if self.app then self.app.expression_notice=notice end
      -- A held draw/resize can pass through a short or ambiguous overlap before
      -- reaching a valid destination. Keep the draft and last valid playback;
      -- validate strictly on release rather than killing the mouse gesture.
      if not commit and a.stream.overlap_config and self.app and self.app.gesture then
        a.overlap_preview_notice=notice;return false
      end
      self:cancel();return false
    end
    error(notice or 'ReaRoll could not write the MIDI events.')
  end
  if a.overlap_preview_notice and self.app and self.app.expression_notice==a.overlap_preview_notice then self.app.expression_notice=nil end
  a.overlap_preview_notice=nil
  a.expected_raw=select(2,reaper.MIDI_GetAllEvts(a.take,''))
end
function Edit:finish()
  if not self.active then return end
  if self.active.group_baseline and not self:check_group_source()then return false end
  local a=self.active; if a.expression_failed then self:cancel();return false end; enforce_note_policy(self,a)
  if require('src.slide_links').reset_curve_releases(a.stream,a.touched)then a.changed=true end
  if a.stream.dirty then if self:flush(true)==false then return false end elseif not a.stream.overlap_config then reaper.MIDI_Sort(a.take) end
  if not a.preview and a.changed then
    local ok,final_raw=reaper.MIDI_GetAllEvts(a.take,'')
    assert(ok,'ReaRoll could not capture the completed edit.')
    local final_pairs=Notes.get_pairing_state(a.take)
    -- Live drags span deferred frames. Rebase the finished edit in one
    -- synchronous undo block so REAPER captures the complete before/after
    -- streams, rather than an intermediate point from the drag.
    assert(reaper.MIDI_SetAllEvts(a.take,a.original_raw),'ReaRoll could not prepare the undo snapshot.')
    assert(Notes.set_pairing_state(a.take,a.pairing_state),'ReaRoll could not prepare note pairing metadata.')
    reaper.Undo_BeginBlock2(0)
    a.undo_open=true
    local committed,err=xpcall(function()
      assert(reaper.MIDI_SetAllEvts(a.take,final_raw),'ReaRoll could not commit MIDI events.')
      assert(Notes.set_pairing_state(a.take,final_pairs),'ReaRoll could not commit note pairing metadata.')
    end,debug.traceback)
    if not committed then
      reaper.MIDI_SetAllEvts(a.take,a.original_raw); Notes.set_pairing_state(a.take,a.pairing_state)
    end
    reaper.Undo_EndBlock2(0,a.name,committed and -1 or 0); a.undo_open=false
    if not committed then error(err) end
  end
  self.active=nil
  self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end; reaper.UpdateArrange()
end
function Edit:cancel()
  if not self.active then return false end
  if self.active.group_baseline and not self:check_group_source()then return false end
  local a=self.active
  local valid=not reaper.ValidatePtr2 or reaper.ValidatePtr2(0,a.take,'MediaItem_Take*')
  if valid then
    -- Release DisableSort before restoring the exact snapshot. Sorting after
    -- restoration could reorder same-position events and alter note pairing.
    reaper.MIDI_Sort(a.take)
    assert(reaper.MIDI_SetAllEvts(a.take,a.original_raw),'ReaRoll could not restore cancelled MIDI edits.')
    assert(Notes.set_pairing_state(a.take,a.pairing_state),'ReaRoll could not restore note pairing metadata.')
    if self.selection.ids then self.selection.ids=a.original_selection end
  end
  if a.undo_open then reaper.Undo_EndBlock2(0,a.name,0) end
  self.active=nil
  self.cache:invalidate(); if self.cc_cache then self.cc_cache:invalidate() end
  reaper.UpdateArrange()
  return valid
end
function Edit:insert(take,s,e,pitch,vel,chan,selected,muted)
  local a=self.active; if not a or a.take~=take then return false end
  local index=a.stream:insert(s,e,pitch,vel,chan,selected,muted)
  a.touched[index]=true; a.changed,a.note_changed=true,true; return true,index
end
-- Preserve raw note payload and notation through structural replacement.
-- Capture sources before deletion: deleting a note renumbers the live array.
function Edit:replace_notes(take,indices,plans)
  local a=self.active;if not a or a.take~=take then return false end
  for _,plan in ipairs(plans)do
    plan.s,plan.e=math.floor(plan.s+.5),math.floor(plan.e+.5)
    if plan.e<=plan.s then if self.app then self.app.expression_notice='Every note fragment must be at least one MIDI tick long.'end;return false end
  end
  if not self:structural_guard(indices,plans)then return false end
  local sources={};for _,index in ipairs(indices)do sources[index]=a.notes[index+1]end
  for _,plan in ipairs(plans)do if not sources[plan.source_index]then return false end end
  self:delete_indices(take,indices,true)
  require('src.expression_structure').add_boundaries(a.stream,a.structure_boundaries)
  for _,plan in ipairs(plans)do
    local source=sources[plan.source_index]
    local index=a.stream:insert_fragment(source,plan.s,plan.e,plan.pitch or source.pitch)
    local note=a.notes[index+1]
    local ending=sources[plan.end_index]or source
    note.off.flags=ending.off.flags
    note.on.order,note.off.order=source.on.order,ending.off.order
    note.off.msg=ending.off.msg:sub(1,1)..string.char(note.pitch)..ending.off.msg:sub(3)
    require('src.expression_structure').decorate(a.stream,note,plan.source_index,a.structure_boundaries)
    a.stream:set(index,{selected=true})
    a.touched[index]=true;a.changed,a.note_changed=true,true
  end
  return true
end
function Edit:insert_draw(take,s,e,pitch,vel,chan,selected,muted,voice_channel)
  local a=self.active;if not a or a.take~=take then return false end
  if self.app then self.app.expression_notice=nil end
  local setup=self.app and self.app.settings;local base=a.stream.overlap_config
  local Setup=require 'src.glide_setup'
  if base and setup then setup=Setup.drawing(a.notes,base,setup)end
  if setup and setup.mpe_enabled then
    local channel,notice=voice_channel or nil
    if a.stream.overlap_config and voice_channel==nil then
      local selected_indices={}
      for _,note in ipairs(self.cache.notes or {})do
        if a.original_selection[note.id]then selected_indices[note.index]=true end
      end
      channel,notice=require('src.overlap_voice').resolve(Setup.candidates(a.notes,base,setup),s,e,setup,selected_indices,pitch)
      if notice then self.app.expression_notice=notice;a.expression_failed=true;return false end
    end
    if not channel then channel,notice=require('src.mpe_assign').new_channel(a.stream,s,e,setup,chan)end
    if channel==nil then self.app.expression_notice=notice;a.expression_failed=true;return false end
    chan=channel
  end
  local source_setup=base and setup and Setup.source(a.notes,base,setup,chan,s)
  local ok,index=self:insert(take,s,e,pitch,vel,chan,selected,muted)
  if ok and base and setup then
    local owned=source_setup or setup
    if not Setup.same(owned,base)then Setup.set(a.stream,a.notes[index+1],owned)end
  end
  if ok and not a.stream.overlap_config and self.app and self.app.settings.mpe_enabled then
    require('src.mpe_assign').initialize(a.stream,a.notes[index+1])
    a.drawn_indices=a.drawn_indices or {};a.drawn_indices[index]=true
  end
  return ok,index,chan
end
function Edit:insert_draw_chord(take,s,e,pitches,vel,chan,selected,muted)
  local a=self.active;if not a or a.take~=take then return false end
  local mapping
  if a.stream.overlap_config and self.app then
    local Setup=require 'src.glide_setup';local setup=Setup.drawing(a.notes,a.stream.overlap_config,self.app.settings)
    if setup.mpe_enabled then mapping=require('src.overlap_voice').chord(Setup.candidates(a.notes,a.stream.overlap_config,setup),s,setup,pitches)end
  end
  local inserted={}
  for i,pitch in ipairs(pitches)do
    local voice_channel
    if mapping then voice_channel=mapping[i];if voice_channel==nil then voice_channel=false end end
    local ok,index,channel=self:insert_draw(take,s,e,pitch,vel,chan,selected,muted,voice_channel)
    if not ok then return false,self.app and self.app.expression_notice end
    inserted[#inserted+1]={index=index,chan=channel,pitch=pitch}
  end
  return true,inserted
end
function Edit:delete_indices(take,indices,preserve_expression)
  local a=self.active; if not a or a.take~=take then return end
  local removed={};for _,index in ipairs(indices)do removed[index]=true end
  local follow
  if not preserve_expression and self.app and self.app.settings.cc_follows_notes==true then
    local changes={};for _,index in ipairs(indices)do changes[#changes+1]={index=index,values={}}end
    follow=require('src.cc_follow').prepare(a.stream,changes,self.app.settings,true)
    if follow==false then self.app.expression_notice='The selected controller/voice context could not be read.';a.expression_failed=true;return false end
  end
  if not preserve_expression and self.app then
    local Links=require 'src.slide_links';local E=require 'src.expression'
    for _,reference in ipairs(a.notes)do if Links.has(reference)and(not self.app.settings.mpe_enabled or not E.member(reference.chan,self.app.settings))then
      local touched=removed[reference.index];local complete=removed[reference.index]
      local first,last=Links.domain(reference)
      for _,other in ipairs(a.notes)do if other~=reference and other.chan==reference.chan and other.s<last and other.e>first then touched=touched or removed[other.index];complete=complete and removed[other.index]end end
      if removed[reference.index]and not complete then self.app.expression_notice='Delete the complete shared-channel slide chord, or remove its slide target first.';a.expression_failed=true;return false end
    end end
  end
  if not preserve_expression and not a.stream.overlap_config and self.app and self.app.settings.mpe_enabled then
    -- Validate the whole deletion first, before changing shared ownership.
    local E=require 'src.expression'
    for _,i in ipairs(indices)do local n=a.notes[i+1];if n then local owned,notice=E.capture(a.stream,n,self.app.settings);if not owned then self.app.expression_notice=notice;a.expression_failed=true;return false end end end
    for _,i in ipairs(indices)do local n=a.notes[i+1];if n then
      if E.member(n.chan,self.app.settings)then E.remove(a.stream,n,self.app.settings)else require('src.slide_links').remove_owned(a.stream,n,removed)end
    end end
  end
  if not preserve_expression and self.app and not self.app.settings.mpe_enabled then for _,index in ipairs(indices)do local n=a.notes[index+1];if n then local ok,notice=require('src.slide_links').remove_owned(a.stream,n,removed);if ok==false then self.app.expression_notice=notice;a.expression_failed=true;return false end end end end
  for _,entry in ipairs(follow and follow.events or {})do entry.event.deleted=true;if entry.shape then entry.shape.deleted=true end;a.stream.dirty=true end
  table.sort(indices,function(a,b)return a>b end)
  for _,i in ipairs(indices) do if a.stream:delete(i) then
    local touched={}; for index in pairs(a.touched) do if index<i then touched[index]=true elseif index>i then touched[index-1]=true end end
    a.touched=touched; a.changed,a.note_changed=true,true
  end end
end
function Edit:delete_cc_indices(take,indices)
  if self.active and self.active.stream.overlap_config then for _,index in ipairs(indices)do require('src.overlap_controllers').edit(self,index,nil,nil,'delete')end;return end
  table.sort(indices,function(a,b)return a>b end); for _,i in ipairs(indices) do if reaper.MIDI_DeleteCC(take,i) then self:touch() end end
end
function Edit:set(index,take,s,e,pitch,vel)
  return self:set_properties(take,index,{s=s,e=e,pitch=pitch,vel=vel})
end
function Edit:set_muted(take,index,muted)
  return self:set_properties(take,index,{muted=muted})
end
function Edit:insert_cc(take,ppq,chan,cc,value)
  local overlap=require('src.overlap_controllers').edit(self,nil,ppq,string.char(176|chan,cc,value));if overlap~=nil then return overlap end
  local ok=reaper.MIDI_InsertCC(take,true,false,ppq,0xB0,chan,cc,value); if ok then self:touch() end; return ok
end
function Edit:set_cc(take,index,ppq,value)
  local overlap=require('src.overlap_controllers').edit(self,index,ppq,nil,'cc',value);if overlap~=nil then return overlap end
  local ok=reaper.MIDI_SetCC(take,index,nil,nil,ppq,nil,nil,nil,value,true); if ok then self:touch() end; return ok
end
function Edit:insert_message(take,ppq,chan,status,value)
  local overlap=require('src.overlap_controllers').edit(self,nil,ppq,string.char(status|chan,math.max(0,math.min(127,math.floor(value+.5))),0));if overlap~=nil then return overlap end
  value=math.max(0,math.min(127,math.floor(value+.5))); local ok=reaper.MIDI_InsertCC(take,true,false,ppq,status,chan,value,0); if ok then self:touch() end; return ok
end
function Edit:set_message(take,index,ppq,value)
  local overlap=require('src.overlap_controllers').edit(self,index,ppq,nil,'message',math.max(0,math.min(127,math.floor(value+.5))));if overlap~=nil then return overlap end
  value=math.max(0,math.min(127,math.floor(value+.5))); local ok=reaper.MIDI_SetCC(take,index,nil,nil,ppq,nil,nil,value,0,true); if ok then self:touch() end; return ok
end
function Edit:insert_pitch(take,ppq,chan,value)
  local overlap=require('src.overlap_controllers').edit(self,nil,ppq,string.char(224|chan,value&127,(value>>7)&127));if overlap~=nil then return overlap end
  value=math.max(0,math.min(16383,math.floor(value+.5))); local lsb=value&0x7F; local msb=(value>>7)&0x7F
  local ok=reaper.MIDI_InsertCC(take,true,false,ppq,0xE0,chan,lsb,msb); if ok then self:touch() end; return ok
end
function Edit:set_pitch(take,index,ppq,value)
  local overlap=require('src.overlap_controllers').edit(self,index,ppq,nil,'pitch',value);if overlap~=nil then return overlap end
  value=math.max(0,math.min(16383,math.floor(value+.5))); local lsb=value&0x7F; local msb=(value>>7)&0x7F
  local ok=reaper.MIDI_SetCC(take,index,nil,nil,ppq,nil,nil,lsb,msb,true); if ok then self:touch() end; return ok
end
return Edit
