-- @noindex
local X=require 'src.midi_exchange'
local M={}
function M.draw(app)
  if not app.midi_exchange_open then return end
  local I,c=app.ImGui,app.ctx;I.SetNextWindowSize(c,530,490,I.Cond_FirstUseEver)
  local visible;visible,app.midi_exchange_open=I.Begin(c,'MIDI file exchange',app.midi_exchange_open)
  if visible then
    I.TextWrapped(c,'Import merges one file track or all tracks into the active item at the edit cursor. Channels and bank/program messages are retained. Musical beats follow the current project tempo; importing does not change the project tempo map.')
    if I.Button(c,'Choose MIDI file')then
      local chosen,path=reaper.GetUserFileNameForRead('','Import MIDI file','.mid')
      if chosen then app.midi_import_file,app.midi_exchange_notice=X.read(path);app.midi_import_track=0;app.midi_import_plan=nil end
    end
    if app.midi_import_file then
      local file=app.midi_import_file;local track=app.midi_import_track or 0
      if I.BeginCombo(c,'File track',track==0 and 'All tracks (merge channels)'or file.tracks[track].name:sub(1,80))then
        if I.Selectable(c,'All tracks (merge channels)',track==0)then app.midi_import_track=0;app.midi_import_plan=nil end
        for index,entry in ipairs(file.tracks)do if I.Selectable(c,index..'. '..entry.name:sub(1,80),track==index)then app.midi_import_track=index;app.midi_import_plan=nil end end;I.EndCombo(c)
      end
      if I.Button(c,'Review import at edit cursor')then
        local anchor=reaper.TimeMap2_timeToQN(0,reaper.GetCursorPosition())
        app.midi_import_plan,app.midi_exchange_notice=X.plan(app,file,(app.midi_import_track or 0)>0 and app.midi_import_track or nil,anchor)
      end
      if app.midi_import_plan then
        local plan=app.midi_import_plan;I.TextWrapped(c,#plan.notes..' notes / '..#plan.events..' MIDI events, '..string.format('%.3f',plan.span)..' beats. Existing MIDI is retained.')
        if I.Button(c,'Import reviewed MIDI')then local ok,notice=X.apply(app,plan);app.midi_exchange_notice=notice;if ok then app.midi_import_plan=nil end end
        I.SameLine(c);if I.Button(c,'Cancel import')then app.midi_import_plan=nil;app.midi_import_file=nil end
      end
    end
    I.Separator(c)
    I.TextWrapped(c,'Export the active item, including all channels, controllers, program changes and complete SysEx. Muted notes/events are omitted. Native controller curves are baked to MIDI steps; the original item is unchanged.')
    if I.Button(c,'Prepare active-item MIDI export')then app.midi_export_raw,app.midi_exchange_notice=X.export(app);app.midi_overwrite_pending=nil end
    if app.midi_export_raw then
      I.Text(c,#app.midi_export_raw..' bytes ready to save')
      local hit;hit,app.midi_export_path=I.InputText(c,'Destination .mid file',app.midi_export_path or '')
      if hit then app.midi_overwrite_pending=nil end
      if I.Button(c,'Save MIDI file')then
        local ok,notice=X.write(app.midi_export_path or '',app.midi_export_raw,false)
        app.midi_exchange_notice=ok and 'MIDI file saved.'or notice
        app.midi_overwrite_pending=not ok and notice=='The destination exists. Confirm overwrite to replace it.'or nil
      end
      if app.midi_overwrite_pending then
        I.TextWrapped(c,'A file already exists at this path.')
        if I.Button(c,'Overwrite existing MIDI file')then local ok,notice=X.write(app.midi_export_path,app.midi_export_raw,true);app.midi_exchange_notice=ok and 'MIDI file saved.'or notice;app.midi_overwrite_pending=nil end
        I.SameLine(c);if I.Button(c,'Keep existing file')then app.midi_overwrite_pending=nil end
      end
    end
    if app.midi_exchange_notice then I.TextWrapped(c,app.midi_exchange_notice)end
  end
  if visible then I.End(c)end
end
return M
