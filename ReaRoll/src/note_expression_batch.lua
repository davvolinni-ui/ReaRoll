-- @noindex
local Model=require 'src.note_expression'
local M={}
function M.signature(app,notes)
  local out={tostring(app.take)};for _,n in ipairs(notes)do out[#out+1]=n.index..':'..n.s..':'..n.e..':'..n.pitch..':'..n.chan end;table.sort(out);return table.concat(out,'|')
end
function M.begin(app,notes,grouped)
  if #notes<(grouped and 1 or 2)then return nil,'Select at least two MPE notes.'end
  local batch={signature=M.signature(app,notes),drafts={},originals={}}
  for _,n in ipairs(notes)do
    local draft,notice=Model.begin(app,n);if not draft then return nil,notice end
    batch.drafts[#batch.drafts+1]=draft;local original={velocity=draft.velocity,release_velocity=draft.release_velocity,values={}}
    for i,p in ipairs(draft.points)do original.values[i]=p.value end
    batch.originals[#batch.originals+1]=original
  end
  return batch
end
function M.adjust(batch,settings,kind,offset,gain,preserve_other)
  if kind~='pitch'and kind~='pressure'and kind~='timbre'and kind~='velocity'and kind~='release_velocity'then return false end
  if type(offset)~='number'or offset~=offset or math.abs(offset)>16384 or type(gain)~='number'or gain~=gain or gain<0 or gain>4 then return false end
  local range=settings.mpe_pitch_bend_range or 48
  for index,draft in ipairs(batch.drafts)do local original=batch.originals[index]
    -- Every slider update starts from the snapshot, avoiding cumulative drift.
    if not preserve_other then draft.velocity=original.velocity;draft.release_velocity=original.release_velocity end
    for i,p in ipairs(draft.points)do if not preserve_other or p.kind==kind then p.value=original.values[i]end end
    if kind=='velocity'or kind=='release_velocity'then draft[kind]=math.max(kind=='velocity'and 1 or 0,math.min(127,math.floor(original[kind]*gain+offset+.5)))
    else for _,p in ipairs(draft.points)do if p.kind==kind and not p.shared then
      if kind=='pitch'then local v=(p.value-8192)/(p.value>=8192 and 8191 or 8192)*range;p.value=require('src.glide').value(v*gain+offset,range)
      elseif kind=='timbre'then p.value=math.max(0,math.min(127,math.floor(64+(p.value-64)*gain+offset+.5)))
      else p.value=math.max(0,math.min(127,math.floor(p.value*gain+offset+.5)))end
    end end end
  end
  return true
end
function M.apply(app,batch,notes,preview)
  if not app.take or reaper.ValidatePtr2 and not reaper.ValidatePtr2(0,app.take,'MediaItem_Take*')then return false,'The source MIDI item is unavailable.'end
  if M.signature(app,notes)~=batch.signature then return false,'The note selection changed. Review its expression again.'end
  if app.edit.active or app.gesture or app.transform_preview or app.lane_tool_preview then return false,'Finish the active edit first.'end
  local selected=require('src.selection').list(app.selection,app.cache:get(false))
  local ok,notice=xpcall(function()
    if preview then app.edit:begin_preview(app.take)else app.edit:begin('ReaRoll: edit selected-note expression',app.take)end
    for _,draft in ipairs(batch.drafts)do local changed,reason=Model.apply(app,draft,{transaction=true});if not changed then error(reason,0)end end
    assert(app.edit:finish()~=false,'Expression could not be committed.')
  end,function(err)return tostring(err)end)
  if not ok then if app.edit.active then app.edit:cancel()end;return false,notice end
  app.cache:rebuild();app:reselect_notes(selected);return true
end
return M
