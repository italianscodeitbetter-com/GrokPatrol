(function () {
  var root = document.documentElement;
  var motion = root.classList.contains('motion');

  // comparsa degli elementi quando entrano nella pagina
  var items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add('in'); seen.unobserve(e.target); }
      });
    }, { rootMargin: '0px 0px -8% 0px' });
    items.forEach(function (el) { seen.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add('in'); });
  }

  if (!motion) return;

  // la scena gira solo mentre si vede, e si può fermare
  var stage = document.querySelector('.stage');
  var toggle = document.querySelector('.motion-toggle');
  var visible = true;
  var paused = false;

  function syncStage() { stage.classList.toggle('is-running', visible && !paused); }

  toggle.hidden = false;
  toggle.addEventListener('click', function () {
    paused = !paused;
    toggle.setAttribute('aria-pressed', String(paused));
    toggle.setAttribute('aria-label', paused ? "Riprendi l'animazione" : "Metti in pausa l'animazione");
    syncStage();
  });
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (e) {
      visible = e[e.length - 1].isIntersecting;
      syncStage();
    }, { threshold: 0.2 }).observe(stage);
  }
  syncStage();

  // i 64 secondi seguono lo scorrimento: ogni riga si accende quando viene raggiunta
  var clock = document.querySelector('.clock');
  var time = document.querySelector('[data-clock]');
  var scale = document.querySelector('.scale');
  var dots = [].slice.call(scale.querySelectorAll('i'));
  var rows = [].slice.call(document.querySelectorAll('.log li'));
  var marks = rows.map(function (r) { return Number(r.dataset.t); });
  var END = 64;
  var queued = false;

  function update() {
    queued = false;
    var line = window.innerHeight * 0.62;
    var tops = rows.map(function (r) { return r.getBoundingClientRect().top; });
    var reached = 0;
    tops.forEach(function (top, i) {
      var on = top < line;
      rows[i].classList.toggle('on', on);
      if (on) reached = i + 1;
    });
    var t = 0;
    if (reached === rows.length) t = END;
    else if (reached > 0) {
      var a = reached - 1;
      var part = (line - tops[a]) / (tops[reached] - tops[a]);
      t = marks[a] + Math.max(0, Math.min(1, part)) * (marks[reached] - marks[a]);
    }
    time.textContent = '+' + Math.round(t) + ' s';
    scale.style.setProperty('--p', (t / END).toFixed(4));
    dots.forEach(function (d) { d.classList.toggle('on', t >= Number(d.dataset.t) - 0.01 && reached > 0); });
    clock.classList.toggle('done', reached === rows.length);
  }

  function request() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  }

  window.addEventListener('scroll', request, { passive: true });
  window.addEventListener('resize', request);
  update();
})();
