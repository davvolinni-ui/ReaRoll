-- @noindex
local M={section='ReaRoll.ToolPresets'}
-- Only tool parameters are persisted. Sources, selections, MIDI channels,
-- edit scope and expression-mode flags are deliberately outside this schema.
local schema={
 ['Timing quantize']={a={lane_quantize_ends=false,lane_quantize_step=.25,lane_quantize_strength=100,lane_quantize_swing=0,groove_enabled=false,groove_slot=1,groove_velocity_strength=0}},
 ['Scale quantize']={a={lane_scale_direction=0},s={scale_root=0,scale_name='Major'}},
 Legato={a={legato_release_qn=0,legato_target='same_pitch'}},
 Humanize={a={human_timing_bias=0,human_preserve_chords=true},s={human_time=8,human_velocity=6}},
 ['Strum / Flam']={a={performance_preview='strum',strum_direction=1},s={strum_qn=.03,flam_qn=.04}},
 Arpeggiator={a={arp_direction='up',arp_gate=.85,arp_octaves=1,arp_swing=0,arp_rhythm='11111111',arp_accent=0,arp_restart=true,arp_rate=.25,arp_seed=1}},
 Velocity={a={velocity_tool_mode='ramp',velocity_set=100,velocity_first=60,velocity_last=110,velocity_scale=1,velocity_pivot=96}},
 Pitch={a={lane_pitch_amount=0,lane_pitch_in_scale=false}},
}
local ranges={lane_quantize_step={.000001,64},lane_quantize_strength={0,100},lane_quantize_swing={0,75},groove_slot={1,8},groove_velocity_strength={0,100},lane_scale_direction={-1,1},scale_root={0,11},legato_release_qn={-.25,.25},human_timing_bias={-100,100},human_time={0,50},human_velocity={0,40},strum_qn={0,.2},flam_qn={.005,.2},arp_gate={.01,1},arp_rate={.000001,64},arp_octaves={1,4},arp_swing={0,.75},arp_accent={0,127},velocity_set={1,127},velocity_first={1,127},velocity_last={1,127},velocity_scale={0,2},velocity_pivot={1,127},lane_pitch_amount={-24,24}}
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)if not s or #s%2~=0 or s:find('[^%da-f]')then return nil end;return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
function M.supported(kind)return schema[kind]~=nil end
function M.capture(app,kind)
  local fields=schema[kind];if not fields then return nil end
  local out={kind=kind,values={}}
  for scope,keys in pairs(fields)do local source=scope=='s' and app.settings or app
    for key,default in pairs(keys)do local v=source[key];if v==nil then v=(key=='arp_rate' or key=='lane_quantize_step') and app.settings.grid_qn or default end
      if type(v)~=type(default)then v=default end
      out.values[scope..'.'..key]=v
    end
  end
  return out
end
function M.encode(preset)
  local out={'RRTOOL1\t'..hex(preset.kind)};local keys={};for key in pairs(preset.values)do keys[#keys+1]=key end;table.sort(keys)
  for _,key in ipairs(keys)do local value=preset.values[key];local tag=type(value):sub(1,1);out[#out+1]=key..'\t'..tag..'\t'..hex(tostring(value))end
  return table.concat(out,'\n')
end
function M.decode(raw,kind)
  if type(raw)~='string' or #raw>12000 or not schema[kind]then return nil,'Unsupported tool preset.'end
  local lines={};for line in (raw..'\n'):gmatch('(.-)\n')do lines[#lines+1]=line end
  if unhex(lines[1]:match('^RRTOOL1\t(%x+)$'))~=kind then return nil,'The preset belongs to another tool.'end
  local out={kind=kind,values={}}
  for i=2,#lines do
    local scope,key,tag,encoded=lines[i]:match('^([as])%.([%w_]+)\t([bns])\t(%x*)$')
    local default=scope and schema[kind][scope] and schema[kind][scope][key]
    if default==nil or out.values[scope..'.'..key]~=nil then return nil,'Unknown or repeated tool parameter.'end
    local value=unhex(encoded)
    if tag=='b' then if value~='true' and value~='false'then return nil,'Invalid toggle.'end;value=value=='true'
    elseif tag=='n' then value=tonumber(value);if not value or value~=value or math.abs(value)>100000 then return nil,'Invalid numeric parameter.'end
    elseif not value or #value>512 then return nil,'Invalid text parameter.'end
    if type(value)~=type(default)then return nil,'Tool parameter type mismatch.'end
    local range=ranges[key];if range and (value<range[1] or value>range[2])then return nil,'Tool parameter is out of range.'end
    out.values[scope..'.'..key]=value
  end
  for scope,keys in pairs(schema[kind])do for key in pairs(keys)do if out.values[scope..'.'..key]==nil then return nil,'Incomplete tool preset.'end end end
  return out
end
function M.apply(app,preset)
  local checked,notice=M.decode(M.encode(preset),preset.kind);if not checked then return false,notice end
  if app.transform_preview then app.transforms.cancel_preview(app)end
  for path,value in pairs(checked.values)do local scope,key=path:match('^([as])%.(.+)$');local target=scope=='s' and app.settings or app;target[key]=value end
  return true
end
function M.names(kind)
  local out={};for name in reaper.GetExtState(M.section,'names_'..hex(kind)):gmatch('[^\n]+')do local n=unhex(name);if n then out[#out+1]=n end end;return out
end
function M.save(app,kind,name)
  name=(name or ''):match('^%s*(.-)%s*$');if name=='' or #name>80 then return false,'Enter a preset name of 1–80 bytes.'end
  local preset=M.capture(app,kind);if not preset then return false,'This tool does not support presets yet.'end
  local raw=M.encode(preset);local checked,notice=M.decode(raw,kind);if not checked then return false,notice end
  local names=M.names(kind);local found=false;for _,n in ipairs(names)do if n==name then found=true end end;if not found then names[#names+1]=name end;table.sort(names)
  local encoded={};for _,n in ipairs(names)do encoded[#encoded+1]=hex(n)end
  reaper.SetExtState(M.section,'preset_'..hex(kind)..'_'..hex(name),raw,true);reaper.SetExtState(M.section,'names_'..hex(kind),table.concat(encoded,'\n'),true);return true
end
function M.load(app,kind,name)
  local preset,notice=M.decode(reaper.GetExtState(M.section,'preset_'..hex(kind)..'_'..hex(name)),kind)
  if not preset then return false,notice end
  local ok,message=M.apply(app,preset);if ok and kind=='Arpeggiator'then app.arp_preset=nil end;return ok,message
end
function M.delete(kind,name)
  local out={};for _,n in ipairs(M.names(kind))do if n~=name then out[#out+1]=hex(n)end end
  reaper.SetExtState(M.section,'names_'..hex(kind),table.concat(out,'\n'),true);reaper.DeleteExtState(M.section,'preset_'..hex(kind)..'_'..hex(name),true)
end
return M
