-- @noindex
local M={section='ReaRoll',key='window_state_v1'}
local function finite(value)return type(value)=='number'and value==value and math.abs(value)<10000000 end
function M.decode(raw)
  local version,dock,x,y,w,h=raw:match('^(%d+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$')
  dock=tonumber(dock)
  if version~='1'or not finite(dock)or dock%1~=0 then return nil end
  if x=='-'and y=='-'and w=='-'and h=='-'then return {dock=dock}end
  x,y,w,h=tonumber(x),tonumber(y),tonumber(w),tonumber(h)
  if not finite(x)or not finite(y)or not finite(w)or not finite(h)or w<100 or h<80 or w>32768 or h>32768 then return nil end
  return {dock=dock,x=x,y=y,w=w,h=h}
end
function M.encode(state)
  if not state.x then return '1|'..state.dock..'|-|-|-|-'end
  return string.format('1|%d|%.3f|%.3f|%.3f|%.3f',state.dock,state.x,state.y,state.w,state.h)
end
function M.prepare(app,rescue)
  if app.window_restore_done then return false end
  app.window_restore_done=true
  local raw=reaper.GetExtState(M.section,M.key)
  app.window_state=M.decode(raw);app.window_state_saved=raw
  if rescue or not app.window_state then return false end
  local I,c,state=app.ImGui,app.ctx,app.window_state
  -- Zero is an explicit undock request, overriding an older native .ini dock.
  I.SetNextWindowDockID(c,state.dock,I.Cond_Always)
  if state.dock==0 and state.x then
    I.SetNextWindowPos(c,state.x,state.y,I.Cond_Always)
    I.SetNextWindowSize(c,state.w,state.h,I.Cond_Always)
  end
  return true
end
function M.save(app,force)
  if not app.window_state_pending or app.window_state_pending==app.window_state_saved then return end
  if force or reaper.time_precise()-(app.window_state_changed_at or 0)>=.35 then
    reaper.SetExtState(M.section,M.key,app.window_state_pending,true)
    app.window_state_saved=app.window_state_pending
  end
end
-- Called inside the visible main window, never from a child or after End().
function M.capture(app)
  local I,c=app.ImGui,app.ctx;local dock=I.GetWindowDockID(c)
  local previous=app.window_state;local state={dock=dock}
  if previous then state.x,state.y,state.w,state.h=previous.x,previous.y,previous.w,previous.h end
  if dock==0 then
    local x,y=I.GetWindowPos(c);local w,h=I.GetWindowSize(c)
    if not finite(x)or not finite(y)or not finite(w)or not finite(h)or w<100 or h<80 then return end
    state.x,state.y,state.w,state.h=x,y,w,h
  end
  local encoded=M.encode(state)
  if encoded~=app.window_state_pending then app.window_state_pending=encoded;app.window_state_changed_at=reaper.time_precise()end
  app.window_state=state
  M.save(app,not previous or previous.dock~=dock)
end
return M
