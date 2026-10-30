-- @noindex
local Scope=require 'src.expression_scope'
local Batch=require 'src.note_expression_batch'
local Notes=require 'src.note_events'
local M={}
function M.signature(app)
  local keys={tostring(app.multi_edit_mode),tostring(app.settings.mpe_enabled),tostring(app.settings.mpe_zone),tostring(app.settings.mpe_members),tostring(app.settings.mpe_pitch_bend_range)}
  for _,n in ipairs(Scope.selected(app))do keys[#keys+1]=tostring(n.take or app.take)..':'..n.index..':'..n.s..':'..n.e..':'..n.chan end
  table.sort(keys);return table.concat(keys,'|')
end
function M.begin(app,minimum)
  local notes=Scope.selected(app)
  if #notes<(minimum or 2)then return nil,'Select at least two notes to adjust together.'end
  local result={signature=M.signature(app),entries={}}
  local groups={}
  for _,n in ipairs(notes)do local take=n.take or app.take;groups[take]=groups[take]or {};table.insert(groups[take],n)end
  for take,selected in pairs(groups)do
    local child=Scope.owner(app,take)
    local batch,notice=Batch.begin(child,selected,true);if not batch then return nil,notice end
    result.entries[#result.entries+1]={take=take,child=child,batch=batch,notes=selected,before_raw=batch.drafts[1].raw,before_pairs=Notes.get_pairing_state(take)}
  end
  return result
end
function M.adjust(group,settings,kind,offset,gain)
  for _,entry in ipairs(group.entries)do Batch.adjust(entry.batch,settings,kind,offset,gain,true)end
end
function M.apply(app,group,direct_gesture)
  if M.signature(app)~=group.signature then return false,'Selection or MPE setup changed. Start the adjustment again.'end
  if app.gesture or app.edit.active or (app.expression_direct_gesture and app.expression_direct_gesture~=direct_gesture)or app.transform_preview or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint or app.multi_notes.drag)then return false,'Finish the current edit first.'end
  for _,entry in ipairs(group.entries)do
    if not Notes.available(entry.take)then return false,'An expression source was removed; no edit was applied.'end
    local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'')
    if not ok or raw~=entry.before_raw then return false,'MIDI changed. Start the adjustment again.'end
    if app.multi_edit_mode then local source=Scope.source(app,entry.take);if not source or source.readonly then return false,'An item is no longer editable.'end end
    entry.expected_raw=raw
  end
  local ok,notice=xpcall(function()
    for _,entry in ipairs(group.entries)do
      local changed,reason=Batch.apply(entry.child,entry.batch,entry.notes,true);assert(changed,reason)
      entry.after_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''));entry.expected_raw=entry.after_raw
      entry.after_pairs=Notes.get_pairing_state(entry.take)
    end
  end,tostring)
  local MultiEdit=require 'src.multi_edit'
  if ok then ok,notice=MultiEdit.commit(group.entries,direct_gesture and(direct_gesture.undo_name or 'ReaRoll: draw selected-note expression')or 'ReaRoll: adjust selected-note expression')end
  if not ok then MultiEdit.restore(group.entries)end
  app.cache:invalidate();app.cc_cache:invalidate();app.expression_direct_cache=nil;app.expression_scope_owners=nil
  if app.multi_edit_mode then
    local wanted={}
    for _,entry in ipairs(group.entries)do for _,draft in ipairs(entry.batch.drafts)do
      wanted[#wanted+1]={take=entry.take,s=reaper.MIDI_GetProjQNFromPPQPos(entry.take,draft.note.s),pitch=draft.note.pitch,chan=draft.note.chan,vel=ok and draft.velocity or draft.note.vel}
    end end
    require('src.multi_notes').select_wanted(app,wanted)
  else
    local indices={};for _,entry in ipairs(group.entries)do for _,note in ipairs(entry.notes)do indices[note.index]=true end end
    app.selection.ids={};for _,note in ipairs(app.cache:get(false))do if indices[note.index]then app.selection.ids[note.id]=true end end
  end
  return ok,notice
end
return M
