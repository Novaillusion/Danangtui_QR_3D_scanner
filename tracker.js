// Fast frame-to-frame planar tracker for a QR code.
// jsQR finds the code once (slow); this follows it every camera frame (fast) using
// pyramidal Lucas–Kanade optical flow on many feature points inside the code, then
// fits a homography with RANSAC. The plane coordinates of each feature are fixed at
// initialisation, so the code's corners (and its orientation) are carried through.

export const QR_SQUARE = [[-0.5, -0.5], [0.5, -0.5], [0.5, 0.5], [-0.5, 0.5]];

// ---------- images ----------
export function toGray(rgba, w, h) {
  const g = new Float32Array(w * h);
  for (let i = 0, j = 0; i < g.length; i++, j += 4) g[i] = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) / 256;
  return g;
}

export function buildPyramid(gray, w, h, levels = 5) {
  const pyr = [{ data: gray, w, h }];
  for (let l = 1; l < levels; l++) {
    const p = pyr[l - 1], nw = p.w >> 1, nh = p.h >> 1;
    if (nw < 16 || nh < 16) break;
    const d = new Float32Array(nw * nh), s = p.data, pw = p.w;
    for (let y = 0; y < nh; y++) {
      const r0 = 2 * y * pw, r1 = r0 + pw;
      for (let x = 0; x < nw; x++) {
        const x2 = 2 * x;
        d[y * nw + x] = (s[r0 + x2] + s[r0 + x2 + 1] + s[r1 + x2] + s[r1 + x2 + 1]) * 0.25;
      }
    }
    pyr.push({ data: d, w: nw, h: nh });
  }
  return pyr;
}

function sample(img, x, y) {
  const { data, w, h } = img;
  if (x < 0) x = 0; else if (x > w - 1.001) x = w - 1.001;
  if (y < 0) y = 0; else if (y > h - 1.001) y = h - 1.001;
  const x0 = x | 0, y0 = y | 0, fx = x - x0, fy = y - y0, i = y0 * w + x0;
  const a = data[i], b = data[i + 1], c = data[i + w], d = data[i + w + 1];
  return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

// ---------- linear algebra ----------
function solve(A, b) {
  const n = b.length;
  for (let i = 0; i < n; i++) {
    let p = i;
    for (let r = i + 1; r < n; r++) if (Math.abs(A[r][i]) > Math.abs(A[p][i])) p = r;
    [A[i], A[p]] = [A[p], A[i]]; [b[i], b[p]] = [b[p], b[i]];
    if (Math.abs(A[i][i]) < 1e-12) return null;
    for (let r = i + 1; r < n; r++) {
      const f = A[r][i] / A[i][i];
      if (f === 0) continue;
      for (let c = i; c < n; c++) A[r][c] -= f * A[i][c];
      b[r] -= f * b[i];
    }
  }
  const x = new Array(n);
  for (let i = n - 1; i >= 0; i--) {
    let s = b[i];
    for (let c = i + 1; c < n; c++) s -= A[i][c] * x[c];
    x[i] = s / A[i][i];
  }
  return x;
}

// Exact homography from 4 point pairs.
export function homography(src, dst) {
  const A = [], b = [];
  for (let i = 0; i < 4; i++) {
    const [X, Y] = src[i], [u, v] = dst[i];
    A.push([X, Y, 1, 0, 0, 0, -u * X, -u * Y]); b.push(u);
    A.push([0, 0, 0, X, Y, 1, -v * X, -v * Y]); b.push(v);
  }
  const h = solve(A, b);
  return h && [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1]];
}

