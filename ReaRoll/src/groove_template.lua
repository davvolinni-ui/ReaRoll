-- @noindex
local M={}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<1e9 end
function M.capture(notes,length,anchor)
  if not finite(length) or length<=0 or length>64 then return nil,'Choose a cycle between 0 and 64 beats.'end
  local points={};anchor=anchor or 0
  for _,note in ipairs(notes)do
    if finite(note.q) and finite(note.vel)then
      local phase=(note.q-anchor)%length
      local key=math.floor(phase*100000+.5)
      local p=points[key] or {q=phase,velocity=0,count=0};points[key]=p
      p.velocity=p.velocity+note.vel;p.count=p.count+1
    end
  end
  local out={length=length,points={}}
  for _,p in pairs(points)do p.velocity=p.velocity/p.count;out.points[#out.points+1]=p end
  if #out.points==0 then return nil,'Select source notes before capturing a groove.'end
  if #out.points>512 then return nil,'Use a shorter source selection (maximum 512 onsets).'end
  table.sort(out.points,function(a,b)return a.q<b.q end);return out
end
function M.target(template,q,anchor)
  anchor=anchor or 0
  local cycle=math.floor((q-anchor)/template.length)
  local best,distance,velocity
  for i=cycle-1,cycle+1 do for _,p in ipairs(template.points)do
    local candidate=anchor+i*template.length+p.q;local d=math.abs(candidate-q)
    if not distance or d<distance-1e-9 or math.abs(d-distance)<1e-9 and candidate>best then best,distance,velocity=candidate,d,p.velocity end
  end end
  return best,velocity
end
function M.encode(template)
  local out={string.format('%.17g',template.length)}
  for _,p in ipairs(template.points)do out[#out+1]=string.format('%.17g,%.17g',p.q,p.velocity)end
  return table.concat(out,';')
end
function M.decode(raw)
  if type(raw)~='string' or #raw>24000 then return nil end
  local chunks={};for part in raw:gmatch('[^;]+')do chunks[#chunks+1]=part end
  local length=tonumber(chunks[1]);if not finite(length) or length<=0 or length>64 or #chunks<2 or #chunks>513 then return nil end
  local out={length=length,points={}};local last=-1
  for i=2,#chunks do
    local a,b=chunks[i]:match('^([^,]+),([^,]+)$');local q,v=tonumber(a),tonumber(b)
    if not finite(q) or not finite(v) or q<0 or q>=length or q<=last or v<1 or v>127 then return nil end
    last=q;out.points[#out.points+1]={q=q,velocity=v}
  end
  return out
end
return M
