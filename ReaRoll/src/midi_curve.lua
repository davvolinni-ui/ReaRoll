-- @noindex
-- Standard shapes use the SWS equations. Native Bézier controls are checked
-- against Envelope_Evaluate by tools/check_curves_host.lua.
local M={}
local function clamp(v,lo,hi)return math.max(lo,math.min(hi,v))end
function M.tension(point)
  local shape=point.shape
  if not shape or #shape.msg~=12 then return 0 end
  local ok,v=pcall(string.unpack,'f',shape.msg,9)
  return ok and v==v and clamp(v,-1,1)or 0
end
local function cubic(a,b,c,d,t)
  local u=1-t;return u*u*u*a+3*u*u*t*b+3*u*t*t*c+t*t*t*d
end
function M.value(points,index,time,minimum,maximum)
  local a,b=points[index],points[index+1]
  if not a then return nil end
  if not b or time<=a.time then return a.value end
  if time>=b.time or b.time<=a.time then return b.value end
  local t=(time-a.time)/(b.time-a.time);local shape=((a.flags or 0)>>4)&15
  if shape==0 then return a.value
  elseif shape==1 then return a.value+(b.value-a.value)*t
  elseif shape==2 then return a.value+(b.value-a.value)*t*t*(3-2*t)
  elseif shape==3 then return a.value+(b.value-a.value)*(1-(1-t)^3)
  elseif shape==4 then return a.value+(b.value-a.value)*t^3
  elseif shape~=5 then return nil end
  if a.value==b.value then return a.value end
  local dx=(b.time-a.time)*.25
  local x1,x2=a.time+dx,b.time-dx
  local before,after=points[index-1],points[index+2]
  local y1=a.value+(b.value-a.value)*.125
  local y2=b.value-(b.value-a.value)*.125
  if before and (((before.flags or 0)>>4)&15)==5 and a.time>before.time then
    local incoming=(a.value-before.value)/(a.time-before.time)
    local outgoing=(b.value-a.value)/(b.time-a.time)
    y1=a.value+dx*(incoming+outgoing)*.5
  end
  if after and (((after.flags or 0)>>4)&15)==5 and after.time>b.time then
    local incoming=(b.value-a.value)/(b.time-a.time)
    local outgoing=(after.value-b.value)/(after.time-b.time)
    y2=b.value-dx*(incoming+outgoing)*.5
  end
  local low,high=math.max(minimum,math.min(a.value,b.value)),math.min(maximum,math.max(a.value,b.value))
  y1,y2=clamp(y1,low,high),clamp(y2,low,high)
  local tension=M.tension(a)
  x1=x1+tension*(tension>0 and b.time-x1 or x1-a.time)
  x2=x2+tension*(tension>0 and b.time-x2 or x2-a.time)
  y1=y1-tension*(tension>0 and y1-a.value or b.value-y1)
  y2=y2-tension*(tension>0 and y2-a.value or b.value-y2)
  x1,x2=clamp(x1,a.time,b.time),clamp(x2,a.time,b.time)
  y1,y2=clamp(y1,minimum,maximum),clamp(y2,minimum,maximum)
  -- Match the native/WDL eight-step bracket and linear interpolation.
  local lo,hi=0,1
  for _=1,8 do local mid=(lo+hi)*.5;local x=cubic(a.time,x1,x2,b.time,mid)
    if x<time then lo=mid elseif x>time then hi=mid else lo=mid;hi=math.min(1,mid+1/256);break end
  end
  local left,right=cubic(a.time,x1,x2,b.time,lo),cubic(a.time,x1,x2,b.time,hi)
  local low_value,high_value=cubic(a.value,y1,y2,b.value,lo),cubic(a.value,y1,y2,b.value,hi)
  return left==right and low_value or low_value+(time-left)*(high_value-low_value)/(right-left)
end
return M