// Least-squares homography from n ≥ 4 pairs (image side normalised for conditioning).
export function homographyLS(src, dst) {
  const n = src.length;
  let mx = 0, my = 0;
  for (const [u, v] of dst) { mx += u; my += v; }
  mx /= n; my /= n;
  let md = 0;
  for (const [u, v] of dst) md += Math.hypot(u - mx, v - my);
  const k = md > 0 ? Math.SQRT2 * n / md : 1;
  const N = Array.from({ length: 8 }, () => new Float64Array(8)), r = new Float64Array(8);
  const row = new Float64Array(8);
  for (let i = 0; i < n; i++) {
    const [X, Y] = src[i], u = (dst[i][0] - mx) * k, v = (dst[i][1] - my) * k;
    for (let pass = 0; pass < 2; pass++) {
      let t;
      if (pass === 0) { row.set([X, Y, 1, 0, 0, 0, -u * X, -u * Y]); t = u; }
      else { row.set([0, 0, 0, X, Y, 1, -v * X, -v * Y]); t = v; }
      for (let a = 0; a < 8; a++) {
        const ra = row[a];
        if (ra === 0) continue;
        r[a] += ra * t;
        for (let c = 0; c < 8; c++) N[a][c] += ra * row[c];
      }
    }
  }
  const h = solve(N.map(x => Array.from(x)), Array.from(r));
  if (!h) return null;
  // undo normalisation: H = T^-1 * Hn, T = [[k,0,-k mx],[0,k,-k my],[0,0,1]]
  const Hn = [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1]];
  return [0, 1, 2].map(i => [0, 1, 2].map(j =>
    i === 2 ? Hn[2][j] : Hn[i][j] / k + (i === 0 ? mx : my) * Hn[2][j]));
}

export function applyH(H, [x, y]) {
  const w = H[2][0] * x + H[2][1] * y + H[2][2];
  return [(H[0][0] * x + H[0][1] * y + H[0][2]) / w, (H[1][0] * x + H[1][1] * y + H[1][2]) / w];
}

