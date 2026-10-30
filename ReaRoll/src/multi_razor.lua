-- @noindex
local Notes=require 'src.note_events';local Razor=require 'src.razor';local Multi=require 'src.multi_edit';local Model=require 'src.multi_notes'
local M={}
local function regions_for(source,areas)
  local out={}
  for _,a in ipairs(areas)do
    local first,last=math.max(a.start_qn,source.start_qn),math.min(a.end_qn,source.end_qn)
    if last>first then out[#out+1]={start_qn=first,end_qn=last,low=a.low,high=a.high,channel=a.channel}end
  end
  return out
end
local function snapshot(take)
  local stream=Notes.read(take);if not stream then return nil end
  return {take=take,before_raw=stream.original_raw,before_pairs=Notes.get_pairing_state(take),expected_raw=stream.original_raw}
end
local function safe_notes(app,source,areas,whole)
  local stream=Notes.read(source.take);if not stream then return nil,'A MIDI source is unavailable.'end
  for _,n in ipairs(stream.notes)do
    local a,b=reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(source.take,n.e)
    local spans=Razor.intervals(n,a,b,areas)
    if #spans>0 and(app.settings.mpe_enabled and require('src.expression').member(n.chan,app.settings)or require('src.slide_links').has(n))then
      if not whole or #spans~=1 or spans[1].s>a+1e-9 or spans[1].e<b-1e-9 then return nil,'Include the complete expression note to edit it with its curves. Partial voice splitting remains protected.'end
    end
  end
  return stream
end
function M.apply(app,areas,operation,dq,dp,scale)
  if app.edit.active or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint)or app.transform_preview then return false,'Finish the current edit first.'end
  areas=areas[1]and areas or {areas};if #areas==0 then return false end
  local first=Razor.bounds(areas);dq,dp=dq or 0,dp or 0;scale=operation=='stretch'and scale or 1
  if not scale or scale<=0 or scale~=scale then return false,'Use a positive stretch duration.'end
  local entries,children,wanted={},{},{}
  local ok,notice=xpcall(function()
    for _,source in ipairs(Model.sources(app))do if not source.readonly then
      local regions=regions_for(source,areas)
      if #regions>0 then
        local stream,reason=safe_notes(app,source,regions,true);assert(stream,reason)
        local hits=false
        for _,n in ipairs(stream.notes)do local a,b=reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(source.take,n.e);if #Razor.intervals(n,a,b,regions)>0 then hits=true;break end end
        if hits then
        local entry=assert(snapshot(source.take));entries[#entries+1]=entry
        local child=require('src.phrase_scope').child_app(app,source.take);children[#children+1]=child;child.mixed_razor=false
        child.edit:begin_preview(source.take)
        local options={transaction=true};local local_first=Razor.bounds(regions)
        local changed,message=Razor.apply(child,regions,operation,dq+(local_first-first)*(scale-1),dp,scale,options)
        assert(changed,message or 'One source destination extends outside its item or pitch range.')
        assert(child.edit:finish()~=false)
        entry.after_raw=select(2,reaper.MIDI_GetAllEvts(source.take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(source.take)
        for _,n in ipairs(options.wanted or {})do wanted[#wanted+1]={take=source.take,s=reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end
        end
      end
    end end
    assert(#entries>0,'No editable sources intersect this area.')
    local changed,message=Multi.commit(entries,'ReaRoll: razor '..operation..' across MIDI items');assert(changed,message)
  end,function(err)return tostring(err)end)
  if not ok then
    for _,child in ipairs(children)do if child.edit.active then child.edit:cancel()end end
    Multi.restore(entries);Model.refresh(app,true);return false,notice
  end
  Model.select_wanted(app,wanted);app.cache:invalidate();app.cc_cache:invalidate();return true
end
function M.copy(app,areas,options)
  if not areas or #areas==0 then return false,'Select a note area first.'end
  local first,last=Razor.bounds(areas);local phrase={span=last-first,notes={}};local mpe=false
  for _,source in ipairs(Model.sources(app))do if not source.readonly then
    local regions=regions_for(source,areas);local stream,notice=safe_notes(app,source,regions,true);if not stream then return false,notice end
    local complete={};for _,n in ipairs(stream.notes)do local a,b=reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(source.take,n.e);local spans=Razor.intervals(n,a,b,regions);complete[n.index]=#spans==1 and spans[1].s<=a+1e-9 and spans[1].e>=b-1e-9 end
    for _,note in ipairs(stream.notes)do
      local a,b=reaper.MIDI_GetProjQNFromPPQPos(source.take,note.s),reaper.MIDI_GetProjQNFromPPQPos(source.take,note.e)
      local spans=Razor.intervals(note,a,b,regions)
      if #spans>0 then
        local with_pedal=options and options.sustain_by_take and options.sustain_by_take[source.take]
        local expression,reason,owned=Razor.capture_expression(app,stream,note,a,b,spans,with_pedal,complete);if not expression then return false,reason end;mpe=mpe or owned
        local sounding=with_pedal and require('src.voice_lifetime').ending(stream,note,app.settings)
        for _,span in ipairs(spans)do phrase.notes[#phrase.notes+1]={offset=span.s-first,length=span.e-span.s,source=note,expression=expression,take=source.take,sounding_length=sounding and(reaper.MIDI_GetProjQNFromPPQPos(source.take,sounding)-a)}end
      end
    end
  end end
  if #phrase.notes==0 then return false,'No editable notes are inside the areas.'end
  local clip={phrase=phrase,areas={},multi=true,mpe=mpe,anchor=first}
  for _,a in ipairs(areas)do clip.areas[#clip.areas+1]={start_qn=a.start_qn-first,end_qn=a.end_qn-first,low=a.low,high=a.high,channel=a.channel}end
  app.razor_clipboard=clip;return true
end
function M.paste(app,clip,q)
  if app.multi_notes and(app.multi_notes.paint or app.multi_notes.transaction)or app.transform_preview or app.edit.active then return false,'Finish the current edit first.'end
  local take=app.multi_creation_take or app.take;local source
  if clip.mpe and type(q)=='number'and q==q then q=require('src.util').snap_time(app.settings,q,clip.anchor or 0)end
  for _,candidate in ipairs(Model.sources(app))do if candidate.take==take then source=candidate;break end end
  if not source or source.readonly then return false,'Choose an editable drawing target for Paste.'end
  if type(q)~='number'or q~=q or q<source.start_qn or q+clip.phrase.span>source.end_qn+1e-8 then return false,'The complete clipboard does not fit in the chosen drawing target.'end
  local entry=assert(snapshot(take));local child=require('src.phrase_scope').child_app(app,take);local wanted={}
  local ok,notice=xpcall(function()
    if clip.mpe then
      child.note_clipboard=Razor.expression_clipboard(clip);child.settings.prevent_overlaps=false
      assert(require('src.clipboard').paste_at(child,q,nil,{preview=true}),child.expression_notice or 'The expression voices cannot be pasted here.')
      for _,n in ipairs(require('src.selection').list(child.selection,child.cache:get(false)))do wanted[#wanted+1]={take=take,s=reaper.MIDI_GetProjQNFromPPQPos(take,n.s),pitch=n.pitch,chan=n.chan,vel=n.vel}end
    else
    child.edit:begin_preview(take);local active=child.edit.active;active.allow_overlaps=true
    for _,n in ipairs(clip.phrase.notes)do
      local s=math.floor(reaper.MIDI_GetPPQPosFromProjQN(take,q+n.offset)+.5);local e=math.floor(reaper.MIDI_GetPPQPosFromProjQN(take,q+n.offset+n.length)+.5)
      assert(e>s,'A pasted note is shorter than one MIDI tick.')
      local index=active.stream:insert_fragment(n.source,s,e,n.source.pitch);active.touched[index]=true;active.changed=true;active.note_changed=true
      wanted[#wanted+1]={take=take,s=reaper.MIDI_GetProjQNFromPPQPos(take,s),pitch=n.source.pitch,chan=n.source.chan,vel=n.source.vel}
    end
    assert(child.edit:finish()~=false)
    end
    entry.after_raw=select(2,reaper.MIDI_GetAllEvts(take,''));entry.expected_raw=entry.after_raw;entry.after_pairs=Notes.get_pairing_state(take)
    local changed,message=Multi.commit({entry},'ReaRoll: paste razor notes into chosen MIDI item');assert(changed,message)
  end,function(err)return tostring(err)end)
  if not ok then if child.edit.active then child.edit:cancel()end;Multi.restore({entry});return false,notice end
  Model.select_wanted(app,wanted)
  app.razor_areas={};app.razor_area=nil
  for i,a in ipairs(clip.areas)do local region={start_qn=q+a.start_qn,end_qn=q+a.end_qn,low=a.low,high=a.high,channel=a.channel}
    if i==#clip.areas then app.razor_area=region else app.razor_areas[#app.razor_areas+1]=region end
  end
  return true
end
return M
