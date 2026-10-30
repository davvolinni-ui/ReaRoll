-- @noindex
local Map=require 'src.instrument_map'
local M={}
local function text(raw)
  if type(raw)~='string' or #raw>2097152 or raw:find('%z')then return nil,'Choose a text map smaller than 2 MB.'end
  return raw:gsub('^\239\187\191',''):gsub('\r\n','\n'):gsub('\r','\n')
end
function M.notes(raw,base)
  local input,notice=text(raw);if not input then return nil,notice end
  local map=base and Map.copy(base)or Map.new();map.rows={};local seen={};local ignored=0
  for original in (input..'\n'):gmatch('(.-)\n')do
    local line=original:match('^%s*(.-)%s*$')
    if line~='' and line:sub(1,1)~='#' and line:sub(1,2)~='//'then
      if line:match('^CC%d+%s+')then ignored=ignored+1
      else
        local pitch,name=line:match('^(%d+)%s+(.+)$');pitch=tonumber(pitch)
        if not pitch or pitch>127 or #name>160 or seen[pitch]then return nil,'Note maps require unique MIDI pitches 0–127 followed by names.'end
        seen[pitch]=true;map.rows[#map.rows+1]={pitch=pitch,name=name,hidden=false}
      end
    end
  end
  if #map.rows==0 then return nil,'No note names were found.'end
  map.enabled=true
  return map,ignored>0 and (ignored..' CC names skipped; drum rows use note names only.')or nil
end
function M.banks(raw)
  local input,notice=text(raw);if not input then return nil,notice end
  local banks,bank,seen={},nil,{}
  for original in (input..'\n'):gmatch('(.-)\n')do
    local line=original:match('^%s*(.-)%s*$')
    if line~='' and line:sub(1,2)~='//' and line:sub(1,1)~='#'then
      local msb,lsb,name=line:match('^Bank%s+(%d+)%s+(%d+)%s+(.+)$')
      if msb then
        msb,lsb=tonumber(msb),tonumber(lsb)
        if msb>127 or lsb>127 or #name>160 or #banks>=256 or seen[msb..':'..lsb]then return nil,'Banks require unique MSB/LSB values 0–127 and a name.'end
        bank={name=name,msb=msb,lsb=lsb,articulations={},seen={}};banks[#banks+1]=bank;seen[msb..':'..lsb]=true
      else
        local program,label=line:match('^(%d+)%s+(.+)$');program=tonumber(program)
        if not bank or not program or program>127 or #label>160 or bank.seen[program]then return nil,'Programs require a Bank header, unique numbers 0–127 and names.'end
        bank.seen[program]=true
        bank.articulations[#bank.articulations+1]={name=label,kind='program',number=program,value=0,channel=-1,lead=0,length=.03125,bank_msb=bank.msb,bank_lsb=bank.lsb}
      end
    end
  end
  if #banks==0 then return nil,'No ReaBank definitions were found.'end
  return banks
end
function M.bank_map(bank,base)
  local map=base and Map.copy(base)or Map.new();map.articulations={}
  for _,a in ipairs(bank.articulations)do local entry={};for k,v in pairs(a)do entry[k]=v end;map.articulations[#map.articulations+1]=entry end
  if not Map.validate(map)then return nil,'This bank cannot be represented as an instrument map.'end
  return map
end
function M.export_notes(map)
  if not Map.validate(map)then return nil,'Invalid map.'end
  local out={'# MIDI note name map. Exported by ReaRoll.'}
  for _,r in ipairs(map.rows)do if r.name:find('[\r\n]')then return nil,'Note-name text cannot contain line breaks; use the full ReaRoll map format.'end;out[#out+1]=r.pitch..' '..r.name end
  return table.concat(out,'\n')
end
function M.read(path)
  local file,notice=io.open(path,'rb');if not file then return nil,notice end
  local raw=file:read(2097153);file:close()
  return text(raw or '')
end
return M
