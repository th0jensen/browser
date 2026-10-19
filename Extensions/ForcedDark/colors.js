/* Chromium CIELAB transform port. See NOTICE for sources and license. */
(() => {
  "use strict";
  const clamp = (x, low = 0, high = 1) => Math.min(high, Math.max(low, x));
  const multiply = (m, v) => m.map(row => row.reduce((sum, x, i) => sum + x * v[i], 0));
  const product = (a, b) => a.map(row => b[0].map((_, j) => row.reduce((sum, x, k) => sum + x * b[k][j], 0)));
  function inverse(m) {
    const [[a,b,c],[d,e,f],[g,h,i]] = m;
    const determinant = a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g);
    return [[e*i-f*h,c*h-b*i,b*f-c*e],[f*g-d*i,a*i-c*g,c*d-a*f],[d*h-e*g,b*g-a*h,a*e-b*d]]
      .map(row => row.map(x => x / determinant));
  }
  const white = [0.964212, 1, 0.825188];
  const bradford = [[0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]];
  const source = multiply(bradford, [0.95042855,1,1.0889004]);
  const destination = multiply(bradford, white);
  const adaptation = product(inverse(bradford), bradford.map((row, i) => row.map(x => x * destination[i] / source[i])));
  const xyz = product(adaptation, [[0.41238642,0.3575915,0.18045056],[0.21263677,0.715183,0.07218022],[0.019330615,0.11919712,0.95037293]]);
  const rgb = inverse(xyz);
  const linear = x => x < 0.04045 ? clamp(x / 12.92) : clamp(((x + 0.055) / 1.055) ** 2.4);
  const gamma = x => clamp(x < 0.0031308 ? 12.92 * x : 1.055 * x ** (1 / 2.4) - 0.055);
  const sigma = 6 / 29;
  const f = x => x > sigma ** 3 ? Math.cbrt(x) : x / (3 * sigma ** 2) + 4 / 29;
  const invf = x => x > sigma ? x ** 3 : 3 * sigma ** 2 * (x - 4 / 29);
  function toLab(color) {
    const [x,y,z] = multiply(xyz, color.slice(0,3).map(linear)).map((x,i) => f(x / white[i]));
    return [clamp(116*y-16,0,100),clamp(500*(x-y),-128,128),clamp(200*(y-z),-128,128)];
  }
  function fromLab([l,a,b], alpha = 1) {
    const y = (clamp(l,0,100)+16)/116;
    return [...multiply(rgb, [invf(y+clamp(a,-128,128)/500)*white[0], invf(y), invf(y-clamp(b,-128,128)/200)*white[2]]).map(gamma),alpha];
  }
  function invert(color) {
    const lab = toLab(color);
    lab[0] = Math.min(110 - lab[0],100);
    const result = fromLab(lab, color[3]);
    // Chromium's AdjustGray: map low neutral grays to Material's #121212.
    if (Math.max(...result.slice(0,3))-Math.min(...result.slice(0,3)) < 1e-6 && result[0] < 32/255 && result[0] > 18/255) {
      return [18/255,18/255,18/255,color[3]];
    }
    return result;
  }
  function parse(value) {
    if (!value || value === "none") return null;
    if (value === "transparent") return [0,0,0,0];
    if (/^#[\da-f]{6}$/i.test(value)) return [1,3,5].map(i => parseInt(value.slice(i,i+2),16)/255).concat(1);
    const match = value.match(/^(rgba?|color)\((.*)\)$/i);
    if (!match) return null;
    const srgb = match[1] === "color" && match[2].startsWith("srgb ");
    if (match[1] === "color" && !srgb) return null;
    const parts = match[2].replace(/^srgb /, "").split(/[\s,\/]+/).filter(Boolean);
    if (parts.length < 3) return null;
    const values = parts.map((x,i) => clamp(parseFloat(x)/(x.endsWith("%") ? 100 : (i < 3 && !srgb ? 255 : 1))));
    return values.every(Number.isFinite) ? [...values.slice(0,3),values[3] ?? 1] : null;
  }
  const css = c => `rgba(${c.slice(0,3).map(x => Math.round(clamp(x)*255)).join(", ")}, ${clamp(c[3] ?? 1)})`;
  const luminance = c => c.slice(0,3).map(linear).reduce((sum,x,i) => sum+x*[0.2126,0.7152,0.0722][i],0);
  const composite = (front, back) => [...front.slice(0,3).map((x,i) => x*front[3]+back[i]*(1-front[3])),1];
  const contrast = (a,b) => (Math.max(luminance(a),luminance(b))+0.05)/(Math.min(luminance(a),luminance(b))+0.05);
  function background(color, surface) {
    if (!color || color[3] === 0) return color;
    const lab = toLab(color);
    // Dark authored surfaces stay dark; pale tints retain their chroma. Neutral
    // whites map to the chosen surface instead of accumulating muddy gray.
    if (lab[0] < 50) return color;
    const transformed = invert(color);
    if (Math.hypot(lab[1],lab[2]) < 12 && lab[0] > 80) {
      const lift = (100-lab[0])*0.002;
      return [...surface.slice(0,3).map(x => clamp(x+lift)),color[3]];
    }
    return transformed;
  }
  function foreground(color, backdrop) {
    if (!color || color[3] === 0) return color;
    const transformed = invert(color);
    // Compare after alpha compositing: translucent text and already-dark panels
    // must be classified against what is actually behind them.
    const originalContrast = contrast(composite(color,backdrop),backdrop);
    const invertedContrast = contrast(composite(transformed,backdrop),backdrop);
    const best = originalContrast >= 4.5 || originalContrast >= invertedContrast ? color : transformed;
    if (contrast(composite(best,backdrop),backdrop) >= 4.6) return best;
    // Preserve chroma and alpha, moving only lightness when inversion alone
    // leaves text below WCAG AA. A small margin survives 8-bit CSS rounding.
    const lab = toLab(best);
    const target = luminance(backdrop) > 0.179 ? 0 : 100;
    let low = 0, high = 1;
    let readable = fromLab([target,lab[1],lab[2]],best[3]);
    if (contrast(composite(readable,backdrop),backdrop) < 4.6) return best;
    for (let i = 0; i < 14; i++) {
      const amount = (low+high)/2;
      const candidate = fromLab([lab[0]+(target-lab[0])*amount,lab[1],lab[2]],best[3]);
      if (contrast(composite(candidate,backdrop),backdrop) >= 4.6) { readable = candidate; high = amount; }
      else low = amount;
    }
    return readable;
  }
  const defaults = Object.freeze({enabled:true, background:"#121212"});
  function settings(value = {}) {
    if (!value || typeof value !== "object") value = {};
    return {enabled:typeof value.enabled === "boolean" ? value.enabled : true,
      background:/^#[\da-f]{6}$/i.test(value.background) && toLab(parse(value.background))[0] <= 45 ? value.background : defaults.background};
  }
  globalThis.ForcedDarkColors = Object.freeze({parse,css,invert,toLab,fromLab,background,foreground,composite,contrast,settings,defaults});
})();
