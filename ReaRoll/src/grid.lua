-- @noindex
local M={}
function M.resolve(px_per_qn)
  local step=1/32
  while step*px_per_qn<24 and step<4 do step=step*2 end
  return step
end
function M.update(app)
  if app.settings.adaptive_grid and not app.gesture and app.viewport.px_per_qn then
    app.settings.grid_qn=M.resolve(app.viewport.px_per_qn)
  end
end
function M.note_length(settings)
  return (settings.mode=='paint' or settings.length_follow_grid) and settings.grid_qn or settings.length_qn
end
return M
