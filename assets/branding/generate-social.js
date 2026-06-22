// Generates a 1280x640 GitHub social-preview banner for the toolkit.
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const W = 1280, H = 640;
const AZ1 = '#388bfd', AZ2 = '#3fb950', AZ3 = '#db6d28';
const BG0 = '#0d1117', BG1 = '#0c131b', LINE = '#30363d', INK = '#e6edf3', MUTE = '#8b949e';

// Reusable mark (dark tile + ascending AZ bars), drawn at a given x/y/size.
function mark(x, y, size) {
  const s = size, bw = s * 0.16, gap = s * 0.085;
  const total = bw * 3 + gap * 2;
  const x0 = x + (s - total) / 2, baseY = y + s * 0.72;
  const defs = [{ h: s * 0.30, c: AZ1 }, { h: s * 0.42, c: AZ2 }, { h: s * 0.54, c: AZ3 }];
  let bars = `<rect x="${x0 - s*0.03}" y="${baseY}" width="${total + s*0.06}" height="${s*0.022}" rx="${s*0.011}" fill="${LINE}"/>`;
  defs.forEach((b, i) => {
    const bx = x0 + i * (bw + gap), by = baseY - b.h;
    bars += `<rect x="${bx}" y="${by}" width="${bw}" height="${b.h}" rx="${s*0.035}" fill="${b.c}"/>`;
    bars += `<rect x="${bx}" y="${by}" width="${bw}" height="${s*0.07}" rx="${s*0.035}" fill="#ffffff" opacity="0.18"/>`;
  });
  return `<rect x="${x}" y="${y}" width="${s}" height="${s}" rx="${s*0.21}" fill="url(#tile)" stroke="${LINE}" stroke-width="2"/>${bars}`;
}

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b1118"/><stop offset="1" stop-color="#0d1117"/>
    </linearGradient>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${BG0}"/><stop offset="1" stop-color="${BG1}"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#bg)"/>
  <rect x="0" y="0" width="${W}" height="6" fill="${AZ1}"/>
  <rect x="${W/3}" y="0" width="${W/3}" height="6" fill="${AZ2}"/>
  <rect x="${2*W/3}" y="0" width="${W/3}" height="6" fill="${AZ3}"/>

  ${mark(96, 168, 304)}

  <g font-family="'Segoe UI',Arial,sans-serif">
    <text x="468" y="262" font-size="62" font-weight="700" fill="${INK}">Azure Capacity &amp;</text>
    <text x="468" y="334" font-size="62" font-weight="700" fill="${INK}">Enablement Toolkit</text>
    <text x="470" y="398" font-size="29" fill="${MUTE}">Read-only tools and a self-contained dashboard for Azure</text>
    <text x="470" y="438" font-size="29" fill="${MUTE}">regional capacity, availability-zone enablement, and quota.</text>
    <g font-size="24" font-weight="600">
      <rect x="470" y="476" width="190" height="44" rx="22" fill="rgba(56,139,253,.16)" stroke="${AZ1}"/>
      <text x="496" y="505" fill="#79c0ff">Reader-only</text>
      <rect x="676" y="476" width="172" height="44" rx="22" fill="rgba(63,185,80,.16)" stroke="${AZ2}"/>
      <text x="700" y="505" fill="#56d364">No changes</text>
      <rect x="864" y="476" width="180" height="44" rx="22" fill="rgba(219,109,40,.16)" stroke="${AZ3}"/>
      <text x="888" y="505" fill="#e3935a">No telemetry</text>
    </g>
  </g>
</svg>`;

fs.writeFileSync(path.join(__dirname, 'social-preview.svg'), svg);
sharp(Buffer.from(svg)).png().toFile(path.join(__dirname, 'social-preview.png'))
  .then(() => console.log('wrote social-preview.svg + social-preview.png'));
