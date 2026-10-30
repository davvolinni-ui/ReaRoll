-- @noindex
local M={}
function M.target(q,step,swing,anchor)
  step=math.max(1e-6,step or .25); anchor=anchor or 0
  swing=math.max(0,math.min(.75,swing or 0))
  local index=math.floor((q-anchor)/step)
  local best,distance
  for i=index-2,index+2 do
    local candidate=anchor+i*step+(i%2==1 and step*swing or 0)
    local delta=math.abs(candidate-q)
    if not distance or delta<distance-1e-9 or math.abs(delta-distance)<1e-9 and candidate>best then best,distance=candidate,delta end
  end
  return best
end
function M.paint_hit(q,item_start,step,every)
  every=math.max(1,math.min(16,math.floor(every or 1)))
  local first=math.ceil((item_start-1e-8)/step)*step
  local index=math.floor((q-first)/step+.5)
  return index>=0 and index%every==0
end
return M
