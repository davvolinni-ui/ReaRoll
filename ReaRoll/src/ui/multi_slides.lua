-- @noindex
-- Reuse the single-item slide workflow in each source's own PPQ coordinates.
local Model=require 'src.multi_notes'
local Selection=require 'src.selection'
local Slides=require 'src.slide_draw'
local Targets=require 'src.ui.slide_targets'
local U=require 'src.util'
local Groups=require 'src.multi_slide_targets'
local M={}
local function state(app)
  app.multi_slides=app.multi_slides or {owners={}}
  return app.multi_slides
end
local function selected_targets(app)
  local current={};for _,source in ipairs(Model.sources(app))do if not source.readonly then current[source.take]=true end end
  local out={};for take,child in pairs(state(app).owners)do if current[take]then for _,h in ipairs(Targets.selected(child))do out[#out+1]=h end else child.slide_group=nil;child.slide_selection=nil end end;return out
end
local function refresh_targets(app)
  for _,child in pairs(state(app).owners)do child.slide_target_cache=nil;Targets.reselect(child)end
end
local function group_action(app,change)
  local targets=selected_targets(app);local g,notice=Groups.begin(app,targets);if not g then return false,notice end
  local ok;ok,notice=Groups.preview(app,g,change)
  if ok then ok,notice=Groups.finish(app,g)else Groups.cancel(app,g)end
  if ok and change.copy then for take,entry in pairs(g.by_take)do local child=state(app).owners[take];if child then Targets.select_new(child,entry.before_raw)end end end
  refresh_targets(app);return ok,notice
end
local function source(app,take)
  for _,s in ipairs(Model.sources(app))do if s.take==take then return s end end
end
local function owner(app,take)
  local s=state(app);local child=s.owners[take]
  if not child then child=require('src.phrase_scope').child_app(app,take);s.owners[take]=child end
  child.settings={};for k,v in pairs(app.settings)do child.settings[k]=v end
  child.settings.phrase_scope='active';child.multi_edit_mode=false;child.controller_selection_active=false
  local current=source(app,take);if current then child.item_start_qn=current.start_qn;child.item_end_qn=current.end_qn end
  child.slide_clipboard=app.slide_clipboard
  child.slide_group_action=function(h,change)
    local targets=selected_targets(app);local takes={};for _,target in ipairs(targets)do takes[target.take]=true end
    local count=0;for _ in pairs(takes)do count=count+1 end;if count<2 then return false end
    local first=reaper.MIDI_GetProjQNFromPPQPos(h.take,h.first);local last=reaper.MIDI_GetProjQNFromPPQPos(h.take,h.last)
    local dt=change.first and reaper.MIDI_GetProjQNFromPPQPos(h.take,change.first)-first or 0
    local dl=(change.last and reaper.MIDI_GetProjQNFromPPQPos(h.take,change.last)-last or 0)-dt
    local ok,notice=group_action(app,{time=dt,length=dl,pitch=change.target and change.target-h.target or 0,curve=change.curve,linear=change.linear,delete=change.delete})
    app.expression_notice=notice;child.expression_notice=notice;return true,ok
  end
  child.selection.ids={};local indices={}
  for _,n in ipairs(Model.chosen(app))do if n.source.take==take then indices[n.index]=true end end
  for _,n in ipairs(child.cache:get(false))do if indices[n.index]then Selection.add(child.selection,n.id)end end
  return child
end
local function viewport(v,take)
  local out={ppq_per_qn=reaper.MIDI_GetPPQPosFromProjQN(take,1)-reaper.MIDI_GetPPQPosFromProjQN(take,0)}
  setmetatable(out,{__index=v})
  function out:x_from_ppq(p)return v:x_from_qn(reaper.MIDI_GetProjQNFromPPQPos(take,p))end
  return out
end
local function invalidate(app)
  app.cache:invalidate();app.cc_cache:invalidate();Model.refresh(app,true)
end
function M.cancel(app)
  local s=app.multi_slides;if not s then return end
  if s.glide_owner then s.glide_owner.gesture=nil;s.glide_owner=nil;app.gesture=nil end
  if s.group then Groups.cancel(app,s.group);s.group=nil end
  local active=s.active
  if active then
    local child,g=active.child,active.child.gesture
    if child.edit.active then
      local ok,raw=false,nil
      if require('src.take').valid(child.take)then ok,raw=reaper.MIDI_GetAllEvts(child.take,'')end
      if ok and g and raw==g.expected_raw then child.edit:cancel()else child.edit.active=nil end
    end
    child.gesture=nil;s.active=nil
  end
  if app.gesture and app.gesture.kind=='multi_slide'then app.gesture=nil end
  invalidate(app)
end
local function valid(app,active)
  local s=source(app,active.child.take);local old=active.source
  return s and not s.readonly and s.start_qn==old.start_qn and s.end_qn==old.end_qn and s.rate==old.rate and s.offset==old.offset
end
local function activate(app,child,src)
  state(app).active={child=child,source=src}
  state(app).focus=child
  app.gesture={kind='multi_slide'}
end
function M.begin(app,n,q,pitch)
  if app.gesture or app.edit.active or app.transform_preview or app.multi_notes.transaction or app.multi_notes.paint then return false,'Finish the current edit first.'end
  local src=source(app,n.source.take)
  if not src or src.readonly then return false,src and src.reason or 'The source left the editing scope.'end
  if src.start_qn~=n.source.start_qn or src.end_qn~=n.source.end_qn or src.rate~=n.source.rate or src.offset~=n.source.offset then return false,'Source timing changed. Select the note again.'end
  local child=owner(app,src.take);local note=child.cache:get(false)[n.index+1]
  if not note then return false,'Select the source note again.'end
  if note.pitch~=n.pitch or note.chan~=n.chan or note.vel~=n.vel or math.abs(reaper.MIDI_GetProjQNFromPPQPos(src.take,note.s)-n.s)>1e-8 or math.abs(reaper.MIDI_GetProjQNFromPPQPos(src.take,note.e)-n.e)>1e-8 then return false,'MIDI changed. Select the source note again.'end
  q=app.settings.snap_enabled and U.snap_time(app.settings,q,n.s)or q
  local first=math.floor(reaper.MIDI_GetPPQPosFromProjQN(src.take,q)+.5)
  if first<note.s or first>=note.e-1 then return false,'Draw the target within the selected source note time span.'end
  local last=math.min(reaper.MIDI_GetPPQPosFromProjQN(src.take,child.item_end_qn),math.floor(reaper.MIDI_GetPPQPosFromProjQN(src.take,q+require('src.grid').note_length(app.settings))+.5))
  child.gesture={kind='slide_draw',source_index=note.index,source_s=note.s,source_e=note.e,first=first,default_last=math.max(first+2,last)}
  local ok,notice=Slides.preview(child,child.gesture,child.gesture.default_last,pitch)
  if ok then activate(app,child,src);app.settings.note_expression_overlay=true
  else child.gesture=nil end
  return ok,notice
end
function M.finish(app)
  local s=state(app);local active=s.active;if not active then return false end
  if not active.child.gesture then M.cancel(app);return false,'The slide was cancelled because its source changed.'end
  if not valid(app,active)then M.cancel(app);return false,'The slide source changed or became read-only; the gesture was cancelled.'end
  local child=active.child;local ok
  if child.gesture.kind=='slide_edit'then ok=Targets.finish(child,child.gesture)else ok=Slides.finish(child,child.gesture)end
  child.gesture=nil;s.active=nil;app.gesture=nil;invalidate(app)
  return ok
end
function M.fold_notes(app,notes)
  if not app.settings.fold_enabled or app.settings.scale_view_only then return notes end
  local out=notes
  for _,src in ipairs(Model.sources(app))do out=Targets.fold_notes(owner(app,src.take),out)end
  return out
end
function M.draw(app,d,v)
  for _,child in pairs(state(app).owners)do child.slide_hits={}end
  local seen={}
  for _,n in ipairs((app.multi_notes.notes or {}))do if not seen[n.source.take]then
    seen[n.source.take]=true;local child=owner(app,n.source.take)
    local view=viewport(v,n.source.take)
    if not app.settings.mpe_pitch_edit then
      if not require('src.ui.expression_direct').grid_visible(app)then require('src.ui.note_expression').draw(child,d,view,child.cache:get(false))end
      Targets.draw(child,d,view)
    end
    require('src.ui.overlap_glide').draw(child,d,view,child.cache:get(false))
  end end
end
function M.interact(app,v,hovered,mx,my,mods,edge)
  local s=state(app);local I,c=app.ImGui,app.ctx
  local Connections=require 'src.ui.overlap_glide'
  local function refresh_links()
    local selected={};for _,n in ipairs(Model.chosen(app))do selected[tostring(n.source.take)..':'..n.index]=true end
    invalidate(app);app.multi_notes.selection={}
    for _,n in ipairs(app.multi_notes.notes)do if selected[tostring(n.source.take)..':'..n.index]then app.multi_notes.selection[n.key]=true end end;Model.sync(app)
  end
  if s.glide_owner then
    local child=s.glide_owner;local src=source(app,child.take)
    if not src or src.readonly then child.gesture=nil;app.gesture=nil;s.glide_owner=nil;return true end
    Connections.interact(child,viewport(v,child.take),hovered,mx,my,mods,edge)
    app.gesture=child.gesture;app.expression_notice=child.expression_notice
    if not child.gesture then s.glide_owner=nil;refresh_links()end
    return true
  end
  if hovered and not app.gesture then for _,child in pairs(s.owners)do
    local src=source(app,child.take)
    if src and not src.readonly and Connections.interact(child,viewport(v,child.take),hovered,mx,my,mods,edge)then
      if child.gesture then s.glide_owner=child;app.gesture=child.gesture else refresh_links()end
      app.expression_notice=child.expression_notice;return true
    end
  end end
  if s.group then
    local g=s.group;local drag=g.drag
    if not Targets.editable(app)or require('src.shortcuts').pressed(app,'cancel',mods)then Groups.cancel(app,g);s.group=nil;refresh_targets(app);return true end
    local dt=v:qn_from_x(mx)-drag.anchor_qn
    local origin=reaper.MIDI_GetProjQNFromPPQPos(drag.take,drag.edge=='right'and drag.last or drag.first)
    if not mods.alt then dt=U.snap_time(app.settings,origin+dt,origin)-origin end
    local change={time=drag.edge=='right'and 0 or dt,length=drag.edge=='right'and dt or drag.edge=='left'and -dt or 0,pitch=drag.edge and 0 or v:pitch_from_y(my)-drag.anchor_pitch}
    if drag.curve_drag then change={curve=math.max(-1,math.min(1,drag.curve+(drag.my-my)/100))}end
    local signature=table.concat({change.time or 0,change.length or 0,change.pitch or 0,change.curve or ''},':')
    if signature~=g.signature and(math.abs(mx-drag.mx)>=3 or math.abs(my-drag.my)>=3)then
      local ok,notice=Groups.preview(app,g,change);app.expression_notice=notice;if ok then g.signature=signature;g.changed=true end
      if not app.gesture then s.group=nil;refresh_targets(app);return true end
    end
    if I.IsMouseReleased(c,I.MouseButton_Left)then
      if g.changed then local _,notice=Groups.finish(app,g);app.expression_notice=notice else Groups.cancel(app,g)end
      s.group=nil;refresh_targets(app)
    end
    return true
  end
  if s.active then
    local active=s.active;local child,g=active.child,active.child.gesture
    if not Targets.editable(app)or not valid(app,active)or require('src.shortcuts').pressed(app,'cancel',mods)then M.cancel(app);return true end
    local view=viewport(v,child.take)
    if g.kind=='slide_edit'then Targets.update(child,g,view,mx,my,mods)
    else
      local last=g.default_last;local target=v:pitch_from_y(my)
      if math.abs(mx-g.mx)>=4 then
        local q=v:qn_from_x(mx);if app.settings.snap_enabled and not mods.alt then q=U.snap_time(app.settings,q,reaper.MIDI_GetProjQNFromPPQPos(child.take,g.first))end
        last=math.max(g.first+2,math.min(reaper.MIDI_GetPPQPosFromProjQN(child.take,child.item_end_qn),math.floor(reaper.MIDI_GetPPQPosFromProjQN(child.take,q)+.5)))
      end
      if last~=g.last or target~=g.target then local ok,notice=Slides.preview(child,g,last,target);app.expression_notice=notice;if not ok and not child.edit.active then g.valid=false end end
    end
    if not child.gesture then M.cancel(app);return true end
    if I.IsMouseReleased(c,I.MouseButton_Left)then local _,notice=M.finish(app);app.expression_notice=notice or child.expression_notice end
    return true
  end
  if not Targets.editable(app)then return false end
  local focus=s.focus
  if hovered then
    local best,distance,best_hit
    for _,child in pairs(s.owners)do for _,hit in ipairs(child.slide_hits or {})do
      if mx>=hit.x1-6 and mx<=hit.x2+6 and math.abs(my-hit.cy)<=math.max(7,app.settings.row_height*.5)then
        local delta=math.abs(my-hit.cy);if not distance or delta<distance then best,distance,best_hit=child,delta,hit end
      end
    end end
    if best then
      if I.IsMouseClicked(c,I.MouseButton_Left)and not mods.ctrl then
        local included=false;for _,h in ipairs(Targets.selected(best))do if h.source_index==best_hit.target.source_index and h.slide_id==best_hit.target.slide_id then included=true end end
        if not included then for _,other in pairs(s.owners)do other.slide_group=nil;other.slide_selection=nil end end
      end
      focus=best;s.focus=best
    end
  end
  if focus then
    local src=source(app,focus.take)
    if not src or src.readonly then focus.slide_hits={};focus.slide_selection=nil;focus=nil;s.focus=nil
    else
      local consumed=Targets.interact(focus,viewport(v,focus.take),hovered,mx,my,mods)
      app.expression_notice=focus.expression_notice;app.slide_clipboard=focus.slide_clipboard
      if focus.expression_setup_visible then app.expression_editor_open=true;app.expression_setup_visible=true;focus.expression_setup_visible=false end
      if focus.gesture then
        local targets=selected_targets(app);local takes={};for _,h in ipairs(targets)do takes[h.take]=true end
        local count=0;for _ in pairs(takes)do count=count+1 end
        if focus.gesture.kind=='slide_edit'and count>1 then
          local drag=focus.gesture;drag.take=focus.take;focus.gesture=nil
          local g,notice=Groups.begin(app,targets);app.expression_notice=notice
          if g then g.drag=drag;s.group=g end;return true
        end
        activate(app,focus,src);return true
      end
      if consumed then invalidate(app);return true end
      if I.IsPopupOpen(c,'##slide_target')then return true end
    end
  end
  if app.settings.mode=='slide'and hovered and I.IsMouseClicked(c,I.MouseButton_Left)and not mods.ctrl then
    if v.fold then app.expression_notice='Unfold pitches before drawing a slide target.';return true end
    local source,notice=Slides.source(Model.refresh(app).notes,v:qn_from_x(mx),app.settings.channel)
    if not source then app.expression_notice=notice;return true end
    app.multi_notes.selection={[source.key]=true};Model.sync(app)
    local ok,message=M.begin(app,source,v:qn_from_x(mx),v:pitch_from_y(my));app.expression_notice=message
    if ok then local g=s.active.child.gesture;g.mx,g.my=mx,my end
    return true
  end
  return false
end
function M.keys(app)
  local s=state(app);if s.active or s.group then return true end
  if not Targets.editable(app)then return false end
  local targets=selected_targets(app);local takes={};for _,h in ipairs(targets)do takes[h.take]=true end
  local source_count=0;for _ in pairs(takes)do source_count=source_count+1 end
  local mods=U.mods(app.ImGui,app.ctx);local pressed=require('src.shortcuts').pressed
  if source_count>1 and not app.ImGui.IsAnyItemActive(app.ctx)and app.ImGui.IsWindowFocused(app.ctx,app.ImGui.FocusedFlags_RootAndChildWindows)then
    if pressed(app,'copy',mods)or pressed(app,'cut',mods)then
      local clip,notice=Groups.copy(app,targets)
      if clip and pressed(app,'cut',mods)then local ok;ok,notice=group_action(app,{delete=true});if ok then app.slide_clipboard=clip;for _,owner in pairs(s.owners)do owner.slide_group=nil;owner.slide_selection=nil end end
      elseif clip then app.slide_clipboard=clip end
      app.expression_notice=notice;return true
    end
    local change
    if pressed(app,'delete',mods)then change={delete=true}
    elseif pressed(app,'nudge_left',mods)then change={time=-app.settings.grid_qn}
    elseif pressed(app,'nudge_right',mods)then change={time=app.settings.grid_qn}
    elseif pressed(app,'pitch_up',mods)then change={pitch=1}
    elseif pressed(app,'pitch_down',mods)then change={pitch=-1}
    elseif pressed(app,'octave_up',mods)then change={pitch=12}
    elseif pressed(app,'octave_down',mods)then change={pitch=-12}
    elseif pressed(app,'length_shorter',mods)then change={length=-app.settings.grid_qn}
    elseif pressed(app,'length_longer',mods)then change={length=app.settings.grid_qn}
    elseif pressed(app,'duplicate',mods)then
      local first,last=math.huge,-math.huge;for _,h in ipairs(targets)do first=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(h.take,h.first));last=math.max(last,reaper.MIDI_GetProjQNFromPPQPos(h.take,h.last))end
      change={copy=true,time=last-first+1/960}
    elseif pressed(app,'cancel',mods)or pressed(app,'deselect',mods)then for _,owner in pairs(s.owners)do owner.slide_group=nil;owner.slide_selection=nil end;return true end
    if change then local ok,notice=group_action(app,change);app.expression_notice=notice;if ok and change.delete then for _,owner in pairs(s.owners)do owner.slide_group=nil;owner.slide_selection=nil end end;return true end
  end
  local child=s.focus
  if app.slide_clipboard and require('src.shortcuts').pressed(app,'paste',U.mods(app.ImGui,app.ctx))then
    if app.slide_clipboard.version==1 then
      child=owner(app,app.multi_creation_take or app.take);s.focus=child
    else
    local chosen=Model.chosen(app)
    if #chosen~=1 then app.expression_notice='Select one source note before pasting a slide target.';return true end
    child=owner(app,chosen[1].source.take);s.focus=child
    end
  end
  if not child and app.slide_clipboard then local chosen=Model.chosen(app);if #chosen==1 then child=owner(app,chosen[1].source.take);s.focus=child end end
  if not child then return false end
  local src=source(app,child.take)
  if not src or src.readonly then child.slide_selection=nil;return false end
  owner(app,child.take)
  local consumed=Targets.keys(child);app.slide_clipboard=child.slide_clipboard;app.expression_notice=child.expression_notice
  if consumed then invalidate(app)end
  return consumed
end
return M
