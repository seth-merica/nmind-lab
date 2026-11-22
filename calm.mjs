// Nmind calm reader. Everything here runs on the phone, frame by frame, and nothing is kept
// after the page closes. It turns the face model's landmarks and expression scores, plus the
// average skin colour of the forehead and cheeks, into a set of signals. Each signal carries a
// confidence from 0 to 1 and drops out of the verdict when the light or the camera is too poor.
//
// Prototype heuristics, not a medical device. Pupil size is not read: the front camera cannot
// measure it reliably in normal light (a native app could use the iPhone's infrared camera).

const clamp=(v,a,b)=>Math.min(b,Math.max(a,v));
const lerp=(a,b,t)=>a+(b-a)*t;
const bsc=(cats,n)=>{for(const c of cats)if(c.categoryName===n)return c.score;return 0;};
const dist=(p,q)=>Math.hypot(p.x-q.x,p.y-q.y);

// resting level tracker: falls quickly to the relaxed level, rises only slowly
class Floor{constructor(){this.v=null;}add(x,learning){if(this.v===null)this.v=x;else this.v+=(x-this.v)*(x<this.v?(learning?0.08:0.02):(learning?0.01:0.0008));return this.v;}}
// personal typical level: learns fast during the first stretch, then barely moves
class Typical{constructor(){this.v=null;this.n=0;}add(x,learning){this.n++;if(this.v===null)this.v=x;else this.v+=(x-this.v)*(learning?Math.max(0.02,1/this.n):0.0015);return this.v;}}
class Ema{constructor(tau){this.tau=tau;this.v=null;}f(x,dt){if(this.v===null)this.v=x;else this.v+=(x-this.v)*(1-Math.exp(-dt/this.tau));return this.v;}}

function trim(arr,now,ms){while(arr.length&&now-arr[0].t>ms)arr.shift();}
export function resample(buf,keys,t0,t1,fs){
  const n=Math.max(0,Math.floor((t1-t0)/1000*fs)),out=keys.map(()=>new Float64Array(n));let j=0;
  for(let i=0;i<n;i++){
    const t=t0+i*1000/fs;while(j<buf.length-2&&buf[j+1].t<t)j++;
    const a=buf[j],b=buf[j+1]||a,u=b.t>a.t?clamp((t-a.t)/(b.t-a.t),0,1):0;
    keys.forEach((k,q)=>{out[q][i]=a[k]+(b[k]-a[k])*u;});
  }
  return out;
}
function movAvg(x,w){const n=x.length,o=new Float64Array(n);let s=0;const h=Math.max(1,Math.floor(w/2));
  const pre=new Float64Array(n+1);for(let i=0;i<n;i++)pre[i+1]=pre[i]+x[i];
  for(let i=0;i<n;i++){const a=Math.max(0,i-h),b=Math.min(n,i+h+1);o[i]=(pre[b]-pre[a])/(b-a);}return o;}
