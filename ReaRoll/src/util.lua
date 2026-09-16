-- @noindex
local M = {}
function M.clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
function M.snap(v,step) return math.floor(v/step+.5)*step end
function M.snap_mode(settings)
  if settings.snap_mode then return settings.snap_mode end
  return settings.snap_enabled==false and 'off' or 'absolute'
end
function M.snap_time(settings,value,origin)
  local mode=M.snap_mode(settings); if mode=='off' then return value end
  if mode=='relative' and origin~=nil then return origin+M.snap(value-origin,settings.grid_qn) end
  return M.snap(value,settings.grid_qn)
end
function M.contains(x,y,x1,y1,x2,y2) return x>=x1 and x<=x2 and y>=y1 and y<=y2 end
function M.is_black(p) local n=p%12 return n==1 or n==3 or n==6 or n==8 or n==10 end
function M.pitch_name(p)
  local names={'C','C#','D','D#','E','F','F#','G','G#','A','A#','B'}
  return names[p%12+1]..tostring(math.floor(p/12)-1)
end
function M.color_scale(c,factor)
  local r=(c>>24)&0xFF; local g=(c>>16)&0xFF; local b=(c>>8)&0xFF; local a=c&0xFF
  r=M.clamp(math.floor(r*factor+.5),0,255); g=M.clamp(math.floor(g*factor+.5),0,255); b=M.clamp(math.floor(b*factor+.5),0,255)
  return (r<<24)|(g<<16)|(b<<8)|a
end
function M.track_color(track,fallback)
  local native=track and reaper.GetTrackColor and reaper.GetTrackColor(track) or 0
  local rgb=native and (native&0xFFFFFF) or 0
  if not native or native==0 or rgb==0 or not reaper.ColorFromNative then return fallback end
  local r,g,b=reaper.ColorFromNative(rgb)
  if r==nil then return fallback end
  return (r<<24)|(g<<16)|(b<<8)|0xFF
end
function M.mods(ImGui,ctx)
  local b=ImGui.GetKeyMods(ctx)
  -- Use the physical Windows modifier state whenever available. ReaImGui can
  -- retain a Ctrl/Shift bit after focus moves through an auxiliary window,
  -- which turns an ordinary draw click into a marquee-selection gesture.
  -- This also keeps wheel modifiers working over an unfocused dock.
  if reaper.JS_Mouse_GetState then
    local physical=reaper.JS_Mouse_GetState(28)
    return {ctrl=(physical&4)~=0,shift=(physical&8)~=0,alt=(physical&16)~=0}
  end
  return {ctrl=(b&ImGui.Mod_Ctrl)~=0,shift=(b&ImGui.Mod_Shift)~=0,alt=(b&ImGui.Mod_Alt)~=0}
end
return M
