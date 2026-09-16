-- @noindex
local M={SECTION='ReaRoll.KeyColors'}

local function encode(colors)
  local out={}
  for pitch=0,127 do if colors[pitch] then out[#out+1]=pitch..':'..tostring(colors[pitch]) end end
  return table.concat(out,',')
end

local function decode(raw)
  local out={}
  for pitch,color in (raw or ''):gmatch('(%d+):(%d+)') do out[tonumber(pitch)]=tonumber(color) end
  return out
end

local function track_key(track)
  if not track then return nil end
  local guid=reaper.GetTrackGUID and reaper.GetTrackGUID(track)
  if (not guid or guid=='') and reaper.GetSetMediaTrackInfo_String then local ok,value=reaper.GetSetMediaTrackInfo_String(track,'GUID','',false); if ok then guid=value end end
  return guid and ('track_'..guid:gsub('[^%w]','')) or nil
end

function M.load_track(track)
  local key=track_key(track); if not key or not reaper.GetProjExtState then return {} end
  local ok,raw=reaper.GetProjExtState(0,M.SECTION,key); return ok==1 and decode(raw) or {}
end

function M.save_track(track,colors)
  local key=track_key(track); if key and reaper.SetProjExtState then reaper.SetProjExtState(0,M.SECTION,key,encode(colors or {})) end
end

function M.presets()
  local names={}; local raw=reaper.GetExtState(M.SECTION,'presets') or ''
  for name in raw:gmatch('[^|]+') do names[#names+1]=name end
  return names
end

function M.save_preset(name,colors)
  name=(name or ''):gsub('[|\r\n]',''):match('^%s*(.-)%s*$'); if name=='' then return false end
  local names=M.presets(); local found=false; for _,existing in ipairs(names) do if existing==name then found=true end end
  if not found then names[#names+1]=name; table.sort(names); reaper.SetExtState(M.SECTION,'presets',table.concat(names,'|'),true) end
  reaper.SetExtState(M.SECTION,'preset_'..name,encode(colors or {}),true); return true
end

function M.load_preset(name) return decode(reaper.GetExtState(M.SECTION,'preset_'..name) or '') end
function M.delete_preset(name)
  local kept={}; for _,existing in ipairs(M.presets()) do if existing~=name then kept[#kept+1]=existing end end
  reaper.SetExtState(M.SECTION,'presets',table.concat(kept,'|'),true); reaper.DeleteExtState(M.SECTION,'preset_'..name,true)
end

return M