function detrend(x,w){const m=movAvg(x,w),o=new Float64Array(x.length);for(let i=0;i<x.length;i++)o[i]=x[i]-m[i];return o;}
// power at each frequency, Hann window
export function spectrum(x,fs,f0,f1,step){
  const n=x.length,fr=[],pw=[];if(n<8)return {fr,pw};
  let mean=0;for(const v of x)mean+=v;mean/=n;
  const w=new Float64Array(n);for(let i=0;i<n;i++)w[i]=(x[i]-mean)*(0.5-0.5*Math.cos(2*Math.PI*i/(n-1)));
  for(let f=f0;f<=f1+1e-9;f+=step){let re=0,im=0;const k=2*Math.PI*f/fs;for(let i=0;i<n;i++){re+=w[i]*Math.cos(k*i);im-=w[i]*Math.sin(k*i);}fr.push(f);pw.push(re*re+im*im);}
  return {fr,pw};
}
// peak frequency and how far it stands above the rest of the band (0 to 1)
function peak(sp,halfBand,harm){
  const {fr,pw}=sp;if(!fr.length)return {f:0,q:0};
  let bi=0;for(let i=1;i<pw.length;i++)if(pw[i]>pw[bi])bi=i;
  const f=fr[bi];let inP=0,tot=0;
  for(let i=0;i<pw.length;i++){tot+=pw[i];const d=Math.abs(fr[i]-f),d2=harm?Math.abs(fr[i]-2*f):9;if(d<=halfBand||d2<=halfBand)inP+=pw[i];}
  // parabolic refinement of the peak
  let fp=f;if(bi>0&&bi<pw.length-1){const a=pw[bi-1],b=pw[bi],c=pw[bi+1],den=a-2*b+c;if(den!==0)fp=f+clamp(0.5*(a-c)/den,-1,1)*(fr[1]-fr[0]);}
  return {f:fp,q:tot>0?inP/tot:0};
}
// plane-orthogonal-to-skin pulse signal (Wang et al. 2017)
export function posPulse(R,G,B,fs){
  const n=R.length,L=Math.max(8,Math.round(1.6*fs)),H=new Float64Array(n);
  for(let s=0;s+L<=n;s+=1){
    let mr=0,mg=0,mb=0;for(let i=s;i<s+L;i++){mr+=R[i];mg+=G[i];mb+=B[i];}mr/=L;mg/=L;mb/=L;
    if(mr<=0||mg<=0||mb<=0)continue;
    const s1=new Float64Array(L),s2=new Float64Array(L);let a1=0,a2=0;
    for(let i=0;i<L;i++){const r=R[s+i]/mr,g=G[s+i]/mg,b=B[s+i]/mb;s1[i]=g-b;s2[i]=g+b-2*r;a1+=s1[i];a2+=s2[i];}
    a1/=L;a2/=L;let v1=0,v2=0;for(let i=0;i<L;i++){v1+=(s1[i]-a1)**2;v2+=(s2[i]-a2)**2;}
    const al=v2>0?Math.sqrt(v1/v2):0;let hm=0;const h=new Float64Array(L);
    for(let i=0;i<L;i++){h[i]=s1[i]+al*s2[i];hm+=h[i];}hm/=L;
    for(let i=0;i<L;i++)H[s+i]+=h[i]-hm;
  }
  return H;
}

export const SIGNALS=[
  ['gaze','Steady gaze'],['sacc','Eye jumps'],['head','Head stillness'],
  ['brate','Blink rate'],['blen','Blink length'],['lids','Eyelids'],
  ['brow','Brow'],['jaw','Jaw and mouth'],
  ['hr','Heart rate'],['hrv','Heart variability'],['breath','Breathing'],
  ['light','Light'],['pupil','Pupil size']
];

