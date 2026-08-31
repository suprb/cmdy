declare module "ogl" {
  type Uniform = { value: unknown };

  export class Renderer {
    gl: WebGL2RenderingContext;
    isWebgl2: boolean;
    constructor(options?: {
      alpha?: boolean;
      antialias?: boolean;
      canvas?: HTMLCanvasElement;
      depth?: boolean;
      dpr?: number;
      powerPreference?: WebGLPowerPreference;
      stencil?: boolean;
    });
    render(options: { scene: Mesh; target?: RenderTarget }): void;
    setSize(width: number, height: number): void;
  }

  export class Plane {
    constructor(gl: WebGL2RenderingContext, options?: { height?: number; width?: number });
  }

  export class Program {
    uniforms: Record<string, Uniform>;
    constructor(gl: WebGL2RenderingContext, options: {
      depthTest?: boolean;
      depthWrite?: boolean;
      fragment: string;
      transparent?: boolean;
      uniforms?: Record<string, Uniform>;
      vertex: string;
    });
  }

  export class Mesh {
    constructor(gl: WebGL2RenderingContext, options: { geometry: Plane; program: Program });
  }

  export class Texture {
    image?: HTMLVideoElement;
    needsUpdate: boolean;
    texture: WebGLTexture;
    constructor(gl: WebGL2RenderingContext, options?: {
      flipY?: boolean;
      generateMipmaps?: boolean;
      image?: HTMLVideoElement;
      magFilter?: number;
      minFilter?: number;
    });
  }

  export class RenderTarget {
    texture: Texture;
    constructor(gl: WebGL2RenderingContext, options?: {
      depth?: boolean;
      height?: number;
      magFilter?: number;
      minFilter?: number;
      width?: number;
    });
  }
}
