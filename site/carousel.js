// The tour: a native scroll-snap track with Previous/Next (looping), one marker per slide and a polite status.
// It does not move by itself; the hero is the page's only rotating element.
{
  const carousel = document.querySelector('.carousel');
  const track = carousel.querySelector('.carousel-track');
  const slides = [...track.children];
  const markers = carousel.querySelector('.carousel-markers');
  const status = carousel.querySelector('[role="status"]');

  let pending = null;   // slide index a click is scrolling to
  let settled = 0;      // last slide scrolling came to rest on

  const buttons = slides.map((slide, i) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = slide.dataset.markerName;
    b.setAttribute('aria-label', `${slide.dataset.markerName}, slide ${i + 1} of ${slides.length}`);
    b.addEventListener('click', () => go(i));
    markers.append(b);
    return b;
  });

  const nearest = () => {
    const mid = track.scrollLeft + track.clientWidth / 2;
    let best = 0, distance = Infinity;
    slides.forEach((s, i) => {
      const d = Math.abs(s.offsetLeft + s.offsetWidth / 2 - mid);
      if (d < distance) { distance = d; best = i; }
    });
    return best;
  };

  const mark = index => {
    buttons.forEach((b, i) => b.setAttribute('aria-current', String(i === index)));
    slides.forEach((s, i) => s.classList.toggle('is-current', i === index));
  };

  const go = index => {
    const i = (index + slides.length) % slides.length;   // wraps from the last slide to the first and back
    pending = i;
    mark(i);
    const s = slides[i];
    track.scrollTo({ left: s.offsetLeft - (track.clientWidth - s.offsetWidth) / 2 });
  };

  carousel.querySelectorAll('[data-direction]').forEach(b =>
    b.addEventListener('click', () => go((pending ?? nearest()) + (b.dataset.direction === 'next' ? 1 : -1))));

  // Markers follow the scroll live; the announcement waits for it to settle.
  let frame = 0;
  track.addEventListener('scroll', () => {
    if (pending !== null || frame) return;
    frame = requestAnimationFrame(() => { frame = 0; mark(nearest()); });
  }, { passive: true });

  const settle = () => {
    const i = nearest();
    pending = null;
    mark(i);
    if (i !== settled) {
      settled = i;
      status.textContent = `Slide ${i + 1} of ${slides.length}: ${slides[i].querySelector('h3').textContent}`;
    }
  };
  if ('onscrollend' in window) {
    track.addEventListener('scrollend', settle);
  } else {
    let timer;
    track.addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(settle, 120); }, { passive: true });
  }

  mark(0);
}
