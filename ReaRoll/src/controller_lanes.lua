-- @noindex
-- Stable parameter identities shared by editable and reference lanes. Channel
-- filtering is separate from parameter identity; labels are presentation only.
local M={}
M.names={[0]='Bank Select MSB',[1]='Mod Wheel',[2]='Breath',[3]='Controller 3',[4]='Foot Controller',[5]='Portamento Time',[6]='Data Entry MSB',[7]='Channel Volume',[8]='Balance',[9]='Controller 9',[10]='Pan',[11]='Expression',[12]='Effect Control 1',[13]='Effect Control 2',[16]='General Purpose 1',[17]='General Purpose 2',[18]='General Purpose 3',[19]='General Purpose 4',[32]='Bank Select LSB',[38]='Data Entry LSB',[64]='Sustain',[65]='Portamento',[66]='Sostenuto',[67]='Soft Pedal',[68]='Legato Footswitch',[69]='Hold 2',[70]='Sound Variation',[71]='Resonance',[72]='Release Time',[73]='Attack Time',[74]='Brightness',[75]='Decay Time',[76]='Vibrato Rate',[77]='Vibrato Depth',[78]='Vibrato Delay',[79]='Sound Controller 10',[80]='General Purpose 5',[81]='General Purpose 6',[82]='General Purpose 7',[83]='General Purpose 8',[84]='Portamento Control',[91]='Reverb Send',[92]='Tremolo Depth',[93]='Chorus Send',[94]='Celeste Depth',[95]='Phaser Depth',[96]='Data Increment',[97]='Data Decrement',[98]='NRPN LSB',[99]='NRPN MSB',[100]='RPN LSB',[101]='RPN MSB',[120]='All Sound Off',[121]='Reset Controllers',[122]='Local Control',[123]='All Notes Off',[124]='Omni Off',[125]='Omni On',[126]='Mono Mode',[127]='Poly Mode'}
M.short_names={[1]='Mod',[7]='Volume',[10]='Pan',[11]='Expr',[64]='Sustain',[74]='Bright',[91]='Reverb',[93]='Chorus'}
local basic={velocity={label='Note-on Velocity',short='VEL'},pitch={label='Pitch Bend',short='PB',pitch=true},pressure={label='Channel Aftertouch (Pressure)',short='AT',status=0xD0},program={label='Program Change',short='PC',status=0xC0,discrete=true}}
function M.identity(target,cc_number)
  if basic[target] then return target end
  local number=target=='cc' and tonumber(cc_number or 1) or type(target)=='string' and tonumber(target:match('^cc(%d+)$'))
  if not number or number~=number or number%1~=0 or number<0 or number>127 then return nil end
  return 'cc'..number
end
function M.definition(settings,names,short_names)
  names=names or M.names;short_names=short_names or M.short_names
  local id=M.identity(settings.lane_target,settings.cc_number)
  if not id then id='velocity' end
  local result={id=id}
  if basic[id] then for k,v in pairs(basic[id]) do result[k]=v end; return result end
  local cc=tonumber(id:sub(3))
  result.cc=cc
  result.label=((names or {})[cc] or 'Controller')..' (CC '..cc..')'
  result.short=(short_names or {})[cc] or ('CC '..cc)
  result.center=(cc==8 or cc==10) and 64 or nil
  result.switch=cc>=64 and cc<=69
  result.discrete=cc>=96 and cc<=101
  result.protected=cc>=120
  return result
end
function M.matches(lane,event,channel)
  if not event or event.chan~=channel then return false end
  return not not (lane.pitch and event.chanmsg==0xE0
    or lane.status and event.chanmsg==lane.status
    or lane.cc~=nil and event.chanmsg==0xB0 and event.msg2==lane.cc)
end
function M.references(settings)
  local pins={}
  local active=M.identity(settings.lane_target,settings.cc_number) or 'velocity'
  local seen={[active]=true}
  for slot=1,settings.lane_refs_expanded and 2 or 0 do
    local target=M.identity(settings['lane_pin_'..slot],settings.cc_number)
    if target and not seen[target] then
      seen[target]=true; pins[#pins+1]={slot=slot,target=target}
    end
  end
  return pins
end
function M.targets(settings)
  local active=M.identity(settings.lane_target,settings.cc_number) or 'velocity'
  local targets,seen={},{}
  if settings.lane_stack_enabled then
    for target in (settings.lane_stack_targets or 'velocity,cc1,cc11'):gmatch('[^,]+') do
      local id=M.identity(target,settings.cc_number)
      if id and not seen[id] and #targets<4 then targets[#targets+1]=id; seen[id]=true end
    end
    if not seen[active] then
      if #targets>=4 then seen[targets[#targets]]=nil; table.remove(targets) end
      targets[#targets+1]=active
    end
  else targets={active} end
  return targets
end
function M.stack(settings,height)
  local active=M.identity(settings.lane_target,settings.cc_number) or 'velocity'
  local targets=M.targets(settings)
  -- A small dock shows the focused lane instead of creating unpickable graphs.
  if #targets>1 and height/#targets<48 then targets={active} end
  local rows={}; local top=0
  for index,id in ipairs(targets) do
    local size=index==#targets and height-top or math.floor(height/#targets)
    rows[#rows+1]={id=id,top=top,height=size}; top=top+size
  end
  return rows
end
function M.set_targets(settings,targets)
  local clean,seen={},{}
  for _,target in ipairs(targets) do local id=M.identity(target,settings.cc_number)
    if id and not seen[id] and #clean<4 then clean[#clean+1]=id; seen[id]=true end
  end
  if #clean==0 then clean={'velocity'} end
  settings.lane_stack_targets=table.concat(clean,',')
end
-- Lane operations own their layout state; no separate stack-mode setup.
function M.add_below(settings,id)
  local targets=M.targets(settings);if #targets>=4 then return false end
  local used={};for _,target in ipairs(targets)do used[target]=true end
  local addition;for _,target in ipairs({'velocity','cc1','cc11','pitch','pressure','cc74'})do if not used[target]then addition=target;break end end
  local result={};local inserted=false
  for _,target in ipairs(targets)do result[#result+1]=target;if target==id then result[#result+1]=addition;inserted=true end end
  if not inserted then return false end
  M.set_targets(settings,result);settings.lane_stack_enabled=true;settings.lane_open=true
  settings.lane_height=math.max(settings.lane_height or 126,70*#result+40)
  return true
end
function M.remove(settings,id)
  local targets=M.targets(settings);if #targets<=1 then return false end
  local result={};for _,target in ipairs(targets)do if target~=id then result[#result+1]=target end end
  if #result==#targets then return false end
  if M.identity(settings.lane_target,settings.cc_number)==id then settings.lane_target=result[1]end
  M.set_targets(settings,result);settings.lane_stack_enabled=#result>1
  return true
end
return M
