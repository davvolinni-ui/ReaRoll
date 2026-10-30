-- @noindex
-- Expand an explicit note selection into complete recorded pedal contexts.
-- This selects existing data only; editing remains with the mixed Razor engine.
local M={}
function M.select(app)
  if not app.settings.mpe_enabled then return false,'Enable MPE mode to select a voice/pedal context.'end
  if app.gesture or app.transform_preview or app.lane_tool_preview or app.edit.active or app.controller_point_gesture or app.controller_razor_drag or app.razor_drag or app.multi_notes and(app.multi_notes.transaction or app.multi_notes.paint or app.multi_notes.structure_brush or app.multi_notes.mute_brush)then return false,'Finish the current edit first.'end
  local Notes=require 'src.note_events';local Model=require 'src.multi_notes';local Areas=require 'src.controller_areas'
  local sources,chosen={},{}
  if app.multi_edit_mode then
    sources=Model.sources(app)
    for _,n in ipairs(Model.chosen(app))do chosen[n.source.take]=chosen[n.source.take]or {};chosen[n.source.take][n.index]=true end
  else
    sources={{take=app.take,start_qn=app.item_start_qn,end_qn=app.item_end_qn}}
    chosen[app.take]={};for _,n in ipairs(require('src.selection').list(app.selection,app.cache:get(false)))do chosen[app.take][n.index]=true end
  end
  local rows,contexts={},{};local count=0;local master=app.settings.mpe_zone=='upper'and 15 or 0
  for _,source in ipairs(sources)do
    if not require('src.take').valid(source.take)then return false,'A MIDI source is no longer available.'end
    local stream=Notes.read(source.take);if not stream then return false,'A MIDI source is unavailable.'end
    local child=app.multi_edit_mode and require('src.phrase_scope').child_app(app,source.take)or app
    local ctx={source=source,stream=stream,child=child,cycles={},regions={}};contexts[#contexts+1]=ctx
    local held={}
    for _,event in ipairs(stream.events)do if not event.deleted and #event.msg>=3 and event.msg:byte(1)>>4==11 and event.msg:byte(2)==64 then
      local ch=event.msg:byte(1)&15
      if event.msg:byte(3)>=64 then held[ch]=held[ch]or event.ppq
      elseif held[ch]then ctx.cycles[#ctx.cycles+1]={channel=ch,first=held[ch],last=event.ppq};held[ch]=nil end
    end end
    local life=require('src.voice_lifetime').index(stream,app.settings)
    for _,n in ipairs(stream.notes)do
      local selected=chosen[source.take]and chosen[source.take][n.index]or false
      rows[#rows+1]={ctx=ctx,note=n,ending=life(n),selected=selected};if selected then count=count+1 end
    end
  end
  if count==0 then return false,'Select a sustained note first.'end
  local note_areas={};local found_pedal=false;local changed=true
  while changed do
    changed=false;note_areas={}
    for _,row in ipairs(rows)do if row.selected then
      local ctx,n=row.ctx,row.note;local source=ctx.source
      if source.readonly then return false,source.reason or 'The complete pedal context includes a read-only MIDI source.'end
      if row.ending==math.huge then return false,'A selected voice has no recorded pedal release.'end
      local first=reaper.MIDI_GetProjQNFromPPQPos(source.take,n.s);local last=reaper.MIDI_GetProjQNFromPPQPos(source.take,row.ending)
      if first<source.start_qn or last>source.end_qn then return false,'The complete voice extends beyond its editable item.'end
      note_areas[#note_areas+1]={start_qn=first,end_qn=last,low=n.pitch,high=n.pitch,channel=n.chan}
      if row.ending>n.e then
        local covered=false
        for _,cycle in ipairs(ctx.cycles)do if(cycle.channel==n.chan or cycle.channel==master)and cycle.first<=n.e and cycle.last>=n.e and cycle.first<row.ending then
          if not cycle.area then
            local a=math.min(first,reaper.MIDI_GetProjQNFromPPQPos(source.take,cycle.first-1));local b=reaper.MIDI_GetProjQNFromPPQPos(source.take,cycle.last)
            a=math.max(source.start_qn,a)
            cycle.area={start_qn=a,end_qn=b,pedal_cycle=true,lane={id='cc64',cc=64,label='Sustain (CC 64)',short='SUS',switch=true},channel=cycle.channel}
            ctx.regions[#ctx.regions+1]=cycle.area;changed=true
          end
          if first<cycle.area.start_qn then cycle.area.start_qn=first;changed=true end
          covered=true;found_pedal=true
        end end
        if not covered then return false,'A reset or missing pedal boundary prevents selecting a complete CC64 cycle.'end
      end
    end end
    for _,row in ipairs(rows)do if not row.selected then
      local take=row.ctx.source.take;local n=row.note
      local first=reaper.MIDI_GetProjQNFromPPQPos(take,n.s);local last=reaper.MIDI_GetProjQNFromPPQPos(take,row.ending)
      local include=false
      for _,a in ipairs(note_areas)do if n.pitch>=a.low and n.pitch<=a.high and n.chan==a.channel and first<a.end_qn and last>a.start_qn then include=true;break end end
      for _,a in ipairs(row.ctx.regions)do if(a.channel==master or a.channel==n.chan)and first<a.end_qn and last>a.start_qn then include=true;break end end
      if include then row.selected=true;count=count+1;changed=true end
    end end
  end
  if not found_pedal then return false,'The selection has no pedal-held tail.'end
  -- Validate all contexts before changing any visible selection.
  for _,ctx in ipairs(contexts)do if #ctx.regions>0 then
    local ok,notice=require('src.sustain_group').prepare(ctx.child,note_areas,ctx.regions,'move',0,1)
    if ok==false then return false,notice end
  end end
  app.razor_areas={};for i,a in ipairs(note_areas)do if i==#note_areas then app.razor_area=a else app.razor_areas[#app.razor_areas+1]=a end end
  local cycles=0
  if app.multi_edit_mode then app.multi_notes.selection={};app.multi_controller_owners={}
    for _,ctx in ipairs(contexts)do if #ctx.regions>0 then Areas.set(ctx.child,ctx.regions);app.multi_controller_owners[ctx.source.take]=ctx.child;cycles=cycles+#ctx.regions end end
    for _,n in ipairs(app.multi_notes.notes)do for _,row in ipairs(rows)do if row.selected and row.ctx.source.take==n.source.take and row.note.index==n.index then app.multi_notes.selection[n.key]=true end end end
    Model.sync(app)
  else
    Areas.set(app,contexts[1].regions);cycles=#contexts[1].regions;app.selection.ids={}
    for _,n in ipairs(app.cache:get(false))do for _,row in ipairs(rows)do if row.selected and row.note.index==n.index then app.selection.ids[n.id]=true end end end
  end
  app.settings.mode='razor';app.settings.lane_open=true;app.settings.lane_target='cc64';app.settings.cc_number=64
  app.expression_editor_open=false;app.mixed_razor=true;app.razor_focus='notes';app.controller_selection_active=false
  return true,tostring(count)..' notes and '..tostring(cycles)..' complete sustain cycles selected. Razor edits include the whole group.'
end
return M
