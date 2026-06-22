// Toolkit brand mark: three ascending availability-zone bars on a dark tile.
// One icon, reused for the repo logo, docs, and all GitHub team avatars.
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const S = 512;
const AZ1 = '#50abff', AZ2 = '#5fd06e', AZ3 = '#f0894e';

function tile(stops, radius, inner) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    ${stops.map((s, i) => `<stop offset="${i / (stops.length - 1)}" stop-color="${s}"/>`).join('')}
  </linearGradient></defs>
  <rect x="8" y="8" width="${S - 16}" height="${S - 16}" rx="${radius}" fill="url(#g)"/>
  ${inner}
</svg>`;
}

// Colored 3-bar glyph (AZ colors) on a dark tile.
function azBars() {
  const bw = 74, gap = 40, total = bw * 3 + gap * 2;
  const x0 = (S - total) / 2, baseY = 360;
  const defs = [{ h: 150, c: AZ1 }, { h: 205, c: AZ2 }, { h: 262, c: AZ3 }];
  let r = '';
  defs.forEach((b, i) => {
    const x = x0 + i * (bw + gap), y = baseY - b.h;
    r += `<rect x="${x}" y="${y}" width="${bw}" height="${b.h}" rx="16" fill="${b.c}"/>`;
    r += `<rect x="${x}" y="${y}" width="${bw}" height="34" rx="16" fill="#ffffff" opacity="0.18"/>`;
  });
  r += `<rect x="${x0 - 14}" y="${baseY}" width="${total + 28}" height="12" rx="6" fill="#ffffff" opacity="0.5"/>`;
  return r;
}

const DARK = ['#1b2735', '#0d1117'];

const svg = tile(DARK, 110, azBars());

fs.writeFileSync(path.join(__dirname, 'logo.svg'), svg);
sharp(Buffer.from(svg)).resize(500, 500).png().toFile(path.join(__dirname, 'logo.png'))
  .then(() => console.log('wrote logo.svg + logo.png'));
