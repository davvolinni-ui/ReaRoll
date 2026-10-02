-- @noindex
local M={}
M.patterns={'up','down','updown','downup','outside-in','inside-out','random'}
M.rhythms={{'Straight','11111111'},{'Offbeat','01010101'},{'Tresillo','10010010'},{'Pulse','10111010'},{'Broken','11010110'}}
M.presets={
  {name='Classic rise',pattern='up',rate=.25,gate=.8,octaves=2,rhythm='11111111',accent=12,swing=0},
  {name='Rolling bounce',pattern='updown',rate=.25,gate=.65,octaves=2,rhythm='11111111',accent=18,swing=.12},
  {name='Offbeat pluck',pattern='outside-in',rate=.5,gate=.45,octaves=1,rhythm='01010101',accent=15,swing=0},
  {name='Tresillo pulse',pattern='up',rate=.5,gate=.65,octaves=1,rhythm='10010010',accent=20,swing=0},
  {name='Trap flutter',pattern='random',rate=.125,gate=.4,octaves=2,rhythm='11010110',accent=22,swing=.08},
  {name='Soft cascade',pattern='downup',rate=.5,gate=.95,octaves=2,rhythm='11111111',accent=8,swing=0},
}
local function clamp(v,a,b)return math.max(a,math.min(b,v))end
function M.generate(notes,options)
  local o=options or {}; local step=o.rate or .25
  if step<=0 then return nil,'Choose a positive arp rate.' end
  local first,last=math.huge,-math.huge
  for _,n in ipairs(notes) do first=math.min(first,n.s); last=math.max(last,n.e) end
  first=math.max(first,o.first or first); last=math.min(last,o.last or last)
  if first>=last then return {} end
  local count=math.ceil((last-first)/step)
  if count>4096 then return nil,'Choose a slower rate or a shorter selection (4096 steps maximum).' end
  local out={}; local phase=0; local previous; local seed=o.seed or 1
  local rhythm=o.rhythm or '11111111'; if #rhythm==0 then rhythm='11111111' end
  for i=0,count-1 do
    local base=first+i*step
    local sq=base+(i%2==1 and step*clamp(o.swing or 0,0,.75) or 0)
    local pool,seen={},{}; local boundary=last
    for _,n in ipairs(notes) do
      if n.s>base+1e-7 then boundary=math.min(boundary,n.s) end
      if n.s<=base+1e-7 and n.e>base+1e-7 then
        boundary=math.min(boundary,n.e)
        for octave=0,clamp(math.floor(o.octaves or 1),1,4)-1 do
          local pitch=n.pitch+octave*12; local key=pitch..':'..(n.chan or 0)
          if pitch<=127 and not seen[key] then seen[key]=true; pool[#pool+1]={pitch=pitch,chan=n.chan or 0,vel=n.vel,muted=n.muted} end
        end
      end
    end
    table.sort(pool,function(a,b)if a.pitch==b.pitch then return a.chan<b.chan end; return a.pitch<b.pitch end)
    local keys={}; for _,n in ipairs(pool) do keys[#keys+1]=n.pitch..':'..n.chan end
    local signature=table.concat(keys,',')
    if o.restart~=false and signature~=previous then phase=0 end
    previous=signature
    local size=#pool
    if size>0 and rhythm:sub(i%#rhythm+1,i%#rhythm+1)=='1' then
      local p=o.pattern or 'up'; local index=phase%size+1
      if p=='down' then index=size-index+1
      elseif (p=='updown' or p=='downup') and size>1 then
        local t=phase%(2*size-2); index=t<size and t+1 or 2*size-1-t
        if p=='downup' then index=size-index+1 end
      elseif p=='outside-in' or p=='inside-out' then
        local order={}; local a,b=1,size
        while a<=b do order[#order+1]=a; if a<b then order[#order+1]=b end; a=a+1;b=b-1 end
        if p=='inside-out' then index=order[size-phase%size] else index=order[index] end
      elseif p=='random' then seed=(seed*48271)%2147483647; index=seed%size+1 end
      local source=pool[index]; local eq=math.min(boundary,sq+step*clamp(o.gate or .85,.1,1))
      if eq>sq then out[#out+1]={s=sq,e=eq,pitch=source.pitch,vel=clamp(math.floor(source.vel+(i%4==0 and (o.accent or 0) or 0)+.5),1,127),chan=source.chan,muted=source.muted} end
      phase=phase+1
    end
  end
  return out
end
return M
