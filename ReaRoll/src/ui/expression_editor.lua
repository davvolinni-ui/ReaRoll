-- @noindex
local E=require 'src.expression'
local Model=require 'src.note_expression'
local Selection=require 'src.selection'
local U=require 'src.util'
local M={}
function M.draw(app,inline,advanced)
  local open_key=advanced and 'expression_advanced_open'or 'expression_editor_open'
  if not app[open_key]then return end
  local I,c,s=app.ImGui,app.ctx,app.settings
  local visible=true
  if not inline then
    I.SetNextWindowSize(c,advanced and 620 or 650,advanced and 240 or 680,I.Cond_FirstUseEver)
    visible,app[open_key]=I.Begin(c,advanced and 'Expression adjustments and voice setup'or 'Note expression / MPE',app[open_key],advanced and I.WindowFlags_AlwaysAutoResize or 0)
  end
  if visible then
    I.Text(c,advanced and 'Voices and group adjustments'or 'Note expression');I.SameLine(c)
    if I.SmallButton(c,'Close##expression')then app[open_key]=false end
    I.SameLine(c)
    local mode_changed,mode_enabled=I.Checkbox(c,'MPE mode',s.mpe_enabled)
    if mode_changed then
      if app.transform_preview then app.transforms.cancel_preview(app)end
      if app.edit.active then app.edit:cancel()end
      s.mpe_enabled=mode_enabled;app.expression_draft=nil;app.expression_batch=nil;app.mpe_assignment=nil
    end
    local setup=I.CollapsingHeader(c,'Instrument setup')
    local hit
    if setup then
    I.TextWrapped(c,'MPE editing preserves recorded member channels. The normal note drawing channel stays independent. Match the zone and pitch range to your instrument.')
    if not s.mpe_enabled then hit,s.pitch_bend_range=I.SliderInt(c,'Instrument bend range',s.pitch_bend_range or 2,1,96,'+/- %d semitones')end
    if s.mpe_enabled then
      if I.BeginCombo(c,'Zone',s.mpe_zone=='upper' and 'Upper (master channel 16)' or 'Lower (master channel 1)')then
        for _,zone in ipairs({'lower','upper'})do if I.Selectable(c,zone,s.mpe_zone==zone)then s.mpe_zone=zone;app.expression_draft=nil end end;I.EndCombo(c)
      end
      hit,s.mpe_members=I.SliderInt(c,'Member channels',s.mpe_members or 15,1,15)
      if hit then app.expression_draft=nil end
      hit,s.mpe_pitch_bend_range=I.SliderInt(c,'Per-note bend range',s.mpe_pitch_bend_range or 48,1,96,'+/- %d semitones')
      if I.IsItemHovered(c)then I.SetTooltip(c,'Display and editing range only. Configure the same range in the instrument; opening this editor sends no MIDI setup messages.')end
    end
    end
    if s.mpe_enabled then
      local selected=not app.multi_edit_mode and Selection.list(app.selection,app.cache:get(false))or {}
      local needs_voices=false
      for _,candidate in ipairs(selected)do if not E.member(candidate.chan,s)then needs_voices=true;break end end
      if needs_voices then I.TextWrapped(c,'These notes use a global channel. Give them independent voices to edit expression separately.')end
      if (needs_voices or setup)and I.Button(c,'Make notes independent')then
        app.mpe_assignment,app.expression_notice=require('src.mpe_assign').begin(app,selected)
      end
      if app.mpe_assignment then
        local assignment=app.mpe_assignment;local changes=0
        for _,voice in ipairs(assignment.assignments)do if voice.channel~=voice.original then changes=changes+1 end end
        I.TextWrapped(c,tostring(changes)..' notes will change channel. Existing recorded expression voices keep their channels. This prepares independent slides; the instrument must be in MPE mode.')
        for index=1,math.min(8,#assignment.assignments)do local voice=assignment.assignments[index];I.Text(c,U.pitch_name(voice.pitch)..': channel '..(voice.original+1)..' -> '..(voice.channel+1))end
        if #assignment.assignments>8 then I.TextDisabled(c,tostring(#assignment.assignments-8)..' more notes')end
        if I.Button(c,'Apply voice assignment')then local ok,notice=require('src.mpe_assign').apply(app,assignment);app.expression_notice=notice;if ok then app.mpe_assignment=nil;app.expression_draft=nil end end
        I.SameLine(c);if I.Button(c,'Cancel voice assignment')then app.mpe_assignment=nil end
      end
      if #selected>1 then
        local Batch=require 'src.note_expression_batch'
        if app.expression_batch and app.expression_batch.signature~=Batch.signature(app,selected)then app.expression_batch=nil end
        I.Separator(c);I.Text(c,#selected..' selected notes')
        if I.Button(c,'Edit expression across selected notes')then
          app.expression_batch,app.expression_notice=Batch.begin(app,selected);app.expression_batch_offset=0;app.expression_batch_gain=1
        end
        if app.expression_batch then
          app.expression_batch_kind=app.expression_batch_kind or 'pitch'
          local kind=app.expression_batch_kind
          if I.BeginCombo(c,'Expression dimension',kind)then
            for _,name in ipairs({'pitch','pressure','timbre','velocity','release_velocity'})do if I.Selectable(c,name,kind==name)then app.expression_batch_kind=name;kind=name;app.expression_batch_offset=0;app.expression_batch_gain=1 end end;I.EndCombo(c)
          end
          hit,app.expression_batch_gain=I.SliderDouble(c,'Value scale',app.expression_batch_gain or 1,0,2,'%.2fx')
          local range=kind=='pitch'and(s.mpe_pitch_bend_range or 48)or 127
          hit,app.expression_batch_offset=I.SliderDouble(c,kind=='pitch'and 'Pitch offset (semitones)'or 'Value offset',app.expression_batch_offset or 0,-range,range,'%.2f')
          Batch.adjust(app.expression_batch,s,kind,app.expression_batch_offset or 0,app.expression_batch_gain or 1)
          I.TextWrapped(c,'Adjusts this dimension across the selected notes. Times, channels and curve shapes are retained; shared endpoints stay fixed. Select one note for direct point editing.')
          if I.Button(c,'Apply selected-note expression')then local ok,notice=Batch.apply(app,app.expression_batch,selected);app.expression_notice=notice;if ok then app.expression_batch=nil end end
          I.SameLine(c);if I.Button(c,'Cancel group expression')then app.expression_batch=nil end
        end
      else app.expression_batch=nil end
      if advanced then
        I.TextWrapped(c,'Edit individual note curves in Expression or with Note Pitch in the piano roll. This window contains voice setup and selected-note adjustments only.')
        if app.expression_notice then I.TextWrapped(c,app.expression_notice)end
        if not inline then I.End(c)end
        return
      end
      local note=#selected==1 and selected[1]
      local draft=app.expression_draft
      if note and E.member(note.chan,s)then
        if not draft or draft.take~=app.take or draft.note.index~=note.index or draft.note.s~=note.s or draft.note.e~=note.e or draft.note.pitch~=note.pitch then app.expression_draft,app.expression_notice=Model.begin(app,note);app.expression_point=nil;app.expression_drag=nil;draft=app.expression_draft end
      else app.expression_draft=nil;draft=nil end
      if app.expression_gesture_draft~=draft then app.expression_drag=nil;app.expression_marquee=nil;app.expression_curve_drag=nil;app.expression_gesture_draft=draft end
      if draft then
        I.Separator(c);I.Text(c,U.pitch_name(draft.note.pitch)..'  |  Channel '..(draft.note.chan+1));I.SameLine(c)
        if I.SmallButton(c,'Apply##expression_header')then local ok,notice=Model.apply(app,draft);app.expression_notice=notice;if ok then app.expression_draft=nil;app.expression_point=nil;app.expression_drag=nil;if not inline then I.End(c)end;return end end
        I.SameLine(c);if I.SmallButton(c,'Revert##expression_header')then app.expression_draft=nil;app.expression_point=nil;app.expression_drag=nil;app.expression_notice=nil;if not inline then I.End(c)end;return end
        app.expression_dimension=app.expression_dimension or 'pitch'
        for i,entry in ipairs({{'Pitch','pitch'},{'Pressure','pressure'},{'Timbre','timbre'}})do
          if i>1 then I.SameLine(c)end
          if I.RadioButton(c,entry[1],app.expression_dimension==entry[2])then app.expression_dimension=entry[2];app.expression_drag=nil;app.expression_marquee=nil;app.expression_curve_drag=nil end
        end
        local kind=app.expression_dimension;local maximum=kind=='pitch' and 16383 or 127
        local bend_range=s.mpe_pitch_bend_range or 48
        app.expression_view_range=math.max(1,math.min(bend_range,app.expression_view_range or 12))
        if kind=='pitch'then hit,app.expression_view_range=I.SliderInt(c,'Pitch view (+/- semitones)',app.expression_view_range,1,bend_range)end
        local view_range=app.expression_view_range
        local function fraction(value)
          if kind~='pitch'then return value/maximum end
          local delta=(value-8192)/(value>=8192 and 8191 or 8192)*bend_range
          return .5+delta/(2*view_range)
        end
        local function from_fraction(f)
          if kind~='pitch'then return math.floor(math.max(0,math.min(maximum,f*maximum))+.5)end
          return require('src.glide').value((f-.5)*2*view_range,bend_range)
        end
        local x,y=I.GetCursorScreenPos(c);local width=math.max(120,I.GetContentRegionAvail(c));local height=140
        I.InvisibleButton(c,'##expression_curve',width,height)
        local graph_hovered=I.IsItemHovered(c)
        local d=I.GetWindowDrawList(c);I.DrawList_AddRectFilled(d,x,y,x+width,y+height,app.theme.panel2,4)
        local points={};for _,p in ipairs(draft.points)do if p.kind==kind and not p.deleted then points[#points+1]=p end end
        for _,p in ipairs(draft.context_points or {})do if p.kind==kind then points[#points+1]=p end end
        table.sort(points,function(a,b)return a.time<b.time end)
        I.DrawList_PushClipRect(d,x,y,x+width,y+height,true)
        if draft.expression_end>draft.note.e then
          local release=x+width*(draft.note.e-draft.note.s)/(draft.expression_end-draft.note.s)
          I.DrawList_AddLine(d,release,y,release,y+height,app.theme.hint,1.5)
          I.DrawList_AddText(d,release+3,y+3,app.theme.hint,'Key release')
        end
        if kind=='pitch'then for semitone=-view_range,view_range do local py=y+height*(.5-semitone/(2*view_range));I.DrawList_AddLine(d,x,py,x+width,py,app.theme.hint,semitone==0 and 1.5 or .4)end end
        local previous,unsupported
        for index,p in ipairs(points)do
          local px,py=x+p.time*width,y+height-fraction(p.value)*height
          if previous then
            local shape=((previous.point.flags or 0)>>4)&15
            if shape==0 then I.DrawList_AddLine(d,previous.x,previous.y,px,previous.y,app.theme.selected_edge,2);I.DrawList_AddLine(d,px,previous.y,px,py,app.theme.selected_edge,2)
            elseif shape>=1 and shape<=5 then
              local first,last=math.max(0,previous.point.time),math.min(1,p.time)
              local steps=math.max(1,math.min(96,math.ceil(math.max(0,last-first)*width/5)))
              local last_x,last_y
              for step=0,steps do if last>=first then
                local time=first+(last-first)*step/steps
                local value=require('src.midi_curve').value(points,index-1,time,0,maximum)
                local next_x,next_y=x+time*width,y+height-fraction(value)*height
                if last_x then I.DrawList_AddLine(d,last_x,last_y,next_x,next_y,app.theme.selected_edge,2)end;last_x,last_y=next_x,next_y
              end end
            else unsupported=true end
          end
          if not p.context then I.DrawList_AddCircleFilled(d,px,py,(p.selected or p==app.expression_point)and 5 or 3,app.theme.selected_edge)end;previous={x=px,y=py,point=p}
        end
        if previous then I.DrawList_AddLine(d,previous.x,previous.y,x+width,previous.y,app.theme.selected_edge,2)end
        I.DrawList_PopClipRect(d)
        if draft.expression_end>draft.note.e then I.TextWrapped(c,'The graph includes expression held by sustain after key release. The pedal itself stays unchanged.')end
        if unsupported then I.TextWrapped(c,'This MIDI contains an unknown curve shape. Its control points and original data are retained.')end
        if graph_hovered and I.IsMouseClicked(c,0)then
          local mx,my=I.GetMousePos(c);local nearest,distance;local mods=U.mods(I,c)
          local segment
          if mods.alt then
            local time=(mx-x)/width
            for index=1,#points-1 do local p,next_point=points[index],points[index+1]
              if not p.shared and not p.context and time>=p.time and time<next_point.time then
                local value=require('src.midi_curve').value(points,index,time,0,maximum)
                if value and math.abs(my-(y+height-fraction(value)*height))<=10 then segment=p end
              end
            end
          end
          for _,p in ipairs(points)do if not p.context then local dx,dy=mx-(x+p.time*width),my-(y+height-fraction(p.value)*height);local delta=dx*dx+dy*dy;if delta<100 and (not distance or delta<distance)then nearest,distance=p,delta end end end
          if segment then
            app.expression_point=segment
            if I.IsMouseDoubleClicked(c,0)then Model.set_shape(segment,1)
            else app.expression_curve_drag={point=segment,y=my,tension=Model.tension(segment)}end
          elseif nearest then
            if not nearest.shared then
              if mods.ctrl then nearest.selected=not nearest.selected
              elseif not nearest.selected then Model.select_range(draft.points,kind,-1,-1,false);nearest.selected=true end
              if nearest.selected then app.expression_drag={group=Model.group_snapshot(draft.points,kind),x=mx,y=my}end
            end
            app.expression_point=nearest
          else
            app.expression_marquee={x=mx,y=my,add=mods.ctrl,first=math.max(0,math.min(1,(mx-x)/width))}
          end
        end
        if app.expression_curve_drag then
          if I.IsMouseDown(c,0)then local _,my=I.GetMousePos(c);local drag=app.expression_curve_drag;Model.set_shape(drag.point,5,math.max(-1,math.min(1,drag.tension+(drag.y-my)/height*2)))
          else app.expression_curve_drag=nil end
        end
        if app.expression_drag then
          if I.IsMouseDown(c,0)then
            local mx,my=I.GetMousePos(c);local drag=app.expression_drag
            local scale=kind=='pitch' and (2*view_range/bend_range)*8191.5 or maximum
            local dx,dy=mx-drag.x,my-drag.y
            if U.mods(I,c).shift then
              if not drag.axis and math.max(math.abs(dx),math.abs(dy))>3 then drag.axis=math.abs(dx)>=math.abs(dy)and 'time' or 'value'end
              if drag.axis=='time'then dy=0 elseif drag.axis=='value'then dx=0 end
            else drag.axis=nil end
            Model.move_group(drag.group,dx/width,-dy/height*scale,maximum)
          else app.expression_drag=nil end
        end
        if app.expression_marquee then
          local marquee=app.expression_marquee;local mx,my=I.GetMousePos(c)
          local last=math.max(0,math.min(1,(mx-x)/width))
          if math.abs(mx-marquee.x)>4 or math.abs(my-marquee.y)>4 then marquee.moved=true end
          if I.IsMouseDown(c,0)then
            local edge=math.max(x,math.min(x+width,mx))
            I.DrawList_AddRect(d,math.min(marquee.x,edge),y,math.max(marquee.x,edge),y+height,app.theme.selected_edge)
          else
            if marquee.moved then Model.select_range(draft.points,kind,marquee.first,last,marquee.add);app.expression_point=nil
            else
              if not marquee.add then Model.select_range(draft.points,kind,-1,-1,false)end
              local p={kind=kind,time=marquee.first,value=from_fraction(1-(marquee.y-y)/height),flags=16,selected=true}
              draft.points[#draft.points+1]=p;app.expression_point=p
            end
            app.expression_marquee=nil
          end
        end
        I.TextDisabled(c,'Click: add  |  Drag: move / select  |  Alt-drag: curve  |  Shift: lock axis')
        if I.SmallButton(c,'Select all points')then Model.select_range(draft.points,kind,0,1,false)end
        I.SameLine(c)
        if I.SmallButton(c,'Delete selected points')then
          for _,p in ipairs(draft.points)do if p.kind==kind and p.selected and not p.shared then p.deleted=true end end
          app.expression_point=nil;app.expression_drag=nil
        end
        local point=app.expression_point
        if point and point.kind==kind and not point.deleted and I.CollapsingHeader(c,'Selected point details')then
          I.BeginDisabled(c,point.shared==true)
          hit,point.time=I.SliderDouble(c,draft.expression_end>draft.note.e and 'Position in sustained voice'or 'Position in note',point.time,0,1,'%.4f')
          if kind=='pitch'then
            local range=s.mpe_pitch_bend_range or 48;local semitones=(point.value-8192)/(point.value>=8192 and 8191 or 8192)*range
            local value;hit,value=I.SliderDouble(c,'Pitch (semitones)',semitones,-range,range,'%.3f');if hit then point.value=math.floor(8192+value/range*(value>=0 and 8191 or 8192)+.5)end
          else hit,point.value=I.SliderInt(c,'Value',point.value,0,127)end
          local shape=((point.flags or 0)>>4)&15
          if I.BeginCombo(c,'Outgoing segment',Model.shapes[shape+1] or 'Imported curve (retained)')then
            for index,label in ipairs(Model.shapes)do if I.Selectable(c,label,shape==index-1)then Model.set_shape(point,index-1,Model.tension(point))end end
            I.EndCombo(c)
          end
          if ((point.flags or 0)>>4)&15==5 then
            local tension;hit,tension=I.SliderDouble(c,'Bézier tension',Model.tension(point),-1,1,'%.3f')
            if hit then Model.set_shape(point,5,tension)end
          end
          if I.Button(c,'Delete point')then point.deleted=true;app.expression_point=nil end
          I.EndDisabled(c)
          if point.shared then I.TextWrapped(c,'Shared boundary: retained for the adjacent note.')end
        end
        if I.CollapsingHeader(c,'Note velocity')then
          hit,draft.velocity=I.SliderInt(c,'Note velocity',draft.velocity,1,127)
          hit,draft.release_velocity=I.SliderInt(c,'Release velocity',draft.release_velocity,0,127)
        end
      else I.TextWrapped(c,app.multi_edit_mode and 'Leave multiple-item editing to edit a recorded voice in the active item.' or needs_voices and 'Select Make notes independent above to prepare these notes for per-note expression. Recorded MPE notes are ready to edit on their existing channels.' or #selected>1 and 'Use the selected-note adjustments above, or select one note to draw its expression.' or 'Select a recorded MPE note in the piano roll. Its Pitch, Pressure and Timbre curves appear here.')end
    else I.TextWrapped(c,'Turn on MPE mode above, then select a recorded MPE note. Match Instrument setup to your instrument once; recorded channels are preserved.')
    end
    if app.expression_notice then I.TextWrapped(c,app.expression_notice)end
  end
  if not inline then I.End(c)end
end
return M
