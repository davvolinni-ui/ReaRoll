-- @noindex
local Shortcuts=require 'src.shortcuts'
local Mouse=require 'src.mouse'
local Wheel=require 'src.wheel'
local WheelSettings=require 'src.ui.wheel_settings'
local M={}
function M.draw(app)
  if not app.shortcuts_open then return end
  local I,c,s=app.ImGui,app.ctx,app.settings
  I.SetNextWindowSize(c,520,640,I.Cond_FirstUseEver)
  local visible; visible,app.shortcuts_open=I.Begin(c,'ReaRoll / Shortcuts and mouse modifiers',app.shortcuts_open)
  if visible then
    I.TextWrapped(c,'Choose a starting preset, then customize it. Applying a preset replaces keyboard and note-grid mouse bindings. REAPER also sets its four main wheel gestures.')
    local preset=Shortcuts.presets[s.input_preset]
    if I.BeginCombo(c,'Preset',preset and preset.label or 'Custom') then
      for _,id in ipairs(Shortcuts.preset_order) do
        if I.Selectable(c,Shortcuts.presets[id].label,s.input_preset==id) then Shortcuts.apply_preset(s,id) end
      end
      I.EndCombo(c)
    end
    I.TextWrapped(c,'DAW presets adapt familiar Windows controls to ReaRoll actions. They do not import your DAW settings. Middle-drag pans. REAPER sets wheel navigation over notes and the empty roll; ReaRoll Default resets all wheel settings. FL Studio and Ableton Live preserve wheel settings.')
    if I.Button(c,'Restore ReaRoll defaults') then Shortcuts.apply_preset(s,'default') end
    I.Separator(c); I.Text(c,'Mouse modifiers / note grid')
    s.mouse=s.mouse or {}
    for _,key in ipairs(Mouse.order) do
      I.SetNextItemWidth(c,150)
      if I.BeginCombo(c,'##mouse_'..key,Wheel.display(Mouse.value(s,key))) then
        for _,choice in ipairs(Mouse.choices[key]) do
          if I.Selectable(c,Wheel.display(choice),choice==Mouse.value(s,key)) then s.mouse[key]=choice; s.input_preset='custom' end
        end
        I.EndCombo(c)
      end
      I.SameLine(c); I.Text(c,Mouse.labels[key])
    end
    I.TextWrapped(c,'Clone takes priority when modifiers overlap. In Marquee mode, double-click empty space to insert; Paint and Chord tools still draw directly.')
    WheelSettings.draw(app)
    I.Separator(c); I.Text(c,'Keyboard shortcuts')
    I.Separator(c); local used={}
    for _,action in ipairs(Shortcuts.order) do
      local binding=s.shortcuts[action] or Shortcuts.defaults[action]; I.SetNextItemWidth(c,150)
      if I.BeginCombo(c,'##shortcut_'..action,Wheel.display(binding)) then
        for _,choice in ipairs(Shortcuts.choices) do if I.Selectable(c,Wheel.display(choice),choice==binding) then s.shortcuts[action]=choice; s.input_preset='custom' end end
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
    for binding,actions in pairs(used) do if #actions>1 then I.TextColored(c,0xF2A65AFF,Wheel.display(binding)..' is assigned to '..table.concat(actions,', ')) end end
  end
  if visible then I.End(c) end
end
return M
