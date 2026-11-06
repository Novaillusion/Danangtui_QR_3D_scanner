# Danangtui QR 3D Scanner

Browser-based AR: point your phone at any QR code and a 3D model appears standing on top of it.

**Live:** https://novaillusion.github.io/Danangtui_QR_3D_scanner/

## Features
- Works in the browser – no app install (Chrome, Safari, Firefox on phone or desktop)
- Each model is linked to its own QR code; other QR codes show nothing
- Tracks the code's position and tilt every frame and anchors the model to it
- Scanning a code with the phone's normal camera app opens the viewer

## Adding your own models
1. Put your model in the `models/` folder (e.g. `models/dragon.glb`). Supported: `.glb` (recommended), `.gltf`, `.fbx`.
   For `.fbx`, embed the textures when exporting, or put the texture files next to the `.fbx` in `models/`.
2. Add an entry to [`models.json`](models.json). The key (`dragon`) becomes part of the QR code:
   ```json
   "dragon": { "name": "Dragon", "file": "models/dragon.glb" }
   ```
   Optional settings per model:
   | field | meaning | default |
   |---|---|---|
   | `scale` | size multiplier (1 = fits the QR code) | `1` |
   | `rotationY` | turn the model, in degrees | `0` |
   | `offsetY` | lift above the code, in QR widths | `0` |
   | `animation` | animation name or number to play | first one |
3. Commit and push. Then open **[qr.html](https://novaillusion.github.io/Danangtui_QR_3D_scanner/qr.html)**
   to print or download the QR code for each model.

Each QR code contains `https://novaillusion.github.io/Danangtui_QR_3D_scanner/?m=<key>`.
To remove a model, delete its entry; its old printed codes then show nothing.

## How it works
1. **Find** – [jsQR](https://github.com/cozmo/jsQR) decodes the QR code in a Web Worker and returns its four corners.
2. **Track** – `tracker.js` follows ~80 feature points inside the code from frame to frame with pyramidal
   Lucas–Kanade optical flow and fits a homography with RANSAC (≈5–10 ms per frame), so the model
   updates on every camera frame instead of waiting for a slow decode.
3. **Correct** – jsQR re-checks the code a few times per second to read its text and fix any drift.
4. **Render** – the homography gives the camera pose of the code; [three.js](https://threejs.org) draws the
   model over the exact camera frame that was tracked, so model and video never drift apart.

## Notes
- Camera access requires HTTPS (GitHub Pages is fine) or `localhost`.
- If the model looks slightly too near or far, adjust `ASSUMED_FOV_DEG` in `index.html`.
- Best results: printed code ≥ 5 cm wide, good lighting.

## Run locally
```
npx serve .
```
then open http://localhost:3000
