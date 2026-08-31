# Writing cmdy shaders

cmdy's post-process shaders are real Metal fragment passes. Beyond the 68
built-ins (including the calm set — thirty slow, muted, ambient fields meant
to be lived with for hours), you can write your own — **edit, save, and the
terminal restyles live**.

## Quick start

1. Command palette (⌘⇧P) → Appearance → Shaders → **New User Shader…**
   (or View ▸ Shader ▸ Browse with Preview… and pick it later).
   This scaffolds `~/.config/cmdy/shaders/myshader.metal`, selects it,
   and opens it in your editor.
2. Edit. Save. Every open terminal recompiles and repaints within ~200ms.
3. Compile errors arrive as a notification (and in the log) — fix, save again.

Select any user shader with `shader = user/<filename>` in the config, from
View ▸ Shader, the palette, or the Config Mixer — they preview live like the
built-ins.

## The contract

You implement one function; it runs per pixel after the terminal scene has
rendered:

```metal
float4 cmdy_main(float2 uv, float4 sceneColor,
                    constant CmdyUniforms &u,
                    texture2d<float> scene, sampler smp)
```

| input | meaning |
|---|---|
| `uv` | 0…1 across the pane; x right, y **down** |
| `sceneColor` | what the terminal drew at this pixel (text + background) |
| `u.resolution` | drawable size in device pixels |
| `u.time` | seconds, always ticking (~30fps) — animate with it |
| `u.background` | the theme's background color |
| `u.cursor` | cursor center in pixels (y-down) |
| `u.keypressAge` | seconds since the last keypress (10 = idle) |
| `u.typingRate` | keys/sec over the last 2 seconds |
| `scene`, `smp` | the scene texture + sampler — sample at shifted uv for displacement/chroma effects |

Free helpers: `cmdy_hash(p)` (noise), `cmdy_palette(t)` (rainbow),
and the important one:

```metal
float mask = cmdy_textMask(sceneColor.rgb, u.background.rgb);
// 0 = background pixel, 1 = text. Keep effects BEHIND the text:
rgb = mix(u.background.rgb + effect, sceneColor.rgb, mask);
```

## Recipes

**Decorative** — a drifting color field behind the text:
```metal
float2 sq = (uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
float3 wash = cmdy_palette(sq.x * 0.3 + u.time * 0.05) * 0.2;
```

**Key-reactive** — flash on every keystroke:
```metal
float pulse = exp(-u.keypressAge * 6.0) * 0.3;   // decays after each key
```

**Cursor-aware** — a spotlight that follows the cursor:
```metal
float d = distance(uv * u.resolution, u.cursor);
float glow = exp(-d / 150.0) * 0.25;
```

**Typing energy** — the harder you type, the wilder it gets:
```metal
float energy = clamp(u.typingRate / 6.0, 0.0, 1.0);
```

**Displacement** — bend the picture itself:
```metal
float2 wobble = float2(sin(uv.y * 30.0 + u.time * 2.0) * 2.0 / u.resolution.x, 0.0);
float4 bent = scene.sample(smp, uv + wobble);
```

Compose freely — the bundled `Ripple`, `Starfield`, `Boot` and `Snow` are all
just these ingredients. Aspect-correct radial geometry with
`(uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0)` so circles stay
circles. Keep it pure math: no file/texture loading, one pass, runs per pixel
at 30fps.
