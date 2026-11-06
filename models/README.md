# Put your 3D models here

1. Copy your `.glb` file into this folder, e.g. `models/dragon.glb`.
2. Add an entry to `models.json` in the repo root:

```json
"dragon": { "name": "Dragon", "file": "models/dragon.glb" }
```

3. Open `qr.html` on the live site to print the QR code for it.

Tips:
- Supported formats: `.glb` (best), `.gltf`, `.fbx`.
- `.fbx` works too, but files are larger and slower to load on phones. When exporting FBX, enable
  **Embed Media / Embed Textures**, or copy the texture images into this folder next to the `.fbx`.
- Keep models under ~10 MB so they load quickly on phones.
- Export from Blender with **File → Export → glTF 2.0**, format **glTF Binary (.glb)**.
