// CanvasRenderingContext2D.filter is unavailable in WebKit. Keep the upstream
// projector's bitmap dimensions, padding and Gaussian sigma, and blur the same
// premultiplied pixels in two GPU passes before they are scaled onto the page.
export default class CanvasBlur {
  constructor() {
    this.canvas = document.createElement('canvas');
    this.gl = this.canvas.getContext('webgl', {
      alpha: true,
      premultipliedAlpha: true,
      antialias: false,
      depth: false,
      stencil: false,
    });
    if (!this.gl) throw new Error('Cannot create the canvas blur renderer');
    this.canvas.addEventListener('webglcontextlost', (event) => {
      event.preventDefault();
      this.ready = false;
    });
    this.canvas.addEventListener('webglcontextrestored', () => {
      this.ready = false;
    });
  }

  initialize() {
    const gl = this.gl;
    const compile = (type, source) => {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        throw new Error(gl.getShaderInfoLog(shader));
      }
      return shader;
    };
    const vertex = compile(gl.VERTEX_SHADER, `
      attribute vec2 position;
      varying vec2 uv;
      void main() {
        uv = (position + 1.0) * 0.5;
        gl_Position = vec4(position, 0.0, 1.0);
      }
    `);
    const fragment = compile(gl.FRAGMENT_SHADER, `
      precision highp float;
      uniform sampler2D image;
      uniform vec2 stepSize;
      uniform float sigma;
      varying vec2 uv;
      vec4 samplePixel(vec2 point) {
        if (point.x < 0.0 || point.x > 1.0 || point.y < 0.0 || point.y > 1.0)
          return vec4(0.0);
        return texture2D(image, point);
      }
      void main() {
        vec4 color = samplePixel(uv);
        float total = 1.0;
        for (int i = 1; i <= 32; i++) {
          float distance = float(i);
          if (distance > ceil(sigma * 3.0)) break;
          float weight = exp(-distance * distance / (2.0 * sigma * sigma));
          vec2 offset = stepSize * distance;
          color += (samplePixel(uv - offset) + samplePixel(uv + offset)) * weight;
          total += 2.0 * weight;
        }
        gl_FragColor = color / total;
      }
    `);
    this.program = gl.createProgram();
    gl.attachShader(this.program, vertex);
    gl.attachShader(this.program, fragment);
    gl.linkProgram(this.program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(this.program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(this.program));
    }
    gl.useProgram(this.program);
    this.vertices = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vertices);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(this.program, 'position');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    this.stepLocation = gl.getUniformLocation(this.program, 'stepSize');
    this.sigmaLocation = gl.getUniformLocation(this.program, 'sigma');
    this.textures = [0, 1].map(() => {
      const texture = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      return texture;
    });
    this.framebuffer = gl.createFramebuffer();
    this.width = this.height = 0;
    this.ready = true;
  }

  apply(canvas, context, sigma) {
    if (!(sigma > 0) || this.gl.isContextLost()) return;
    if (!this.ready) this.initialize();
    const gl = this.gl;
    // Bound the shader kernel for large blur settings without truncating sigma.
    const scale = Math.max(1, sigma / 8);
    const width = Math.max(1, Math.ceil(canvas.width / scale));
    const height = Math.max(1, Math.ceil(canvas.height / scale));
    if (width !== this.width || height !== this.height) {
      this.canvas.width = this.width = width;
      this.canvas.height = this.height = height;
      gl.bindTexture(gl.TEXTURE_2D, this.textures[1]);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, this.framebuffer);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.textures[1], 0);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
        throw new Error('Cannot allocate the canvas blur buffer');
      }
    }
    gl.viewport(0, 0, width, height);
    gl.bindTexture(gl.TEXTURE_2D, this.textures[0]);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvas);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.framebuffer);
    gl.uniform1f(this.sigmaLocation, sigma * width / canvas.width);
    gl.uniform2f(this.stepLocation, 1 / width, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.bindTexture(gl.TEXTURE_2D, this.textures[1]);
    gl.uniform1f(this.sigmaLocation, sigma * height / canvas.height);
    gl.uniform2f(this.stepLocation, 0, 1 / height);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(this.canvas, 0, 0, canvas.width, canvas.height);
  }

  dispose() {
    this.gl.getExtension('WEBGL_lose_context')?.loseContext();
    this.ready = false;
  }
}
