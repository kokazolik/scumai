import random, math, json, sys
MIN_PER_CALL=float(sys.argv[1]) if len(sys.argv)>1 else 2.5
TAKE=float(sys.argv[2]) if len(sys.argv)>2 else 0.4
D=json.load(open(sys.argv[3] if len(sys.argv)>3 else 'tools/balance_design.json'))
RANKS=D['ranks']; SCHEMES=D['schemes']; METHODS=D['methods']; UPG=D['upgrades']; SK=D['skills']
def rank(e): return max(i for i,r in enumerate(RANKS) if e>=r['earned'])
def run(seed):
    random.seed(seed); bal=0; earned=0; sch=['repair']; meth=['card']; up={}; calls=0; deals=0; t=0; out={}; sk={}
    quota=15000; shift_e=0; fails=0; shifts=0
    marks=[15,30,60,120,240,480,720,1200]
    while t<1200:
        r=rank(earned)
        lv=lambda k: up.get(k,0)
        m=RANKS[r]['mult']*(1+0.15*lv('office'))*(1+0.05*sk.get('bargain',0))
        ss=[s for s in SCHEMES if s['id'] in sch]
        s=random.choices(ss,weights=[i+1 for i in range(len(ss))])[0]
        mult=s['mult']*(1+0.04*(len(sch)-1))
        best=max((x for x in METHODS if x['id'] in meth), key=lambda x:x['cap'])
        budget=random.randint(4,40)*500*m*mult*best['cap']
        chance=min(0.95,0.6+0.03*lv('script')+0.03*lv('spoof')+0.025*sk.get('persuade',0)+best['chance']/100)
        take=TAKE/0.6*chance*budget
        bal+=take; earned+=take; shift_e+=take; calls+=1; t+=MIN_PER_CALL; deals+=chance
        sk_pts=int(math.sqrt(deals*2)); spent=sum(sk.values())
        for k in ['persuade','bargain','charm','cool','acting']*5:
            if spent<sk_pts and sk.get(k,0)<5: sk[k]=sk.get(k,0)+1; spent+=1
        if calls%(8+lv('coffee'))==0:
            shifts+=1
            p=sum(x['passive'] for x in SCHEMES if x['id'] in sch)
            if shift_e<quota: fails+=1; p//=2
            else: quota=int(max(quota*D['quota_growth'], shift_e*D['quota_follow'])/500)*500
            bal+=p; earned+=p; shift_e=0
        opts=[]
        for x in SCHEMES:
            if x['id'] not in sch and r>=x['rank']: opts.append((x['price'],'s',x['id']))
        for x in METHODS:
            if x['id'] not in meth and r>=x['rank']: opts.append((x['price'],'m',x['id']))
        for x in UPG:
            l=up.get(x['id'],0)
            if l<len(x['prices']) and r>=x['rank']: opts.append((x['prices'][l],'u',x['id']))
        for pr,k,i in sorted(opts):
            if bal>=pr:
                bal-=pr
                if k=='s': sch.append(i)
                elif k=='m': meth.append(i)
                else: up[i]=up.get(i,0)+1
        for mk in marks:
            if t>=mk and mk not in out: out[mk]=(int(earned),RANKS[r]['name'],len(sch),len(meth),sum(up.values()),int(math.sqrt(deals*2)),quota,fails,shifts)
    return out
for k,v in run(int(sys.argv[4]) if len(sys.argv)>4 else 1).items():
    print(f"{k:>5} мин: {v[0]:>13,} ₽ | {v[1]:<18} схем {v[2]} способов {v[3]} улучш {v[4]} ур.{v[5]} план {v[6]:,} провалов {v[7]}/{v[8]}".replace(',',' '))
