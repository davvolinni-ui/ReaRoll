-- @noindex
local M={modes={'track','channel','pitch','velocity','single'}}
local pitch={0xEB6A68FF,0xE98C55FF,0xDEB653FF,0xA9C957FF,0x69BF79FF,0x4DBBA7FF,0x54B8CEFF,0x609EE5FF,0x7B83E4FF,0xA47BD8FF,0xCD75BDFF,0xE77196FF}
local function blend(a,b,t)
  local result=255;for _,shift in ipairs({8,16,24})do result=result|(math.floor(((a>>shift)&255)*(1-t)+((b>>shift)&255)*t+.5)<<shift)end;return result
end
function M.base(settings,theme,note,track_color)
  local mode=settings.note_color_mode or 'track'
  if settings.uniform_note_color or mode=='single'then return theme.note end
  if mode=='pitch'then return pitch[(note.pitch or 0)%12+1]end
  if mode=='velocity'then
    local value=math.max(0,math.min(1,(note.vel or 100)/127))
    return value<.5 and blend(0x548EE5FF,0x59C998FF,value*2)or blend(0x59C998FF,0xED7065FF,(value-.5)*2)
  end
  if mode=='channel'then return theme.channel_colors[(note.chan or 0)+1]or theme.note end
  return track_color or theme.note
end
return M
