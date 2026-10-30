-- @noindex
-- Explicit point selections edit only the boxed points, independently of the
-- selected-note scope used for ordinary single-point expression gestures.
local Scope=require 'src.expression_scope'
local Group=require 'src.expression_group'
local Shared=require 'src.expression_selection'
local Model=require 'src.note_expression'
local Notes=require 'src.note_events'
local M={}
local function key(take,index,point)
 return table.concat({tostring(take),index,point.kind,point.original_time or '',point.order or '',point.original_msg or ''},':')
end
function M.ref(draft,point,note_id)
 return {take=draft.take,index=draft.note.index,kind=point.kind,time=point.time,value=point.value,key=key(draft.take,draft.note.index,point),note_id=note_id}
end
function M.current(app)
 local state=app.expression_point_selection
 if not state then return end
 if app.expression_group_open or state.kind~=app.expression_dimension or state.signature~=Group.signature(app)then app.expression_point_selection=nil;return end
 for take,raw in pairs(state.raws)do
  if not Notes.available(take)then app.expression_point_selection=nil;return end
  local ok,current=reaper.MIDI_GetAllEvts(take,'');if not ok or current~=raw then app.expression_point_selection=nil;return end
 end
 return state
end
function M.set(app,refs,kind)
 local state={kind=kind,signature=Group.signature(app),raws={},points={},count=0}
 for _,note in ipairs(Scope.selected(app))do local take=note.take or app.take
  if not Notes.available(take)then return nil,'An expression source was removed.'end
  if not state.raws[take]then local ok,raw=reaper.MIDI_GetAllEvts(take,'');if not ok then return nil,'The expression source could not be read.'end;state.raws[take]=raw end
 end
 for _,ref in ipairs(refs)do if ref.kind==kind and not state.points[ref.key]then state.points[ref.key]=ref;state.count=state.count+1 end end
 app.expression_point_selection=state;app.expression_point_focus=nil
 return state
end
function M.selected(app,draft,point)
 local state=app.expression_point_selection
 return state and state.points[key(draft.take,draft.note.index,point)]~=nil
end
function M.begin(app,operation)
 local state=M.current(app)
 if not state or state.count==0 then return nil,'Select expression points first.'end
 if app.gesture or app.edit.active or app.transform_preview or app.lane_tool_preview or app.expression_direct_gesture or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint or app.multi_notes.drag)then return nil,'Finish the current edit first.'end
 local group,notice=Group.begin(app,1);if not group then return nil,notice end
 local g={selection_group=group,point_selection=true,kind=state.kind,operation=operation or 'move',members={},note_wanted=Scope.selected(app),original_selection=state,changed=operation=='delete',undo_name=operation=='delete'and 'ReaRoll: delete expression points'or 'ReaRoll: move expression points'}
 local entries={}
 for _,entry in ipairs(group.entries)do
  entry.geometry=Shared.geometry(entry.take)
  local drafts,notes={},{}
  for i,draft in ipairs(entry.batch.drafts)do
   local used=false
   for _,point in ipairs(draft.points)do if not point.deleted and not point.shared and not point.context and state.points[key(entry.take,draft.note.index,point)]then
    local first=reaper.MIDI_GetProjQNFromPPQPos(entry.take,draft.note.s)
    local last=reaper.MIDI_GetProjQNFromPPQPos(entry.take,draft.expression_end)
    local qn=reaper.MIDI_GetProjQNFromPPQPos(entry.take,draft.note.s+point.time*(draft.expression_end-draft.note.s))
    g.members[#g.members+1]={draft=draft,point=point,time=point.time,value=point.value,qn=qn,first=first,last=last};used=true
    if operation=='delete'then point.deleted=true end
   end end
   if used then drafts[#drafts+1]=draft;notes[#notes+1]=entry.notes[i]end
  end
  if #drafts>0 then
   entry.batch.drafts=drafts;entry.notes=notes;entry.batch.signature=require('src.note_expression_batch').signature(entry.child,notes)
   entries[#entries+1]=entry
  end
 end
 group.entries=entries
 if #g.members~=state.count then return nil,'The selected points changed; select them again.'end
 g.draft=g.members[1].draft;g.point=g.members[1].point
 local valid;valid,notice=Shared.valid(app,g);if not valid then return nil,notice end
 return g
end
function M.update(g,delta,value)
 local lo,hi,vlo,vhi=-math.huge,math.huge,-math.huge,math.huge
 local maximum=g.kind=='pitch'and 16383 or 127
 for _,m in ipairs(g.members)do
  lo=math.max(lo,m.first-m.qn);hi=math.min(hi,m.last-m.qn)
  vlo=math.max(vlo,-m.value);vhi=math.min(vhi,maximum-m.value)
 end
 delta=math.max(lo,math.min(hi,delta));value=math.floor(math.max(vlo,math.min(vhi,value))+.5)
 g.changed=false
 for _,m in ipairs(g.members)do
  local tick=reaper.MIDI_GetPPQPosFromProjQN(m.draft.take,m.qn+delta)
  m.point.time=math.max(0,math.min(1,(tick-m.draft.note.s)/math.max(1,m.draft.expression_end-m.draft.note.s)))
  m.point.value=m.value+value
  if math.floor(tick+.5)~=math.floor(m.draft.note.s+m.time*(m.draft.expression_end-m.draft.note.s)+.5)or value~=0 then g.changed=true end
 end
end
local function restore_notes(app,g)
 if app.multi_edit_mode then
  local wanted={};for _,note in ipairs(g.note_wanted)do wanted[#wanted+1]={take=note.take,s=reaper.MIDI_GetProjQNFromPPQPos(note.take,note.s),pitch=note.pitch,chan=note.chan,vel=note.vel}end
  require('src.multi_notes').select_wanted(app,wanted)
 else
  app.selection.ids={};for _,note in ipairs(g.note_wanted)do app.selection.ids[note.id]=true end
 end
end
function M.finish(app,g)
 local valid,notice=Shared.valid(app,g);if not valid then return false,notice end
 if not g.changed then return true end
 local ok;ok,notice=Group.apply(app,g.selection_group,g)
 restore_notes(app,g)
 if not ok then return false,notice end
 local refs={}
 if g.operation~='delete'then
  local drafts={}
  for _,m in ipairs(g.members)do
   local k=tostring(m.draft.take)..':'..m.draft.note.index
   local draft=drafts[k]
   if not draft then draft=Model.begin(Scope.owner(app,m.draft.take),m.draft.note);drafts[k]=draft end
   if draft then for _,point in ipairs(draft.points)do
    if not point.shared and point.kind==g.kind and point.value==m.point.value and math.abs(point.time-m.point.time)*math.max(1,draft.expression_end-draft.note.s)<.51 then
     refs[#refs+1]=M.ref(draft,point);break
    end
   end end
  end
 end
 M.set(app,refs,g.kind)
 return true
end
return M
