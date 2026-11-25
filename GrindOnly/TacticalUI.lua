-- Grind Only shared Modern Tactical UI system (v1.3.0)
-- All textures are bundled TGAs, not browser effects or Retail-only APIs.
GrindOnlyUI = GrindOnlyUI or {}
local U=GrindOnlyUI
U.colors={gold={.96,.72,.34},pale={.91,.95,1},muted={.58,.68,.78},line={.23,.33,.43},green={.36,.87,.55},red={1,.40,.34}}
local base='Interface\\AddOns\\GrindOnly\\Media\\'
function U.Texture(parent,name,layer)
 local t=parent:CreateTexture(nil,layer or 'BACKGROUND');t:SetTexture(base..name);return t
end
function U.Solid(parent,r,g,b,a,layer)
 local t=parent:CreateTexture(nil,layer or 'ARTWORK');t:SetColorTexture(r,g,b,a or 1);return t
end
function U.Label(parent,value,size,color)
 local f=parent:CreateFontString(nil,'OVERLAY')
 local font=STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF'
 f:SetFont(font,size or 11,'')
 local c=U.colors[color or 'pale'] or U.colors.pale
 f:SetTextColor(c[1],c[2],c[3],1)
 f:SetJustifyH('LEFT');f:SetText(value or '')
 return f
end
function U.Surface(parent,texture)
 local f=CreateFrame('Frame',nil,parent)
 local bg=U.Texture(f,texture or 'TacticalCard');bg:SetAllPoints()
 local edge=U.Solid(f,.24,.35,.45,.8,'BORDER');edge:SetHeight(1);edge:SetPoint('BOTTOMLEFT',0,0);edge:SetPoint('BOTTOMRIGHT',0,0)
 return f
end
function U.Rule(parent)
 local t=U.Solid(parent,.24,.34,.44,.8);t:SetHeight(1);return t
end
function U.Metric(parent,label)
 local f=U.Surface(parent,'TacticalCard')
 local l=U.Label(f,label,10,'muted');l:SetPoint('TOPLEFT',11,-10)
 local v=U.Label(f,'--',16,'pale');v:SetPoint('TOPLEFT',11,-26);v:SetPoint('RIGHT',f,'RIGHT',-7,0)
 return f,v
end
