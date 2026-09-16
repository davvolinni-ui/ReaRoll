-- @noindex
local M={}
-- Call immediately after a value widget. Disabled/active widgets and popup
-- windows retain their normal input ownership.
function M.input(app,label,value,default)
  local I,c=app.ImGui,app.ctx
  if not I.IsItemHovered(c) or not I.IsWindowHovered(c) then return 0,false end
  I.SetTooltip(c,string.format('%s: %s\nWheel: adjust / right-click: reset (%s)',label,tostring(value),tostring(default)))
  if I.IsAnyItemActive(c) then return 0,false end
  local reset=I.IsMouseClicked(c,I.MouseButton_Right)
  local wheel=I.GetMouseWheel(c)
  if wheel~=0 then app.control_wheel_consumed=true end
  return wheel,reset
end
function M.number(app,target,key,default,step,lo,hi,label)
  local wheel,reset=M.input(app,label or key,target[key],default)
  if reset then target[key]=default
  elseif wheel~=0 then
    local value=target[key]+(wheel>0 and 1 or -1)*step
    target[key]=math.max(lo,math.min(hi,value))
  end
  return reset or wheel~=0
end
function M.choice(app,target,key,default,values,label)
  local wheel,reset=M.input(app,label or key,target[key],default)
  if reset then target[key]=default;return true end
  if wheel~=0 then
    local index=1
    for i,value in ipairs(values) do if value==target[key] then index=i;break end end
    index=math.max(1,math.min(#values,index+(wheel>0 and 1 or -1)))
    target[key]=values[index];return true
  end
  return false
end
function M.toggle(app,target,key,default,label)
  local wheel,reset=M.input(app,label or key,target[key] and 'On' or 'Off',default and 'On' or 'Off')
  if reset then target[key]=default elseif wheel~=0 then target[key]=wheel>0 end
  return reset or wheel~=0
end
return M
