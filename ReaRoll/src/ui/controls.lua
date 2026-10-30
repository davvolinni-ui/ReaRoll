-- @noindex
local M={}
-- Call immediately after a value widget. Disabled/active widgets and popup
-- windows retain their normal input ownership.
function M.wheel(app,locked)
  local I,c=app.ImGui,app.ctx
  if locked or app.control_wheel_consumed or not I.IsItemHovered(c) or not I.IsWindowHovered(c)
    or I.IsAnyItemActive(c) then return 0 end
  local wheel=I.GetMouseWheel(c)
  if wheel~=0 then app.control_wheel_consumed=true end
  return wheel
end
-- Closed selectors cycle; open popup lists retain native scrolling.
function M.cycle(app,values,current,locked)
  local wheel=M.wheel(app,locked)
  if wheel==0 or #values==0 then return current,false end
  local index=1
  for i,value in ipairs(values)do if value==current then index=i;break end end
  if type(current)=='number' and type(values[1])=='number' then
    if wheel>0 then
      for _,value in ipairs(values)do if value>current then return value,true end end
      return values[#values],true
    end
    for i=#values,1,-1 do if values[i]<current then return values[i],true end end
    return values[1],true
  end
  index=math.max(1,math.min(#values,index+(wheel>0 and 1 or -1)))
  return values[index],true
end
function M.scroll_window(app)
  local I,c=app.ImGui,app.ctx
  if not app.control_wheel_consumed and I.IsWindowHovered(c) and not I.IsAnyItemActive(c) then
    local wheel=I.GetMouseWheel(c)
    if wheel~=0 then I.SetScrollY(c,math.max(0,I.GetScrollY(c)-wheel*I.GetTextLineHeight(c)*3))end
  end
end
function M.input(app,label,value,default,quiet)
  local I,c=app.ImGui,app.ctx
  if not I.IsItemHovered(c) or not I.IsWindowHovered(c) then return 0,false end
  if not quiet then I.SetTooltip(c,string.format('%s: %s\nWheel: adjust / right-click: reset (%s)',label,tostring(value),tostring(default)))end
  if I.IsAnyItemActive(c) then return 0,false end
  local reset=I.IsMouseClicked(c,I.MouseButton_Right)
  return M.wheel(app),reset
end
function M.number(app,target,key,default,step,lo,hi,label,quiet)
  local wheel,reset=M.input(app,label or key,target[key],default,quiet)
  if reset then target[key]=default
  elseif wheel~=0 then
    local value=target[key]+(wheel>0 and 1 or -1)*step
    target[key]=math.max(lo,math.min(hi,value))
  end
  return reset or wheel~=0
end
function M.choice(app,target,key,default,values,label,quiet)
  local wheel,reset=M.input(app,label or key,target[key],default,quiet)
  if reset then target[key]=default;return true end
  if wheel~=0 then
    if type(target[key])=='number' and type(values[1])=='number' then
      local current=target[key];local value=wheel>0 and values[#values]or values[1]
      if wheel>0 then for _,v in ipairs(values)do if v>current then value=v;break end end
      else for i=#values,1,-1 do if values[i]<current then value=values[i];break end end end
      target[key]=value;return true
    end
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
