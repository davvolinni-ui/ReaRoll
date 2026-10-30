-- @noindex
local M={}
function M.load(app)
 local chosen,path=reaper.GetUserFileNameForRead('','Load articulation map (.rrmap)','rrmap')
 if not chosen then return end
 local raw,notice=require('src.map_exchange').read(path)
 if not raw then app.inspector_articulation_notice=notice;return end
 local Map=require 'src.instrument_map';local loaded;loaded,notice=Map.decode(raw:gsub('\r\n','\n'):gsub('\n+$',''))
 if not loaded or #loaded.articulations==0 then app.inspector_articulation_notice=notice or 'This file contains no articulation definitions. Choose a ReaRoll instrument map.';return end
 local current=Map.copy(app.instrument_map or Map.new());current.articulations=loaded.articulations
 local ok;ok,notice=Map.save(app,current);app.inspector_articulation_notice=notice;return ok
end
function M.setup(app)
 app.instrument_map_open=true;app.instrument_map_section='articulations'
end
function M.menu(app)
 local I,c=app.ImGui,app.ctx;local entries=app.instrument_map and app.instrument_map.articulations or {}
 if #entries==0 then
  if I.MenuItem(c,'Load articulation map...')then M.load(app)end
  if I.MenuItem(c,'Set up articulations...')then M.setup(app)end
 elseif I.BeginMenu(c,'Articulation')then
  I.TextDisabled(c,'Assign to selected notes')
  local groups,seen={},{}
  for _,entry in ipairs(entries)do local group=entry.group or 'Playing style';if not seen[group]then seen[group]=true;groups[#groups+1]=group end end
  for _,group in ipairs(groups)do
   I.Separator(c);I.TextDisabled(c,group)
   for _,entry in ipairs(entries)do if (entry.group or 'Playing style')==group then
    if I.MenuItem(c,'Default ('..entry.name..')##clear'..group)then local _,notice=require('src.articulations').assign_notes(app,entry,nil,true);app.inspector_articulation_notice=notice end;break
   end end
   for i,entry in ipairs(entries)do if (entry.group or 'Playing style')==group and I.MenuItem(c,entry.name..'##artcontext'..i)then
    local _,notice=require('src.articulations').assign_notes(app,entry);app.inspector_articulation_notice=notice
   end end
  end
  I.Separator(c)
  if I.MenuItem(c,'Load another map...')then M.load(app)end
  if I.MenuItem(c,'Instrument setup...')then M.setup(app)end
  I.EndMenu(c)
 end
end
return M
