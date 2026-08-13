// Reads build.json, written by the image build. Absent in local dev, which is fine.
fetch('build.json', { cache: 'no-store' })
  .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
  .then(function (b) {
    set('m-ver', b.version);
    set('m-sha', b.commit);
    set('m-time', b.built);
    set('m-base', b.base);
  })
  .catch(function () {
    ['m-ver', 'm-sha', 'm-time', 'm-base'].forEach(function (id) {
      document.getElementById(id).textContent = 'local build — not from CI';
    });
  });

function set(id, v) { document.getElementById(id).textContent = v || 'unset'; }

// Live service status. Absent API is a normal state, not an error.
fetch('/api/health').then(function(r){return r.ok?r.json():Promise.reject();})
  .then(function(h){
    document.getElementById('m-api').textContent =
      'up · db ' + h.database + ' · egress ' + h.egress_proxy;
    document.getElementById('m-api').className = 'ok';
  })
  .catch(function(){
    document.getElementById('m-api').textContent = 'not running — static mode';
  });
