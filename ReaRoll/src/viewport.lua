-- @noindex
local U=require 'src.util'; local V={}; V.__index=V
function V.new(settings) return setmetatable({s=settings},V) end
function V:set_geometry(x,y,w,h,take,item_qn,item_end_qn)
  if self.h and math.abs(h-self.h)>.5 then
    local old_rows=math.max(1,math.floor(self.h/self.s.row_height))
    self.s.row_height=U.clamp(h/old_rows,8,32)
  end
  self.x,self.y,self.w,self.h,self.take=x,y,w,h,take
  if self.s.start_qn==0 then self.s.start_qn=item_qn end
  -- Keep some project timeline visible around the active item. Besides making
  -- item boundaries legible, this gives drawing gestures room to extend the
  -- item instead of trapping the viewport inside it.
  local context=math.max(8,(self.s.visible_qn or 8)*.75)
  self.min_qn=math.max(0,(item_qn or 0)-context)
  self.timeline_end=item_end_qn and item_end_qn+context or math.huge
  self.max_start=item_end_qn and math.max(self.min_qn,self.timeline_end-self.s.visible_qn) or math.huge
  self.s.start_qn=U.clamp(self.s.start_qn,self.min_qn,self.max_start)
  self.ppq0=reaper.MIDI_GetPPQPosFromProjQN(take,self.s.start_qn); self.ppq1=reaper.MIDI_GetPPQPosFromProjQN(take,self.s.start_qn+self.s.visible_qn)
  self.ppq_per_qn=(self.ppq1-self.ppq0)/self.s.visible_qn; self.px_per_qn=w/self.s.visible_qn
  self.s.low_pitch=U.clamp(self.s.low_pitch,0,math.max(0,128-self:rows()))
end
function V:set_fold(notes)
  if not self.s.fold_enabled then self.fold,self.fold_index=nil,nil; return end
  local seen,pitches={},{}
  for _,n in ipairs(notes or {}) do if not seen[n.pitch] then seen[n.pitch]=true; pitches[#pitches+1]=n.pitch end end
  if #pitches==0 then self.fold,self.fold_index=nil,nil; return end
  table.sort(pitches); self.fold=pitches; self.fold_index={}
  for i,p in ipairs(pitches) do self.fold_index[p]=i end
  self.s.fold_offset=U.clamp(self.s.fold_offset or 0,0,math.max(0,#pitches-self:rows()))
end
function V:x_from_ppq(p) return self.x+((p-self.ppq0)/self.ppq_per_qn)*self.px_per_qn end
function V:ppq_from_x(x) return self.ppq0+((x-self.x)/self.px_per_qn)*self.ppq_per_qn end
function V:qn_from_x(x) return self.s.start_qn+(x-self.x)/self.px_per_qn end
function V:x_from_qn(q) return self.x+(q-self.s.start_qn)*self.px_per_qn end
function V:rows() local capacity=math.min(128,math.max(1,math.floor(self.h/self.s.row_height))); return self.fold and math.min(capacity,math.max(1,#self.fold)) or capacity end
function V:pitch_at_row(r) if self.fold and #self.fold>0 then return self.fold[(self.s.fold_offset or 0)+self:rows()-r] end; return self.s.low_pitch+self:rows()-1-r end
function V:y_from_pitch_unclipped(p)
  if self.fold then local i=self.fold_index and self.fold_index[p]; if not i then return nil end; local o=self.s.fold_offset or 0; return self.y+(o+self:rows()-i)*self.s.row_height end
  return self.y+(self.s.low_pitch+self:rows()-1-p)*self.s.row_height
end
function V:y_from_pitch(p)
  if self.fold then local i=self.fold_index and self.fold_index[p]; local o=self.s.fold_offset or 0; if not i or i<=o or i>o+self:rows() then return nil end
  elseif p<self.s.low_pitch or p>self:high_pitch() then return nil end
  return self:y_from_pitch_unclipped(p)
end
function V:pitch_from_y(y) local r=U.clamp(math.floor((y-self.y)/self.s.row_height),0,self:rows()-1); return U.clamp(self:pitch_at_row(r) or 60,0,127) end
function V:is_pitch_visible(p) return self:y_from_pitch(p)~=nil end
function V:high_pitch() if self.fold and #self.fold>0 then return self.fold[math.min(#self.fold,(self.s.fold_offset or 0)+self:rows())] end; return U.clamp(self.s.low_pitch+self:rows()-1,0,127) end
function V:zoom_time(factor,mx) local a=self:qn_from_x(mx); local r=(mx-self.x)/self.w; self.s.visible_qn=U.clamp(self.s.visible_qn*factor,1/16,256); self.s.start_qn=U.clamp(a-r*self.s.visible_qn,self.min_qn or 0,self.max_start or math.huge) end
function V:zoom_pitch(factor,my)
  local old_height=self.s.row_height; local requested=U.clamp(old_height*factor,8,32)
  -- Do nothing at a zoom limit. Recalculating the anchor while the height is
  -- unchanged caused repeated wheel input to walk the viewport unexpectedly.
  if math.abs(requested-old_height)<.000001 then return end
  if self.fold then
    local anchor=self:pitch_from_y(my); self.s.row_height=requested
    local index=self.fold_index and self.fold_index[anchor] or 1; local rows=self:rows(); local from_bottom=(self.y+self.h-my)/self.h
    self.s.fold_offset=U.clamp(math.floor(index-rows*from_bottom+.5),0,math.max(0,#self.fold-rows)); return
  end
  local p=self:pitch_from_y(my); local from_bottom=(self.y+self.h-my)/self.h
  self.s.row_height=requested; local rows=self:rows()
  self.s.low_pitch=U.clamp(math.floor(p-from_bottom*rows+.5),0,math.max(0,128-rows))
end
function V:scroll_pitch(delta)
  self.pitch_remainder=(self.pitch_remainder or 0)+delta
  local whole=self.pitch_remainder>=0 and math.floor(self.pitch_remainder) or math.ceil(self.pitch_remainder)
  self.pitch_remainder=self.pitch_remainder-whole
  local key=self.fold and 'fold_offset' or 'low_pitch'
  local limit=math.max(0,(self.fold and #self.fold or 128)-self:rows())
  self.s[key]=U.clamp((self.s[key] or 0)+whole,0,limit)
end
function V:pan(dx,dy)
  self.s.start_qn=U.clamp(self.s.start_qn-dx/self.px_per_qn,self.min_qn or 0,self.max_start or math.huge)
  self:scroll_pitch(dy/self.s.row_height)
end
return V
