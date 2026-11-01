-- @noindex
local M={contexts={'grid','keys','empty'},context_labels={grid='Note grid',keys='Piano keys',empty='Empty roll'}}
M.modifiers={'None','Ctrl','Shift','Ctrl+Shift','Alt','Ctrl+Alt','Shift+Alt','Ctrl+Shift+Alt'}
M.actions={'Disabled','Scroll pitches','Scroll time','Zoom time','Zoom pitch','Adjust note property','Divide selection'}
M.defaults={}
for _,context in ipairs(M.contexts) do
 for mask=0,7 do
  local ctrl,shift,alt=mask&1~=0,mask&2~=0,mask&4~=0
  local vertical,horizontal='Scroll pitches','Scroll time'
  if context=='grid' then
   if ctrl and shift then vertical='Divide selection'
   elseif ctrl then vertical=alt and 'Zoom pitch' or 'Zoom time';horizontal=vertical
   elseif alt then vertical='Adjust note property'
   elseif shift then vertical='Scroll time' end
  elseif context=='keys' then
   horizontal='Disabled'
   if ctrl or alt then vertical='Zoom pitch';horizontal=vertical end
  elseif ctrl then vertical='Zoom time';horizontal=vertical
  elseif shift then vertical='Scroll time' end
  M.defaults[context..'_v_'..mask]=vertical
  M.defaults[context..'_h_'..mask]=horizontal
 end
end
-- Apply only on explicit preset selection, never while loading saved settings.
function M.apply_preset(s,id)
 if id~='default' and id~='reaper' then return end
 s.wheel={}
 if id=='default' then return end
 local actions={[0]='Zoom time',[1]='Zoom pitch',[4]='Scroll time',[5]='Scroll pitches'}
 for _,context in ipairs({'grid','empty'}) do
  for mask,action in pairs(actions) do
   s.wheel[context..'_v_'..mask]=action
   -- Unmodified sideways input remains a horizontal scroll.
   if mask~=0 then s.wheel[context..'_h_'..mask]=action end
  end
 end
end
-- Keep stored names portable while displaying the keys printed on this platform.
function M.display(binding)
 local os=reaper.GetOS and reaper.GetOS() or ''
 if os:match('^OSX') or os:match('^macOS') then
  return (binding:gsub('Ctrl','Command'):gsub('Alt','Option'))
 end
 return binding
end
function M.value(s,key)return s and s.wheel and s.wheel[key] or M.defaults[key] end
function M.resolve(s,context,mods,vertical,horizontal)
 local mask=(mods.ctrl and 1 or 0)+(mods.shift and 2 or 0)+(mods.alt and 4 or 0)
 local key=context..(vertical~=0 and '_v_' or '_h_')..mask
 local delta=vertical~=0 and vertical or horizontal
 if s and s.wheel and s.wheel[key..'_reverse']=='1' then delta=-delta end
 return M.value(s,key),delta
end
function M.load(s)
 s.wheel={}
 for key,default in pairs(M.defaults) do
  local value=reaper.GetExtState('ReaRoll','wheel_'..key);local valid=false
  for _,action in ipairs(M.actions) do if action==value then valid=true end end
  s.wheel[key]=valid and value or default
  s.wheel[key..'_reverse']=reaper.GetExtState('ReaRoll','wheel_'..key..'_reverse')=='1' and '1' or '0'
 end
end
function M.save(s)
 for key in pairs(M.defaults) do
  reaper.SetExtState('ReaRoll','wheel_'..key,M.value(s,key),true)
  reaper.SetExtState('ReaRoll','wheel_'..key..'_reverse',s.wheel and s.wheel[key..'_reverse'] or '0',true)
 end
end
return M
