-- @noindex
local E=require 'src.expression'
local M={}
function M.preview(app,gesture,delta,pitch_for)
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,'')
  if not ok or gesture.expected_raw and raw~=gesture.expected_raw then
    -- Another editor owns the new stream. Do not restore our earlier snapshot.
    app.edit.active=nil;app.cache:invalidate();app.gesture=nil
    return false,'MIDI changed externally; the external edit was preserved.'
  end
  if app.edit.active then app.edit:cancel()end
  app.edit:begin('ReaRoll: duplicate notes with expression',app.take)
  local a=app.edit.active;local wanted={}
  local chosen={};for _,item in ipairs(gesture.items)do chosen[item.index]=true end
  local original={notes={}};for _,n in ipairs(a.notes)do original.notes[#original.notes+1]=n end
  local shared={}
  if not app.settings.mpe_enabled then
    local valid,notice=require('src.shared_slide').require_complete(original,chosen)
    if not valid then app.edit:cancel();gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));return false,notice end
  end
  local changes={}
  for _,item in ipairs(gesture.items)do changes[#changes+1]={index=item.index,values={s=item.s+delta,e=item.e+delta}}end
  local follow,notice=require('src.cc_follow').prepare(a.stream,changes,app.settings,true)
  if follow==false then app.edit:cancel();return false,notice end
  local valid,message=require('src.cc_follow').bounds(app,follow)
  if not valid then app.edit:cancel();return false,message end
  for _,item in ipairs(gesture.items)do
    local source=a.notes[item.index+1]
    if not source then app.edit:cancel();return false,'The source note is unavailable.'end
    local first,last=item.s+delta,item.e+delta;local pitch=pitch_for(item.pitch)
    local effective=require('src.slide_links').expression_settings(source,app.settings)
    local index,notice
    if effective then
      local cohort
      if effective.expression_pitch_only then cohort,notice=require('src.slide_links').cohort(original,source,chosen);if not cohort then app.edit:cancel();return false,notice end end
      index,notice=E.duplicate(a.stream,source,first,last,pitch,effective,cohort,effective.expression_pitch_only and shared or nil,follow and follow.voices[source.index])
    else index=a.stream:insert_fragment(source,first,last,pitch);a.stream.notes[index+1].slide_copy_group=shared end
    if not index then app.edit:cancel();gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));return false,notice end
    require('src.cc_follow').copy_note(follow,source,a.notes[index+1])
    a.stream:set(index,{selected=true});a.touched[index]=true;a.changed,a.note_changed=true,true
    wanted[#wanted+1]={s=first,e=last,pitch=pitch,chan=source.chan,vel=source.vel}
  end
  require('src.cc_follow').apply(follow)
  app.edit:flush();gesture.expected_raw=select(2,reaper.MIDI_GetAllEvts(app.take,''));gesture.wanted=wanted
  app.cache:invalidate();app.cache:rebuild();app:reselect_notes(wanted);return true
end
function M.finish(app,gesture)
  if not app.edit.active then return false end
  local ok,raw=reaper.MIDI_GetAllEvts(app.take,'')
  if not ok or raw~=gesture.expected_raw then app.edit.active=nil;app.cache:invalidate();app.expression_notice='MIDI changed externally; the external edit was preserved.';return false end
  local result=app.edit:finish();app.cache:rebuild();app:reselect_notes(gesture.wanted or {});return result~=false
end
return M
