-- Modern Tactical dashboard; presentation-only. Existing tracking remains in GrindOnly.lua.
local U=GrindOnlyUI
local panel=GrindOnlyPanel
if not (U and panel and GrindOnlyDashboardData) then return end
local root=CreateFrame('Frame','GrindOnlyTacticalDashboard',panel)
root:SetAllPoints(panel)
root:SetFrameLevel(panel:GetFrameLevel()+2)
root:EnableMouse(false)
local bg=U.Texture(root,'TacticalPanel');bg:SetAllPoints()
local top=U.Solid(root,.92,.64,.25,1);top:SetPoint('TOPLEFT',0,0);top:SetPoint('TOPRIGHT',0,0);top:SetHeight(3)
local brand=U.Label(root,'GRIND ONLY',11,'gold');brand:SetPoint('TOPLEFT',14,-14)
local subtitle=U.Label(root,'LIVE PERFORMANCE',9,'muted');subtitle:SetPoint('TOPRIGHT',-14,-16)
local line=U.Rule(root);line:SetPoint('TOPLEFT',12,-34);line:SetPoint('TOPRIGHT',-12,-34)
local metrics={}
local labels={'GOLD / HR (15M)','SESSION GOLD','XP / HR (15M)','SESSION XP'}
for i=1,4 do
 local frame,value=U.Metric(root,labels[i])
 frame.value=value
 metrics[i]=frame
end
local score=U.Surface(root,'TacticalCard')
local scoreTitle=U.Label(score,'OVERALL EFFICIENCY',10,'muted');scoreTitle:SetPoint('TOPLEFT',12,-10)
local grade=U.Label(score,'--',29,'gold');grade:SetPoint('TOPLEFT',12,-24)
local gradeOut=U.Label(score,'/ 10',11,'muted');gradeOut:SetPoint('BOTTOMLEFT',grade,'BOTTOMRIGHT',5,4)
local feedback=U.Label(score,'COLLECTING DATA',9,'muted');feedback:SetPoint('BOTTOMLEFT',12,10)
local gs=U.Label(score,'GOLD  --',12,'pale');gs:SetPoint('TOPRIGHT',-12,-26)
local xs=U.Label(score,'XP/HR  --',12,'pale');xs:SetPoint('TOPRIGHT',-12,-46)
local track=U.Solid(score,.18,.25,.32,1);track:SetPoint('BOTTOMLEFT',12,25);track:SetPoint('BOTTOMRIGHT',-12,25);track:SetHeight(5)
local fill=U.Solid(score,.91,.64,.25,1);fill:SetPoint('LEFT',track,'LEFT',0,0);fill:SetHeight(5);fill:SetWidth(1)
local buffs=U.Surface(root,'TacticalCard')
local buffTitle=U.Label(buffs,'BUFF STATUS',10,'gold');buffTitle:SetPoint('TOPLEFT',11,-9)
local buffValue=U.Label(buffs,'Checking buffs...',11,'pale');buffValue:SetPoint('TOPLEFT',11,-25);buffValue:SetPoint('RIGHT',buffs,'RIGHT',-10,0)
local function layout()
 local w=panel:GetWidth();local h=panel:GetHeight()
 local margin=12;local gap=8;local cw=(w-margin*2-gap)/2
 local cardH=math.max(51,math.min(72,(h-151)/2))
 for i,f in ipairs(metrics) do
  f:ClearAllPoints();f:SetSize(cw,cardH)
  local col=(i-1)%2;local row=math.floor((i-1)/2)
  f:SetPoint('TOPLEFT',root,'TOPLEFT',margin+col*(cw+gap),-43-row*(cardH+gap))
  f.value:SetWidth(cw-19)
 end
 local scoreY=43+2*(cardH+gap)+1
 local buffH=46
 local scoreH=math.max(79,h-scoreY-buffH-24)
 score:ClearAllPoints();score:SetPoint('TOPLEFT',root,'TOPLEFT',margin,-scoreY);score:SetSize(w-margin*2,scoreH)
 buffs:ClearAllPoints();buffs:SetPoint('BOTTOMLEFT',root,'BOTTOMLEFT',margin,12);buffs:SetSize(w-margin*2,buffH)
end
panel:HookScript('OnSizeChanged',layout)
layout()
local function setText(label,value) label:SetText(value or '--') end
local function refresh()
 local d=GrindOnlyDashboardData()
 if not d then return end
 setText(metrics[1].value,d.goldRate);setText(metrics[2].value,d.sessionGold)
 setText(metrics[3].value,d.xpRate);setText(metrics[4].value,d.sessionXP)
 setText(grade,d.grade);setText(feedback,d.feedback)
 setText(gs,(d.goldScore or 'Gold: --'):upper());setText(xs,(d.xpScore or 'XP/hr: --'):upper())
 local v=tonumber(d.grade)
 if v then
  local width=math.max(1,(score:GetWidth()-24)*math.min(1,math.max(0,v/10)))
  fill:SetWidth(width)
 else fill:SetWidth(1) end
 setText(buffTitle,d.buffTitle or 'BUFF STATUS');setText(buffValue,d.buffs)
 if d.buffCount and d.buffCount>0 then buffValue:SetTextColor(1,.52,.41) else buffValue:SetTextColor(.36,.87,.55) end
end
local elapsed=0
root:SetScript('OnUpdate',function(self,dt)
 elapsed=elapsed+dt
 if elapsed<.35 then return end
 elapsed=0;refresh()
end)
refresh()
