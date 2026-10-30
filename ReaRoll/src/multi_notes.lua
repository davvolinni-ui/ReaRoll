-- @noindex
local Notes=require 'src.note_events';local Take=require 'src.take';local Multi=require 'src.multi_edit'
local M={}
function M.sources(app)
  local out,seen={},{}
  local revision=reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0)
  if not app.multi_pool_cache or app.multi_pool_revision~=revision then
    local counts={}
    if reaper.CountMediaItems and reaper.GetItemStateChunk then for i=0,reaper.CountMediaItems(0)-1 do
      local item=reaper.GetMediaItem(0,i);local ok,chunk=reaper.GetItemStateChunk(item,'',false)
      if ok then for pool in chunk:gmatch('POOLEDEVTS%s+(%b{})')do counts[pool]=(counts[pool] or 0)+1 end end
    end end
    app.multi_pool_cache=counts;app.multi_pool_revision=revision
  end
  local function add(item)
    local take=item and reaper.GetActiveTake(item)
    if not Take.valid(take) or seen[take]then return end;seen[take]=true
    local readonly=reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0
    local reason=readonly and 'Locked item' or nil
    if reaper.GetItemStateChunk then local ok,raw=reaper.GetItemStateChunk(item,'',false);local pool=ok and raw:match('POOLEDEVTS%s+(%b{})');if pool and (app.multi_pool_cache[pool] or 0)>1 then readonly=true;reason='Pooled MIDI: unpool before editing' end end
    local first,last=Take.item_start_qn(take),Take.item_end_qn(take)
    if reaper.GetMediaItemTake_Source and reaper.GetMediaSourceLength then
      local length,qn=reaper.GetMediaSourceLength(reaper.GetMediaItemTake_Source(take))
      local rate=reaper.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE')
      if qn and length>0 and last-first>length/math.max(.000001,rate)+1e-6 then readonly=true;reason='Repeated source: split/unloop before editing' end
    end
    out[#out+1]={take=take,item=item,start_qn=first,end_qn=last,readonly=readonly,reason=reason,name=Take.name(take),rate=reaper.GetMediaItemTakeInfo_Value and reaper.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE'),offset=reaper.GetMediaItemTakeInfo_Value and reaper.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')}
  end
  if app.multi_source_scope=='track' then local track=Take.track(app.take);if track then for i=0,reaper.CountTrackMediaItems(track)-1 do add(reaper.GetTrackMediaItem(track,i))end end
  else for i=0,reaper.CountSelectedMediaItems(0)-1 do add(reaper.GetSelectedMediaItem(0,i))end end
  return out
end
function M.creation_take(app)
 local sources=M.sources(app);local target=app.multi_creation_take;local fallback
 for _,source in ipairs(sources)do if not source.readonly then
  fallback=fallback or source.take
  if source.take==target then return target end
 end end
 for _,source in ipairs(sources)do if source.take==app.take and not source.readonly then fallback=source.take;break end end
 app.multi_creation_take=fallback;return fallback
end
function M.refresh(app,force)
  local state=app.multi_notes or {selection={},cache={}};app.multi_notes=state
  -- A deleted/Undo-replaced source must not survive the refresh throttle.
  -- Its cached notes would otherwise reach source-local PPQ and overlay APIs.
  for _,source in ipairs(state.sources or {})do if not Take.valid(source.take)then
    if state.transaction then M.cancel(app);return app.multi_notes end
    force=true;break
  end end
  if state.transaction then return state end
  if not force and reaper.time_precise()<(state.next_refresh or 0)then return state end
  state.next_refresh=reaper.time_precise()+.12;state.sources=M.sources(app);state.notes={};local present={}
  for _,source in ipairs(state.sources)do
    local _,hash=reaper.MIDI_GetHash(source.take,false,'');local cached=state.cache[source.take]
    if not cached or cached.hash~=hash or force then cached={hash=hash,stream=Notes.read(source.take)};state.cache[source.take]=cached end
    for _,n in ipairs(cached.stream and cached.stream.notes or {})do
      local q,e=reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(source.take,n.e)
      if e>=source.start_qn and q<=source.end_qn then
        local key=tostring(source.take)..':'..n.s..':'..n.pitch..':'..n.chan..':'..n.vel..':'..n.index
        state.notes[#state.notes+1]={key=key,source=source,index=n.index,s=q,e=e,pitch=n.pitch,chan=n.chan,vel=n.vel,muted=n.muted};present[key]=true
      end
    end
  end
  if not app.transform_preview then for key in pairs(state.selection)do if not present[key]then state.selection[key]=nil end end;M.sync(app)end
  return state
end
function M.sync(app)
  local state=app.multi_notes;app.multi_selection_by_take={};app.selection.ids={}
  if not state then return end
  for _,n in ipairs(state.notes or {})do if state.selection[n.key] and not n.source.readonly then
    local ids=app.multi_selection_by_take[n.source.take] or {};app.multi_selection_by_take[n.source.take]=ids;ids[n.index]=true;app.selection.ids[n.key]=true
  end end
end
function M.chosen(app)
  local out,available={},{}
  for _,n in ipairs((app.multi_notes or {}).notes or {})do
    local take=n.source.take
    if available[take]==nil then available[take]=Take.valid(take)end
    if available[take]and app.multi_notes.selection[n.key]and not n.source.readonly then out[#out+1]=n end
  end
  return out
end
function M.begin(app)
  if app.gesture and(app.gesture.kind=='multi_slide'or app.gesture.kind=='multi_slide_targets')then return false,'Finish the slide gesture first.'end
  local state=app.multi_notes;if state.transaction then return true end
  local chosen=M.chosen(app);if #chosen==0 then return false,'Select editable notes first.'end
  local current={};for _,source in ipairs(M.sources(app))do current[source.take]=source end
  for _,n in ipairs(chosen)do local source=current[n.source.take]
    if not source or source.readonly then M.refresh(app,true);return false,source and source.reason or 'The source scope changed. Select the notes again.'end
    if source.start_qn~=n.source.start_qn or source.end_qn~=n.source.end_qn or source.rate~=n.source.rate or source.offset~=n.source.offset then M.refresh(app,true);return false,'Source timing changed. Select the notes again.'end
  end
  local group={entries={},children={},items=chosen,by_take={},revision=reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0)}
  for _,n in ipairs(chosen)do if not group.by_take[n.source.take]then
    local ok,raw=reaper.MIDI_GetAllEvts(n.source.take,'');if not ok then return false,'Could not snapshot a source.'end
    local child=require('src.phrase_scope').child_app(app,n.source.take)
    local entry={take=n.source.take,before_raw=raw,before_pairs=Notes.get_pairing_state(n.source.take),expected_raw=raw,child=child,original_stream=Notes.read(n.source.take),start_qn=Take.item_start_qn(n.source.take),end_qn=Take.item_end_qn(n.source.take),rate=n.source.rate,offset=n.source.offset}
    group.entries[#group.entries+1]=entry;group.by_take[n.source.take]=entry
  end end
  state.transaction=group;return true
end
function M.cancel(app)
  local state=app.multi_notes;local group=state and state.transaction;if not group then return false end
  if state.erase_brush then state.selection=state.erase_brush.before;state.erase_brush=nil end
  if state.mute_brush then state.selection=state.mute_brush.before_selection;state.mute_brush=nil end
  if state.structure_brush then state.selection=state.structure_brush.before_selection;state.structure_brush=nil end
  local ok=Multi.restore(group.entries);state.transaction=nil;state.drag=nil
  if app.gesture and(app.gesture.kind=='source_notes'or app.gesture.kind=='source_erase')then app.gesture=nil;app.audition:stop()end
  M.refresh(app,true);app.cache:invalidate();app.cc_cache:invalidate()
  if not ok then state.notice='An externally changed/removed source was preserved; the other sources were restored.'end
  return ok
end
function M.preview(app,operation,delta,pitch_delta,pitches)
  local state=app.multi_notes;local group=state.transaction
  if not group then local ok,notice=M.begin(app);if not ok then return false,notice end;group=state.transaction end
  local erase_keys=operation=='erase'and delta or nil
  if erase_keys then operation='delete';delta=0 end
  local values=operation=='velocity_values'and delta or nil
  if values then delta=0 end
  local properties=operation=='properties' and delta or nil
  if properties then delta=properties.move or 0;pitch_delta=properties.transpose or 0 end
  delta=delta or 0;pitch_delta=pitch_delta or 0
  local selected_by_take={};for _,n in ipairs(group.items)do selected_by_take[n.source.take]=selected_by_take[n.source.take]or {};selected_by_take[n.source.take][n.index]=true end
  local shared_groups={}
  if operation=='copy'and not app.settings.mpe_enabled then
    for _,entry in ipairs(group.entries)do local ok,notice=require('src.shared_slide').require_complete(entry.original_stream,selected_by_take[entry.take]or {});if not ok then return false,notice end end
  end
  local first,last,low,high=math.huge,-math.huge,127,0
  for _,n in ipairs(group.items)do first=math.min(first,n.s);last=math.max(last,n.e);low=math.min(low,n.pitch);high=math.max(high,n.pitch)end
  if operation=='scale_time'and(type(delta)~='number'or delta<=0 or delta~=delta or delta==math.huge)then return false,'Invalid time scale.'end
  local function geometry(n)
    if operation=='reverse'then return first+last-n.e,first+last-n.s end
    if operation=='scale_time'then return first+(n.s-first)*delta,first+(n.e-first)*delta end
    if operation=='invert'then return n.s,n.e end
    return operation=='resize' and n.s or n.s+delta,operation=='resize_left' and n.e or n.e+delta+(properties and properties.length_delta or 0)
  end
  local controller_delta=operation=='controller'and delta or 0;if operation=='controller'then delta=0 end
  local velocity_delta=operation=='velocity'and delta or 0;if operation=='velocity'then delta=0 end
  local function velocity(n)return values and values[n.key]or properties and properties.velocity or operation=='velocity'and math.max(1,math.min(127,n.vel+velocity_delta))or n.vel end
  if properties and (properties.velocity and (properties.velocity<1 or properties.velocity>127)or properties.channel and(properties.channel<0 or properties.channel>15))then return false,'Invalid velocity or channel.'end
  if operation=='move'or operation=='copy'then
    local low,high=127,0;for _,note in ipairs(group.items)do low=math.min(low,note.pitch);high=math.max(high,note.pitch)end
    pitch_delta=math.max(-low,math.min(127-high,pitch_delta))
  end
  group.pitch_delta=pitch_delta
  local function target_pitch(n)return pitches and pitches[n.key]or math.max(0,math.min(127,n.pitch+pitch_delta))end
  if reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0)~=group.revision then
    for _,source in ipairs(M.sources(app))do if group.by_take[source.take] and source.readonly then
      if source.reason and source.reason:find('Pooled')then group.by_take[source.take].expected_raw=false end
      M.cancel(app);return false,'A source became locked, pooled or repeated during the edit.'
    end end
  end
  for _,entry in ipairs(group.entries)do
    if not Take.valid(entry.take) or reaper.GetMediaItemInfo_Value(Take.item(entry.take),'C_LOCK')~=0 then M.cancel(app);return false,'An edit target was removed or locked.'end
    if math.abs(Take.item_start_qn(entry.take)-entry.start_qn)>1e-8 or math.abs(Take.item_end_qn(entry.take)-entry.end_qn)>1e-8 then M.cancel(app);return false,'A source item moved or changed length during the edit.'end
    if reaper.GetMediaItemTakeInfo_Value and (reaper.GetMediaItemTakeInfo_Value(entry.take,'D_PLAYRATE')~=entry.rate or reaper.GetMediaItemTakeInfo_Value(entry.take,'D_STARTOFFS')~=entry.offset)then M.cancel(app);return false,'A source offset or play rate changed during the edit.'end
    local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'')
    if not ok or raw~=entry.expected_raw then M.cancel(app);return false,'A source changed externally. Its edit was preserved.'end
  end
  for _,n in ipairs(group.items)do
    local first,last=geometry(n)
    if target_pitch(n)<0 or target_pitch(n)>127 then return false,'The pitch would leave the MIDI range.'end
    if operation~='delete' and (first<n.source.start_qn-1e-8 or last>n.source.end_qn+1e-8 or last<=first)then return false,'The selection would extend outside one of its source items.'end
    if operation=='copy' then
      local original=group.by_take[n.source.take].original_stream.notes
      local s=reaper.MIDI_GetPPQPosFromProjQN(n.source.take,first);local e=reaper.MIDI_GetPPQPosFromProjQN(n.source.take,last)
      if app.settings.prevent_overlaps then for _,old in ipairs(original)do if old.pitch==target_pitch(n) and old.chan==n.chan and old.s<e and old.e>s then return false,'The copy overlaps an existing note on the same pitch/channel.'end end end
      local expression_settings=require('src.slide_links').expression_settings(group.by_take[n.source.take].original_stream.notes[n.index+1],app.settings)
      if expression_settings then
        local stream=group.by_take[n.source.take].original_stream
        local E=require 'src.expression'
        local cohort,notice
        if expression_settings.expression_pitch_only then cohort,notice=require('src.slide_links').cohort(stream,stream.notes[n.index+1],selected_by_take[n.source.take]);if not cohort then return false,notice end end
        local owned;owned,notice=E.capture(stream,stream.notes[n.index+1],expression_settings,cohort)
        if not owned then return false,notice end
        if E.member(n.chan,expression_settings)then for _,old in ipairs(original)do if old.chan==n.chan and old.s<e and old.e>s then return false,'The copy would share an MPE member channel with another sounding note.'end end end
      end
    end
  end
  if not Multi.restore(group.entries)then M.cancel(app);return false,'Could not restore the preview snapshots.'end
  local success,failure=xpcall(function()
    for _,entry in ipairs(group.entries)do
      local child=entry.child;child.cache:invalidate();child.edit:begin_preview(entry.take);local deletions={};entry.wanted={}
      local follow
      if operation=='copy'then
        local changes={}
        for _,n in ipairs(group.items)do if n.source.take==entry.take then local sq,eq=geometry(n);changes[#changes+1]={index=n.index,values={s=reaper.MIDI_GetPPQPosFromProjQN(entry.take,sq),e=reaper.MIDI_GetPPQPosFromProjQN(entry.take,eq)}}end end
        local notice;follow,notice=require('src.cc_follow').prepare(child.edit.active.stream,changes,app.settings,true);assert(follow~=false,notice)
        local valid,message=require('src.cc_follow').bounds(child,follow);assert(valid,message)
      end
      if operation~='copy'and operation~='delete'and operation~='validate'and operation~='controller'then child.edit:begin_group()end
      for _,n in ipairs(group.items)do if n.source.take==entry.take then
        if operation=='delete' then if not erase_keys or erase_keys[n.key]then deletions[#deletions+1]=n.index end
        else
          local sq,eq=geometry(n)
          local s=reaper.MIDI_GetPPQPosFromProjQN(entry.take,sq);local e=reaper.MIDI_GetPPQPosFromProjQN(entry.take,eq)
          s,e=math.floor(s+.5),math.floor(e+.5)
          local pitch=operation=='invert'and(low+high-n.pitch)or(operation=='resize' or operation=='resize_left') and n.pitch or target_pitch(n)
          if operation=='copy' then
            local active=child.edit.active;local index;shared_groups[entry.take]=shared_groups[entry.take]or {}
            local effective=require('src.slide_links').expression_settings(active.notes[n.index+1],app.settings)
            if effective then
              local notice,cohort,shared
              if effective.expression_pitch_only then
                cohort,notice=require('src.slide_links').cohort(entry.original_stream,entry.original_stream.notes[n.index+1],selected_by_take[entry.take]);assert(cohort,notice)
                shared=shared_groups[entry.take]or {};shared_groups[entry.take]=shared
              end
              index,notice=require('src.expression').duplicate(active.stream,active.notes[n.index+1],s,e,pitch,effective,cohort,shared,follow and follow.voices[n.index]);assert(index,notice)
            else index=active.stream:insert_fragment(active.notes[n.index+1],s,e,pitch);active.stream.notes[index+1].slide_copy_group=shared_groups[entry.take]end
            require('src.cc_follow').copy_note(follow,active.notes[n.index+1],active.notes[index+1])
            active.allow_overlaps=true;active.touched[index]=true;active.changed=true;active.note_changed=true
          elseif operation~='validate'and operation~='controller'then assert(child.edit:set_properties(entry.take,n.index,{s=s,e=e,pitch=pitch,vel=velocity(n),chan=properties and properties.channel,muted=properties and properties.muted}),child.expression_notice or 'A note could not be edited.')end
          if operation=='controller'then
            local lane=require('src.controller_lanes').definition(app.settings)
            assert(not lane.protected and not lane.discrete,'Edit discrete controller messages in their lane.')
            local found
            for _,event in ipairs(child.cc_cache:get(true))do if require('src.controller_lanes').matches(lane,event,n.chan)and math.abs(event.ppq-s)<.5 then found=event;break end end
            local base=lane.pitch and(found and((found.msg3<<7)|found.msg2)or 8192)or(found and(lane.status and found.msg2 or found.msg3)or lane.center or 0)
            local step=lane.pitch and math.max(1,math.floor(8192/math.max(1,app.settings.pitch_bend_range)/100+.5))or 1
            local value=math.max(0,math.min(lane.pitch and 16383 or 127,base+controller_delta*step))
            if found then
              if lane.pitch then child.edit:set_pitch(entry.take,found.index,s,value)elseif lane.status then child.edit:set_message(entry.take,found.index,s,value)else child.edit:set_cc(entry.take,found.index,s,value)end
            elseif lane.pitch then child.edit:insert_pitch(entry.take,s,n.chan,value)elseif lane.status then child.edit:insert_message(entry.take,s,n.chan,lane.status,value)else child.edit:insert_cc(entry.take,s,n.chan,lane.cc,value)end
          end
          entry.wanted[#entry.wanted+1]={take=entry.take,s=reaper.MIDI_GetProjQNFromPPQPos(entry.take,s),pitch=pitch,chan=properties and properties.channel or n.chan,vel=velocity(n)}
        end
      end end
      require('src.cc_follow').apply(follow)
      if child.edit.active.collecting then assert(child.edit:end_group(),child.expression_notice or 'A note group could not be edited.')end
      if #deletions>0 then child.edit:delete_indices(entry.take,deletions)end
      assert(child.edit:finish()~=false,child.expression_notice or 'An expression edit could not be applied.')
      entry.after_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(entry.take)
    end
  end,debug.traceback)
  if not success then
    for _,entry in ipairs(group.entries)do if entry.child.edit.active then pcall(function()entry.child.edit:cancel()end)end
      if Take.valid(entry.take)then entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''))end
    end
    M.cancel(app);return false,failure
  end
  group.revision=reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0)
  app.cache:invalidate();app.cc_cache:invalidate();return true
end
function M.structure(app,operation,argument,options)
  if operation~='mute'and operation~='slice'and operation~='glue'and operation~='chop'then return false,'Unsupported note operation.'end
  -- Reuse the same snapshot, source-lock, timing and external-change validation
  -- as ordinary multi-item edits, without moving any note geometry.
  local ready,notice=M.preview(app,'validate',0,0)
  if not ready then if app.multi_notes.transaction then M.cancel(app)end;return false,notice end
  local group=app.multi_notes.transaction
  local ok,failure=xpcall(function()
    for _,entry in ipairs(group.entries)do
      local child=entry.child;child.edit:begin_preview(entry.take);local active=child.edit.active
      local chosen,cuts={},{};entry.wanted={}
      for _,n in ipairs(group.items)do if n.source.take==entry.take and(not options or not options.keys or options.keys[n.key])then chosen[#chosen+1]=active.stream.notes[n.index+1];cuts[n.index]=options and options.cuts and options.cuts[n.key]end end
      local function wanted(n)entry.wanted[#entry.wanted+1]={take=entry.take,s=reaper.MIDI_GetProjQNFromPPQPos(entry.take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end
      if operation=='mute'then
        for _,n in ipairs(chosen)do if n.muted~=(argument==true)then assert(child.edit:set_muted(entry.take,n.index,argument==true))end;wanted(n)end
      else
        local E=require 'src.expression';local Links=require 'src.slide_links'
        local function safe(n,cut)
          local parts={};local cursor=n.s
          if cut then parts={{s=n.s,e=cut,pitch=n.pitch,source_index=n.index},{s=cut,e=n.e,pitch=n.pitch,source_index=n.index}}
          else
            local q=reaper.MIDI_GetProjQNFromPPQPos(entry.take,n.s);local ending=reaper.MIDI_GetProjQNFromPPQPos(entry.take,n.e);local count=0
            while q+app.settings.grid_qn<ending-1e-9 do
              count=count+1;assert(count<=8192,'The chop would create too many notes.');q=q+app.settings.grid_qn
              local edge=math.floor(reaper.MIDI_GetPPQPosFromProjQN(entry.take,q)+.5)
              if edge>cursor and edge<n.e then parts[#parts+1]={s=cursor,e=edge,pitch=n.pitch,source_index=n.index};cursor=edge end
            end
            parts[#parts+1]={s=cursor,e=n.e,pitch=n.pitch,source_index=n.index}
          end
          local ok,notice,boundaries=require('src.expression_structure').validate(active.stream,{n.index},parts,app.settings)
          assert(ok,notice);if boundaries and boundaries.curve_split then group.curve_split=true end;require('src.expression_structure').add_boundaries(active.stream,boundaries)
          return boundaries
        end
        if operation=='chop'then
          local step=app.settings.grid_qn;assert(type(step)=='number'and step>0,'Choose a valid grid before chopping.')
          for _,n in ipairs(chosen)do
            local start=reaper.MIDI_GetProjQNFromPPQPos(entry.take,n.s);local ending=reaper.MIDI_GetProjQNFromPPQPos(entry.take,n.e)
            if ending-start>step+1e-9 then
              local boundaries=safe(n);local fragments={n};local original_index=n.index;local previous=n.s;local original_end=n.e;local count=0;local previous_note=n
              while start+step<ending-1e-9 do
                count=count+1;assert(count<=8192,'The chop would create too many notes.')
                start=start+step;local cut=math.floor(reaper.MIDI_GetPPQPosFromProjQN(entry.take,start)+.5)
                if cut>previous and cut<original_end then
                  local index=active.stream:insert_fragment(n,cut,original_end,n.pitch);local fragment=active.stream.notes[index+1]
                  active.stream:set(previous_note.index,{e=cut});wanted(previous_note);previous_note=fragment;fragments[#fragments+1]=fragment
                  previous=cut
                end
              end
              for _,fragment in ipairs(fragments)do require('src.expression_structure').decorate(active.stream,fragment,original_index,boundaries)end
              if previous_note~=n then wanted(previous_note)end
              active.changed=true;active.note_changed=true;active.allow_overlaps=true
            else wanted(n)end
          end
        elseif operation=='slice'then
          for _,n in ipairs(chosen)do
            local cut=math.floor(reaper.MIDI_GetPPQPosFromProjQN(entry.take,cuts[n.index]or argument)+.5)
            if cut>n.s and cut<n.e then
              local boundaries=safe(n,cut)
              local index=active.stream:insert_fragment(n,cut,n.e,n.pitch)
              local right=active.stream.notes[index+1]
              active.stream:set(n.index,{e=cut});wanted(right)
              require('src.expression_structure').decorate(active.stream,n,n.index,boundaries)
              require('src.expression_structure').decorate(active.stream,right,n.index,boundaries)
              active.changed=true;active.note_changed=true;active.allow_overlaps=true
            end
            wanted(n)
          end
        else
          table.sort(chosen,function(a,b)if a.chan~=b.chan then return a.chan<b.chan elseif a.pitch~=b.pitch then return a.pitch<b.pitch else return a.s<b.s end end)
          local plans,indices={},{}
          for _,n in ipairs(chosen)do
            indices[#indices+1]=n.index;local last=plans[#plans]
            if last and last.chan==n.chan and last.pitch==n.pitch and math.abs(last.e-n.s)<=1 and(not options or not options.joins or options.joins[entry.take]and options.joins[entry.take][n.index])then last.e=n.e;last.end_index=n.index
            else plans[#plans+1]={s=n.s,e=n.e,pitch=n.pitch,chan=n.chan,source_index=n.index,end_index=n.index}end
          end
          local expression_ok,expression_notice,structure_boundaries=require('src.expression_structure').validate(active.stream,indices,plans,app.settings)
          assert(expression_ok,expression_notice)
          local anchor;local deletions={}
          for _,n in ipairs(chosen)do
            if anchor and anchor.chan==n.chan and anchor.pitch==n.pitch and math.abs(anchor.e-n.s)<=1 and(not options or not options.joins or options.joins[entry.take]and options.joins[entry.take][n.index])then
              active.stream:set(anchor.index,{e=n.e});anchor.off.msg=n.off.msg;anchor.off.flags=n.off.flags;anchor.off.order=n.off.order
              deletions[#deletions+1]=n.index;active.changed=true;active.note_changed=true
            else if anchor then wanted(anchor)end;anchor=n end
          end
          if anchor then wanted(anchor)end
          for _,p in ipairs(plans)do require('src.expression_structure').decorate(active.stream,active.stream.notes[p.source_index+1],p.source_index,structure_boundaries)end
          if #deletions>0 then child.edit:delete_indices(entry.take,deletions,true)end
        end
      end
      entry.operation_changed=child.edit.active.changed
      assert(child.edit:finish()~=false,child.expression_notice or 'The edit was refused.')
      entry.after_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(entry.take)
    end
  end,function(err)return tostring(err)end)
  if not ok then
    for _,entry in ipairs(group.entries)do if entry.child.edit.active then entry.child.edit:cancel()end;if Take.valid(entry.take)then entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''))end end
    M.cancel(app);return false,failure
  end
  if options and options.preview then return true end
  local changed=false;for _,entry in ipairs(group.entries)do changed=changed or entry.operation_changed end
  if not changed then M.cancel(app);return true end
  local committed,reason=M.commit(app,'ReaRoll: '..operation..' notes across MIDI items')
  if committed and group.curve_split then app.settings.note_expression_overlay=true;return true,'Slide split: pitch data retained on each fragment. Edit it as a pitch curve.'end
  return committed,reason
end
function M.action(app,operation,argument)
  if app.gesture or app.transform_preview or app.multi_notes.transaction then return false,'Finish the current edit first.'end
  if operation=='chop'or operation=='glue'then return M.structure(app,operation)end
  if operation=='duplicate'then
    local first,last=math.huge,-math.huge;for _,n in ipairs(M.chosen(app))do first=math.min(first,n.s);last=math.max(last,n.e)end
    if first==math.huge then return false,'Select notes first.'end
    if app.settings.cc_follows_notes==true then
      local ok,notice=M.copy(app);if not ok then return false,notice end
      local low,high=require('src.clipboard').bounds(app.note_clipboard);first=math.min(first,app.note_clipboard.span_start+low);last=math.max(last,app.note_clipboard.span_start+high)
    end
    operation,argument='copy',math.max(app.settings.grid_qn,last-first)
  end
  local ok,notice=M.preview(app,operation,argument or 0,0)
  if not ok then if app.multi_notes.transaction then M.cancel(app)end;return false,notice end
  local changed=false;for _,entry in ipairs(app.multi_notes.transaction.entries)do changed=changed or entry.after_raw~=entry.before_raw or entry.after_pairs~=entry.before_pairs end
  if not changed then M.cancel(app);return true end
  return M.commit(app,'ReaRoll: '..operation..' selected notes')
end
function M.mute_begin(app,hit)
  local state=app.multi_notes
  if not state or state.transaction or state.paint or app.gesture or app.transform_preview or hit.source.readonly then return false,'Finish the current edit and choose an editable note.'end
  local previous={};for key,value in pairs(state.selection)do previous[key]=value end
  local keys={};if state.selection[hit.key]then for key,value in pairs(state.selection)do keys[key]=value end else keys[hit.key]=true end
  -- Freeze every potential source once; subsequent hits only expand the target
  -- set. No per-note Undo blocks are created while the pointer is held.
  state.selection={};for _,n in ipairs(state.notes)do if not n.source.readonly then state.selection[n.key]=true end end;M.sync(app)
  local ok,notice=M.begin(app)
  state.selection={};for key,value in pairs(keys)do state.selection[key]=value end;M.sync(app)
  if not ok then state.selection=previous;M.sync(app);return false,notice end
  state.mute_brush={before_selection=previous,keys=keys,muted=not hit.muted}
  return M.structure(app,'mute',state.mute_brush.muted,{keys=keys,preview=true})
end
function M.mute_add(app,note)
  local state=app.multi_notes;local brush=state and state.mute_brush
  if not brush then return false,'Start a mute gesture first.'end
  if note.source.readonly or brush.keys[note.key]then return true end
  brush.keys[note.key]=true
  return M.structure(app,'mute',brush.muted,{keys=brush.keys,preview=true})
end
function M.mute_finish(app)
  local state=app.multi_notes;local brush=state and state.mute_brush;if not brush then return false end
  local ok,notice=M.commit(app,'ReaRoll: mute brush across MIDI items')
  if ok then state.mute_brush=nil end
  return ok,notice
end
function M.structure_begin(app,kind,x,y)
  local state=app.multi_notes
  if(kind~='slice'and kind~='glue')or not state or state.transaction or state.paint or app.gesture or app.transform_preview then return false,'Finish the current edit first.'end
  local previous={};for key,value in pairs(state.selection)do previous[key]=value end
  state.selection={};for _,n in ipairs(state.notes)do if not n.source.readonly then state.selection[n.key]=true end end;M.sync(app)
  local ok,notice=M.begin(app);state.selection=previous;M.sync(app)
  if not ok then return false,notice end
  state.structure_brush={kind=kind,before_selection=previous,keys={},cuts={},joins={},x=x,y=y,last_x=x,last_y=y}
  return true
end
function M.slice_preview(app,cuts)
  local state=app.multi_notes;local brush=state and state.structure_brush
  if not brush or brush.kind~='slice'then return false,'Start a Slice gesture first.'end
  brush.cuts=cuts;brush.keys={}
  for _,n in ipairs(state.notes)do local q=cuts[n.key]
    if q and not n.source.readonly then
      local cut=math.floor(reaper.MIDI_GetPPQPosFromProjQN(n.source.take,q)+.5)
      if cut>reaper.MIDI_GetPPQPosFromProjQN(n.source.take,n.s)and cut<reaper.MIDI_GetPPQPosFromProjQN(n.source.take,n.e)then brush.keys[n.key]=true end
    end
  end
  return M.structure(app,'slice',nil,{keys=brush.keys,cuts=brush.cuts,preview=true})
end
function M.glue_preview(app,seams)
  local state=app.multi_notes;local brush=state and state.structure_brush
  if not brush or brush.kind~='glue'then return false,'Start a Glue gesture first.'end
  local changed=false
  for _,pair in ipairs(seams)do local left,right=pair[1],pair[2]
    if left.source.take==right.source.take and left.chan==right.chan and left.pitch==right.pitch and not left.source.readonly and math.abs(reaper.MIDI_GetPPQPosFromProjQN(left.source.take,left.e)-reaper.MIDI_GetPPQPosFromProjQN(right.source.take,right.s))<=1 then
      brush.joins[right.source.take]=brush.joins[right.source.take]or {}
      if not brush.joins[right.source.take][right.index]then
        brush.joins[right.source.take][right.index]=true;brush.keys[left.key]=true;brush.keys[right.key]=true;changed=true
      end
    end
  end
  if not changed then return true end
  return M.structure(app,'glue',nil,{keys=brush.keys,joins=brush.joins,preview=true})
end
function M.structure_finish(app)
  local state=app.multi_notes;local brush=state and state.structure_brush;if not brush then return false end
  if not next(brush.keys)then M.cancel(app);return true end
  local ok,notice=M.commit(app,'ReaRoll: '..brush.kind..' gesture across MIDI items')
  if ok then state.structure_brush=nil end
  return ok,notice
end
function M.commit(app,name)
  local state=app.multi_notes;local group=state and state.transaction;if not group then return false end
  local sources={};for _,source in ipairs(M.sources(app))do sources[source.take]=source end
  for _,entry in ipairs(group.entries)do local source=sources[entry.take]
    if not source or source.readonly or source.start_qn~=entry.start_qn or source.end_qn~=entry.end_qn or source.rate~=entry.rate or source.offset~=entry.offset then
      if source and source.reason and source.reason:find('Pooled')then entry.expected_raw=false end
      M.cancel(app);return false,'An edit source changed scope, timing or editability before release; the gesture was cancelled.'
    end
  end
  local ok,notice=Multi.commit(group.entries,name or 'ReaRoll: edit notes across MIDI items')
  if not ok then state.notice=notice;M.cancel(app);return false end
  local wanted={}
  for _,entry in ipairs(group.entries)do for _,n in ipairs(entry.wanted or {})do wanted[#wanted+1]=n end end
  state.transaction=nil;M.select_wanted(app,wanted);return true
end
function M.select_wanted(app,wanted)
  local state=M.refresh(app,true);state.selection={}
  local function key(take,s,pitch,channel,velocity)return tostring(take)..':'..string.format('%.9f',s)..':'..pitch..':'..channel..':'..velocity end
  local buckets={}
  for _,n in ipairs(state.notes)do local k=key(n.source.take,n.s,n.pitch,n.chan,n.vel);local bucket=buckets[k] or {first=1};buckets[k]=bucket;bucket[#bucket+1]=n end
  for _,w in ipairs(wanted)do local bucket=buckets[key(w.take,w.s,w.pitch,w.chan,w.vel)]
    if bucket and bucket[bucket.first]then state.selection[bucket[bucket.first].key]=true;bucket.first=bucket.first+1 end
  end
  M.sync(app)
end
function M.copy(app)
  M.sync(app)
  local selected=M.chosen(app);if #selected==0 then return false,'Select notes to copy.'end
  local first=math.huge;local takes={}
  for _,n in ipairs(selected)do first=math.min(first,n.s);takes[n.source.take]=true end
  local combined={notes={},controllers={},span_start=first,mpe=false}
  for take in pairs(takes)do
    local child=require('src.phrase_scope').child_app(app,take)
    local ok=require('src.clipboard').copy(child);if not ok then return false,child.expression_notice or 'Could not copy one of the selected voices.'end
    local clip=child.note_clipboard;combined.mpe=combined.mpe or clip.mpe;combined.follow=combined.follow or clip.follow
    for _,point in ipairs(clip.controllers or {})do point.offset=point.offset+clip.span_start-first;combined.controllers[#combined.controllers+1]=point end
    for _,n in ipairs(clip.notes)do n.offset=n.offset+clip.span_start-first;combined.notes[#combined.notes+1]=n end
  end
  app.note_clipboard=combined;return true
end
function M.paste(app,q)
  if not app.note_clipboard or #app.note_clipboard.notes==0 then return false,'Copy notes first.'end
  if app.transform_preview or app.edit.active or app.multi_notes.transaction or app.multi_notes.paint then return false,'Finish the current edit first.'end
  local take=app.multi_creation_take or app.take;local source
  for _,candidate in ipairs(M.sources(app))do if candidate.take==take then source=candidate;break end end
  if not source or source.readonly then return false,'Choose an editable paste target.'end
  local first,span=require('src.clipboard').bounds(app.note_clipboard)
  if q+first<source.start_qn or q+span>source.end_qn+1e-8 then return false,'The clipboard does not fit inside the chosen target.'end
  local child=require('src.phrase_scope').child_app(app,take);local raw=select(2,reaper.MIDI_GetAllEvts(take,''))
  local entry={take=take,before_raw=raw,before_pairs=Notes.get_pairing_state(take),expected_raw=raw}
  local ok,notice=xpcall(function()
    local changed=require('src.clipboard').paste_at(child,q,nil,{preview=true});assert(changed,child.expression_notice or 'The notes could not be pasted.')
    entry.after_raw=select(2,reaper.MIDI_GetAllEvts(take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(take)
    local committed,message=Multi.commit({entry},'ReaRoll: paste notes into chosen MIDI item');assert(committed,message)
  end,function(err)return tostring(err)end)
  if not ok then if child.edit.active then child.edit:cancel()end;Multi.restore({entry});return false,notice end
  local wanted={};for _,n in ipairs(require('src.selection').list(child.selection,child.cache:get(false)))do wanted[#wanted+1]={take=take,s=reaper.MIDI_GetProjQNFromPPQPos(take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end
  M.select_wanted(app,wanted);return true
end
function M.insert(app,take,q,pitch,length)
  if app.transform_preview or app.multi_notes and app.multi_notes.transaction then return false,'Finish the current edit first.'end
  local source;for _,candidate in ipairs(M.sources(app))do if candidate.take==take then source=candidate;break end end
  if not source or source.readonly then return false,source and source.reason or 'Choose an editable creation target in this scope.'end
  if q<source.start_qn or q+length>source.end_qn+1e-8 then return false,'The note is outside the chosen creation item. Choose another target or resize that item.'end
  local child=require('src.phrase_scope').child_app(app,take)
  if app.settings.scale_snap then pitch=require('src.harmony_regions').snap(child,q,pitch)end
  local s,e=reaper.MIDI_GetPPQPosFromProjQN(take,q),reaper.MIDI_GetPPQPosFromProjQN(take,q+length)
  s,e=math.floor(s+.5),math.floor(e+.5)
  local channel=app.settings.channel;local velocity=app.settings.velocity
  if app.settings.prevent_overlaps and not app.settings.mpe_enabled then for _,n in ipairs(child.cache:get(false))do if n.chan==channel and n.pitch==pitch and n.s<e and n.e>s then return false,'This pitch/channel is already occupied.'end end end
  local raw=select(2,reaper.MIDI_GetAllEvts(take,''));local entry={take=take,before_raw=raw,before_pairs=Notes.get_pairing_state(take),expected_raw=raw}
  local ok,notice=xpcall(function()child.edit:begin_preview(take);local inserted,index,assigned=child.edit:insert_draw(take,s,e,pitch,velocity,channel,true,false);assert(inserted,child.expression_notice);channel=assigned;assert(child.edit:finish()~=false,child.expression_notice)
    entry.after_raw=select(2,reaper.MIDI_GetAllEvts(take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(take)
  end,debug.traceback)
  if not ok then if child.edit.active then child.edit:cancel()end;return false,notice end
  local committed,message=Multi.commit({entry},'ReaRoll: draw note in multi-item scope')
  if not committed then Multi.restore({entry});return false,message end
  M.select_wanted(app,{{take=take,s=reaper.MIDI_GetProjQNFromPPQPos(take,s),pitch=pitch,chan=channel,vel=velocity}});return true
end
function M.paint_begin(app,take)
  local state=app.multi_notes
  if not state or state.paint or state.transaction or app.transform_preview or app.lane_tool_preview or app.edit.active then return false,'Finish the current edit first.'end
  local source;for _,candidate in ipairs(M.sources(app))do if candidate.take==take then source=candidate;break end end
  if not source or source.readonly then return false,source and source.reason or 'Choose an editable drawing target.'end
  local child=require('src.phrase_scope').child_app(app,take)
  local stream=Notes.read(take);if not stream then return false,'The drawing target is unavailable.'end
  local entry={take=take,before_raw=stream.original_raw,before_pairs=Notes.get_pairing_state(take),expected_raw=stream.original_raw}
  child.edit:begin_preview(take)
  local selection={};for key,value in pairs(state.selection)do selection[key]=value end
  state.paint={source=source,child=child,entry=entry,seen={},wanted={},channel=app.settings.channel,velocity=app.settings.velocity,selection=selection}
  return true
end
function M.paint_cancel(app)
  local paint=app.multi_notes and app.multi_notes.paint;if not paint then return false end
  if Take.valid(paint.source.take)then
    local ok,raw=reaper.MIDI_GetAllEvts(paint.source.take,'')
    if ok and raw==paint.entry.expected_raw then paint.child.edit:cancel()
    else
      -- Release our sort lock without overwriting another editor's MIDI.
      reaper.MIDI_Sort(paint.source.take)
      if ok then reaper.MIDI_SetAllEvts(paint.source.take,raw)end
      paint.child.edit.active=nil
    end
  else paint.child.edit.active=nil end
  app.multi_notes.paint=nil;app.multi_notes.selection=paint.selection;M.refresh(app,true);return true
end
function M.paint_add(app,q,pitch,length)
  local paint=app.multi_notes and app.multi_notes.paint;if not paint then return false,'Start a paint gesture first.'end
  local take=paint.source.take;local source
  for _,candidate in ipairs(M.sources(app))do if candidate.take==take then source=candidate;break end end
  if not source or source.readonly or math.abs(source.start_qn-paint.source.start_qn)>1e-8 or math.abs(source.end_qn-paint.source.end_qn)>1e-8 or source.rate~=paint.source.rate or source.offset~=paint.source.offset then M.paint_cancel(app);return false,'The drawing target changed, moved or became read-only.'end
  local ok,raw=reaper.MIDI_GetAllEvts(take,'')
  if not ok or raw~=paint.entry.expected_raw then M.paint_cancel(app);return false,'The target changed externally. Its MIDI was preserved.'end
  if q<source.start_qn or q+length>source.end_qn+1e-8 or length<=0 then return false,'The painted note is outside the chosen target item.'end
  local child=paint.child
  if app.settings.scale_snap and not paint.exact_pitches then pitch=require('src.harmony_regions').snap(child,q,pitch)end
  local s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(take,q)+.5);local e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(take,q+length)+.5)
  if e<=s or pitch<0 or pitch>127 then return false,'The painted note has invalid pitch or duration.'end
  paint.last={q,pitch,length}
  local key=s..':'..pitch;if paint.seen[key]then return true end
  if app.settings.prevent_overlaps and not app.settings.mpe_enabled then for _,n in ipairs(child.edit.active.notes)do if n.chan==paint.channel and n.pitch==pitch and n.s<e and n.e>s then paint.seen[key]=true;return true end end end
  local good,index,channel=child.edit:insert_draw(take,s,e,pitch,paint.velocity,paint.channel,true,false)
  if not good then local notice=child.expression_notice;M.paint_cancel(app);return false,notice or 'Could not paint the note.'end
  local written,notice=xpcall(function()child.edit:flush()end,debug.traceback)
  if not written then M.paint_cancel(app);return false,notice end
  paint.entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(take,''));paint.seen[key]=true
  paint.wanted[#paint.wanted+1]={take=take,s=reaper.MIDI_GetProjQNFromPPQPos(take,s),pitch=pitch,chan=channel,vel=paint.velocity}
  M.refresh(app,true);return true
end
function M.paint_commit(app)
  local state=app.multi_notes;local paint=state and state.paint;if not paint then return false end
  if paint.last then local valid,notice=M.paint_add(app,table.unpack(paint.last));if not valid then if state.paint then M.paint_cancel(app)end;return false,notice end end
  local ok,raw=reaper.MIDI_GetAllEvts(paint.source.take,'')
  if not ok or raw~=paint.entry.expected_raw then M.paint_cancel(app);return false,'External MIDI changes were preserved; painting was cancelled.'end
  if paint.child.edit:finish()==false then local notice=paint.child.expression_notice;M.paint_cancel(app);return false,notice end
  if #paint.wanted==0 then state.paint=nil;M.refresh(app,true);return true end
  local entry=paint.entry;entry.after_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(entry.take)
  local committed,notice=Multi.commit({entry},'ReaRoll: paint notes in multi-item scope')
  if not committed then Multi.restore({entry})end
  state.paint=nil;M.select_wanted(app,committed and paint.wanted or {});return committed,notice
end
function M.draw_pitches(app,take,q,pitches,length)
  local ok,notice=M.paint_begin(app,take);if not ok then return false,notice end
  local paint=app.multi_notes.paint
  if length<=0 or q<paint.source.start_qn or q+length>paint.source.end_qn+1e-8 then M.paint_cancel(app);return false,'The chord is outside the drawing item.'end
  local s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(take,q)+.5)
  local e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(take,q+length)+.5)
  local inserted;ok,inserted=paint.child.edit:insert_draw_chord(take,s,e,pitches,paint.velocity,paint.channel,true,false)
  if not ok then notice=paint.child.expression_notice;M.paint_cancel(app);return false,notice end
  for _,entry in ipairs(inserted)do paint.wanted[#paint.wanted+1]={take=take,s=q,pitch=entry.pitch,chan=entry.chan,vel=paint.velocity}end
  return M.paint_commit(app)
end
function M.draw_chord(app,take,q,pitch,length)
  local child=require('src.phrase_scope').child_app(app,take)
  return M.draw_pitches(app,take,q,require('src.harmony_regions').chord(child,q,pitch),length)
end
function M.enter(app)
  app.multi_controller_owners=nil;app.multi_controller_focus=nil;app.multi_controller_drag_signature=nil
  app.expression_direct_gesture=nil;app.expression_direct_cache=nil;app.expression_scope_owners=nil;app.expression_point_focus=nil
  if app.transform_preview then app.transforms.cancel_preview(app)end
  if app.lane_tool_preview then require('src.ui.lane_tools').cancel(app)end
  if app.gesture and app.edit.active then app.edit:cancel();app.gesture=nil;app.audition:stop()end
  app.razor_area=nil;app.razor_areas={};app.controller_razor=nil;app.controller_razor_areas={};app.mixed_razor=false;app.controller_selection_active=false
  app.multi_previous_view={};for _,key in ipairs({'start_qn','visible_qn','low_pitch','row_height','fold_offset'})do app.multi_previous_view[key]=app.settings[key]end
  app.multi_previous_scope=app.settings.phrase_scope;app.settings.phrase_scope='multi_selection';app.multi_edit_mode=true
  M.creation_take(app);M.refresh(app,true)
end
function M.exit(app)
  require('src.ui.editable_sources').cancel_draw(app)
  app.source_velocity=nil
  require('src.controller_points').cancel(app);app.multi_controller_point_focus=nil
  app.multi_controller_owners=nil;app.multi_controller_focus=nil;app.multi_controller_drag_signature=nil
  if app.multi_slides then require('src.ui.multi_slides').cancel(app);app.multi_slides=nil end
  app.expression_direct_gesture=nil;app.expression_direct_cache=nil;app.expression_scope_owners=nil;app.expression_point_focus=nil
  if app.multi_notes and app.multi_notes.paint then M.paint_cancel(app)end
  if app.multi_notes and app.multi_notes.transaction then M.cancel(app)end
  if app.transform_preview then app.transforms.cancel_preview(app)end
  if app.gesture and app.gesture.kind=='source_marquee'then app.gesture=nil end
  app.multi_creation_take=nil
  app.multi_edit_mode=false;app.settings.phrase_scope=app.multi_previous_scope or 'active';app.multi_previous_scope=nil
  if app.multi_notes then app.multi_notes.drag=nil;app.multi_notes.marquee=nil end
  if app.viewport then app.viewport:cancel_scroll();app.viewport.pitch_zoom_anchor=nil;app.viewport.time_zoom_anchor=nil end
  for key,value in pairs(app.multi_previous_view or {})do app.settings[key]=value end;app.multi_previous_view=nil
  app.multi_selection_by_take=nil;app.selection.ids={};app.cache:invalidate()
  app.razor_area=nil;app.razor_areas={};app.razor_drag=nil
end
return M
