import AppKit

/// User-authored post-process shaders: `.metal` files in
/// ~/.config/cmdy/shaders/, compiled at runtime and hot-reloaded on save —
/// edit in your editor, save, watch the terminal restyle live.
/// A user shader is selected as `shader = user/<filename>` in the config.
public enum UserShaders {

    public static var directory: URL {
        ConfigFile.directory.appendingPathComponent("shaders", isDirectory: true)
    }

    /// Gallery names for every user shader on disk ("user/<stem>").
    public static var names: [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "metal" }
            .map { "user/" + $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Source for a gallery name ("user/foo" → shaders/foo.metal).
    public static func source(named name: String) -> String? {
        guard name.hasPrefix("user/") else { return nil }
        let stem = String(name.dropFirst("user/".count))
        let url = directory.appendingPathComponent(stem + ".metal")
        return try? BoundedFileReader.utf8String(
            at: url, maxBytes: 4 * 1024 * 1024)
    }

    /// Scaffold a fresh documented shader, select it, and open it in the
    /// user's editor — save the file and the terminal restyles live.
    public static func createAndEdit() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stem = "myshader"
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".metal").path) {
            stem = "myshader\(n)"
            n += 1
        }
        let url = directory.appendingPathComponent(stem + ".metal")
        try? template.write(to: url, atomically: true, encoding: .utf8)
        Preferences.shared.shaderName = "user/" + stem
        NSWorkspace.shared.open(url)
    }

    /// The starter file — the docs live in the file itself.
    public static let template = """
    // cmdy user shader — edit, save, and the terminal restyles live.
    //
    // You implement one function, cmdy_main. It runs per pixel, after the
    // terminal scene has rendered, and returns the final color.
    //
    //   uv          0…1 across the pane (x right, y DOWN)
    //   sceneColor  what the terminal drew at this pixel (text + background)
    //   u.resolution   drawable size in device pixels
    //   u.time         seconds, always ticking — animate with it
    //   u.background   the theme's background color (float4)
    //   u.cursor       cursor center in pixels (y-down) — spotlight it!
    //   u.keypressAge  seconds since the last keypress (10 = idle)
    //   u.typingRate   keys/sec over the last 2s — typing energy
    //   scene, smp     the scene texture + sampler, for displacement effects:
    //                  scene.sample(smp, uv + offset)
    //
    // Helpers included for free:
    //   cmdy_hash(p)      cheap noise
    //   cmdy_palette(t)   smooth rainbow palette
    //   cmdy_textMask(rgb, bg)  0 = background pixel, 1 = text pixel.
    //     Draw effects BEHIND text with:
    //     mix(u.background.rgb + effect, sceneColor.rgb, mask)
    //
    // Keep it pure math — no textures/files. Compile errors show up as a
    // notification; fix and save again.

    float4 cmdy_main(float2 uv, float4 sceneColor,
                        constant CmdyUniforms &u,
                        texture2d<float> scene, sampler smp) {
        float3 rgb = sceneColor.rgb;
        float mask = cmdy_textMask(rgb, u.background.rgb);

        // --- decorative: a slow color wash drifting behind the text ---
        float2 sq = (uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
        float3 wash = cmdy_palette(sq.x * 0.25 + u.time * 0.05) * 0.15;

        // --- responsive: the cursor glows, typing pumps it ---
        float2 pp = uv * u.resolution;
        float d = distance(pp, u.cursor);
        float energy = clamp(u.typingRate / 6.0, 0.0, 1.0);
        float glow = exp(-d / 120.0) * (0.08 + 0.25 * energy) * exp(-u.keypressAge * 0.8);

        rgb = mix(u.background.rgb + wash + glow, rgb, mask);
        rgb += glow * 0.3;   // let the glow kiss the glyphs too
        return float4(rgb, sceneColor.a);
    }
    """
}
