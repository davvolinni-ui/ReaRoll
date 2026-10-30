-- @noindex
local M={}
function M.key(area)
  local lane=area.lane
  return tostring(area.channel)..':'..(lane.pitch and 'pitch' or lane.status==0xD0 and 'pressure' or 'cc'..tostring(lane.cc))
end
function M.list(app,active)
  active=active or app.controller_razor
  local out,seen={},{}
  -- Replace only an earlier version of the active area, not another region on
  -- the same parameter. Disjoint selections on one lane remain independent.
  if active then seen[active.identity or active]=true end
  for _,a in ipairs(app.controller_razor_areas or {})do
    local key=a.identity or a
    if a.end_qn>a.start_qn and not seen[key]then out[#out+1]=a;seen[key]=true end
  end
  if active and active.end_qn>active.start_qn then out[#out+1]=active end
  return out
end
function M.union(areas)
  local sorted={};for _,a in ipairs(areas)do if a.end_qn>a.start_qn then sorted[#sorted+1]=a end end
  table.sort(sorted,function(a,b)local x,y=M.key(a),M.key(b);if x~=y then return x<y end;return a.start_qn<b.start_qn end)
  local out={}
  for _,a in ipairs(sorted)do local last=out[#out]
    if last and M.key(last)==M.key(a)and a.start_qn<=last.end_qn then last.end_qn=math.max(last.end_qn,a.end_qn)
    else out[#out+1]={start_qn=a.start_qn,end_qn=a.end_qn,lane=a.lane,channel=a.channel,identity=a.identity or a,pedal_cycle=a.pedal_cycle}end
  end
  return out
end
function M.set(app,areas,focus)
  app.controller_razor_areas={};app.controller_razor=nil
  local active
  if focus then for _,a in ipairs(areas)do if(a.identity or a)==(focus.identity or focus)then active=a;break end end end
  active=active or areas[#areas]
  for _,a in ipairs(areas)do if a==active then app.controller_razor=a else app.controller_razor_areas[#app.controller_razor_areas+1]=a end end
end
function M.translate(a,delta,scale)
  return {start_qn=a.start_qn+delta,end_qn=a.start_qn+delta+(a.end_qn-a.start_qn)*(scale or 1),lane=a.lane,channel=a.channel,identity=a.identity or a,pedal_cycle=a.pedal_cycle}
end
return M
