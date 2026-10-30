-- @noindex
local Points=require 'src.controller_points'
local Model=require 'src.multi_notes'
local M={}
function M.scope(app)
  local context=app.controller_point_context
  if not context then return nil,'Click the controller lane to choose the generator target.'end
  local source;for _,candidate in ipairs(Model.sources(app))do if candidate.take==context.take then source=candidate end end
  if not source or source.readonly then return nil,source and source.reason or 'The controller source left the editing scope.'end
  local first,last=math.huge,-math.huge;local count=0
  local selected=Points.selection(app,context.key,context.take)
  for _,p in ipairs(Points.points(context.take,context.lane,context.ch))do if selected[p.index]then
    local q=reaper.MIDI_GetProjQNFromPPQPos(context.take,p.ppq);first=math.min(first,q);last=math.max(last,q);count=count+1
  end end
  local label='Selected controller range'
  if count<2 then
    first,last=math.huge,-math.huge;label='Selected notes in this source'
    for _,n in ipairs(Model.chosen(app))do if n.source.take==source.take then first=math.min(first,n.s);last=math.max(last,n.e)end end
    if first==math.huge then first,last=source.start_qn,source.end_qn;label='Entire source item'end
  end
  first=math.max(source.start_qn,first);last=math.min(source.end_qn,last)
  return {take=source.take,ch=context.ch,lane=context.lane,key=context.key,first=first,last=last,label=label,name=source.name}
end
function M.preview(app,def,mode,options)
  if app.multi_shape_blocked then return false,'The generator source changed. Close and reopen Shape before trying again.'end
  local p=app.lane_tool_preview
  if p and p.multi_controller then
    if app.controller_point_gesture~=p.g then app.lane_tool_preview=nil;app.multi_shape_blocked=true;return false,app.multi_controller_point_notice or 'The generator source changed.'end
  else
    local target,notice=M.scope(app);if not target then return false,notice end
    local ok;ok,notice=Points.begin(app,target.take,target.lane,target.ch,'generate',Points.selection(app,target.key,target.take))
    if not ok then return false,notice end
    p={multi_controller=true,g=app.controller_point_gesture,target=target,def=def};app.lane_tool_preview=p
  end
  local copied={};for k,v in pairs(options)do copied[k]=v end
  if mode=='lfo'and copied.sync_qn then
    copied._sync_origin_ppq=reaper.MIDI_GetPPQPosFromProjQN(p.target.take,p.g.source.start_qn)
    copied._sync_ppq=math.abs(reaper.MIDI_GetPPQPosFromProjQN(p.target.take,p.g.source.start_qn+copied.sync_qn)-copied._sync_origin_ppq)
  end
  p.g.generator={first=p.target.first,last=p.target.last,resolution=copied.resolution or .125,mode=mode,options=copied,def=def}
  local ok,notice=Points.preview(app);p.valid=ok;return ok,notice
end
function M.cancel(app)
  Points.cancel(app);app.lane_tool_preview=nil;return true
end
function M.apply(app)
  local ok,notice=Points.finish(app);app.lane_tool_preview=nil;return ok,notice
end
return M
