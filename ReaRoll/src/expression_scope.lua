-- @noindex
local Notes=require 'src.note_events'
local G=require 'src.expression_gesture'
local Multi=require 'src.multi_notes'
local M={}
local function wrapped(n)
  return {id=n.key,index=n.index,take=n.source.take,source=n.source,pitch=n.pitch,chan=n.chan,vel=n.vel,muted=n.muted,s=reaper.MIDI_GetPPQPosFromProjQN(n.source.take,n.s),e=reaper.MIDI_GetPPQPosFromProjQN(n.source.take,n.e)}
end
function M.all(app)
  if not app.multi_edit_mode then return app.cache:get(false)end
  local out={};for _,n in ipairs(Multi.refresh(app).notes)do if not n.source.readonly then out[#out+1]=wrapped(n)end end;return out
end
function M.select(app,note)
  app.expression_focus_id=note.id
  if app.multi_edit_mode then app.multi_notes.selection={[note.id]=true};Multi.sync(app)
  else require('src.selection').set_only(app.selection,note.id)end
end
function M.selected(app)
  if not app.multi_edit_mode then return require('src.selection').list(app.selection,app.cache:get(false))end
  local out={}
  for _,n in ipairs(Multi.chosen(app))do
    out[#out+1]=wrapped(n)
  end
  return out
end
function M.owner(app,take)
  if not app.multi_edit_mode then return app end
  app.expression_scope_owners=app.expression_scope_owners or {}
  local child=app.expression_scope_owners[take]
  if not child then child=require('src.phrase_scope').child_app(app,take);app.expression_scope_owners[take]=child end
  child.settings={};for k,v in pairs(app.settings)do child.settings[k]=v end
  child.settings.phrase_scope='active';child.multi_edit_mode=false;child.gesture=nil;child.transform_preview=nil
  return child
end
function M.source(app,take)
  for _,source in ipairs(Multi.sources(app))do if source.take==take then return source end end
end
function M.assign(app)
  if app.gesture or app.edit.active or app.expression_direct_gesture or app.transform_preview or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint)then return false,'Finish the current edit first.'end
  local Assign=require 'src.mpe_assign';local notes=M.selected(app)
  if #notes==0 then return false,'Select the notes to make MPE.'end
  if not app.multi_edit_mode then
    local draft,notice=Assign.begin(app,notes);if not draft then return false,notice end
    local ok,message=Assign.apply(app,draft);app.expression_direct_cache=nil;return ok,message
  end
  local groups,entries={},{}
  for _,note in ipairs(notes)do local take=note.take;groups[take]=groups[take]or {};groups[take][#groups[take]+1]=note end
  for take,selected in pairs(groups)do
    local source=M.source(app,take);if not source or source.readonly then return false,'Choose editable MIDI items before assigning voices.'end
    local child=M.owner(app,take);local draft,notice=Assign.begin(child,selected);if not draft then return false,notice end
    entries[#entries+1]={take=take,child=child,draft=draft,before_raw=draft.raw,before_pairs=Notes.get_pairing_state(take),expected_raw=draft.raw}
  end
  local wanted={};local changed=false
  local ok,notice=xpcall(function()
    for _,entry in ipairs(entries)do
      local success,message=Assign.apply(entry.child,entry.draft,{preview=true});assert(success,message)
      entry.after_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(entry.take)
      changed=changed or entry.after_raw~=entry.before_raw
      for _,voice in ipairs(entry.draft.assignments)do wanted[#wanted+1]={take=entry.take,s=reaper.MIDI_GetProjQNFromPPQPos(entry.take,voice.first),pitch=voice.pitch,chan=voice.channel,vel=voice.velocity}end
    end
  end,function(err)return tostring(err)end)
  if not ok then
    for _,entry in ipairs(entries)do if entry.child.edit.active then entry.child.edit:cancel()end end
    require('src.multi_edit').restore(entries);return false,notice
  end
  if changed then ok,notice=require('src.multi_edit').commit(entries,'ReaRoll: make selected notes MPE');if not ok then require('src.multi_edit').restore(entries);return false,notice end end
  app.expression_direct_cache=nil;app.expression_scope_owners=nil;Multi.select_wanted(app,wanted);return true
end
function M.begin(app,draft,kind,time,value,operation,point)
  if app.settings.mpe_enabled and #M.selected(app)>1 then return require('src.expression_selection').begin(app,draft,kind,time,value,operation,point)end
  if not app.multi_edit_mode then return G.begin(app,draft.note,kind,time,value,operation,point)end
  if app.gesture or app.transform_preview or app.edit.active or app.multi_notes.transaction or app.multi_notes.paint or app.multi_notes.drag then return nil,'Finish the current edit first.'end
  local source=M.source(app,draft.take)
  if not source or source.readonly then return nil,source and source.reason or 'The expression source left the editing scope.'end
  local child=M.owner(app,draft.take)
  local gesture,notice=G.begin(child,draft.note,kind,time,value,operation,point)
  if gesture then
    gesture.owner=child;gesture.source=source;gesture.before_pairs=Notes.get_pairing_state(draft.take);gesture.wanted={}
    for _,n in ipairs(Multi.chosen(app))do gesture.wanted[#gesture.wanted+1]={take=n.source.take,s=n.s,pitch=n.pitch,chan=n.chan,vel=n.vel}end
  end
  return gesture,notice
end
function M.finish(app,g)
  if g.selection_group then return require('src.expression_selection').finish(app,g)end
  if not g.owner then return G.finish(app,g)end
  if not app.multi_edit_mode then return false,'The editing scope changed; the expression gesture was cancelled.'end
  local source=M.source(app,g.draft.take)
  if not source or source.readonly or source.start_qn~=g.source.start_qn or source.end_qn~=g.source.end_qn or source.rate~=g.source.rate or source.offset~=g.source.offset then return false,'The expression source changed or became read-only; no edit was applied.'end
  if not g.changed then return true end
  local child=M.owner(app,g.draft.take)
  local ran,ok,notice=pcall(require('src.note_expression').apply,child,g.draft,{preview=true})
  if not ran then
    if child.edit.active then pcall(function()child.edit:cancel()end)end
    app.cache:invalidate();app.cc_cache:invalidate();app.expression_scope_owners=nil
    return false,'The source could not be written; the expression edit was cancelled.'
  end
  if not ok then return false,notice end
  local entry={take=g.draft.take,before_raw=g.draft.raw,before_pairs=g.before_pairs,after_raw=select(2,reaper.MIDI_GetAllEvts(g.draft.take,'')),after_pairs=Notes.get_pairing_state(g.draft.take)}
  entry.expected_raw=entry.after_raw
  ok,notice=require('src.multi_edit').commit({entry},'ReaRoll: edit expression in MIDI item')
  if not ok then require('src.multi_edit').restore({entry})end
  app.cache:invalidate();app.cc_cache:invalidate();app.expression_direct_cache=nil;app.expression_scope_owners=nil
  Multi.select_wanted(app,g.wanted)
  return ok,notice
end
return M
