-- @noindex
local Selection=require 'src.selection'
local M={}
function M.notes(app)
  if app.multi_edit_mode then return require('src.multi_notes').chosen(app)end
  local out={}
  for _,n in ipairs(Selection.list(app.selection,app.cache:get(false)))do
    local copy={};for k,v in pairs(n)do copy[k]=v end
    copy.s=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s)
    copy.e=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
    out[#out+1]=copy
  end
  return out
end
function M.apply(app,values)
  for key,v in pairs(values)do
    if key=='muted'then if type(v)~='boolean'then return false,'Invalid mute value.'end
    elseif type(v)~='number'or v~=v or math.abs(v)==math.huge then return false,'Enter finite numeric note properties.'
    elseif (key=='transpose'or key=='velocity'or key=='channel')and v~=math.floor(v)then return false,'Pitch, velocity and channel must be whole numbers.'end
  end
  if app.gesture or app.transform_preview or app.edit.active then return false,'Finish or cancel the current edit first.'end
  local notes=M.notes(app);if #notes==0 then return false,'Select notes first.'end
  if app.multi_edit_mode then
    local model=require 'src.multi_notes'
    if app.multi_notes.transaction then return false,'Finish the current edit first.'end
    local ok,notice=model.preview(app,'properties',values)
    if not ok then if app.multi_notes.transaction then model.cancel(app)end;return false,notice end
    return model.commit(app)
  end
  if not require('src.take').valid(app.take)or reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(app.take),'C_LOCK')~=0 then return false,'The item is unavailable or locked.'end
  local wanted={}
  for _,n in ipairs(notes)do
    local first=n.s+(values.move or 0);local last=n.e+(values.move or 0)+(values.length_delta or 0)
    local pitch=n.pitch+(values.transpose or 0)
    if first<app.item_start_qn-1e-8 or last>app.item_end_qn+1e-8 or last<=first or pitch<0 or pitch>127 then return false,'The edit would exceed the item, note length or pitch bounds.'end
    wanted[#wanted+1]={index=n.index,s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,first)+.5),e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(app.take,last)+.5),pitch=pitch,chan=values.channel or n.chan,vel=values.velocity or n.vel}
  end
  if values.velocity and(values.velocity<1 or values.velocity>127)or values.channel and(values.channel<0 or values.channel>15)then return false,'Invalid velocity or channel.'end
  app.edit:begin('ReaRoll: note properties',app.take);app.edit:begin_group()
  for _,n in ipairs(wanted)do
    local ok=app.edit:set_properties(app.take,n.index,{s=n.s,e=n.e,pitch=n.pitch,chan=n.chan,vel=n.vel,muted=values.muted})
    if not ok then app.edit:cancel();return false,app.expression_notice or 'The note properties could not be changed.'end
  end
  if not app.edit:end_group()then app.edit:cancel();return false,app.expression_notice or 'The note group could not be changed.'end
  if app.edit:finish()==false then return false,app.expression_notice or 'The edit was refused.'end
  app.cache:invalidate();app.cache:rebuild();app.cc_cache:invalidate();app:reselect_notes(wanted)
  return true
end
return M
