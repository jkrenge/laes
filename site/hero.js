// Hero showcase: Weeks, Tasks and Notes on the Mac and iPhone, switching together every 6 seconds.
// The fill animation under the current screen's button is the timer (style.css), so pausing it pauses rotation.
// Rotation holds while hovered, focused or off screen, stops once a screen is picked, and never starts by itself
// when reduced motion is asked for.
{
  const showcase = document.querySelector('.showcase');
  const shots = [...showcase.querySelectorAll('.shot')];
  const picks = [...showcase.querySelectorAll('.picker button')];
  const toggle = showcase.querySelector('.rotation');
  const status = showcase.querySelector('[role="status"]');
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  let current = 0;

  const show = (index, announce) => {
    current = (index + shots.length) % shots.length;
    shots.forEach((s, i) => s.classList.toggle('is-current', i === current));
    picks.forEach((b, i) => b.setAttribute('aria-current', String(i === current)));
    // Only screens the user picks are announced; automatic changes stay quiet.
    if (announce) status.textContent = shots[current].getAttribute('aria-label');
  };

  // The label switches between Pause and Play, so no aria-pressed (it would read as a pressed "Play").
  const play = on => {
    showcase.classList.toggle('is-playing', on);
    toggle.querySelector('span').textContent = on ? 'Pause' : 'Play';
  };

  picks.forEach((b, i) => b.addEventListener('click', () => { play(false); show(i, true); }));
  toggle.addEventListener('click', () => {
    // An explicit Play starts right away, even with the pointer or focus still on the button.
    showcase.classList.remove('is-hovered', 'is-focused');
    play(!showcase.classList.contains('is-playing'));
  });
  showcase.addEventListener('animationend', e => {
    if (e.animationName === 'fill' && showcase.classList.contains('is-playing')) show(current + 1);
  });

  showcase.addEventListener('pointerenter', () => showcase.classList.add('is-hovered'));
  showcase.addEventListener('pointerleave', () => showcase.classList.remove('is-hovered'));
  showcase.addEventListener('focusin', () => showcase.classList.add('is-focused'));
  showcase.addEventListener('focusout', e => {
    if (!showcase.contains(e.relatedTarget)) showcase.classList.remove('is-focused');
  });
  new IntersectionObserver(([entry]) => showcase.classList.toggle('is-offscreen', !entry.isIntersecting))
    .observe(showcase);
  reduceMotion.addEventListener('change', () => { if (reduceMotion.matches) play(false); });

  play(!reduceMotion.matches);
}
