// Nmind offline cache. Stores only the app's own files on this device; nothing about the user.
const CACHE='nmind-v3';
const CORE=['./','./index.html','./manifest.webmanifest','./icon.png','./icon-192.png','./icon-512.png','./lib/vision_bundle.mjs','./models/face_landmarker.task'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET'||u.origin!==location.origin)return;
  const heavy=/\/(lib|models)\//.test(u.pathname)||/\.png$/.test(u.pathname);
  if(heavy){
    // big files: cache first, fill the cache on first use
    e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request).then(res=>{if(res.ok){const cp=res.clone();caches.open(CACHE).then(c=>c.put(e.request,cp));}return res;})));
  }else{
    // the page itself: network first so updates arrive, cache when offline
    e.respondWith(fetch(e.request).then(res=>{if(res.ok){const cp=res.clone();caches.open(CACHE).then(c=>c.put(e.request,cp));}return res;}).catch(()=>caches.match(e.request).then(r=>r||caches.match('./index.html'))));
  }
});
