const {test} = require('node:test');
const assert = require('node:assert/strict');
require('../ForcedDark/colors.js');
const C = globalThis.ForcedDarkColors;
const near = (actual,expected,epsilon=0.001) => actual.forEach((x,i) => assert.ok(Math.abs(x-expected[i]) < epsilon, `${actual} ≈ ${expected}`));

test('Chromium D50 Lab conversion round trips sRGB and alpha', () => {
  for (const rgb of [[1,1,1,1],[0,0,0,1],[1,0,0,0.3],[0,0.5,0.7,1],[0.4,0.2,0.9,0.5]]) {
    near(C.fromLab(C.toLab(rgb),rgb[3]),rgb);
  }
  near(C.toLab([1,1,1,1]),[100,0,0]);
});
test('Chromium lightness inversion uses 110 − L, capped at 100', () => {
  near(C.invert([0,0,0,0.4]),[1,1,1,0.4]);
  const input = C.parse('#008877');
  const lab = C.toLab(input);
  near(C.invert(input),C.fromLab([Math.min(110-lab[0],100),lab[1],lab[2]],1));
});
test('dark authored canvases are detected before page transformation', () => {
  assert.equal(C.isDark(C.parse('#202124')),true);
  assert.equal(C.isDark(C.parse('#121212')),true);
  assert.equal(C.isDark(C.parse('#808080')),false);
  assert.equal(C.isDark(C.parse('#ffffff')),false);
  assert.equal(C.isDark(null),false);
});
test('light neutral surfaces use the custom background and retain alpha', () => {
  const surface = C.parse('#181c20');
  near(C.background([1,1,1,0.6],surface),[...surface.slice(0,3),0.6]);
  near(C.background(C.parse('#101e28'),surface),C.parse('#101e28'));
  near(C.background([0,0,0,0],surface),[0,0,0,0]);
});
test('foreground detection preserves readable light text and lifts dark text', () => {
  const dark = C.parse('#121212');
  near(C.foreground(C.parse('#ffffff'),dark),C.parse('#ffffff'));
  assert.ok(C.contrast(C.foreground(C.parse('#222222'),dark),dark)>10);
  const light = C.parse('#ffffff');
  near(C.foreground(C.parse('#222222'),light),C.parse('#222222'));
});
test('malformed and bright preferences cannot inject CSS or break contrast', () => {
  assert.deepEqual(C.settings({background:'red;display:none',enabled:false}),{background:'#121212',enabled:false});
  assert.equal(C.settings({background:'#ffffff'}).background,'#121212');
  assert.equal(C.settings({background:'#17211c'}).background,'#17211c');
  assert.deepEqual(C.settings(),C.defaults);
});
test('computed sRGB syntax preserves alpha', () => {
  near(C.parse('rgba(255, 128, 0, 0.5)'),[1,128/255,0,0.5]);
  near(C.parse('rgb(100% 0% 0% / 25%)'),[1,0,0,0.25]);
  near(C.parse('color(srgb 0.1 0.2 0.3 / 0.4)'),[0.1,0.2,0.3,0.4]);
  assert.equal(C.parse('color(display-p3 1 0 0)'),null);
});

test('low-contrast chromatic text reaches AA without changing alpha', () => {
  for (const background of ['#121212','#181c20','#17211c','#211c19','#000000']) {
    for (const foreground of ['#0000ff','#555555','#777777','#993344','#008877']) {
      const bg = C.parse(background);
      const result = C.foreground(C.parse(foreground),bg);
      const rounded = C.parse(C.css(result));
      assert.ok(C.contrast(rounded,bg) >= 4.5, `${foreground} on ${background}: ${C.contrast(rounded,bg)}`);
      assert.equal(result[3],1);
    }
  }
});

test('modern Lab colors retain readable foreground/background pairing', () => {
  near(C.parse('lab(100 0 0)'),[1,1,1,1]);
  const surface = C.parse('#121212');
  const card = C.background(C.parse('lab(97.194298 1.38536 0.498641)'),surface);
  const text = C.foreground(C.parse('lab(2.33353 10.3966 3.72023)'),card);
  assert.ok(C.contrast(text,card) >= 4.5);
  near(C.parse('lab(50% 0 0 / 25%)'),C.fromLab([50,0,0],0.25));
});
