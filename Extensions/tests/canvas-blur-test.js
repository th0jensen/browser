// Pixel comparison with a separable Gaussian reference, independent of the GPU.
(() => {
  const blur = new window.CanvasBlur();
  const results = [];
  for (const [width, height, sigma] of [[64, 64, 0], [64, 64, 2], [96, 64, 6], [128, 96, 8]]) {
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = 'red';
    ctx.fillRect(19, 25, 12, 8);
    const radius = Math.ceil(sigma * 3);
    const weights = Array.from({ length: 2 * radius + 1 }, (_, i) =>
      sigma ? Math.exp(-((i - radius) ** 2) / (2 * sigma * sigma)) : 1);
    const total = weights.reduce((sum, value) => sum + value, 0);
    const weight = (distance) => Math.abs(distance) <= radius ? weights[distance + radius] / total : 0;
    blur.apply(canvas, ctx, sigma);
    const pixels = ctx.getImageData(0, 0, width, height).data;
    let maxError = 0;
    let coloredPixels = 0;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        let horizontal = 0;
        let vertical = 0;
        for (let sx = 19; sx < 31; sx++) horizontal += weight(x - sx);
        for (let sy = 25; sy < 33; sy++) vertical += weight(y - sy);
        const alpha = pixels[(y * width + x) * 4 + 3];
        maxError = Math.max(maxError, Math.abs(alpha - horizontal * vertical * 255));
        // Blurring transparent pixels must preserve premultiplied color: no dark halo.
        if (alpha > 8) {
          const index = (y * width + x) * 4;
          if (pixels[index] < 250 || pixels[index + 1] || pixels[index + 2]) {
            throw new Error('Blur changed the source color or introduced a dark halo');
          }
          coloredPixels++;
        }
      }
    }
    if (maxError > 2 || !coloredPixels) throw new Error(`Gaussian mismatch at sigma ${sigma}: ${maxError}`);
    results.push({ width, height, sigma, maxAlphaError: maxError });
  }
  // High sigma uses a smaller buffer; ensure resizing it back restores sharp detail.
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 256;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = 'red';
  ctx.fillRect(96, 96, 64, 64);
  blur.apply(canvas, ctx, 32);
  if (ctx.getImageData(80, 128, 1, 1).data[3] === 0) throw new Error('Large blur was truncated');
  if (ctx.getImageData(128, 128, 1, 1).data[3] >= 220) throw new Error('Large blur did not soften the image');
  blur.dispose();
  return results;
})()
