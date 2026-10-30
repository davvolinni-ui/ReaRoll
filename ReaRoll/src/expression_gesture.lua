-- @noindex
-- Direct manipulation shares the recorded-voice ownership and atomic edit model.
local Model=require 'src.note_expression'
local Curve=require 'src.midi_curve'
local M={}
function M.points(draft,kind)
  local out,changed={},false
  for _,p in ipairs(draft.points)do if p.kind==kind then
    if not p.deleted then out[#out+1]=p end
    if p.deleted or not p.original_msg or p.original_value~=p.value or p.flags~=p.original_flags or(p.shape and p.shape.msg)~=p.original_shape or math.floor(draft.note.s+p.time*(draft.expression_end-draft.note.s)+.5)~=p.original_time then changed=true end
  end end
  for _,p in ipairs(draft.context_points or {})do if p.kind==kind then out[#out+1]=p end end
  local boundary=draft.boundaries and draft.boundaries[kind]
  if changed and boundary and not boundary.retained and not boundary.unsafe then out[#out+1]={kind=kind,time=1,value=boundary.value,flags=boundary.flags,shape=boundary.shape,shared=true,context=true,guard=true}end
  table.sort(out,function(a,b)if a.time~=b.time then return a.time<b.time end;return not a.guard and b.guard==true end)
  return out
end
function M.value(points,time,kind)
  if #points==0 or time<points[1].time then return kind=='pitch'and 8192 or kind=='timbre'and 64 or 0 end
  for i=#points,1,-1 do if points[i].time<=time then return Curve.value(points,i,time,0,kind=='pitch'and 16383 or 127)or points[i].value end end
end
function M.begin(app,note,kind,time,value,operation,point)
  if app.multi_edit_mode or app.gesture or app.transform_preview or app.edit.active then return nil,'Finish the current edit before editing expression.'end
  local draft,notice=Model.begin(app,note);if not draft then return nil,notice end
  local target
  if point then
    for _,p in ipairs(draft.points)do if p.kind==kind and p.original_time==point.original_time and p.order==point.order and p.original_msg==point.original_msg then target=p;break end end
    if not target or target.shared then return nil,'This boundary belongs to an adjacent voice and stays fixed.'end
  end
  if operation=='delete'then if not target then return nil end;target.deleted=true
  elseif operation=='curve'then if not target then return nil end
  elseif not target then
    target={kind=kind,time=math.max(0,math.min(1,time)),value=value,flags=16}
    draft.points[#draft.points+1]=target
  end
  return {draft=draft,point=target,kind=kind,operation=operation or 'move',time=target.time,value=target.value,tension=Model.tension(target),changed=not point or operation=='delete'}
end
function M.update(g,time,value,tension)
  if g.selection_group then return require('src.expression_selection').update(g,time,value,tension)end
  if g.operation=='curve'then
    Model.set_shape(g.point,5,math.max(-1,math.min(1,g.tension+(tension or 0))));g.changed=true
  elseif g.operation~='delete'then
    time=math.max(0,math.min(1,time));value=math.floor(math.max(0,math.min(g.kind=='pitch'and 16383 or 127,value))+.5)
    g.changed=g.changed or time~=g.point.time or value~=g.point.value;g.point.time=time;g.point.value=value
  end
end
function M.finish(app,g)
  if not g.changed then return true end
  local ok,notice=Model.apply(app,g.draft)
  if ok then app.cc_cache:invalidate();app.expression_index=nil;app.expression_draft=nil;app.slide_target_cache=nil end
  return ok,notice
end
return M
