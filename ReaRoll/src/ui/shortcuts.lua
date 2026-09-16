-- @noindex
local Shortcuts=require 'src.shortcuts'
local M={}
function M.draw(app)
  if not app.shortcuts_open then return end
  local I,c,s=app.ImGui,app.ctx,app.settings
  I.SetNextWindowSize(c,430,560,I.Cond_FirstUseEver)
  local visible; visible,app.shortcuts_open=I.Begin(c,'ReaRoll / Keyboard shortcuts',app.shortcuts_open)
  if visible then
    I.TextWrapped(c,'One ReaRoll keymap. Every command can be reassigned or disabled; duplicate bindings are highlighted below.')
    if I.Button(c,'Restore ReaRoll defaults') then for k,v in pairs(Shortcuts.defaults) do s.shortcuts[k]=v end end
    I.Separator(c); local used={}
    for _,action in ipairs(Shortcuts.order) do
      local binding=s.shortcuts[action] or Shortcuts.defaults[action]; I.SetNextItemWidth(c,150)
      if I.BeginCombo(c,'##shortcut_'..action,binding) then
        for _,choice in ipairs(Shortcuts.choices) do if I.Selectable(c,choice,choice==binding) then s.shortcuts[action]=choice end end
        I.EndCombo(c)
      end
      I.SameLine(c); I.Text(c,Shortcuts.labels[action]); if binding~='None' then used[binding]=used[binding] or {}; used[binding][#used[binding]+1]=Shortcuts.labels[action] end
    end
    I.Separator(c); I.TextDisabled(c,'REAPER action slots accept a numeric command ID or named command ID.')
    for slot=1,4 do
      local key='reaper_action_'..slot; I.SetNextItemWidth(c,220)
      local changed,value=I.InputText(c,'Action '..slot,s[key] or '')
      if changed then s[key]=value end
    end
    for binding,actions in pairs(used) do if #actions>1 then I.TextColored(c,0xF2A65AFF,binding..' is assigned to '..table.concat(actions,', ')) end end
  end
  if visible then I.End(c) end
end
return M
