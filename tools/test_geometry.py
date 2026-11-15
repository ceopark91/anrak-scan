# Convert.swift의 PlanGeometry를 그대로 옮겨 안락실측 geo()로 되돌렸을 때 원래 모서리와 같은지 검산
import math, random
def simplify(q, minEdge=80, minTurn=4):
    q=list(q); changed=True
    while changed and len(q)>3:
        changed=False
        for i in range(len(q)):
            a,b=q[i],q[(i+1)%len(q)]
            if math.hypot(b[0]-a[0],b[1]-a[1])<minEdge:
                q[i]=((a[0]+b[0])/2,(a[1]+b[1])/2); q.pop((i+1)%len(q)) if (i+1)%len(q)!=0 else q.pop(0); changed=True; break
        if changed: continue
        for i in range(len(q)):
            p,c,n=q[i-1],q[i],q[(i+1)%len(q)]
            t=math.degrees(math.atan2(n[1]-c[1],n[0]-c[0])-math.atan2(c[1]-p[1],c[0]-p[0]))
            while t>180:t-=360
            while t<=-180:t+=360
            if abs(t)<minTurn: q.pop(i); changed=True; break
    return q
def room(pts):
    q=simplify(pts)
    s2=sum(q[i][0]*q[(i+1)%len(q)][1]-q[(i+1)%len(q)][0]*q[i][1] for i in range(len(q)))
    if s2<0: q=[q[0]]+q[1:][::-1]
    n=len(q); ang=[math.degrees(math.atan2(q[(i+1)%n][1]-q[i][1],q[(i+1)%n][0]-q[i][0])) for i in range(n)]
    walls=[]
    for i in range(n):
        a,b=q[i],q[(i+1)%n]; t=ang[(i+1)%n]-ang[i]
        while t>180:t-=360
        while t<=-180:t+=360
        t=round(t*10)/10
        turn='R' if abs(t-90)<1.5 else 'L' if abs(t+90)<1.5 else t
        walls.append((round(math.hypot(b[0]-a[0],b[1]-a[1])/10)*10,turn))
    return walls,q[0],round(ang[0]*10)/10
def geo(walls,x0,y0,rot):
    x=y=a=0; pts=[(0,0)]
    for L,t in walls:
        r=math.radians(a); x+=math.cos(r)*L; y+=math.sin(r)*L; pts.append((x,y)); a+= 90 if t=='R' else -90 if t=='L' else t
    r=math.radians(rot); c,s=math.cos(r),math.sin(r)
    return [(p[0]*c-p[1]*s+x0,p[0]*s+p[1]*c+y0) for p in pts], math.hypot(x,y)
shapes={'사각':[(0,0),(4000,0),(4000,3000),(0,3000)],
 'ㄱ자':[(0,0),(5000,0),(5000,2000),(3000,2000),(3000,4200),(0,4200)],
 '반시계+잡점':[(0,0),(0,3000),(1500,3010),(3500,3000),(3500,0),(3530,0)],
 '사선벽':[(0,0),(4000,0),(4600,2500),(0,2500)]}
ok=True
for name,P in shapes.items():
    for rot in [0,17,-63,135]:
        r=math.radians(rot)
        Q=[(p[0]*math.cos(r)-p[1]*math.sin(r)+1234+random.uniform(-3,3),p[0]*math.sin(r)+p[1]*math.cos(r)-777+random.uniform(-3,3)) for p in P]
        walls,p0,rot0=room(Q)
        back,gap=geo(walls,p0[0],p0[1],rot0)
        simp=simplify(Q)
        err=max(min(math.hypot(b[0]-s[0],b[1]-s[1]) for s in simp) for b in back)
        good=gap<=60 and err<40
        ok&=good
        print(f"{name:8} rot{rot:5}: 벽 {[(L,t) for L,t in walls]} 닫힘오차 {gap:.0f}mm 모서리오차 {err:.0f}mm {'OK' if good else 'FAIL'}")
print('ALL OK' if ok else 'FAILED')
