-- @noindex
local M={key='P_EXT:ReaRollInstrumentMap'}
local function integer(n,lo,hi)return type(n)=='number' and n==math.floor(n) and n>=lo and n<=hi end
local function number(n,lo,hi)return type(n)=='number' and n==n and n>=lo and n<=hi end
local function hex(s)return (s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)
  if not s or #s%2~=0 or s:find('[^%da-f]')then return nil end
  return (s:gsub('..',function(c)return string.char(tonumber(c,16))end))
end
function M.new()return {channel=0,enabled=false,rows={},articulations={}}end
function M.validate(map)
  if type(map)~='table' or not integer(map.channel,0,15) or type(map.rows)~='table' or type(map.articulations)~='table' then return false end
  if #map.rows>128 or #map.articulations>128 then return false end
  local seen={}
  for _,r in ipairs(map.rows)do
    if not integer(r.pitch,0,127) or seen[r.pitch] or type(r.name)~='string' or #r.name>160 then return false end
    seen[r.pitch]=true
  end
  for _,a in ipairs(map.articulations)do
    if type(a.name)~='string' or #a.name>160 or not integer(a.channel,-1,15) or not integer(a.number,0,127) or not integer(a.value,0,127) then return false end
    if a.kind~='note' and a.kind~='cc' and a.kind~='program' then return false end
    if a.group~=nil and(type(a.group)~='string'or #a.group==0 or #a.group>80)then return false end
    if a.bank_msb~=nil or a.bank_lsb~=nil then
      if a.kind~='program' or not integer(a.bank_msb,0,127) or not integer(a.bank_lsb,0,127)then return false end
    end
    if not number(a.lead,0,4) or not number(a.length,.001,4) or a.kind=='note' and a.value==0 then return false end
  end
  return true
end
function M.encode(map)
  assert(M.validate(map),'Invalid instrument map')
  local version=1;for _,a in ipairs(map.articulations)do if a.bank_msb~=nil then version=math.max(version,2)end;if a.group~=nil then version=3 end end
  local out={'RRMAP'..version..'\t'..map.channel..'\t'..(map.enabled and '1' or '0')}
  for _,r in ipairs(map.rows)do out[#out+1]=table.concat({'r',r.pitch,r.hidden and 1 or 0,hex(r.name)},'\t')end
  for _,a in ipairs(map.articulations)do
    local fields={'a',a.kind,a.channel,a.number,a.value,string.format('%.17g',a.lead),string.format('%.17g',a.length),hex(a.name)}
    if version>=2 then fields[9]=a.bank_msb or '-';fields[10]=a.bank_lsb or '-'end
    if version==3 then fields[11]=hex(a.group or 'Playing style')end
    out[#out+1]=table.concat(fields,'\t')
  end
  return table.concat(out,'\n')
end
function M.decode(raw)
  if raw=='' or raw==nil then return M.new()end
  if type(raw)~='string' or #raw>140000 then return nil,'Instrument map is too large.'end
  local lines={};for line in (raw..'\n'):gmatch('(.-)\n')do lines[#lines+1]=line end
  local version,ch,enabled=lines[1]:match('^RRMAP([123])\t(%d+)\t([01])$')
  if not ch then return nil,'Unknown instrument-map format.'end
  local map={channel=tonumber(ch),enabled=enabled=='1',rows={},articulations={}}
  for i=2,#lines do
    local fields={};for f in (lines[i]..'\t'):gmatch('(.-)\t')do fields[#fields+1]=f end
    if fields[1]=='r' and #fields==4 then
      if fields[3]~='0' and fields[3]~='1' then return nil,'Invalid row visibility.'end
      map.rows[#map.rows+1]={pitch=tonumber(fields[2]),hidden=fields[3]=='1',name=unhex(fields[4])}
    elseif fields[1]=='a' and (#fields==8 and version=='1' or #fields==10 and version=='2' or #fields==11 and version=='3')then
      map.articulations[#map.articulations+1]={kind=fields[2],channel=tonumber(fields[3]),number=tonumber(fields[4]),value=tonumber(fields[5]),lead=tonumber(fields[6]),length=tonumber(fields[7]),name=unhex(fields[8])}
      if version=='2'or version=='3'then
        if fields[9]~='-' or fields[10]~='-'then
          local a=map.articulations[#map.articulations];a.bank_msb=tonumber(fields[9]);a.bank_lsb=tonumber(fields[10])
          if a.bank_msb==nil or a.bank_lsb==nil then return nil,'Invalid bank select values.'end
        end
      end
      if version=='3'then map.articulations[#map.articulations].group=unhex(fields[11]);if not map.articulations[#map.articulations].group then return nil,'Invalid articulation group.'end end
    else return nil,'Malformed instrument-map entry.'end
  end
  if not M.validate(map)then return nil,'Invalid instrument-map values.'end
  return map
end
function M.layout(map,channel)
  if not map or not map.enabled or map.channel~=channel then return nil end
  local pitches={}
  for i=#map.rows,1,-1 do local r=map.rows[i];if not r.hidden then pitches[#pitches+1]=r.pitch end end
  return #pitches>0 and pitches or nil
end
function M.label(map,channel,pitch)
  if not map or map.channel~=channel then return nil end
  for _,r in ipairs(map.rows)do if r.pitch==pitch and r.name~='' then return r.name end end
end
function M.track(app)return app.take and require('src.take').track(app.take) or app.empty_track end
function M.refresh(app,force)
  local track=M.track(app);local now=reaper.time_precise()
  if not force and track==app.instrument_map_track and now<(app.next_map_poll or 0)then return end
  app.next_map_poll=now+.2
  local raw='';if track then local ok,value=reaper.GetSetMediaTrackInfo_String(track,M.key,'',false);if ok then raw=value end end
  if force or track~=app.instrument_map_track or raw~=app.instrument_map_raw then
    local map,notice=M.decode(raw)
    app.instrument_map=map or M.new();app.instrument_map_notice=notice
    app.instrument_map_track=track;app.instrument_map_raw=raw;app.note_names={}
    app.map_row_draft=nil;app.map_art_draft=nil
    app.map_import=nil;app.map_import_banks=nil
  end
end
function M.save(app,map)
  if app.gesture or app.transform_preview or app.edit and app.edit.active or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint)then return false,'Finish the current edit before changing the instrument map.'end
  local track=M.track(app)
  if not track or not M.validate(map)then return false,'Select a track and enter a valid map.'end
  local raw=M.encode(map);local _,before=reaper.GetSetMediaTrackInfo_String(track,M.key,'',false)
  if raw==before then return true end
  reaper.Undo_BeginBlock2(0)
  local ok=reaper.GetSetMediaTrackInfo_String(track,M.key,raw,true)
  reaper.Undo_EndBlock2(0,'ReaRoll: instrument map',ok and 1 or 0)
  if not ok then return false,'Could not save the track instrument map.'end
  app.instrument_map=map;app.instrument_map_raw=raw;app.instrument_map_track=track;app.note_names={}
  reaper.UpdateArrange();return true
end
function M.copy(map)return assert(M.decode(M.encode(map)))end
function M.presets()
  local out={};for encoded in reaper.GetExtState('ReaRoll.InstrumentMaps','names'):gmatch('[^\n]+')do local name=unhex(encoded);if name then out[#out+1]=name end end;return out
end
function M.save_preset(name,map)
  name=(name or ''):match('^%s*(.-)%s*$')
  if name=='' or #name>80 or not M.validate(map)then return false end
  local names=M.presets();local found=false;for _,n in ipairs(names)do if n==name then found=true end end
  if not found then names[#names+1]=name end;table.sort(names)
  local encoded={};for _,n in ipairs(names)do encoded[#encoded+1]=hex(n)end
  reaper.SetExtState('ReaRoll.InstrumentMaps','preset_'..hex(name),M.encode(map),true)
  reaper.SetExtState('ReaRoll.InstrumentMaps','names',table.concat(encoded,'\n'),true);return true
end
function M.load_preset(name)
  local raw=reaper.GetExtState('ReaRoll.InstrumentMaps','preset_'..hex(name))
  if raw=='' then return nil,'The preset is missing.'end
  return M.decode(raw)
end
function M.delete_preset(name)
  local kept={};for _,n in ipairs(M.presets())do if n~=name then kept[#kept+1]=hex(n)end end
  reaper.SetExtState('ReaRoll.InstrumentMaps','names',table.concat(kept,'\n'),true)
  reaper.DeleteExtState('ReaRoll.InstrumentMaps','preset_'..hex(name),true)
end
function M.essentials(channel)
  local map=M.new();map.channel=channel or 9;map.enabled=true
  for _,r in ipairs({{36,'Kick'},{38,'Snare'},{37,'Side stick'},{39,'Hand clap'},{42,'Closed hi-hat'},{44,'Pedal hi-hat'},{46,'Open hi-hat'},{45,'Low tom'},{47,'Mid tom'},{50,'High tom'},{49,'Crash cymbal'},{51,'Ride cymbal'}})do map.rows[#map.rows+1]={pitch=r[1],name=r[2],hidden=false}end
  return map
end
return M
