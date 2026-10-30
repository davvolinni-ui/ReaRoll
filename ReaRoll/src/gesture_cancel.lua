-- @noindex
local Shortcuts=require 'src.shortcuts'
local U=require 'src.util'
local M={}
local cancellable={slide_edit=true,slide_draw=true,expression_copy=true,move=true,resize=true,stretch=true,draw=true,paint=true,
  erase=true,mute=true,chord_draw=true,velocity=true,velocity_swipe=true,cc=true,cc_move=true}
function M.poll(app)
  local g=app.gesture
  if not g or not cancellable[g.kind] or not app.edit.active then return false end
  -- Phrase previews own their own restoration and keyboard handling.
  if app.transform_preview or app.lane_tool_preview then return false end
  local I,c=app.ImGui,app.ctx
  if not I.IsWindowFocused(c,I.FocusedFlags_RootAndChildWindows) then return false end
  if not Shortcuts.pressed(app,'cancel',U.mods(I,c)) then return false end
  app.edit:cancel()
  app.audition:stop()
  app.gesture=nil
  app.cache:rebuild()
  app.cc_cache:rebuild()
  return true
end
return M
