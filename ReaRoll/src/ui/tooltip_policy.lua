-- @noindex
local M={}
-- Wrap only this editor's API; never change the shared ReaImGui module.
function M.wrap(api,settings)
  local last,started,seen
  local proxy=setmetatable({},{__index=api})
  function proxy.SetTooltip(ctx,text,...)
    if settings.tooltips_enabled==false then last=nil;return end
    local now=api.GetTime(ctx)
    if text~=last or not seen or now-seen>.15 then last=text;started=now end
    seen=now
    if now-started>=math.max(0,settings.tooltip_delay or .45)then return api.SetTooltip(ctx,text,...)end
  end
  return proxy
end
return M
