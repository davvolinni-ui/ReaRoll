-- @noindex
-- One direct curve gesture, mapped into every selected note's own time span.
-- Drafts stay in memory until a single atomic commit across all source takes.
local G=require 'src.expression_gesture'
local Group=require 'src.expression_group'
local Scope=require 'src.expression_scope'
local Notes=require 'src.note_events'
local Take=require 'src.take'
local Model=require 'src.note_expression'
local M={}
local function geometry(take)
 local first,last=Take.item_start_qn(take),Take.item_end_qn(take)
 local rate,offset
 if reaper.GetMediaItemTakeInfo_Value then rate=reaper.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE');offset=reaper.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')end
 return {first=first,last=last,rate=rate,offset=offset}
end
local function matching(draft,kind,time)
 local tolerance=.5/math.max(1,draft.expression_end-draft.note.s)+1e-9
 local best,distance
 for _,point in ipairs(draft.points)do if point.kind==kind and not point.deleted and math.abs(point.time-time)<=tolerance then
  local delta=math.abs(point.time-time)
  if not best or best.shared and not point.shared or best.shared==point.shared and delta<distance then best,distance=point,delta end
 end end
 return best
end
M.geometry=geometry
function M.valid(app,g)
 if not app.settings.mpe_enabled and not g.point_selection or Group.signature(app)~=g.selection_group.signature then return false,'The note selection or MPE setup changed; the curve edit was cancelled.'end
 for _,entry in ipairs(g.selection_group.entries)do
  if not Notes.available(entry.take)then return false,'An expression source was removed; no curve edits were applied.'end
  local item=Take.item(entry.take)
  if not item or reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false,'An expression source became locked; no curve edits were applied.'end
  local now,old=geometry(entry.take),entry.geometry
  if now.first~=old.first or now.last~=old.last or now.rate~=old.rate or now.offset~=old.offset then return false,'A source item moved or changed timing; the curve edit was cancelled.'end
  if app.multi_edit_mode then local source=Scope.source(app,entry.take);if not source or source.readonly then return false,'An expression source left the editable selection.'end end
  local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'')
  if not ok or raw~=entry.before_raw then return false,'MIDI changed outside this gesture; those changes were preserved.'end
 end
 return true
end
local function sync(g,tension)
 local reference=g.reference;local dt=reference.point.time-g.origin_time;local dv=reference.point.value-g.origin_value
 local tmin,tmax,vmin,vmax=-math.huge,math.huge,-math.huge,math.huge
 local maximum=g.kind=='pitch'and 16383 or 127
 local cmin,cmax=-math.huge,math.huge
 for _,member in ipairs(g.members)do
  tmin=math.max(tmin,-member.time);tmax=math.min(tmax,1-member.time)
  vmin=math.max(vmin,-member.value);vmax=math.min(vmax,maximum-member.value)
  cmin=math.max(cmin,-1-member.tension);cmax=math.min(cmax,1-member.tension)
 end
 dt=math.max(tmin,math.min(tmax,dt));dv=math.max(vmin,math.min(vmax,dv))
 local curve_delta=math.max(cmin,math.min(cmax,tension or 0))
 for _,member in ipairs(g.members)do local peer=member.gesture
  if g.operation=='curve'then
   Model.set_shape(peer.point,5,member.tension+curve_delta)
  elseif g.operation~='delete'then
   peer.point.time=member.time+dt;peer.point.value=math.floor(member.value+dv+.5)
  end
 end
 g.changed=reference.changed
end
function M.begin(app,draft,kind,time,value,operation,point)
 if app.gesture or app.transform_preview or app.edit.active or app.expression_direct_gesture or app.lane_tool_preview or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint or app.multi_notes.drag)then return nil,'Finish the current edit first.'end
 local group,notice=Group.begin(app);if not group then return nil,notice end
 local reference;reference,notice=G.begin(Scope.owner(app,draft.take),draft.note,kind,time,value,operation,point)
 if not reference then return nil,notice end
 local g={};for key,item in pairs(reference)do g[key]=item end
 g.selection_group=group;g.reference=reference;g.members={};g.origin_time=reference.time
 g.origin_value=point and point.value or G.value(G.points(draft,kind),time,kind)
 for _,entry in ipairs(group.entries)do
  entry.geometry=geometry(entry.take)
  for index,other in ipairs(entry.batch.drafts)do
   local peer,base
   if entry.take==draft.take and other.note.index==draft.note.index then peer=reference;base=g.origin_value
   else
    local target=matching(other,kind,g.origin_time)
    if operation~='delete'or target then
     base=target and target.value or G.value(G.points(other,kind),g.origin_time,kind)
     -- A missing corresponding point is added without replacing that note's
     -- existing curve. Curvature edits use the new point as a segment start.
     local requested=operation=='curve'and not target and 'move'or operation
     peer,notice=G.begin(entry.child,other.note,kind,g.origin_time,base,requested,target)
     if not peer then return nil,notice end
     peer.operation=operation or 'move'
    end
   end
   if peer then
    entry.batch.drafts[index]=peer.draft
    g.members[#g.members+1]={gesture=peer,time=peer.time,value=base,tension=peer.tension}
   end
  end
 end
 local valid;valid,notice=M.valid(app,g);if not valid then return nil,notice end
 sync(g,0)
 return g
end
function M.update(g,time,value,tension)
 G.update(g.reference,time,value,tension)
 sync(g,g.operation=='curve'and(tension or 0)or 0)
end
function M.finish(app,g)
 local valid,notice=M.valid(app,g);if not valid then return false,notice end
 if not g.changed then return true end
 return Group.apply(app,g.selection_group,g)
end
function M.draft(g,take,index)
 if not g or not g.selection_group then return end
 for _,entry in ipairs(g.selection_group.entries)do if entry.take==take then
  for _,draft in ipairs(entry.batch.drafts)do if draft.note.index==index then return draft end end
 end end
end
return M
