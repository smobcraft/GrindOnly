-- Offline estimates; session throughput includes downtime, not target fight time.
GrindOnlyPrediction={}
do
 local P=GrindOnlyPrediction
 local cache={}
 function P.history(H,level,exclude,now)
  local c=cache[level];if c and c.h==H and c.exclude==exclude and now-c.t<30 then return c.kph,nil,c.kills end
  local kills,seconds=0,0
  for _,s in ipairs(H.sessions or {}) do
   local l=s.levelStart or s.level;local d=type(l)=='number' and math.abs(l-level) or 99
   local w=({[0]=1,[1]=.75,[2]=.4,[3]=.15})[d] or 0
   if s~=exclude and w>0 and (s.duration or 0)>=300 and (s.kills or 0)>=10 then
    kills=kills+s.kills*w;seconds=seconds+s.duration*w
   end
  end
  local kph=seconds>0 and kills*3600/seconds or nil
  cache[level]={h=H,exclude=exclude,t=now,kph=kph,kills=kills}
  return kph,nil,kills
 end
 -- Classic-style solo XP estimate. Forever green-mob scaling is provisional.
 function P.mobXP(pl,ml,classification,restPool)
  if pl<1 or pl>60 or ml<1 or classification=='worldboss' then return nil end
  local gray=pl<6 and 0 or (pl<40 and pl-5-math.floor(pl/10) or pl-1-math.floor(pl/5))
  if ml<=gray then return 0 end
  local xp=pl*5+45
  if ml>pl then xp=xp*(1+.05*math.min(4,ml-pl))
  elseif ml<pl then
   local zd=pl<8 and 5 or pl<10 and 6 or pl<12 and 7 or pl<16 and 8 or pl<20 and 9 or pl<30 and 11 or pl<40 and 12 or pl<45 and 13 or pl<50 and 14 or pl<55 and 15 or pl<60 and 16 or 17
   xp=(ml*5+45)*(1-(pl-ml)/zd)
  end
  if classification=='elite' or classification=='rareelite' then xp=xp*2 end
  xp=math.max(0,math.floor(xp+.5))
  return xp+math.min(xp,math.max(0,restPool or 0))
 end
 function P.forecast(H,id,name,mobLevel,playerLevel,ev,missing,coinKnown,dropCount,exclude,now,classification,restPool)
  local kph,_,samples=P.history(H,playerLevel,exclude,now)
  local kills,earn=0,0
  for _,m in pairs(H.mobs or {}) do
   if (m.npcIDs and m.npcIDs[tostring(id)] or (not m.npcIDs and m.name==name)) and tonumber(m.level)==mobLevel then
    kills=kills+(m.kills or 0);earn=earn+(m.coin or 0)+(m.vendor or 0)
   end
  end
  local gold,source
  if dropCount>0 and missing<dropCount or coinKnown then gold=ev;source='DB / known loot' end
  if kills>=20 and earn>0 then
   if gold then local w=math.min(.8,kills/(kills+50));gold=gold*(1-w)+earn/kills*w;source='DB + observed loot' else gold=earn/kills;source='Observed loot' end
  end
  local xpk=P.mobXP(playerLevel,mobLevel,classification,restPool)
  local baseXP=P.mobXP(playerLevel,mobLevel,classification,0)
  -- Rested bonus is limited by the remaining pool over the projected hour.
  local xph=kph and baseXP and (kph*baseXP+math.min(kph*baseXP,math.max(0,restPool or 0))) or nil
  return {kph=kph,xpk=xpk,gpk=gold,gph=kph and gold and kph*gold or nil,xph=xph,kills=kills,source=source,samples=samples,confidence=kph and 'Low (historical kill rate)' or 'Insufficient history'}
 end
end
