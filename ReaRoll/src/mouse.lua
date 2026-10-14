-- @noindex
local M={}
M.defaults={clone='Shift',select='Ctrl',marquee='Ctrl or Shift',unsnap='Alt',right_note='Erase',double_note='Properties',empty='Draw'}
M.order={'clone','select','marquee','unsnap','right_note','double_note','empty'}
M.labels={clone='Clone note drag',select='Toggle note selection',marquee='Marquee on empty grid',unsnap='Bypass snap while editing',right_note='Right-click note',double_note='Double-click note',empty='Unmodified empty-grid drag'}
M.choices={clone={'Shift','Ctrl','Alt','None'},select={'Ctrl','Shift','None'},marquee={'Ctrl or Shift','Ctrl','Shift','None'},unsnap={'Alt','Shift','None'},right_note={'Erase','Marquee','Actions'},double_note={'Properties','Erase'},empty={'Draw','Marquee'}}
function M.value(s,key)return s.mouse and s.mouse[key] or M.defaults[key] end
function M.held(binding,mods)
  if binding=='Ctrl or Shift' then return mods.ctrl or mods.shift end
  return binding=='Ctrl' and mods.ctrl or binding=='Shift' and mods.shift or binding=='Alt' and mods.alt or false
end
function M.is(s,key,mods)return M.held(M.value(s,key),mods) end
function M.edit_mods(s,mods)
  return {ctrl=mods.ctrl,shift=mods.shift,alt=M.is(s,'unsnap',mods)}
end
return M
