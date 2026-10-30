-- @noindex
local Notes=require 'src.note_events'
local Take=require 'src.take'
local M={}
function M.state(app)
  if not Take.valid(app.take) then app.overlap_mode_cache=nil;return nil end
  -- A take can disappear between validation and the next native API call.
  local ran,ok,hash=pcall(reaper.MIDI_GetHash,app.take,false,'')
  if not ran or not ok then app.overlap_mode_cache=nil;return nil end
  local cached=app.overlap_mode_cache
  if cached and cached.take==app.take and ok and cached.hash==hash then return cached.config,cached.error end
  local read,stream=pcall(Notes.read,app.take)
  if not read then
    app.overlap_mode_cache=nil
    if not Take.valid(app.take) then return nil end
    error(stream,0)
  end
  if not stream then app.overlap_mode_cache=nil;return nil end
  app.overlap_mode_cache={take=app.take,hash=hash,config=stream and stream.overlap_config,error=stream and stream.overlap_error,stream=stream}
  return app.overlap_mode_cache.config,app.overlap_mode_cache.error
end
function M.drawing_settings(app)
  local config=M.state(app)
  if not config then return app.settings,false end
  local stream=app.overlap_mode_cache and app.overlap_mode_cache.stream
  return require('src.glide_setup').drawing(stream and stream.notes or {},config,app.settings)
end
local function editable_item(app)
  if not Take.valid(app.take) then app.overlap_mode_cache=nil;return false,'Choose a valid MIDI item first.'end
  local item=Take.item(app.take)
  if not item then app.overlap_mode_cache=nil;return false,'Choose a valid MIDI item first.'end
  local ok,locked=pcall(reaper.GetMediaItemInfo_Value,item,'C_LOCK')
  if not ok then app.overlap_mode_cache=nil;return false,'The MIDI item is no longer available.'end
  if locked~=0 then return false,'Unlock this MIDI item first.'end
  return true
end
function M.set(app,enabled)
  if not app.take or app.gesture or app.edit.active or app.transform_preview or app.expression_direct_gesture then return false,'Finish the current edit first.'end
  local editable,notice=editable_item(app);if not editable then return false,notice end
  local _,invalid=M.state(app);if invalid then return false,invalid end
  app.edit:begin(enabled and 'ReaRoll: enable overlap glide'or 'ReaRoll: disable overlap glide',app.take)
  local stream=app.edit.active.stream
  if enabled then
    local s=app.settings
    stream.overlap_config={mpe_enabled=s.mpe_enabled==true,mpe_zone=s.mpe_zone,mpe_members=s.mpe_members,pitch_bend_range=s.pitch_bend_range or 2,mpe_pitch_bend_range=s.mpe_pitch_bend_range or 48}
  else stream.overlap_config=nil end
  stream.dirty=true;app.edit.active.changed=true
  local ok=app.edit:finish();app.overlap_mode_cache=nil
  return ok~=false,app.expression_notice
end
function M.keep_external(app)
  if not app.take or app.gesture or app.edit.active or app.transform_preview or app.expression_direct_gesture then return false,'Finish the current edit first.'end
  local editable,notice=editable_item(app);if not editable then return false,notice end
  local _,invalid=M.state(app);if not invalid then return false,'No external overlap changes to recover.'end
  app.edit:begin('ReaRoll: keep externally edited glide playback',app.take)
  local stream=app.edit.active.stream
  for _,event in ipairs(stream.events)do
    if event.msg:sub(1,18)==string.char(255,1)..'REAROLL_OVERLAP ' then event.deleted=true end
  end
  stream.overlap_error=nil;stream.overlap_config=nil;stream.dirty=true;app.edit.active.changed=true
  local ok=app.edit:finish();app.overlap_mode_cache=nil
  return ok~=false,'External notes and bends kept as ordinary MIDI. Undo restores the saved overlap score.'
end
function M.range(app,value)
  if type(value)~='number' or value%1~=0 or value<1 or value>96 then return false,'Choose a pitch range from 1 to 96 semitones.'end
  if not app.take or app.gesture or app.edit.active or app.transform_preview or app.expression_direct_gesture then return false,'Finish the current edit first.'end
  local editable,notice=editable_item(app);if not editable then return false,notice end
  local config,invalid=M.state(app);if not config then return false,invalid or 'Enable Glide for this item first.'end
  app.edit:begin('ReaRoll: change glide pitch range',app.take)
  local stream=app.edit.active.stream
  local Setup=require 'src.glide_setup';local key=app.settings.mpe_enabled and 'mpe_pitch_bend_range'or 'pitch_bend_range'
  local base=stream.overlap_config;local matching=(base.mpe_enabled==true)==(app.settings.mpe_enabled==true)
  if matching then base[key]=value end
  local changed=matching
  for _,note in ipairs(stream.notes)do local saved=Setup.read(note)
    if saved and(saved.mpe_enabled==true)==(app.settings.mpe_enabled==true)then
      local next_setup={};for k,v in pairs(saved)do next_setup[k]=v end;next_setup[key]=value;Setup.set(stream,note,next_setup);changed=true
    end
  end
  if not changed then app.edit:cancel();app.settings[key]=value;return true end
  stream.dirty=true;app.edit.active.changed=true
  local ok=app.edit:finish();app.overlap_mode_cache=nil
  if ok~=false then app.settings[key]=value;return true end
  return false,app.expression_notice
end
return M
