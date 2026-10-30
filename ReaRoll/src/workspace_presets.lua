-- @noindex
local Suite=require 'src.suite_theme'
local M={section='ReaRoll.WorkspacePresets'}
local layout={inspector_open='b',lane_stack_enabled='b',lane_open='b',lane_tools_open='b',lane_refs_expanded='b',lane_height={60,1000},lane_target='s',lane_stack_targets='s',lane_pin_1='s',lane_pin_2='s',cc_number={0,127},row_height={5,80}}
local theme={ui_scale={.8,1.5},uniform_note_color='b',note_color_mode='s',scale_opacity={.02,.4},playhead_color_custom='b',playhead_color={0,4294967295},playhead_width={.1,20},playhead_opacity={0,1},playhead_glow={0,1},playhead_trail={0,1}}
local flags={sources_open=true,expression_editor_open=true}
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)if #s%2~=0 or s:find('[^%da-f]')then return nil end;return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local function valid(value,rule)
  if rule=='b'then return type(value)=='boolean'end
  if rule=='s'then return type(value)=='string'and #value<=150 and not value:find('[\r\n\t]')end
  return type(value)=='number'and value==value and value>=rule[1]and value<=rule[2]
end
function M.capture(app,kind)
  local data={kind=kind,values={}};local spec=kind=='layout'and layout or theme
  for key,rule in pairs(spec)do local value=app.settings[key];if valid(value,rule)then data.values[key]=value end end
  if kind=='layout'then for key in pairs(flags)do data.values['app.'..key]=app[key]==true end
  elseif kind=='theme'then for _,key in ipairs(Suite.KEYS)do data.values['color.'..key]=app.theme_state.colors[key]end end
  return data
end
function M.validate(data)
  if type(data)~='table'or(data.kind~='layout'and data.kind~='theme')or type(data.values)~='table'then return false end
  local spec=data.kind=='layout'and layout or theme;local count=0;local colors={};for _,key in ipairs(Suite.KEYS)do colors['color.'..key]=true end
  for key,value in pairs(data.values)do
    if type(key)~='string'then return false end
    count=count+1
    if spec[key]then if not valid(value,spec[key])then return false end
    elseif data.kind=='layout'and flags[key:match('^app%.(.+)$')]then if type(value)~='boolean'then return false end
    elseif data.kind=='theme'and colors[key]then if not valid(value,{0,4294967295})or value%1~=0 then return false end
    else return false end
  end
  return count>0 and count<=64
end
function M.encode(data)
  assert(M.validate(data),'Invalid workspace preset');local out={'RRWORK1\t'..data.kind};local keys={};for key in pairs(data.values)do keys[#keys+1]=key end;table.sort(keys)
  for _,key in ipairs(keys)do local value=data.values[key];local kind=type(value):sub(1,1)
    out[#out+1]=key..'\t'..kind..'\t'..(kind=='b'and(value and '1'or '0')or kind=='s'and hex(value)or string.format('%.17g',value))
  end
  return table.concat(out,'\n')
end
function M.decode(raw)
  if type(raw)~='string'or #raw>20000 then return nil,'Preset data is invalid.'end
  local kind=raw:match('^RRWORK1\t(%a+)');local data={kind=kind,values={}};local first=true
  for line in(raw..'\n'):gmatch('(.-)\n')do
    if first then if line~='RRWORK1\t'..tostring(kind)then return nil,'Unknown preset format.'end;first=false
    else local key,t,value=line:match('^([^\t]+)\t([bns])\t(.*)$')
      if not key or data.values[key]~=nil or t=='b'and value~='0'and value~='1'then return nil,'Malformed preset.'end
      if t=='b'then value=value=='1'elseif t=='n' then value=tonumber(value)else value=unhex(value)end
      if value==nil then return nil,'Malformed preset value.'end;data.values[key]=value
    end
  end
  if not M.validate(data)then return nil,'Preset contains unsupported or invalid settings.'end
  return data
end
function M.apply(app,data)
  if not M.validate(data)then return false,'Invalid preset.'end
  if app.gesture or app.edit and app.edit.active or app.transform_preview or app.lane_tool_preview or app.multi_notes and(app.multi_notes.paint or app.multi_notes.transaction)then return false,'Finish the active edit before changing the workspace.'end
  for key,value in pairs(data.values)do
    local flag=key:match('^app%.(.+)$');local color=key:match('^color%.(.+)$')
    if flag then app[flag]=value elseif color then app.theme_state.colors[color]=value else app.settings[key]=value end
  end
  if data.kind=='theme'then Suite.ensure_contrast(app.theme_state);Suite.save(reaper,app.theme_state);require('src.ui.appearance').apply(app)end
  return true
end
function M.names(kind)
  local out={};for name in reaper.GetExtState(M.section,'names_'..kind):gmatch('[^\n]+')do local decoded=unhex(name);if decoded then out[#out+1]=decoded end end;return out
end
function M.save(name,data)
  name=(name or ''):match('^%s*(.-)%s*$');if name==''or #name>80 or not M.validate(data)then return false,'Enter a preset name of 1–80 bytes.'end
  local names=M.names(data.kind);local found=false;for _,n in ipairs(names)do if n==name then found=true end end;if not found then names[#names+1]=name end;table.sort(names)
  local encoded={};for _,n in ipairs(names)do encoded[#encoded+1]=hex(n)end
  reaper.SetExtState(M.section,data.kind..'_'..hex(name),M.encode(data),true);reaper.SetExtState(M.section,'names_'..data.kind,table.concat(encoded,'\n'),true);return true
end
function M.load(kind,name)return M.decode(reaper.GetExtState(M.section,kind..'_'..hex(name)))end
function M.delete(kind,name)
  local out={};for _,n in ipairs(M.names(kind))do if n~=name then out[#out+1]=hex(n)end end
  reaper.SetExtState(M.section,'names_'..kind,table.concat(out,'\n'),true);reaper.DeleteExtState(M.section,kind..'_'..hex(name),true)
end
return M
