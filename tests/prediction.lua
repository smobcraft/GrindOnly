dofile('GrindOnly/Prediction.lua')
local P=GrindOnlyPrediction
assert(P.mobXP(40,40,'normal',0)==245)
assert(P.mobXP(40,31,'normal',0)==0)
assert(P.mobXP(40,40,'elite',0)==490)
assert(P.mobXP(40,40,'normal',100)==345)
assert(P.mobXP(40,40,'worldboss',0)==nil)
local H={sessions={{level=40,duration=600,kills=20,xp=999999}},mobs={}}
local f=P.forecast(H,1,'Mob',40,40,100,0,true,1,nil,100,'normal',1000)
assert(f.kph==120 and f.gph==12000 and f.xph==30400)
local empty=P.forecast({sessions={},mobs={}},1,'Mob',40,40,0,0,false,0,nil,100,'normal',0)
assert(empty.kph==nil and empty.xph==nil and empty.gph==nil)
print('Prediction: 7 assertions passed')
