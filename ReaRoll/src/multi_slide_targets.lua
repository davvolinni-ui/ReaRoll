-- @noindex
local Notes=require 'src.note_events'
local Model=require 'src.multi_notes'
local Multi=require 'src.multi_edit'
local Slides=require 'src.slide_draw'
local M={}
local function sources(app)local out={};for _,s in ipairs(Model.sources(app))do out[s.take]=s end;return out end
local function valid(app,g)
  local current=sources(app)
  for _,entry in ipairs(g.entries)do
    local s=current[entry.take];local old=entry.source
    if not s or s.readonly or s.start_qn~=old.start_qn or s.end_qn~=old.end_qn or s.rate~=old.rate or s.offset~=old.offset then
      if s and s.reason and s.reason:find('Pooled')then entry.expected_raw=false end
      return false,'A slide source changed scope, timing or editability.'
    end
    local ok,raw=reaper.MIDI_GetAllEvts(entry.take,'');if not ok or raw~=entry.expected_raw then return false,'A slide source changed externally; its edit was preserved.'end
  end
  return true
end
function M.begin(app,targets)
  if app.gesture or app.transform_preview or app.edit.active or app.multi_notes.transaction or app.multi_notes.paint then return nil,'Finish the current edit first.'end
  if not targets or #targets==0 then return nil,'Select slide targets first.'end
  local current=sources(app);local g={entries={},by_take={}}
  for _,h in ipairs(targets)do
    local source=current[h.take];if not source or source.readonly then return nil,source and source.reason or 'A source left the item scope.'end
    local entry=g.by_take[h.take]
    if not entry then
      local ok,raw=reaper.MIDI_GetAllEvts(h.take,'');if not ok then return nil,'Could not read a slide source.'end
      local child=require('src.phrase_scope').child_app(app,h.take)
      entry={take=h.take,source=source,child=child,before_raw=raw,expected_raw=raw,before_pairs=Notes.get_pairing_state(h.take),targets={}}
      g.by_take[h.take]=entry;g.entries[#g.entries+1]=entry
    end
    if h.raw~=entry.before_raw then return nil,'MIDI changed since the targets were selected. Select them again.'end
    entry.targets[#entry.targets+1]=h
  end
  app.gesture={kind='multi_slide_targets'};return g
end
function M.cancel(app,g)
  if not g then return end
  for _,entry in ipairs(g.entries)do if entry.child.edit.active then entry.child.edit:cancel()end end
  Multi.restore(g.entries)
  if app.gesture and app.gesture.kind=='multi_slide_targets'then app.gesture=nil end
  app.cache:invalidate();app.cc_cache:invalidate();Model.refresh(app,true)
end
function M.preview(app,g,change)
  local ok,notice=valid(app,g);if not ok then M.cancel(app,g);return false,notice end
  if not change.delete then for _,entry in ipairs(g.entries)do for _,h in ipairs(entry.targets)do
    local first=reaper.MIDI_GetProjQNFromPPQPos(entry.take,h.first)+(change.time or 0)
    local last=reaper.MIDI_GetProjQNFromPPQPos(entry.take,h.last)+(change.time or 0)+(change.length or 0)
    if first<entry.source.start_qn-1e-8 or last>entry.source.end_qn+1e-8 or last<=first then return false,'The slide group would leave a source item or have an invalid duration.'end
  end end end
  if not Multi.restore(g.entries)then M.cancel(app,g);return false,'Could not restore the slide group snapshots.'end
  for _,entry in ipairs(g.entries)do entry.expected_raw=entry.before_raw end
  for _,entry in ipairs(g.entries)do
    local origin=reaper.MIDI_GetProjQNFromPPQPos(entry.take,entry.targets[1].first)
    local function ticks(delta)return math.floor(reaper.MIDI_GetPPQPosFromProjQN(entry.take,origin+(delta or 0))-reaper.MIDI_GetPPQPosFromProjQN(entry.take,origin)+.5)end
    local gesture={take=entry.take,source_index=entry.targets[1].source_index,slide_id=entry.targets[1].slide_id,targets=entry.targets,expected_raw=entry.before_raw,preview=true}
    if change.copy then
      local clip,anchor=Slides.copy_targets(entry.child,entry.targets)
      if clip then ok,notice=Slides.paste_targets(entry.child,clip,anchor+(change.time or 0),true)else ok,notice=false,anchor end
    else
      ok,notice=Slides.preview_edit(entry.child,gesture,{time_delta=ticks(change.time),length_delta=ticks(change.length),pitch_delta=change.pitch,curve=change.curve,linear=change.linear,delete=change.delete})
      if ok then ok=Slides.finish(entry.child,gesture)end
    end
    entry.expected_raw=select(2,reaper.MIDI_GetAllEvts(entry.take,''))
    if not ok then
      Multi.restore(g.entries);for _,part in ipairs(g.entries)do part.expected_raw=part.before_raw;part.after_raw=nil end
      return false,notice or 'The slide group could not be changed.'
    end
    entry.after_raw=entry.expected_raw;entry.after_pairs=Notes.get_pairing_state(entry.take)
  end
  app.cache:invalidate();app.cc_cache:invalidate();return true
end
function M.finish(app,g)
  local ok,notice=valid(app,g);if not ok then M.cancel(app,g);return false,notice end
  local changed=false;for _,entry in ipairs(g.entries)do if not entry.after_raw then M.cancel(app,g);return false,'No valid slide edit was previewed.'end;changed=changed or entry.after_raw~=entry.before_raw end
  if not changed then M.cancel(app,g);return true end
  ok,notice=Multi.commit(g.entries,'ReaRoll: edit slide targets across MIDI items')
  if not ok then M.cancel(app,g);return false,notice end
  app.gesture=nil;app.cache:invalidate();app.cc_cache:invalidate();Model.refresh(app,true);return true
end
function M.copy(app,targets)
  local current=sources(app);for _,h in ipairs(targets)do local source=current[h.take];if not source or source.readonly then return nil,source and source.reason or 'A slide source left the editing scope.'end end
  local grouped={};for _,h in ipairs(targets)do local part=grouped[h.take]or {};grouped[h.take]=part;part[#part+1]=h end
  local captures={};local first=math.huge
  for take,part in pairs(grouped)do
    local child=require('src.phrase_scope').child_app(app,take);local clip,anchor=Slides.copy_targets(child,part)
    if not clip then return nil,anchor end
    captures[#captures+1]={clip=clip,anchor=anchor};first=math.min(first,anchor)
  end
  if first==math.huge then return nil,'Select targets first.'end
  local clip={version=1,targets={},span=0}
  for _,capture in ipairs(captures)do for _,target in ipairs(capture.clip.targets)do
    local copy={};for k,v in pairs(target)do copy[k]=v end
    copy.time=copy.time+capture.anchor-first;clip.targets[#clip.targets+1]=copy;clip.span=math.max(clip.span,copy.time+copy.duration)
  end end
  return clip
end
return M
