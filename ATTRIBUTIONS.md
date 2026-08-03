# Attributions

**This game contains no third-party assets.** No fonts, no textures, no images, no sounds, no
models, no editor plugins. Verified rather than assumed — `assets/` is the application icon and
nothing else, `art/` is one `.blend` and four shaders, there is no `addons/` directory, and the
repository contains no `.wav`, `.ogg`, `.mp3`, `.ttf` or `.otf` file of any kind. The HUD's
typeface is `HudSkin.font()`, which returns Godot's own built-in font.

So the licensing pass is one item: the engine.

## Godot Engine

Built with [Godot Engine](https://godotengine.org) 4.7, redistributed inside the exported
application under the MIT License.

```
Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### The engine's own dependencies

Godot bundles **102** third-party components of its own — FreeType, Mesa, zlib, Thorvg and the
rest — each under its own permissive licence. Reproducing that list here would be a copy that
goes stale the first time the engine is updated, so it is not copied: the engine carries it, and
the authoritative version for whichever build shipped is available at runtime through
`Engine.get_copyright_info()` and `Engine.get_license_info()`.

The number above came from asking the engine, not from counting.

## Our own work

Everything else in this repository — code, shaders, the mouse model, the icon, the design
documents — is original to this project.