export class CalmReader{
  constructor(){this.reset(0);}
  reset(now){
    this.t0=now;this.faceT=0;this.lastT=now;
    this.blinkOn=false;this.blinkStart=0;this.blinks=[];this.blinkLens=[];
    this.prevEye=null;this.velFloor=0.3;this.saccades=[];this.lastSacc=0;
    this.lidT=new Typical();this.browF=new Floor();this.jawF=new Floor();this.squintF=new Floor();this.wideF=new Floor();
    this.rgb=[];this.motion=[];this.hrHist=[];this.hr=0;this.hrConf=0;this.hrBase=new Typical();this.hrTrend=[];
    this.hrv=0;this.hrvConf=0;this.hrvBase=new Typical();
    this.br=0;this.brConf=0;this.lastSpec=now;this.luma=0;this.lumaE=new Ema(1);
    this.tE=new Ema(4);this.mE=new Ema(4);this.sE=new Ema(2);
    this.verdict='Learning you';this.cand=this.verdict;this.candT=0;
    this.out={signals:{},tension:0,mellow:0,still:0,verdict:this.verdict,learning:true,learnLeft:20};
    this.fps=30;
  }
  // f: {now,dt,lm,cats,W,H,looking,blinkScore,ex,ey,s1,s2,s3,sampler}
  frame(f){
    const {now,dt,lm,cats,W,H}=f;const o=this.out,S=o.signals;
    this.fps+=((dt>0?1/dt:30)-this.fps)*0.05;
    this.faceT+=dt;const learning=this.faceT<20;o.learning=learning;o.learnLeft=Math.max(0,Math.ceil(20-this.faceT));
    const P=i=>({x:lm[i].x*W,y:lm[i].y*H});
    const faceW=dist(P(234),P(454))||1;
    const fpsC=clamp((this.fps-12)/14,0,1);

    // ---- light, and skin colour for the pulse ----
    const rois=[[lerp(lm[10].x,lm[9].x,0.45),lerp(lm[10].y,lm[9].y,0.45),0.34,0.12],[lm[50].x,lm[50].y,0.13,0.13],[lm[280].x,lm[280].y,0.13,0.13]];
    let cr=0,cg=0,cb=0,cn=0;
    if(f.sampler){for(const [x,y,wf,hf] of rois){const w=wf*faceW,h=hf*faceW,c=f.sampler(x*W-w/2,y*H-h/2,w,h);if(c){cr+=c.r;cg+=c.g;cb+=c.b;cn++;}}}
    if(cn){cr/=cn;cg/=cn;cb/=cn;this.luma=this.lumaE.f(0.299*cr+0.587*cg+0.114*cb,dt);this.rgb.push({t:now,r:cr,g:cg,b:cb});}
    trim(this.rgb,now,32000);
    const lightC=cn?clamp((this.luma-35)/50,0,1):0;
    S.light={text:!cn?'unknown':this.luma<35?'too dark':this.luma<70?'dim':this.luma>235?'too bright':'good',conf:cn?1:0,lean:0,v:this.luma};

    // ---- eyes: blinks ----
    const bl=f.blinkScore;
    if(!this.blinkOn&&bl>0.5){this.blinkOn=true;this.blinkStart=now;}
    else if(this.blinkOn&&bl<0.3){this.blinkOn=false;const d=now-this.blinkStart;if(d>40&&d<700){this.blinks.push(now);this.blinkLens.push(d);if(this.blinkLens.length>10)this.blinkLens.shift();}}
    this.blinks=this.blinks.filter(b=>now-b<60000);
    const span=Math.min(60,Math.max(15,(now-this.t0)/1000));
    const bpm=this.blinks.length*60/span;
    const brC=clamp((now-this.t0)/40000,0,1)*0.9;
    const blen=this.blinkLens.length?this.blinkLens.reduce((a,b)=>a+b,0)/this.blinkLens.length:0;
    const blC=fpsC*clamp(this.blinkLens.length/4,0,1)*0.8;

    // ---- eyes: steadiness and jumps ----
    const eyeOpen=bl<0.35;
    if(eyeOpen&&this.prevEye&&dt>0&&dt<0.12){
      const v=Math.hypot(f.ex-this.prevEye.x,f.ey-this.prevEye.y)/dt;
      if(v<this.velFloor*3)this.velFloor+=(v-this.velFloor)*0.02;
      if(v>Math.max(4*this.velFloor,0.5)&&now-this.lastSacc>150){this.saccades.push(now);this.lastSacc=now;}
    }
    this.prevEye=eyeOpen?{x:f.ex,y:f.ey}:null;
    this.saccades=this.saccades.filter(s=>now-s<30000);
    const sRate=this.saccades.length*60/Math.min(30,Math.max(10,(now-this.t0)/1000));
    const sC=fpsC*clamp((now-this.t0)/15000,0,1)*0.8;

    // ---- lids, brow, squint, jaw ----
    const ap=((dist(P(159),P(145))/(dist(P(33),P(133))||1))+(dist(P(386),P(374))/(dist(P(362),P(263))||1)))/2;
    let lidRel=1;if(eyeOpen){const base=this.lidT.add(ap,learning);lidRel=base>0?ap/base:1;}
    const squint=(bsc(cats,'eyeSquintLeft')+bsc(cats,'eyeSquintRight'))/2;
    const wide=(bsc(cats,'eyeWideLeft')+bsc(cats,'eyeWideRight'))/2;
    const brow=(bsc(cats,'browDownLeft')+bsc(cats,'browDownRight'))/2+0.5*bsc(cats,'browInnerUp');
    const jaw=(bsc(cats,'mouthPressLeft')+bsc(cats,'mouthPressRight'))/2+0.6*bsc(cats,'jawForward')+0.4*(bsc(cats,'mouthRollLower')+bsc(cats,'mouthRollUpper'))/2+0.4*(bsc(cats,'mouthShrugLower'));
    const faceC=(cats.length?1:0)*clamp(0.4+lightC,0,1);
    const tBrow=clamp((brow-this.browF.add(brow,learning)-0.04)/0.22,0,1);
    const tJaw=clamp((jaw-this.jawF.add(jaw,learning)-0.04)/0.25,0,1);
    const tSquint=clamp((squint-this.squintF.add(squint,learning)-0.05)/0.25,0,1);
    const tWide=clamp((wide-this.wideF.add(wide,learning)-0.06)/0.25,0,1);

    // ---- slow head motion for breathing ----
    const no=P(1);this.motion.push({t:now,y:no.y/faceW,s:faceW/W});trim(this.motion,now,34000);

    // ---- spectra, once a second ----
    if(now-this.lastSpec>1000){this.lastSpec=now;this.spectra(now,lightC,f.s2,fpsC);}
    const hrC=this.hrConf,hrvC=this.hrvConf,brthC=this.brConf;

    // ---- per-signal readout ----
    S.gaze={text:Math.round(f.s1*100)+'%',conf:0.9,lean:0,v:f.s1};
    S.sacc={text:Math.round(sRate)+'/min',conf:sC,lean:sRate>45?-1:0,v:sRate};
    S.head={text:Math.round(f.s2*100)+'%',conf:0.9,lean:0,v:f.s2};
    S.brate={text:Math.round(bpm)+'/min',conf:brC,lean:bpm<5?1:bpm<=22?-2:0,v:bpm};
    S.blen={text:blen?Math.round(blen)+' ms':'—',conf:blC,lean:blen&&blen<120?1:blen>=180?-2:0,v:blen};
    const lidTxt=tSquint>0.4?'squint':tWide>0.4?'wide':lidRel<0.62?'heavy':lidRel<0.95?'soft':'open';
    S.lids={text:lidTxt,conf:faceC*0.85,lean:lidTxt==='squint'||lidTxt==='wide'?1:lidTxt==='soft'?-2:0,v:lidRel};
    S.brow={text:tBrow>0.5?'tense':tBrow>0.2?'slight':'relaxed',conf:faceC*0.8,lean:tBrow>0.35?1:-2,v:tBrow};
    S.jaw={text:tJaw>0.5?'tense':tJaw>0.2?'slight':'relaxed',conf:faceC*0.7,lean:tJaw>0.35?1:-2,v:tJaw};
    const hb=this.hrBase.v;
    const trend=this.hrTrendSlope();
    S.hr={text:hrC>0.15?Math.round(this.hr)+' bpm'+(trend<-0.04?' ↓':trend>0.04?' ↑':''):'—',conf:hrC,lean:hrC>0.15&&hb?(this.hr>hb+4?1:this.hr<=hb?-2:0):0,v:this.hr};
    S.hrv={text:hrvC>0.1?Math.round(this.hrv)+' ms':'—',conf:hrvC,lean:hrvC>0.1&&this.hrvBase.v?(this.hrv<this.hrvBase.v*0.8?1:this.hrv>this.hrvBase.v*1.05?-2:0):0,v:this.hrv};
    S.breath={text:brthC>0.15?this.br.toFixed(1)+'/min':'—',conf:brthC,lean:brthC>0.15?(this.br<=10?-2:this.br>18?1:0):0,v:this.br};
    S.pupil={text:'not readable here',conf:0,lean:0,v:0};

    // ---- tense and mellow ----
    const hrUp=hb?clamp((this.hr-hb-3)/8,0,1):0,hrDown=hb?clamp(0.5+(hb-this.hr)/8,0,1):0.5;
    const hvb=this.hrvBase.v||0;
    const T=[
      [tBrow,1.0,faceC],[tSquint,0.8,faceC],[tJaw,0.8,faceC],[tWide,0.5,faceC],
      [bpm<5?1:bpm<8?0.5:0,1.0,brC],[blen&&blen<120?1:blen&&blen<150?0.4:0,0.5,blC],
      [hrUp,0.8,hrC],[hvb?clamp((hvb*0.85-this.hrv)/(hvb*0.4),0,1):0,0.4,hrvC],
      [this.br>18?clamp((this.br-18)/6,0,1):0,0.4,brthC]
    ];
    const soft=lidRel>=0.62&&lidRel<0.97&&tSquint<0.3?1:lidRel<0.62?0.5:0.2;
    const M=[
      [soft,1.0,faceC*0.85],[1-Math.max(tBrow,tJaw,tSquint),1.0,faceC],
      [bpm>=5&&bpm<=22?1:0.2,0.8,brC],[blen>=180?1:blen>=140?0.5:0,0.6,blC],
      [hrDown*(trend<0?1:0.7),0.7,hrC],[hvb?clamp(0.5+(this.hrv-hvb)/(hvb*0.5),0,1):0.5,0.4,hrvC],
      [this.br?clamp((16-this.br)/6,0,1):0,0.9,brthC]
    ];
    const wavg=a=>{let s=0,w=0;for(const [v,wt,c] of a){if(c<0.25)continue;s+=v*wt*c;w+=wt*c;}return w>0?s/w:0;};
    const still=clamp((0.42*f.s1+0.25*f.s2+0.15*f.s3+0.18*clamp(1-(sRate-15)/40,0,1))*(0.5+0.5*f.s2),0,1);
    o.tension=this.tE.f(wavg(T),dt);o.mellow=this.mE.f(wavg(M),dt);o.still=this.sE.f(still,dt);

    let c;
    if(!f.looking)c='Paused';
    else if(learning)c='Learning you';
    else if(o.still<0.5)c='Restless';
    else if(o.tension>=0.42&&o.tension>o.mellow-0.12)c='Tense calm';
    else if(o.mellow>=0.55&&o.tension<0.38&&o.still>=0.7)c='Mellow calm';
    else c='Settling';
    if(c!==this.cand){this.cand=c;this.candT=0;}else this.candT+=dt;
    if(c!==this.verdict&&(this.candT>1.5||c==='Paused'||this.verdict==='Learning you'))this.verdict=c;
    o.verdict=this.verdict;o.hr=this.hr;o.hrConf=hrC;
    return o;
  }
  hrTrendSlope(){ // bpm per second over the last 45 s of confident readings
    const a=this.hrTrend;if(a.length<6)return 0;
    const t0=a[0].t;let n=0,sx=0,sy=0,sxx=0,sxy=0;for(const p of a){const x=(p.t-t0)/1000;n++;sx+=x;sy+=p.v;sxx+=x*x;sxy+=x*p.v;}
    const d=n*sxx-sx*sx;return d?(n*sxy-sx*sy)/d:0;
  }
  spectra(now,lightC,headStill,fpsC){
    // heart rate from the last 12 s of skin colour
    const buf=this.rgb;
    if(buf.length>60&&now-buf[0].t>9000){
      const fs=30,t1=buf[buf.length-1].t,t0=Math.max(buf[0].t,t1-12000);
      const [R,G,B]=resample(buf,['r','g','b'],t0,t1,fs);
      const h=detrend(posPulse(R,G,B,fs),Math.round(fs*1.2));
      const pk=peak(spectrum(h,fs,0.7,3.0,1/60),0.1,true);
      const bpm=pk.f*60;
      const conf=clamp((pk.q-0.25)/0.45,0,1)*lightC*clamp((headStill-0.2)/0.5,0,1)*fpsC;
      if(conf>0.1){this.hrHist.push(bpm);if(this.hrHist.length>5)this.hrHist.shift();const s=this.hrHist.slice().sort((a,b)=>a-b);this.hr=s[s.length>>1];}
      this.hrConf=this.hrConf*0.5+conf*0.5;
      if(this.hrConf>0.35){this.hrBase.add(this.hr,(now-this.t0)<60000);this.hrTrend.push({t:now,v:this.hr});}
      trim(this.hrTrend,now,45000);
      // variability: beat to beat timing over the last 30 s (rough at 30 frames a second)
      this.hrvConf=0;
      if(this.hrConf>0.4&&now-buf[0].t>25000){
        const u0=Math.max(buf[0].t,t1-30000),[R2,G2,B2]=resample(buf,['r','g','b'],u0,t1,fs);
        const x=movAvg(detrend(posPulse(R2,G2,B2,fs),Math.round(fs*0.9)),3);
        const per=fs*60/Math.max(40,this.hr),minGap=Math.floor(per*0.6),pks=[];
        for(let i=1;i<x.length-1;i++){if(x[i]>0&&x[i]>=x[i-1]&&x[i]>x[i+1]){
          const a=x[i-1],b=x[i],c=x[i+1],den=a-2*b+c,ti=i+(den?clamp(0.5*(a-c)/den,-0.5,0.5):0);
          if(pks.length&&ti-pks[pks.length-1]<minGap){if(b>x[Math.round(pks[pks.length-1])])pks[pks.length-1]=ti;}else pks.push(ti);}}
        const ibi=[];for(let i=1;i<pks.length;i++)ibi.push((pks[i]-pks[i-1])/fs*1000);
        const med=ibi.slice().sort((a,b)=>a-b)[ibi.length>>1]||0,good=ibi.filter(v=>Math.abs(v-med)<med*0.22);
        if(good.length>=12){let s=0,n=0;for(let i=1;i<good.length;i++){s+=(good[i]-good[i-1])**2;n++;}
          const r=Math.sqrt(s/Math.max(1,n));this.hrv=this.hrv?lerp(this.hrv,r,0.3):r;
          this.hrvConf=clamp(this.hrConf*0.6*(good.length/ibi.length)*fpsC,0,0.6);
          if(this.hrvConf>0.25)this.hrvBase.add(this.hrv,(now-this.t0)<90000);}
      }
    }else{this.hrConf*=0.8;}
    // breathing from slow up and down head motion over the last 32 s
    const m=this.motion;
    if(m.length>100&&now-m[0].t>20000){
      const fs=10,t1=m[m.length-1].t,t0=Math.max(m[0].t,t1-32000);
      const [Y,Sc]=resample(m,['y','s'],t0,t1,fs);
      const y=detrend(Y,fs*12),s=detrend(Sc,fs*12);
      const a=peak(spectrum(y,fs,0.1,0.6,0.005),0.03,false),b=peak(spectrum(s,fs,0.1,0.6,0.005),0.03,false);
      const best=a.q>=b.q?a:b;
      const conf=clamp((best.q-0.3)/0.4,0,1)*clamp((headStill-0.3)/0.5,0,1)*clamp((t1-t0-20000)/10000+0.5,0,1);
      if(conf>0.1)this.br=this.br?lerp(this.br,best.f*60,0.35):best.f*60;
      this.brConf=this.brConf*0.5+conf*0.5;
    }
  }
}
