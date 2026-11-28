// The task dropped into the calendar: a CSS animation (style.css) with its own Pause, as the hero has.
{
  const drop = document.querySelector('.drop');
  const toggle = drop.querySelector('[data-toggle-animation]');
  toggle.addEventListener('click', () => {
    const on = drop.classList.toggle('is-playing');
    toggle.querySelector('span').textContent = on ? 'Pause' : 'Play';
  });
}

// The icon designer, with the app's own rules (Laes/Views/IconEditor.swift): a sticker has two corners it can sit in,
// each sticker once, one tilde at most. Sizes and places are StickerFrames.swift's, in fractions of the icon's side.
{
  const picture = {
    yellowTilde: [-.2248, -.1770, .4463], whiteTilde: [-.2248, -.1770, .4463], page: [-.1727, -.1720, .3477],
    tick: [-.1570, -.1476, .3193], notepad: [-.1600, -.1642, .3164], name: [-.1798, -.1271, .3574],
  };
  const centre = { topLeft: [.34, .30], topRight: [.70, .34], bottomLeft: [.30, .70], bottomRight: [.67, .72] };
  const cornerTitle = { topLeft: 'top left', topRight: 'top right', bottomLeft: 'bottom left', bottomRight: 'bottom right' };
  const cornersOf = s => ['yellowTilde', 'whiteTilde', 'name'].includes(s) ? ['topLeft', 'bottomRight'] : ['topRight', 'bottomLeft'];
  const isTilde = s => s.endsWith('Tilde');

  const lab = document.querySelector('.icon-lab');
  const plate = lab.querySelector('.icon-plate');
  const status = lab.querySelector('[role="status"]');
  const buttons = [...lab.querySelectorAll('[data-sticker]')];
  const title = s => buttons.find(b => b.dataset.sticker === s).textContent.trim();
  const standard = { topLeft: 'yellowTilde', topRight: 'page', bottomLeft: 'tick', bottomRight: 'name' };
  let design = { ...standard };

  const describe = () => {
    const parts = Object.keys(centre).filter(c => design[c]).map(c => `${title(design[c])} ${cornerTitle[c]}`);
    return parts.length ? parts.join(', ') : 'No stickers';
  };

  const draw = added => {
    plate.querySelectorAll('.on').forEach(img => img.remove());
    for (const [corner, sticker] of Object.entries(design)) {
      const source = buttons.find(b => b.dataset.sticker === sticker).querySelector('img');
      const [x, y, width] = picture[sticker], [cx, cy] = centre[corner];
      const img = new Image();
      img.src = source.src;
      img.alt = '';
      img.className = sticker === added ? 'on is-new' : 'on';
      img.dataset.on = sticker;
      img.style.cssText = `left:${(cx + x) * 100}%;top:${(cy + y) * 100}%;width:${width * 100}%`;
      plate.append(img);
    }
    buttons.forEach(b => b.setAttribute('aria-pressed', String(Object.values(design).includes(b.dataset.sticker))));
    plate.setAttribute('aria-label', `The lães app icon. ${describe()}.`);
  };

  // The demo: a hand drags stickers off the standard icon and others onto it, as you do in the app, until Pause or a tap.
  const row = lab.querySelector('.icon-row'), hand = lab.querySelector('.hand'), toggle = lab.querySelector('[data-toggle-animation]');
  const swaps = [['tick', 'notepad', 'bottomLeft'], ['yellowTilde', 'whiteTilde', 'topLeft'], ['notepad', 'tick', 'bottomLeft'], ['whiteTilde', 'yellowTilde', 'topLeft']];
  let run = 0;   // each play() has its number; a newer one, or stop(), ends it at its next step
  const wait = ms => new Promise(done => setTimeout(done, ms));
  const inTray = sticker => buttons.find(b => b.dataset.sticker === sticker).querySelector('img');
  // Where something is, measured from the row the hand and the carried sticker live in.
  const box = el => {
    const r = el.getBoundingClientRect(), o = row.getBoundingClientRect();
    return { x: r.left - o.left, y: r.top - o.top, w: r.width, h: r.height };
  };
  const cornerBox = (sticker, corner) => {
    const p = box(plate), t = box(inTray(sticker)), [x, y, width] = picture[sticker], [cx, cy] = centre[corner];
    return { x: p.x + (cx + x) * p.w, y: p.y + (cy + y) * p.w, w: width * p.w, h: width * p.w * t.h / t.w };
  };
  const point = at => {
    hand.style.translate = `${at.x + at.w / 2 - 11}px ${at.y + at.h / 2 - 3}px`;   // the fingertip, not the corner
    return wait(700);
  };
  const carry = async (sticker, from, to, me, grabbed) => {
    await point(from);
    if (me !== run) return false;
    hand.classList.add('is-down');
    const ghost = Object.assign(new Image(), { src: inTray(sticker).src, alt: '', className: 'carried' });
    const put = at => ghost.style.cssText = `left:${at.x}px;top:${at.y}px;width:${at.w}px`;
    put(from);
    row.append(ghost);
    grabbed?.();
    await wait(200);
    if (me !== run) return false;
    put(to);
    await point(to);
    if (me !== run) return false;
    hand.classList.remove('is-down');
    ghost.remove();
    return true;
  };
  const play = async () => {
    const me = ++run;
    design = { ...standard };
    draw();
    lab.classList.add('is-playing');
    toggle.querySelector('span').textContent = 'Pause';
    hand.classList.add('is-shown');
    for (let i = 0; ; i = (i + 1) % swaps.length) {
      const [out, into, corner] = swaps[i];
      await wait(1300);
      if (me !== run) return;
      const onIcon = plate.querySelector(`[data-on="${out}"]`);
      if (!await carry(out, box(onIcon), box(inTray(out)), me, () => onIcon.style.visibility = 'hidden')) return;
      delete design[corner];
      draw();
      await wait(300);
      if (me !== run || !await carry(into, box(inTray(into)), cornerBox(into, corner), me)) return;
      design[corner] = into;
      draw();
    }
  };
  const stop = () => {
    run++;
    lab.classList.remove('is-playing');
    toggle.querySelector('span').textContent = 'Play';
    hand.classList.remove('is-shown', 'is-down');
    row.querySelectorAll('.carried').forEach(img => img.remove());
    draw();
  };
  toggle.addEventListener('click', () => lab.classList.contains('is-playing') ? stop() : play());
  if (matchMedia('(prefers-reduced-motion: no-preference)').matches) play();

  buttons.forEach(button => button.addEventListener('click', () => {
    if (lab.classList.contains('is-playing')) stop();
    const sticker = button.dataset.sticker;
    const at = Object.keys(design).find(c => design[c] === sticker);
    if (at) {
      delete design[at];
    } else {
      // Into its first free corner, or else its first; the other tilde makes way.
      const corner = cornersOf(sticker).find(c => !design[c]) ?? cornersOf(sticker)[0];
      for (const c of Object.keys(design)) if (isTilde(design[c]) && isTilde(sticker)) delete design[c];
      design[corner] = sticker;
    }
    draw(at ? null : sticker);
    status.textContent = describe();
  }));
}
