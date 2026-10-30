-- @noindex
local Selection=require 'src.selection'
local M={}
function M.area(q1,q2,p1,p2,channel)
  return {start_qn=math.min(q1,q2),end_qn=math.max(q1,q2),low=math.min(p1,p2),high=math.max(p1,p2),channel=channel}
end
function M.hits(note,first,last,area)
  return (area.channel==nil or note.chan==area.channel) and note.pitch>=area.low and note.pitch<=area.high and last>area.start_qn and first<area.end_qn
end
function M.fragments(first,last,pitch,area,operation,dq,dp,scale)
  local result={}
  local left,right=math.max(first,area.start_qn),math.min(last,area.end_qn)
  if right<=left then return nil end
  if operation~='copy' then
    if first<left then result[#result+1]={s=first,e=left,pitch=pitch} end
    if last>right then result[#result+1]={s=right,e=last,pitch=pitch} end
  end
  if operation~='delete' then
    local start,ending=left+(dq or 0),right+(dq or 0)
    if operation=='stretch' then start=area.start_qn+(left-area.start_qn)*scale+(dq or 0); ending=area.start_qn+(right-area.start_qn)*scale+(dq or 0) end
    result[#result+1]={s=start,e=ending,pitch=pitch+(dp or 0)}
  end
  return result
end
function M.intervals(note,first,last,areas)
  local spans={}
  for _,area in ipairs(areas)do if M.hits(note,first,last,area)then spans[#spans+1]={s=math.max(first,area.start_qn),e=math.min(last,area.end_qn)}end end
  table.sort(spans,function(a,b)return a.s<b.s end)
  local out={};for _,span in ipairs(spans)do local prior=out[#out]
    if prior and span.s<=prior.e+1e-9 then prior.e=math.max(prior.e,span.e)else out[#out+1]=span end
  end
  return out
end
function M.bounds(areas)
  local first,last,low,high=math.huge,-math.huge,127,0
  for _,area in ipairs(areas)do first=math.min(first,area.start_qn);last=math.max(last,area.end_qn);low=math.min(low,area.low);high=math.max(high,area.high)end
  return first,last,low,high
end
function M.union_fragments(note,first,last,areas,operation,dq,dp,scale)
  local spans=M.intervals(note,first,last,areas);if #spans==0 then return nil end
  local anchor=M.bounds(areas);local out={};local cursor=first
  for _,span in ipairs(spans)do
    if operation~='copy' and cursor<span.s then out[#out+1]={s=cursor,e=span.s,pitch=note.pitch}end
    if operation~='delete' then out[#out+1]={s=anchor+(span.s-anchor)*scale+dq,e=anchor+(span.e-anchor)*scale+dq,pitch=note.pitch+dp}end
    cursor=span.e
  end
  if operation~='copy' and cursor<last then out[#out+1]={s=cursor,e=last,pitch=note.pitch}end
  return out
end
function M.apply(app,area,operation,dq,dp,scale,options)
  if app.multi_edit_mode and not options and app.mixed_razor and require('src.multi_controller_razor').has(app)then local ok,notice=require('src.multi_controller_razor').apply(app,area,operation,dq,dp,scale);app.razor_notice=notice;return ok,notice end
  if app.multi_edit_mode and not options then local ok,notice=require('src.multi_razor').apply(app,area,operation,dq,dp,scale);app.razor_notice=notice;return ok,notice end
  if app.mixed_razor and app.controller_razor and not options then
    local ok,notice=require('src.mixed_razor').apply(app,area,app.controller_razor,operation,dq,dp,scale)
    app.razor_notice=notice;return ok,notice
  end
  if not app.take or not area then return false end
  if reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false end
  if reaper.GetMediaItemTake_Item and reaper.GetMediaItemInfo_Value then local item=reaper.GetMediaItemTake_Item(app.take);if item and reaper.GetMediaItemInfo_Value(item,'C_LOCK')~=0 then return false end end
  local areas=area[1] and area or {area}
  if #areas==0 then return false end
  for _,region in ipairs(areas)do if region.end_qn<=region.start_qn then return false end end
  assert(operation=='copy' or operation=='move' or operation=='delete' or operation=='stretch','Invalid razor operation')
  dq,dp=dq or 0,dp or 0
  scale=operation=='stretch' and scale or 1
  if not scale or scale~=scale or scale<=0 then return false end
  local first_bound,last_bound,low,high=M.bounds(areas)
  local target_end=first_bound+(last_bound-first_bound)*scale+dq
  if operation~='delete' and (first_bound+dq<app.item_start_qn-1e-7 or target_end>app.item_end_qn+1e-7 or low+dp<0 or high+dp>127) then return false end
  local cached=app.cache:get(false);local selected={};local wanted={}
  for _,note in ipairs(cached)do if Selection.has(app.selection,note.id)then selected[note.index]=true end end
  -- The display cache deliberately omits notation/slide metadata. Ownership
  -- planning must use the actual event stream, not those lightweight rows.
  local snapshot=require('src.note_events').read(app.take);if not snapshot then return false,'The MIDI source is unavailable.'end
  local sources=snapshot.notes
  local plans={}
  for _,note in ipairs(sources) do
    local first=reaper.MIDI_GetProjQNFromPPQPos(app.take,note.s)
    local last=reaper.MIDI_GetProjQNFromPPQPos(app.take,note.e)
    local fragments=M.union_fragments(note,first,last,areas,operation,dq,dp,scale)
    if fragments then
      local expression=require('src.slide_links').expression_settings(note,app.settings)
      if expression then
        local spans=M.intervals(note,first,last,areas)
        if #spans~=1 or spans[1].s>first+1e-9 or spans[1].e<last-1e-9 then app.razor_notice='This area cuts through an expression voice. Include the complete note to move, copy, stretch or delete it with its curves.';return false,app.razor_notice end
      end
      plans[#plans+1]={index=note.index,fragments=fragments,expression=expression}
    elseif selected[note.index] then wanted[#wanted+1]=note end
  end
  if #plans==0 then return true end
  if not app.settings.mpe_enabled then
    local touched={};for _,plan in ipairs(plans)do touched[plan.index]=true end
    local ok,notice=require('src.shared_slide').require_complete(snapshot,touched)
    if not ok then return false,notice end
  end
  local complete,by_index={},{}
  for _,plan in ipairs(plans)do
    by_index[plan.index]=plan
    local n=sources[plan.index+1];local first,last=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e)
    local spans=M.intervals(n,first,last,areas)
    complete[n.index]=#spans==1 and spans[1].s<=first+1e-9 and spans[1].e>=last-1e-9
  end
  for _,plan in ipairs(plans)do if plan.expression and plan.expression.expression_pitch_only then
    local cohort,notice=require('src.slide_links').cohort({notes=sources},sources[plan.index+1],complete)
    if not cohort then return false,notice end
    if next(cohort)then
      plan.cohort=cohort;local group={};plan.shared_group=group
      for index in pairs(cohort)do by_index[index].shared_group=group end
    end
  end end
  if not (options and options.transaction)then app.edit:begin('ReaRoll: razor '..operation,app.take)end
  local transaction=app.edit.active
  -- Razor moves merge into the destination. Do not silently trim unrelated
  -- destination notes through the ordinary drawing overlap policy.
  transaction.allow_overlaps=true
  -- Destination geometry was validated above. Original outside fragments may
  -- extend beyond the visible item and must retain that hidden source data.
  transaction.preserve_source_bounds=true
  local ok,err=xpcall(function()
    local deletes,changes={},{}
    for _,plan in ipairs(plans) do
      local source=transaction.notes[plan.index+1]
      if operation~='copy'and(not(plan.expression or plan.shared_group)or operation=='delete')then deletes[#deletes+1]=plan.index
      elseif operation=='copy'and selected[plan.index] then wanted[#wanted+1]=source end
      for _,fragment in ipairs(plan.fragments) do
        local first=reaper.MIDI_GetPPQPosFromProjQN(app.take,fragment.s)
        local last=reaper.MIDI_GetPPQPosFromProjQN(app.take,fragment.e)
        if math.floor(last+.5)>math.floor(first+.5) then
          if(plan.expression or plan.shared_group)and operation~='copy'then changes[#changes+1]={index=source.index,values={s=first,e=last,pitch=fragment.pitch}}
          else
            local index,notice
            if plan.expression then index,notice=require('src.expression').duplicate(transaction.stream,source,first,last,fragment.pitch,plan.expression,plan.cohort,plan.shared_group);assert(index,notice)
            else index=transaction.stream:insert_fragment(source,first,last,fragment.pitch);transaction.stream.notes[index+1].slide_copy_group=plan.shared_group end
            transaction.changed,transaction.note_changed=true,true; transaction.touched[index]=true
          end
          if selected[plan.index] then wanted[#wanted+1]={s=first,e=last,pitch=fragment.pitch,vel=source.vel,chan=source.chan} end
        end
      end
    end
    if #changes>0 then assert(app.edit:set_group(app.take,changes),app.expression_notice or 'The expression destination is occupied.')end
    assert(app.edit:delete_indices(app.take,deletes)~=false,app.expression_notice or 'The shared expression group could not be deleted.')
    if not (options and options.transaction)then assert(app.edit:finish()~=false,app.expression_notice or 'The expression edit could not be committed.')end
  end,debug.traceback)
  if not ok then if app.edit.active then app.edit:cancel() end;return false,tostring(err)end
  if options and options.transaction then options.wanted=wanted
  else app.cache:rebuild(); app:reselect_notes(wanted)end
  return true
end
function M.capture_expression(app,stream,note,first,last,spans,with_pedal,selected)
  local settings=require('src.slide_links').expression_settings(note,app.settings)
  if not settings then return {},nil,false end
  if #spans~=1 or spans[1].s>first+1e-9 or spans[1].e<last-1e-9 then return nil,'Include the complete expression note before copying it.'end
  local cohort,notice
  if settings.expression_pitch_only then cohort,notice=require('src.slide_links').cohort(stream,note,selected);if not cohort then return nil,notice end end
  local owned;owned,notice=require('src.expression').capture(stream,note,settings,cohort)
  if not owned then return nil,notice end
  if owned.sustained and not with_pedal then return nil,'Include the full pedal cycle and every affected note in a mixed Razor clipboard group.'end
  local out={}
  for _,entry in ipairs(owned)do local event=entry.event
    out[#out+1]={offset=reaper.MIDI_GetProjQNFromPPQPos(stream.take,event.ppq)-first,flags=event.flags,msg=event.msg,order=event.order,shape=entry.shape and{flags=entry.shape.flags,msg=entry.shape.msg}}
  end
  return out,nil,true
end
function M.expression_clipboard(clip)
  local out={mpe=true,span_start=clip.anchor or 0,notes={}}
  for _,n in ipairs(clip.phrase.notes)do local source=n.source
    out.notes[#out.notes+1]={offset=n.offset,length=n.length,source=source,pitch=source.pitch,vel=source.vel,chan=source.chan,muted=source.muted,expression=n.expression or{}}
  end
  return out
end
function M.copy(app,areas,options)
  if app.multi_edit_mode and not options and app.mixed_razor and require('src.multi_controller_razor').has(app)then return require('src.multi_controller_razor').copy(app,areas)end
  if app.multi_edit_mode and not options then local ok,notice=require('src.multi_razor').copy(app,areas);app.razor_notice=notice;return ok,notice end
  if app.mixed_razor and app.controller_razor and not options then
    local ok,notice=require('src.mixed_razor').copy(app,areas);app.razor_notice=notice;return ok,notice
  end
  if not areas or #areas==0 then return false end
  if not app.take or reaper.ValidatePtr2 and not require('src.take').valid(app.take)then return false end
  local first,last=M.bounds(areas);local stream=require('src.note_events').read(app.take)
  if not stream then return false end
  local phrase={span=last-first,notes={}};local mpe=false
  local complete={};for _,n in ipairs(stream.notes)do local a,b=reaper.MIDI_GetProjQNFromPPQPos(app.take,n.s),reaper.MIDI_GetProjQNFromPPQPos(app.take,n.e);local spans=M.intervals(n,a,b,areas);complete[n.index]=#spans==1 and spans[1].s<=a+1e-9 and spans[1].e>=b-1e-9 end
  for _,note in ipairs(stream.notes)do
    local a,b=reaper.MIDI_GetProjQNFromPPQPos(app.take,note.s),reaper.MIDI_GetProjQNFromPPQPos(app.take,note.e)
    local spans=M.intervals(note,a,b,areas)
    if #spans>0 then
      local expression,notice,owned=M.capture_expression(app,stream,note,a,b,spans,options and options.sustain,complete)
      if not expression then app.razor_notice=notice;return false,notice end
      mpe=mpe or owned
      local sounding=options and options.sustain and require('src.voice_lifetime').ending(stream,note,app.settings)
      for _,span in ipairs(spans)do phrase.notes[#phrase.notes+1]={offset=span.s-first,length=span.e-span.s,source=note,expression=expression,sounding_length=sounding and(reaper.MIDI_GetProjQNFromPPQPos(app.take,sounding)-a)}end
    end
  end
  if #phrase.notes==0 then return false end
  app.razor_clipboard={phrase=phrase,areas={},mpe=mpe,anchor=first}
  for _,a in ipairs(areas)do app.razor_clipboard.areas[#app.razor_clipboard.areas+1]={start_qn=a.start_qn-first,end_qn=a.end_qn-first,low=a.low,high=a.high,channel=a.channel}end
  return true
end
function M.paste(app,q)
  local clip=app.razor_clipboard;if not clip then return false end
  if app.multi_edit_mode and clip.controller then return require('src.multi_controller_razor').paste(app,clip,q)end
  if app.multi_edit_mode and not clip.controller then return require('src.multi_razor').paste(app,clip,q)end
  if clip.controller then return require('src.mixed_razor').paste(app,clip,q)end
  local child={};for k,v in pairs(app)do child[k]=v end;setmetatable(child,getmetatable(app))
  child.settings={};for k,v in pairs(app.settings)do child.settings[k]=v end;child.settings.prevent_overlaps=false
  local ok,notice
  if clip.mpe then
    q=require('src.util').snap_time(app.settings,q,clip.anchor or 0)
    if q<app.item_start_qn or q+clip.phrase.span>app.item_end_qn+1e-8 then return false,'The complete area does not fit in the destination item.'end
    child.note_clipboard=M.expression_clipboard(clip);ok=require('src.clipboard').paste_at(child,q,'ReaRoll: paste razor expression voices');notice=child.expression_notice
  else ok,notice=require('src.phrase_library').insert(child,clip.phrase,q)end
  if ok then
    app.razor_areas={};app.razor_area=nil
    for i,a in ipairs(clip.areas)do local region={start_qn=q+a.start_qn,end_qn=q+a.end_qn,low=a.low,high=a.high,channel=a.channel}
      if i==#clip.areas then app.razor_area=region else app.razor_areas[#app.razor_areas+1]=region end
    end
  end
  return ok,notice
end
return M
