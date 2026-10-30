-- @noindex
local M={}
function M.view(app,expression,lanes)
  app.mpe_previous_view=nil
  app.expression_editor_open=expression
  if lanes~=nil then app.settings.lane_open=lanes end
  app.expression_direct_gesture=nil;app.expression_point_selection=nil;app.expression_point_marquee=nil
end
function M.set(app,enabled,automatic)
  if app.edit and app.edit.active or app.gesture or app.expression_direct_gesture then return false,'Finish the active edit before changing MIDI mode.'end
  if not automatic then require('src.mpe_detect').manual(app)end
  app.audition:stop()
  if enabled and not app.settings.mpe_enabled then
    app.mpe_previous_view={expression=app.expression_editor_open==true,lanes=app.settings.lane_open}
  end
  app.settings.mpe_enabled=enabled==true
  if enabled then
    app.expression_editor_open=true;app.expression_group_open=false
    app.expression_dimension=app.expression_dimension or 'pitch'
  else
    app.settings.mpe_pitch_edit=false
    local previous=app.mpe_previous_view
    if previous then app.expression_editor_open=previous.expression;app.settings.lane_open=previous.lanes end
    app.mpe_previous_view=nil
  end
  app.expression_direct_cache=nil;app.expression_point_focus=nil;app.expression_notice=nil;app.expression_point_selection=nil;app.expression_point_marquee=nil
  return true
end
function M.tool(app,mode)
  if app.gesture or app.edit and app.edit.active then return false end
  if app.audition then app.audition:stop()end
  app.settings.mode=mode;app.settings.mpe_pitch_edit=false
  app.expression_direct_gesture=nil;app.expression_direct_cache=nil;app.expression_point_focus=nil
  app.controller_selection_active=false;app.multi_controller_point_focus=false;app.controller_point_focus_key=nil
  app.razor_focus='notes'
  return true
end
function M.label(settings)
  return settings.mpe_enabled and('MPE: '..tostring(settings.mpe_members or 15)..' voices')or 'Standard MIDI'
end
return M
