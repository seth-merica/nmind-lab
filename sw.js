// Nmind offline cache. Stores only the app's own files on this device; nothing about the user.
// v4: always try the network first so a fresh copy is used; the cache is only a backup for offline use.
const CACHE='nmind-v6';
self.addEventListener('install',e=>{self.skipWaiting();});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET'||u.origin!==location.origin||e.request.headers.has('range'))return;
  e.respondWith(fetch(e.request).then(res=>{
    if(res.ok&&res.status===200&&res.type==='basic'){const cp=res.clone();caches.open(CACHE).then(c=>c.put(e.request,cp)).catch(()=>{});}
    return res;
  }).catch(()=>caches.match(e.request,{ignoreSearch:true}).then(r=>r||(e.request.mode==='navigate'?caches.match('./index.html',{ignoreSearch:true}):Response.error()))));
});
