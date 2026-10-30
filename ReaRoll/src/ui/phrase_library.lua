-- @noindex
local Library=require 'src.phrase_library'
local M={}
function M.draw(app)
  if not app.phrase_library_open then return end
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,420,350,I.Cond_FirstUseEver)
  local visible;visible,app.phrase_library_open=I.Begin(c,'Saved phrases',app.phrase_library_open)
  if visible then
    I.TextWrapped(c,'Save selected notes and reuse them in other items/projects. Pitches, channels, release velocities and note notation are retained.')
    I.TextWrapped(c,'Notes only: CCs, pitch bends and MPE expression are not included. Insertion uses the saved note channels.')
    local changed;changed,app.phrase_library_name=I.InputText(c,'Phrase name',app.phrase_library_name or '')
    I.BeginDisabled(c,not app.take)
    if I.Button(c,'Save selected notes')then
      local phrase,notice=Library.capture(app)
      if phrase then local _,message=Library.save(app.phrase_library_name,phrase);notice=message end
      app.phrase_library_notice=notice
    end
    I.EndDisabled(c)
    I.Separator(c)
    if I.BeginCombo(c,'Saved phrase',app.phrase_library_selected or 'Choose')then
      for _,name in ipairs(Library.names())do if I.Selectable(c,name,app.phrase_library_selected==name)then app.phrase_library_selected=name;app.phrase_library_loaded=nil end end
      I.EndCombo(c)
    end
    if app.phrase_library_selected then
      local phrase,notice=Library.load(app.phrase_library_selected)
      if phrase then
        I.Text(c,string.format('%d notes / %.3f beats',#phrase.notes,phrase.span))
        if I.Button(c,'Insert at edit cursor')then local _,message=Library.insert(app,phrase,reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition()));app.phrase_library_notice=message end
        if I.Button(c,'Delete saved phrase')then Library.delete(app.phrase_library_selected);app.phrase_library_selected=nil end
      elseif notice then I.TextWrapped(c,notice)end
    end
    if app.phrase_library_notice then I.TextWrapped(c,app.phrase_library_notice)end
  end
  if visible then I.End(c)end
end
return M
