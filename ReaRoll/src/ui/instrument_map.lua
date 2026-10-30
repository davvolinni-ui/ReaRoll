-- @noindex
local Map=require 'src.instrument_map'
local M={}
local function save(app,map)
  local ok,notice=Map.save(app,map);app.instrument_map_notice=notice;return ok
end
local function clone(t)local out={};for k,v in pairs(t)do out[k]=v end;return out end
function M.draw(app)
  if app.map_audition_until and reaper.time_precise()>=app.map_audition_until then app.audition:stop();app.map_audition_until=nil end
  if not app.instrument_map_open then return end
  Map.refresh(app)
  local I,c=app.ImGui,app.ctx
  I.SetNextWindowSize(c,600,570,I.Cond_FirstUseEver)
  local visible;visible,app.instrument_map_open=I.Begin(c,'Drum map',app.instrument_map_open)
  if visible then
    local map=app.instrument_map or Map.new();local track=Map.track(app)
    I.TextWrapped(c,'Definitions belong to this track. Row layouts do not change MIDI pitches or channels.')
    if app.instrument_map_notice then I.TextWrapped(c,app.instrument_map_notice)end
    I.BeginDisabled(c,not track or app.transform_preview~=nil or app.gesture~=nil)
    local hit;local requested=app.instrument_map_section
    local hit,enabled=I.Checkbox(c,'Use mapped drum rows',map.enabled)
    if hit then local changed=Map.copy(map);changed.enabled=enabled;save(app,changed);map=app.instrument_map end
    local ch;hit,ch=I.SliderInt(c,'Drum-map channel',map.channel+1,1,16)
    if hit then local changed=Map.copy(map);changed.channel=ch-1;save(app,changed);map=app.instrument_map end
    if map.enabled and app.settings.channel~=map.channel then
      I.TextWrapped(c,'Choose the map channel in the toolbar to use this row layout.')
      if I.Button(c,'Edit channel '..(map.channel+1))then app.settings.channel=map.channel end
    end
    if app.settings.scale_view_only then I.TextWrapped(c,'Scale-only view currently takes precedence over mapped rows.')end
    if I.Button(c,'Load GM essentials (12 rows)')then local changed=Map.essentials(map.channel);changed.articulations=map.articulations;if save(app,changed)then app.map_row_draft=nil end;map=app.instrument_map end
    I.Separator(c);I.Text(c,'Drum rows (top to bottom)')
    for index,row in ipairs(map.rows)do
      I.PushID(c,index)
      if I.SmallButton(c,'Play')then app.audition:play(row.pitch,app.settings.velocity,map.channel);app.map_audition_until=reaper.time_precise()+.2 end
      I.SameLine(c);I.SetNextItemWidth(c,160)
      app.map_row_names=app.map_row_names or {};local key=tostring(Map.track(app))..':'..row.pitch
      local hit,name=I.InputText(c,'##name',app.map_row_names[key]or row.name)
      if hit then app.map_row_names[key]=name end
      if I.IsItemDeactivatedAfterEdit(c)then local copy=Map.copy(map);copy.rows[index].name=name;if save(app,copy)then map=app.instrument_map;app.map_row_names[key]=nil end end
      I.SameLine(c);I.SetNextItemWidth(c,65)
      app.map_row_pitches=app.map_row_pitches or {}
      local pitch_changed,pitch=I.InputInt(c,'##pitch',app.map_row_pitches[key]or row.pitch,0,0)
      if pitch_changed then app.map_row_pitches[key]=pitch end
      if I.IsItemDeactivatedAfterEdit(c)then local copy=Map.copy(map);copy.rows[index].pitch=pitch;if save(app,copy)then map=app.instrument_map;app.map_row_pitches[key]=nil end end
      if I.IsItemHovered(c)then I.SetTooltip(c,'MIDI pitch: '..require('src.util').pitch_name(row.pitch))end
      I.SameLine(c);local hide,hidden=I.Checkbox(c,'Hide',row.hidden==true)
      if hide then local copy=Map.copy(map);copy.rows[index].hidden=hidden;save(app,copy);map=app.instrument_map end
      for _,move in ipairs({{'Up',-1},{'Down',1}})do
        I.SameLine(c);I.BeginDisabled(c,index+move[2]<1 or index+move[2]>#map.rows)
        if I.SmallButton(c,move[1])then local copy=Map.copy(map);local other=index+move[2];copy.rows[index],copy.rows[other]=copy.rows[other],copy.rows[index];save(app,copy)end
        I.EndDisabled(c)
      end
      I.PopID(c)
    end
    if I.Button(c,'Add drum row')then
      local used={};for _,row in ipairs(map.rows)do used[row.pitch]=true end
      local pitch=36;while used[pitch]and pitch<128 do pitch=pitch+1 end
      if pitch<128 then local copy=Map.copy(map);copy.rows[#copy.rows+1]={pitch=pitch,name=require('src.util').pitch_name(pitch),hidden=false};save(app,copy)end
    end
    if I.CollapsingHeader(c,'Import / export maps')then
      I.TextWrapped(c,'Import REAPER note-name text or a ReaRoll drum map.')
      if I.Button(c,'Choose map file')then
        local chosen,path=reaper.GetUserFileNameForRead('','Import instrument map','')
        if chosen then
          local Exchange=require 'src.map_exchange';local raw,notice=Exchange.read(path)
          app.instrument_map_notice=notice;app.map_import=nil;app.map_import_banks=nil
          if raw then
            if raw:match('^RRMAP')then app.map_import,app.instrument_map_notice=Map.decode(raw:gsub('\n+$',''))
            elseif path:lower():match('%.reabank$')then app.instrument_map_notice='Choose a drum-name text file or ReaRoll drum map.'
            else app.map_import,app.instrument_map_notice=Exchange.notes(raw,map)end
          end
        end
      end
      if app.map_import then
        I.Text(c,#app.map_import.rows..' drum rows')
        if I.Button(c,'Apply imported map')then app.map_import.articulations=map.articulations;if save(app,app.map_import)then app.map_import=nil;app.map_import_banks=nil;app.map_row_draft=nil;app.map_art_draft=nil;map=app.instrument_map end end
        I.SameLine(c);if I.Button(c,'Cancel import')then app.map_import=nil;app.map_import_banks=nil end
      end
      if I.Button(c,'Copy full map to clipboard')then I.SetClipboardText(c,Map.encode(map));app.instrument_map_notice='Full map copied. Save it as a .rrmap text file to share.'end
      if I.Button(c,'Copy REAPER note names')then local raw,notice=require('src.map_exchange').export_notes(map);if raw then I.SetClipboardText(c,raw);notice='Note names copied. Save as a .txt file; use full map export to preserve visibility and channels.'end;app.instrument_map_notice=notice end
    end
    if I.CollapsingHeader(c,'Map presets')then
    if I.BeginCombo(c,'Preset',app.map_preset_name or 'Choose')then
      for _,name in ipairs(Map.presets())do if I.Selectable(c,name,app.map_preset_name==name)then
        local preset,notice=Map.load_preset(name);if preset then local current=Map.copy(map);current.rows=preset.rows;current.channel=app.settings.channel;current.enabled=true;preset=current end;if preset and save(app,preset)then app.map_preset_name=name;app.map_row_draft=nil;app.map_art_draft=nil else app.instrument_map_notice=notice end
      end end
      I.EndCombo(c)
    end
    hit,app.map_preset_name=I.InputText(c,'Preset name',app.map_preset_name or '')
    if I.Button(c,'Save map preset')then if not Map.save_preset(app.map_preset_name,app.instrument_map or map)then app.instrument_map_notice='Enter a preset name of 1 to 80 bytes.'end end
    I.SameLine(c)
    if I.Button(c,'Delete preset') and (app.map_preset_name or '')~='' then Map.delete_preset(app.map_preset_name);app.map_preset_name='' end
    end
    I.EndDisabled(c)
  end
  if visible then I.End(c)end
end
return M
