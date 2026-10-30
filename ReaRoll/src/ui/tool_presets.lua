-- @noindex
local Presets=require 'src.tool_presets'
local M={}
function M.draw(app,kind)
  if not Presets.supported(kind)then return end
  local I,c=app.ImGui,app.ctx
  if I.BeginMenu(c,'User presets')then
    app.tool_preset_names=app.tool_preset_names or {};local name=app.tool_preset_names[kind] or ''
    local changed;changed,name=I.InputText(c,'Preset name',name);app.tool_preset_names[kind]=name
    if I.Button(c,'Save current parameters')then local _,notice=Presets.save(app,kind,name);app.tool_preset_notice=notice end
    I.Separator(c)
    for _,saved in ipairs(Presets.names(kind))do
      if I.Selectable(c,saved)then local _,notice=Presets.load(app,kind,saved);app.tool_preset_notice=notice;app.tool_preset_names[kind]=saved;I.CloseCurrentPopup(c)end
    end
    if name~='' and I.Button(c,'Delete named preset')then Presets.delete(kind,name);app.tool_preset_names[kind]=''end
    if app.tool_preset_notice then I.TextWrapped(c,app.tool_preset_notice)end
    I.EndMenu(c)
  end
end
return M
