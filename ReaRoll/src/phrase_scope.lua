-- @noindex
local Take=require 'src.take'
local Cache=require 'src.midi_cache'
local CCCache=require 'src.cc_cache'
local Edit=require 'src.midi_edit'
local Selection=require 'src.selection'
local Notes=require 'src.note_events'
local Multi=require 'src.multi_edit'
local M={}
function M.targets(app)
  local takes,seen={},{}
  local function add(item)
    if not item then return end
    if reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return end
    local take=reaper.GetActiveTake(item)
    if Take.valid(take) and not seen[take] then takes[#takes+1]=take;seen[take]=true end
  end
  if app.settings.phrase_scope=='multi_selection' then
    for take,ids in pairs(app.multi_selection_by_take or {})do if next(ids) and Take.valid(take)then add(Take.item(take))end end
  elseif app.settings.phrase_scope=='track' then
    local track=Take.track(app.take)
    if track then for i=0,reaper.CountTrackMediaItems(track)-1 do add(reaper.GetTrackMediaItem(track,i))end end
  else for i=0,reaper.CountSelectedMediaItems(0)-1 do add(reaper.GetSelectedMediaItem(0,i))end end
  local pools={}
  for _,take in ipairs(takes)do
    local item=Take.item(take)
    if reaper.GetItemStateChunk then
      local ok,chunk=reaper.GetItemStateChunk(item,'',false)
      local pool=ok and chunk:match('POOLEDEVTS%s+(%b{})')
      if pool then
        if pools[pool] then return nil,'This scope contains shared pooled MIDI. Unpool those items before applying different item-relative transforms.' end
        pools[pool]=true
      end
    end
  end
  if #takes==0 then return nil,'No unlocked MIDI items exist in this phrase-tool scope.' end
  return takes
end
local function child_app(app,take)
  local child={};for k,v in pairs(app)do child[k]=v end
  setmetatable(child,getmetatable(app))
  child.settings={};for k,v in pairs(app.settings)do child.settings[k]=v end
  child.settings.phrase_scope='active'
  child.multi_edit_mode=false
  child.take=take;child.item_start_qn=Take.item_start_qn(take);child.item_end_qn=Take.item_end_qn(take)
  child.cache=Cache.new();child.cache:set_take(take)
  child.cc_cache=CCCache.new();child.cc_cache:set_take(take)
  child.selection=Selection.new();child.transform_preview=nil;child.lane_tool_preview=nil
  child.edit=Edit.new(child.cache,child.selection,child.cc_cache);child.edit.app=child
  child.cache:rebuild();for _,n in ipairs(child.cache.notes)do Selection.add(child.selection,n.id)end
  if app.settings.phrase_scope=='multi_selection' then
    child.selection.ids={};local ids=(app.multi_selection_by_take or {})[take] or {}
    for _,n in ipairs(child.cache.notes)do if ids[n.index]then Selection.add(child.selection,n.id)end end
  end
  return child
end
local function invalidate(app)
  app.cache:invalidate();app.cc_cache:invalidate()
end
function M.cancel(app)
  local group=app.scoped_phrase_preview;if not group then return false end
  local restored=Multi.restore(group.entries)
  app.scoped_phrase_preview=nil;app.transform_preview=nil;invalidate(app)
  if app.multi_edit_mode and app.multi_notes and group.multi_selection then app.multi_notes.selection=group.multi_selection;require('src.multi_notes').refresh(app,true)end
  if not restored then app.scope_notice='Removed or externally changed targets were preserved; other previews were restored.' end
  reaper.UpdateArrange();return true
end
function M.preview(app,name,run,base_cancel,...)
  local arguments=table.pack(...)
  local targets,notice=M.targets(app)
  if not targets then M.cancel(app);app.scope_notice=notice;return false end
  local signature=name..':'..table.concat((function()local out={};for _,take in ipairs(targets)do out[#out+1]=tostring(take)end;return out end)(),'|')
  local group=app.scoped_phrase_preview
  if group and group.signature~=signature then M.cancel(app);group=nil end
  if not group then
    if app.transform_preview then base_cancel(app)end
    group={signature=signature,children={},entries={}}
    if app.multi_edit_mode and app.multi_notes then group.multi_selection={};for k,v in pairs(app.multi_notes.selection)do group.multi_selection[k]=v end end
    for _,take in ipairs(targets)do
      local ok,raw=reaper.MIDI_GetAllEvts(take,'');if not ok then app.scope_notice='Could not snapshot a phrase target.';return false end
      group.children[#group.children+1]=child_app(app,take)
      group.entries[#group.entries+1]={take=take,before_raw=raw,before_pairs=Notes.get_pairing_state(take),expected_raw=raw}
    end
    app.scoped_phrase_preview=group
  end
  for _,entry in ipairs(group.entries)do
    if not Take.valid(entry.take) then M.cancel(app);app.scope_notice='A preview item was removed.';return false end
    local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'')
    if not ok or raw~=entry.expected_raw then M.cancel(app);app.scope_notice='An item changed externally. It was preserved and the other previews were cancelled.';return false end
  end
  local combined={kind=name:gsub('^preview_',''),originals={},scoped=true,invalid=false}
  for i,child in ipairs(group.children)do
    local entry=group.entries[i]
    local ok,result=xpcall(function()return run(child,table.unpack(arguments,1,arguments.n))end,debug.traceback)
    if not ok or not result then
      entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(child.take,''))
      M.cancel(app);app.scope_notice=not ok and result or child.glide_notice or 'A target has no usable notes for this tool.'
      app.transform_preview={kind=name:gsub('^preview_',''),originals={},scoped=true,invalid=true}
      return false
    end
    entry.after_raw=select(2,reaper.MIDI_GetAllEvts(child.take,''));entry.expected_raw=entry.after_raw
    entry.after_pairs=Notes.get_pairing_state(child.take)
    local p=child.transform_preview
    if p then combined.kind=p.kind end
    for _,note in ipairs(p and p.originals or {})do combined.originals[#combined.originals+1]=note end
    combined.generated_count=(combined.generated_count or 0)+(p and p.generated_count or 0)
    combined.glide_count=(combined.glide_count or 0)+(p and p.glide_count or 0)
  end
  combined.scope_count=#targets;app.transform_preview=combined;app.scope_notice=nil;invalidate(app)
  for _,child in ipairs(group.children)do if child.take==app.take then
    if combined.kind=='glide' then
      app.settings.mpe_enabled=child.settings.mpe_enabled
      app.settings.pitch_bend_range=child.settings.pitch_bend_range
      app.settings.note_expression_overlay=child.settings.note_expression_overlay
    end
  end end
  return true
end
function M.commit(app)
  local group=app.scoped_phrase_preview;if not group then return false end
  local ok,notice=Multi.commit(group.entries,'ReaRoll: phrase tools across '..#group.entries..' MIDI items')
  app.scope_notice=notice
  if ok then
    local wanted={}
    if app.multi_edit_mode then for _,child in ipairs(group.children)do for _,n in ipairs(child.cache:get(false))do if child.selection.ids[n.id]then wanted[#wanted+1]={take=child.take,s=reaper.MIDI_GetProjQNFromPPQPos(child.take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end end end end
    app.scoped_phrase_preview=nil;app.transform_preview=nil;invalidate(app)
    if app.multi_edit_mode then require('src.multi_notes').select_wanted(app,wanted)end
  end
  return ok
end
M.child_app=child_app
return M