export function invertH(H) {
  const [[a, b, c], [d, e, f], [g, h, i]] = H;
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-15) return null;
  return [
    [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
    [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
    [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
  ];
}

// ---------- features ----------
// Shi–Tomasi corners inside the code (plane coords |X|,|Y| < limit), spread out on a grid.
export function selectFeatures(img, H, maxN = 80, limit = 0.48) {
  const Hi = invertH(H);
  if (!Hi) return [];
  const corners = QR_SQUARE.map(p => applyH(H, p));
  const xs = corners.map(p => p[0]), ys = corners.map(p => p[1]);
  const side = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
  const { data, w, h } = img;
  const x0 = Math.max(4, Math.floor(Math.min(...xs))), x1 = Math.min(w - 5, Math.ceil(Math.max(...xs)));
  const y0 = Math.max(4, Math.floor(Math.min(...ys))), y1 = Math.min(h - 5, Math.ceil(Math.max(...ys)));
  if (x1 <= x0 || y1 <= y0) return [];
  const step = Math.max(1, Math.round(side / 80));
  const cell = Math.max(4, side / Math.sqrt(maxN) * 0.9);
  const best = new Map();
  const R = 2 * step;
  for (let y = y0; y <= y1; y += step) {
    for (let x = x0; x <= x1; x += step) {
      const q = applyH(Hi, [x, y]);
      if (Math.abs(q[0]) > limit || Math.abs(q[1]) > limit) continue;
      let sxx = 0, syy = 0, sxy = 0;
      for (let dy = -R; dy <= R; dy += step) {
        const yy = y + dy;
        if (yy < 1 || yy >= h - 1) continue;
        for (let dx = -R; dx <= R; dx += step) {
          const xx = x + dx;
          if (xx < 1 || xx >= w - 1) continue;
          const i = yy * w + xx;
          const gx = data[i + 1] - data[i - 1], gy = data[i + w] - data[i - w];
          sxx += gx * gx; syy += gy * gy; sxy += gx * gy;
        }
      }
      const tr = sxx + syy, disc = Math.sqrt((sxx - syy) * (sxx - syy) + 4 * sxy * sxy);
      const score = (tr - disc) / 2;                       // min eigenvalue
      const key = Math.floor(x / cell) * 100000 + Math.floor(y / cell);
      const cur = best.get(key);
      if (!cur || score > cur.score) best.set(key, { x, y, score, plane: q });
    }
  }
  const list = [...best.values()].filter(f => f.score > 50).sort((a, b) => b.score - a.score).slice(0, maxN);
  return list.map(f => ({ img: [f.x, f.y], plane: f.plane }));
}

// ---------- optical flow ----------
// Pyramidal Lucas–Kanade. pts: [[x,y]] in level-0 pixels of prev. guess: optional predicted positions.
export function trackPoints(prev, next, pts, guess = null, r = 6) {
  const L = Math.min(prev.length, next.length);
  const out = new Array(pts.length), ok = new Array(pts.length);
  const n = (2 * r + 1) * (2 * r + 1);
  const T = new Float32Array(n), Ix = new Float32Array(n), Iy = new Float32Array(n);
  for (let k = 0; k < pts.length; k++) {
    const p0 = pts[k];
    const top = 1 << (L - 1);
    // displacement in current level's pixels
    let gx = guess ? (guess[k][0] - p0[0]) / top : 0, gy = guess ? (guess[k][1] - p0[1]) / top : 0;
    let good = true, err = 0;
    for (let l = L - 1; l >= 0; l--) {
      const s = 1 << l, px = p0[0] / s, py = p0[1] / s;
      const A = prev[l], B = next[l];
      let gxx = 0, gyy = 0, gxy = 0, m = 0;
      for (let dy = -r; dy <= r; dy++) for (let dx = -r; dx <= r; dx++, m++) {
        const x = px + dx, y = py + dy;
        T[m] = sample(A, x, y);
        const ix = (sample(A, x + 1, y) - sample(A, x - 1, y)) * 0.5;
        const iy = (sample(A, x, y + 1) - sample(A, x, y - 1)) * 0.5;
        Ix[m] = ix; Iy[m] = iy;
        gxx += ix * ix; gyy += iy * iy; gxy += ix * iy;
      }
      const det = gxx * gyy - gxy * gxy;
      const minEig = (gxx + gyy - Math.sqrt((gxx - gyy) ** 2 + 4 * gxy * gxy)) / 2;
      if (det < 1e-6 || minEig / n < 1e-3) { good = false; break; }
      let vx = 0, vy = 0;
      for (let it = 0; it < 12; it++) {
        let bx = 0, by = 0; m = 0;
        const ox = px + gx + vx, oy = py + gy + vy;
        for (let dy = -r; dy <= r; dy++) for (let dx = -r; dx <= r; dx++, m++) {
          const e = T[m] - sample(B, ox + dx, oy + dy);
          bx += e * Ix[m]; by += e * Iy[m];
        }
        const ux = (gyy * bx - gxy * by) / det, uy = (gxx * by - gxy * bx) / det;
        vx += ux; vy += uy;
        if (ux * ux + uy * uy < 0.0009) break;
      }
      if (l > 0) { gx = 2 * (gx + vx); gy = 2 * (gy + vy); }
      else {
        gx += vx; gy += vy;
        m = 0; err = 0;
        for (let dy = -r; dy <= r; dy++) for (let dx = -r; dx <= r; dx++, m++)
          err += Math.abs(T[m] - sample(B, px + gx + dx, py + gy + dy));
        err /= n;
      }
    }
    const nx = p0[0] + gx, ny = p0[1] + gy;
    const B0 = next[0];
    if (!good || err > 25 || nx < 0 || ny < 0 || nx > B0.w - 1 || ny > B0.h - 1) ok[k] = false;
    else ok[k] = true;
    out[k] = [nx, ny];
  }
  return { pts: out, ok };
}

// ---------- RANSAC ----------
function ransacH(src, dst, iters = 60, thresh = 2.5) {
  const n = src.length;
  let bestIn = null, bestCount = 0;
  const t2 = thresh * thresh;
  for (let it = 0; it < iters; it++) {
    const idx = new Set();
    while (idx.size < 4) idx.add((Math.random() * n) | 0);
    const ids = [...idx];
    const H = homography(ids.map(i => src[i]), ids.map(i => dst[i]));
    if (!H) continue;
    const inl = [];
    for (let i = 0; i < n; i++) {
      const p = applyH(H, src[i]), dx = p[0] - dst[i][0], dy = p[1] - dst[i][1];
      if (dx * dx + dy * dy < t2) inl.push(i);
    }
    if (inl.length > bestCount) { bestCount = inl.length; bestIn = inl; if (bestCount > 0.9 * n) break; }
  }
  if (!bestIn || bestCount < 8) return null;
  let H = homographyLS(bestIn.map(i => src[i]), bestIn.map(i => dst[i]));
  if (!H) return null;
  // one re-weighting pass on the refined model
  const inl = [];
  for (let i = 0; i < n; i++) {
    const p = applyH(H, src[i]), dx = p[0] - dst[i][0], dy = p[1] - dst[i][1];
    if (dx * dx + dy * dy < t2) inl.push(i);
  }
  if (inl.length >= 8) H = homographyLS(inl.map(i => src[i]), inl.map(i => dst[i])) || H;
  return { H, inliers: inl };
}

// ---------- tracker ----------
export class QRTracker {
  constructor({ maxFeatures = 80, minFeatures = 12, refillBelow = 45 } = {}) {
    Object.assign(this, { maxFeatures, minFeatures, refillBelow });
    this.reset();
  }
  reset() { this.feats = null; this.pyr = null; this.H = null; this.prevH = null; }
  get active() { return !!this.feats; }

  // pyr: pyramid of the frame where `corners` (TL,TR,BR,BL in level-0 px) were measured.
  init(pyr, corners) {
    const H = homography(QR_SQUARE, corners);
    if (!H) return false;
    const feats = selectFeatures(pyr[0], H, this.maxFeatures);
    if (feats.length < this.minFeatures) return false;
    this.feats = feats; this.pyr = pyr; this.H = H; this.prevH = H;
    return true;
  }

  // Advance to a new frame. Returns corners (level-0 px) or null if lost.
  update(pyr) {
    if (!this.feats) return null;
    // constant-velocity prediction of the homography gives LK a good starting guess
    let guess = null;
    if (this.prevH && this.H !== this.prevH) {
      guess = this.feats.map(f => {
        const a = applyH(this.prevH, f.plane), b = applyH(this.H, f.plane);
        return [2 * b[0] - a[0], 2 * b[1] - a[1]];
      });
    }
    const { pts, ok } = trackPoints(this.pyr, pyr, this.feats.map(f => f.img), guess);
    const src = [], dst = [], keep = [];
    for (let i = 0; i < pts.length; i++) if (ok[i]) { src.push(this.feats[i].plane); dst.push(pts[i]); keep.push(i); }
    if (src.length < this.minFeatures) { this.reset(); return null; }
    const fit = ransacH(src, dst);
    if (!fit || fit.inliers.length < this.minFeatures) { this.reset(); return null; }
    const H = fit.H;
    let feats = fit.inliers.map(j => ({ img: dst[j], plane: src[j] }));
    // top up features when many were lost (motion blur, occlusion)
    if (feats.length < this.refillBelow) {
      const fresh = selectFeatures(pyr[0], H, this.maxFeatures);
      const minD = 4;
      for (const f of fresh) {
        if (feats.length >= this.maxFeatures) break;
        if (feats.every(g => Math.abs(g.img[0] - f.img[0]) + Math.abs(g.img[1] - f.img[1]) > minD)) feats.push(f);
      }
    }
    this.feats = feats; this.pyr = pyr; this.prevH = this.H; this.H = H;
    return QR_SQUARE.map(p => applyH(H, p));
  }
}
