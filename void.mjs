// Nmind geometric void. Layers of geometry sit one behind another; calm travel moves you
// inward, so far layers grow toward you and pass by. New shape families and colour worlds
// open the deeper you go. Every change is eased: nothing flashes or flickers.
// Fold counts skip 6, and star figures are only drawn with 7 or more points, so no
// six-pointed star can appear.

const clamp=(v,a,b)=>Math.min(b,Math.max(a,v));
const lerp=(a,b,t)=>a+(b-a)*t;
const TAU=Math.PI*2;
export const FOLDS=[5,7,8,9,10,11,12];
// families open in this order as you travel deeper
export const FAMILIES=['rosette','seed','polygon','spiral','lattice','lotus','fractal'];
export const LEVEL_AT=[0,3,6,10,14,19,25];  // travel distance where each family opens
// colour worlds by depth: deep ocean purple, teal, violet, azure, rose, sea green, gold, then everything
const WORLD_HUES=[262,174,288,208,326,150,48];
export const WORLD_NAMES=['Deep ocean','Teal reef','Violet drift','Azure','Rose nebula','Sea glass','Gold','Prism'];

function rng(seed){let s=seed*2654435761>>>0;return ()=>{s^=s<<13;s>>>=0;s^=s>>17;s^=s<<5;s>>>=0;return s/4294967296;};}
export function levelOf(Z){let L=0;for(let i=0;i<LEVEL_AT.length;i++)if(Z>=LEVEL_AT[i])L=i;return L;}

