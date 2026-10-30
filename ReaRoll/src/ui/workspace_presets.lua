-- @noindex
local P=require 'src.workspace_presets'
local M={}
function M.draw(app)
  if not app.workspace_presets_open then return end
  local I,c=app.ImGui,app.ctx;I.SetNextWindowSize(c,440,330,I.Cond_FirstUseEver)
  local visible;visible,app.workspace_presets_open=I.Begin(c,'Workspace and theme presets',app.workspace_presets_open)
  if visible then
    app.workspace_preset_kind=app.workspace_preset_kind or 'layout'
    if I.RadioButton(c,'Workspace',app.workspace_preset_kind=='layout')then app.workspace_preset_kind='layout';app.workspace_preset_name=''end
    I.SameLine(c);if I.RadioButton(c,'Appearance',app.workspace_preset_kind=='theme')then app.workspace_preset_kind='theme';app.workspace_preset_name=''end
    local kind=app.workspace_preset_kind
    I.TextWrapped(c,kind=='layout'and 'Saves panels, row size and controller-lane layout. Musical settings, channels, bindings and the viewed time range stay as they are.'or 'Saves this editor’s palette, scale shading, interface size and playhead appearance. Musical settings and bindings stay as they are.')
    if I.BeginCombo(c,'Saved preset',app.workspace_preset_name or 'Choose')then
      for _,name in ipairs(P.names(kind))do if I.Selectable(c,name,app.workspace_preset_name==name)then app.workspace_preset_name=name end end;I.EndCombo(c)
    end
    local hit;hit,app.workspace_preset_name=I.InputText(c,'Name',app.workspace_preset_name or '')
    if I.Button(c,'Save current')then local _,notice=P.save(app.workspace_preset_name,P.capture(app,kind));app.workspace_preset_notice=notice end
    I.SameLine(c);if I.Button(c,'Load preset')then
      local data,notice=P.load(kind,app.workspace_preset_name or '')
      if data then local before=P.capture(app,kind);local ok;ok,notice=P.apply(app,data);if ok then app.workspace_preset_restore=before end end
      app.workspace_preset_notice=notice
    end
    if I.Button(c,'Delete saved preset')then P.delete(kind,app.workspace_preset_name or '');app.workspace_preset_name=''end
    if app.workspace_preset_restore and I.Button(c,'Restore previous workspace / appearance')then local ok,notice=P.apply(app,app.workspace_preset_restore);app.workspace_preset_notice=notice;if ok then app.workspace_preset_restore=nil end end
    if app.workspace_preset_notice then I.TextWrapped(c,app.workspace_preset_notice)end
  end
  if visible then I.End(c)end
end
return M
