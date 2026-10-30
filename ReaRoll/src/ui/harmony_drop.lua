-- @noindex
local M={}
function M.insert(app,payload,q)
 if app.gesture or app.edit.active or app.transform_preview or app.expression_direct_gesture then return false,'Finish the current edit first.'end
 local pitches={}
 if type(payload)~='string' or not payload:match('^%d[%d,]*$')then return false,'Invalid chord.'end
 for value in payload:gmatch('%d+')do local p=tonumber(value);if p>127 then return false,'Invalid chord pitch.'end;pitches[#pitches+1]=p end
 if #pitches<2 or #pitches>16 then return false,'Invalid chord.'end
 local take=app.multi_edit_mode and (app.multi_creation_take or app.take)or app.take
 local Take=require 'src.take'
 if not Take.valid(take)or reaper.GetMediaItemInfo_Value(Take.item(take),'C_LOCK')~=0 then return false,'Choose an unlocked MIDI item.'end
 local length=require('src.grid').note_length(app.settings)
 if app.multi_edit_mode then return require('src.multi_notes').draw_pitches(app,take,q,pitches,length)end
 if q<app.item_start_qn or q>=app.item_end_qn then return false,'Drop inside the MIDI item.'end
 local first=reaper.MIDI_GetPPQPosFromProjQN(take,q)
 local last=reaper.MIDI_GetPPQPosFromProjQN(take,math.min(q+length,app.item_end_qn))
 app.edit:begin('ReaRoll: insert library chord',take)
 local wanted={}
 local inserted,entries=app.edit:insert_draw_chord(take,first,last,pitches,app.settings.velocity,app.settings.channel,true)
 if not inserted then app.edit:cancel();return false,app.expression_notice or 'Could not insert this chord.'end
 for _,entry in ipairs(entries)do wanted[#wanted+1]={s=first,e=last,pitch=entry.pitch,vel=app.settings.velocity,chan=entry.chan}end
 local ok=app.edit:finish();app.cache:rebuild()
 if ok==false then return false,app.expression_notice end
 app:reselect_notes(wanted);return true
end
function M.target(app,v)
 local I,c=app.ImGui,app.ctx
 if not I.BeginDragDropTarget or not I.BeginDragDropTarget(c)then return end
 local mx=I.GetMousePos(c);local q=v:qn_from_x(mx)
 if not I.IsKeyDown(c,I.Mod_Alt)then q=require('src.util').snap_time(app.settings,q)end
 if app.harmony_drag then
  local d=I.GetWindowDrawList(c);local x=v:x_from_qn(q);local last=v:x_from_qn(q+require('src.grid').note_length(app.settings))
  for _,pitch in ipairs(app.harmony_drag)do local y=v:y_from_pitch(pitch)
   if y and y>=v.y and y+app.settings.row_height<=v.y+v.h then
    I.DrawList_AddRect(d,math.max(v.x,x),y+1,math.min(v.x+v.w,last),y+app.settings.row_height-1,app.theme.note,3)
   end
  end
 end
 local accepted,payload=I.AcceptDragDropPayload(c,'REAROLL_CHORD')
 if accepted then
  local mx=I.GetMousePos(c);local q=v:qn_from_x(mx)
  if not I.IsKeyDown(c,I.Mod_Alt)then q=require('src.util').snap_time(app.settings,q)end
  local ok,notice=M.insert(app,payload,q);app.harmony_notice=ok and nil or notice
 end
 I.EndDragDropTarget(c)
end
return M