export class VoidRenderer{
  constructor(ctx){this.ctx=ctx;this.specs=new Map();this.Z=0;this.t=0;this.motes=[];
    const r=rng(99);for(let i=0;i<70;i++)this.motes.push({a:r()*TAU,d:r()*8,s:0.5+r()});}
  spec(k){
    let s=this.specs.get(k);if(s)return s;
    const L=levelOf(Math.max(0,k-6)),r=rng(k*7919+13);   // a layer born far away belongs to the level you will reach
    const open=Math.min(FAMILIES.length,L+2);
    const fam=FAMILIES[Math.floor(r()*open)];
    let folds=FOLDS[Math.floor(r()*FOLDS.length)];
    const prism=L>=7||k>LEVEL_AT[6]+8;
    const hue=prism?r()*360:WORLD_HUES[Math.min(L,WORLD_HUES.length-1)]+(r()-0.5)*60;
    s={fam,folds,hue,hue2:(hue+40+r()*110)%360,spin:(r()<0.5?-1:1)*(0.03+r()*0.06),rot:r()*TAU,seed:r()*100};
    this.specs.set(k,s);
    for(const kk of this.specs.keys())if(kk<k-14)this.specs.delete(kk);
    return s;
  }
  // st: {w,h,cx,cy,R,F,I,vib,wash,alpha,scatter,speed,dt,reduce}
  draw(st){
    const c=this.ctx,{cx,cy,R,dt}=st;
    this.t+=dt*(st.reduce?0.25:1);
    const N=7,base=Math.floor(this.Z);
    c.save();c.translate(cx,cy);c.globalCompositeOperation='lighter';
    // the void's heart: a soft glow that warms with depth
    const hueC=WORLD_HUES[Math.min(levelOf(this.Z),WORLD_HUES.length-1)];
    const g=c.createRadialGradient(0,0,0,0,0,R*0.55);
    g.addColorStop(0,`hsla(${hueC},${lerp(20,80,st.vib)*(1-st.wash)}%,${lerp(30,62,st.vib)}%,${0.10+0.16*st.F})`);
    g.addColorStop(1,'hsla(0,0%,0%,0)');c.fillStyle=g;c.beginPath();c.arc(0,0,R*0.55,0,TAU);c.fill();
    // motes stream outward while you travel
    const mv=st.speed;
    for(const m of this.motes){
      m.d-=mv*dt*1.2+dt*0.02;if(m.d<-1){m.d+=8;m.a=Math.random()*TAU;}
      const sc=Math.exp(-m.d*0.55),rr=R*1.4*sc;if(rr>R*1.6)continue;
      const al=clamp((8-m.d)/2,0,1)*clamp((m.d+1)/1,0,1)*0.5*st.alpha;
      c.fillStyle=`hsla(${hueC+40},70%,80%,${al*(0.3+0.7*st.F)})`;c.beginPath();c.arc(Math.cos(m.a)*rr,Math.sin(m.a)*rr,Math.max(0.6,1.6*sc*m.s),0,TAU);c.fill();
    }
    for(let j=N-1;j>=-1;j--){
      const k=base+j,d=k-this.Z;if(d<-0.9)continue;
      const sc=Math.exp(-d*0.52),r=R*1.18*sc;
      const a=clamp((N-1-d)/1.4,0,1)*clamp((d+0.9)/0.9,0,1)*st.alpha;
      if(a<0.01||r<2)continue;
      const s=this.spec(k);
      c.save();c.rotate(s.rot+this.t*s.spin*(0.5+0.8*st.F));
      this.layer(s,r,a,st,d);
      c.restore();
    }
    c.restore();
  }
  col(h,st,a,lift=0){
    const sat=lerp(14,96,st.vib)*(1-st.wash*0.85),li=clamp(lerp(36,64,st.vib)+lift,10,92);
    return `hsla(${h.toFixed(0)},${sat.toFixed(0)}%,${li.toFixed(0)}%,${clamp(a,0,1).toFixed(3)})`;
  }
  layer(s,r,a,st,d){
    const c=this.ctx,n=s.folds,I=st.I,sc=st.scatter,t=this.t;
    c.lineWidth=Math.max(0.7,r/lerp(150,230,I))*(d<0?1:1);
    const jit=(i,q)=>sc*r*0.07*Math.sin(t*0.6+i*1.7+q*2.3+s.seed);
    const A=a*lerp(0.45,1,st.F);
    switch(s.fam){
      case 'rosette':{
        const rings=1+Math.round(I*3);
        for(let m=0;m<rings;m++){
          const rr=r*(0.3+0.22*m),pl=r*(0.2+0.05*m),pw=pl*lerp(0.22,0.34,I),cnt=n*(m%2?2:1);
          c.strokeStyle=this.col(m%2?s.hue2:s.hue,st,A*(0.8-m*0.1),m*4);
          for(let i=0;i<cnt;i++){const th=i*TAU/cnt+m*0.2;c.beginPath();c.ellipse(Math.cos(th)*rr+jit(i,m),Math.sin(th)*rr+jit(i,m+1),pl,pw,th,0,TAU);c.stroke();}
        }
        if(I>0.5){c.fillStyle=this.col(s.hue2,st,A*(I-0.5),18);for(let i=0;i<n*2;i++){const th=i*TAU/(n*2);c.beginPath();c.arc(Math.cos(th)*r*0.95,Math.sin(th)*r*0.95,r*0.018,0,TAU);c.fill();}}
        break;}
      case 'seed':{
        const cr=r*0.46;c.strokeStyle=this.col(s.hue,st,A*0.7);
        for(let i=0;i<n;i++){const th=i*TAU/n;c.beginPath();c.arc(Math.cos(th)*cr+jit(i,0),Math.sin(th)*cr+jit(i,1),cr,0,TAU);c.stroke();}
        if(I>0.35){c.strokeStyle=this.col(s.hue2,st,A*(I-0.2)*0.8,8);for(let i=0;i<n;i++){const th=(i+0.5)*TAU/n;c.beginPath();c.arc(Math.cos(th)*cr*1.55,Math.sin(th)*cr*1.55,cr*0.55,0,TAU);c.stroke();}}
        if(I>0.7){c.fillStyle=this.col(s.hue2,st,A*(I-0.6)*1.5,22);for(let i=0;i<n;i++){const th=(i+0.5)*TAU/n;c.beginPath();c.arc(Math.cos(th)*cr*0.98,Math.sin(th)*cr*0.98,r*0.016,0,TAU);c.fill();}}
        break;}
      case 'polygon':{
        const count=3+Math.round(I*6),tw=0.14+0.1*Math.sin(t*0.2+s.seed);
        for(let m=0;m<count;m++){
          const rr=r*(1-m*0.1);if(rr<r*0.1)break;
          c.strokeStyle=this.col(m%2?s.hue2:s.hue,st,A*(0.85-m*0.06),m*3);c.beginPath();
          for(let v=0;v<=n;v++){const th=v*TAU/n+m*tw;const x=Math.cos(th)*rr+jit(v,m),y=Math.sin(th)*rr+jit(v,m+3);v?c.lineTo(x,y):c.moveTo(x,y);}
          c.stroke();
        }
        if(I>0.45&&n>=7){ // star polygon through the outer vertices: {n/2} or {n/3}, never fewer than 7 points
          const k=n>=10?3:2;c.strokeStyle=this.col(s.hue2,st,A*(I-0.3),12);c.beginPath();
          for(let v=0;v<=n;v++){const th=(v*k%n)*TAU/n;const x=Math.cos(th)*r,y=Math.sin(th)*r;v?c.lineTo(x,y):c.moveTo(x,y);}c.stroke();
        }
        break;}
      case 'spiral':{
        const arms=n,steps=24+Math.round(I*24),turns=lerp(0.6,1.3,I);
        for(let i=0;i<arms;i++){
          c.strokeStyle=this.col(i%2?s.hue2:s.hue,st,A*0.8,i%2?10:0);c.beginPath();
          for(let q=0;q<=steps;q++){const u=q/steps,rr=r*(0.06+0.94*Math.pow(u,1.3)),th=i*TAU/arms+u*turns*TAU*(s.spin>0?1:-1);
            const x=Math.cos(th)*rr+jit(q,i)*u,y=Math.sin(th)*rr+jit(q,i+2)*u;q?c.lineTo(x,y):c.moveTo(x,y);}
          c.stroke();
          if(I>0.4){c.fillStyle=this.col(s.hue2,st,A*(I-0.3),20);const beads=2+Math.round(I*4);
            for(let b=1;b<=beads;b++){const u=b/(beads+1),rr=r*(0.06+0.94*Math.pow(u,1.3)),th=i*TAU/arms+u*turns*TAU*(s.spin>0?1:-1);c.beginPath();c.arc(Math.cos(th)*rr,Math.sin(th)*rr,r*0.012*(1+u),0,TAU);c.fill();}}
        }
        break;}
      case 'lattice':{
        const rings=2+Math.round(I*4),cells=n*2;let prev=null;
        for(let m=0;m<=rings;m++){
          const rr=r*(0.2+0.8*m/rings),off=(m%2)*Math.PI/cells;
          c.strokeStyle=this.col(s.hue,st,A*0.45);c.beginPath();c.arc(0,0,rr,0,TAU);c.stroke();
          const pts=[];for(let i=0;i<cells;i++){const th=i*TAU/cells+off;pts.push([Math.cos(th)*rr+jit(i,m),Math.sin(th)*rr+jit(i,m+5)]);}
          if(prev){c.strokeStyle=this.col(m%2?s.hue2:s.hue,st,A*0.75,6);c.beginPath();
            for(let i=0;i<cells;i++){const p=prev[i],q1=pts[i],q2=pts[(i+cells-(m%2?0:1))%cells];c.moveTo(p[0],p[1]);c.lineTo(q1[0],q1[1]);c.moveTo(p[0],p[1]);c.lineTo(q2[0],q2[1]);}
            c.stroke();}
          prev=pts;
        }
        break;}
      case 'lotus':{
        const layers=1+Math.round(I*3);
        for(let m=layers-1;m>=0;m--){
          const cnt=n,len=r*(0.55+0.15*m),wd=len*lerp(0.22,0.3,I),off=m*Math.PI/cnt;
          c.strokeStyle=this.col(m%2?s.hue2:s.hue,st,A*(0.9-m*0.12),m*6);c.beginPath();
          for(let i=0;i<cnt;i++){const th=i*TAU/cnt+off,ca=Math.cos(th),sa=Math.sin(th),px=-sa,py=ca,j=jit(i,m);
            const tx=ca*len+j,ty=sa*len+j*0.5,b0=r*0.08;
            c.moveTo(ca*b0,sa*b0);
            c.quadraticCurveTo(ca*len*0.55+px*wd,sa*len*0.55+py*wd,tx,ty);
            c.quadraticCurveTo(ca*len*0.55-px*wd,sa*len*0.55-py*wd,ca*b0,sa*b0);}
          c.stroke();
          if(I>0.55){c.strokeStyle=this.col(s.hue2,st,A*(I-0.45),16);c.beginPath();for(let i=0;i<cnt;i++){const th=i*TAU/cnt+off;c.moveTo(Math.cos(th)*r*0.1,Math.sin(th)*r*0.1);c.lineTo(Math.cos(th)*len*0.85,Math.sin(th)*len*0.85);}c.stroke();}
        }
        break;}
      case 'fractal':{
        const kids=Math.min(n,8),maxD=1+Math.round(I*2);let budget=260;
        const rec=(x,y,rr,dep,h)=>{
          if(budget--<=0)return;
          c.strokeStyle=this.col(h,st,A*(0.85-dep*0.18),dep*8);c.beginPath();c.arc(x,y,rr,0,TAU);c.stroke();
          if(dep>=maxD||rr<3)return;
          for(let i=0;i<kids;i++){const th=i*TAU/kids+dep*0.4+t*0.02*(dep%2?1:-1);rec(x+Math.cos(th)*rr*0.62,y+Math.sin(th)*rr*0.62,rr*0.34,dep+1,dep%2?s.hue:s.hue2);}
        };
        rec(0,0,r*0.9,0,s.hue);
        break;}
    }
  }
}
