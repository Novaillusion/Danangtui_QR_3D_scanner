# Put your 3D models here

1. Copy your `.glb` file into this folder, e.g. `models/dragon.glb`.
2. Add an entry to `models.json` in the repo root:

```json
"dragon": { "name": "Dragon", "file": "models/dragon.glb" }
```

3. Open `qr.html` on the live site to print the QR code for it.

Tips:
- Use `.glb` (single file). Keep it under ~10 MB so it loads quickly on phones.
- Export from Blender with **File → Export → glTF 2.0**, format **glTF Binary (.glb)**.
