# WeGit v2 image generation prompts

Built-in image_gen; generated originals are preserved unmodified in generated/.

## mark

```text
Use case: logo-brand
Asset type: standalone vector-friendly brand symbol for WeGit, a refined native macOS Git client.
Create ONE original finished symbol, no presentation board or variations. Genuine transparent background, square canvas, generous clear space.
Design: a beautifully proportioned continuous uppercase W monogram made from a single precise medium-weight path with softly rounded internal turns and restrained rounded terminals. Four diagonal legs make the W instantly recognizable. A single very short branching path emerges near the upper-right leg, terminating in ONE small commit node integrated into the silhouette. It suggests version-control branching as a quiet secondary detail. No central upright stalk. No four big circles, no crown silhouette. Slight purposeful asymmetry only from the small right-side fork; the main W must remain balanced.
Optical style: meticulous custom geometric logomark for an excellent professional Apple-platform developer tool. Calm, clean, confident, distinctive in silhouette; open counters and smooth continuous curvature. Width of the mark about 66% of the canvas. A little lighter than a bold font, never hairline. The node is only slightly wider than the path, never a large ball.
Color: one solid rich cobalt blue #2463DB. Flat solid fill, absolutely NO gradient, NO shading, NO glass, NO bevel or background tile. No text, no letters beyond the W symbol itself, no watermark, no checkerboard drawn into the art.
Output: high-resolution clean transparent PNG of the isolated mark, suitable for later precise vector reconstruction and app-icon development.
```

## refine

```text
Use case: logo-brand
Input image 1 is the edit target: the new cobalt WeGit W symbol on transparency.
Refine only the symbol geometry. Preserve the basic continuous W, rich cobalt blue, transparent background, square composition, and overall identity.
Make the path approximately 30 percent thinner and the turns more controlled, less inflated. Keep enough weight for 16px rendering.
CRITICAL: replace the single curving stalk at upper right with a clearly recognizable tiny Y-shaped Git fork. The main upper-right diagonal leg should end in a clean rounded terminal. A second short diagonal stem must emerge from that leg BELOW its main terminal, diverging toward the upper-right and ending in one small solid node. Two separate terminal tips with open negative space between them. Main terminal has NO circle; only the secondary fork endpoint has a small circle approximately 1.15 times path thickness. No other nodes anywhere. No central vertical stalk. Do not turn the fork into a molecule, crown, antenna, or arrow.
The finished mark should feel optically balanced, precise, understated, custom-designed and effortlessly legible. Occupy about 66 percent of canvas width and center by visual mass, allowing a little extra headroom for the fork.
Flat single-color #2463DB, no gradient or texture, no 3D, no background tile, no text, no watermark, genuine transparent background.
```

## icon

```text
Use case: logo-brand
Asset type: finished macOS application icon for WeGit.
Input image 1 is a SHAPE REFERENCE: use its exact W-with-one-small-right-fork identity, rounded continuous W and a clear two-tip Git fork on upper right. Keep its recognizable silhouette, but optically center it.
Create ONE premium app icon, front view, square composition, genuine transparent exterior around a native rounded-square enclosure. No scene, no pedestal, no perspective mockup.
Enclosure: rich deep cobalt blue, subtle top-to-bottom tonal variation, a precisely softened continuous corner shape and a very narrow restrained light-catching rim. Quiet fine material, no neon.
Foreground: the reference W in cool pearl white, subtle translucent enamel / satin glass, shallow physical depth, almost-flat face with a precise bright upper edge and a tiny soft contact shadow. White body should remain clearly readable, never a transparent outline. Keep the node small and integrated; no extra dots. Mark occupies about 65 to 68 percent of tile width with generous balanced padding.
Lighting: soft studio light from above, calm, carefully crafted, native Apple-platform quality. Keep all highlights very controlled. No rainbow, no chrome, no thick bevel, no lens flare, no inner nested square, no outer drop shadow halo, no text, no Apple logo, no watermark.
High-resolution square PNG with true alpha outside the rounded-square icon.
```

## dark

```text
Use case: logo-brand
Asset type: DARK appearance companion to this WeGit macOS application icon.
Input image 1 is the edit target. Preserve the exact W-and-small-fork silhouette, the centered placement, proportions, front view, rounded-square enclosure, and transparent exterior. This is the SAME icon in dark appearance.
Change the enclosure from vivid cobalt blue to deep neutral graphite #171B24 with a restrained midnight-blue undertone near its lower edge. Reduce the intensity of the outer rim to a fine cool edge light. Keep the W pearl-white with a subtle cool-blue reflected edge, shallow satin glass depth and very soft compact contact shadow. Reduce glossy contrast slightly for a calm dark macOS desktop.
No neon glow, no rainbow, no thick metal/chrome bevel, no additional shapes, no text, no Apple logo, no mockup scene, no background outside the rounded square. Genuine transparent background.
One finished high-resolution square app icon, exactly matching the identity of the reference.
```
