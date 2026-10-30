-- @noindex
local Selection=require 'src.selection'
local Curve=require 'src.midi_curve'
local M={}
function M.draw(app,d,v,notes)
  if not app.settings.note_expression_overlay or v.fold then return end
  if app.expression_group_open and app.expression_group_draft then return end
  -- Generated playback bends use the carrier pitch, not each displayed
  -- destination note. The overlap connector already shows this trajectory.
  if require('src.overlap_mode').state(app)then return end
  local events=app.cc_cache:get(false)
  local index=app.expression_index
  if not index or index.events~=events or index.count~=#events or app.gesture then
    index={events=events,count=#events,channels={}}
    for _,event in ipairs(events)do if event.chanmsg==0xE0 then
      local group=index.channels[event.chan] or {};index.channels[event.chan]=group
      local point={time=event.ppq,value=(event.msg3<<7)|event.msg2,flags=(event.shape or 0)<<4}
      if event.shape==5 then point.shape={msg=string.char(255,15)..'CCBZ '..string.char(0)..string.pack('f',event.tension or 0)}end
      group[#group+1]=point
    end end
    for _,group in pairs(index.channels)do table.sort(group,function(a,b)return a.time<b.time end)end
    app.expression_index=index
  end
  local I,c,s=app.ImGui,app.ctx,app.settings
  local range=math.max(1,(s.mpe_enabled and s.mpe_pitch_bend_range or s.pitch_bend_range) or 2)
  for _,note in ipairs(notes)do if Selection.has(app.selection,note.id) and (not s.mpe_enabled or require('src.expression').member(note.chan,s)) then
    local group=index.channels[note.chan]
    if group then
      local low,high=1,#group
      while low<=high do local mid=(low+high)//2;if group[mid].time<=note.s then low=mid+1 else high=mid-1 end end
      local function xy(ppq,value)
        local delta=(value-8192)/(value>=8192 and 8191 or 8192)*range
        return v:x_from_ppq(ppq),v:y_from_pitch_unclipped(note.pitch+delta)+s.row_height*.5
      end
      local cursor=note.s
      local function line(a,av,b,bv)
        local ax,ay=xy(a,av);local bx,by=xy(b,bv)
        I.DrawList_AddLine(d,ax,ay,bx,by,app.theme.selected_edge,2)
      end
      if low==1 then local ending=math.min(note.e,group[1].time);line(cursor,8192,ending,8192);cursor=ending end
      for i=math.max(1,low-1),#group do
        local point,next_point=group[i],group[i+1]
        local first=math.max(cursor,point.time)
        local last=math.min(note.e,next_point and next_point.time or note.e)
        if last>=first then
          local shape=(point.flags>>4)&15
          if shape==0 or not next_point then
            line(first,point.value,last,point.value)
            if next_point and last==next_point.time and last<note.e then line(last,point.value,last,next_point.value)end
          else
            local steps=math.max(1,math.min(128,math.ceil(math.abs(v:x_from_ppq(last)-v:x_from_ppq(first))/4)))
            local previous_time,previous_value=first,Curve.value(group,i,first,0,16383)
            for step=1,steps do
              local time=first+(last-first)*step/steps;local value=Curve.value(group,i,time,0,16383)
              if previous_value and value then line(previous_time,previous_value,time,value)end
              previous_time,previous_value=time,value
            end
          end
          cursor=last
        end
        if cursor>=note.e then break end
      end
    end
  end end
end
return M
