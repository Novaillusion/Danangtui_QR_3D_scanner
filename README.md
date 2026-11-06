# Danangtui QR 3D Scanner

Browser-based AR: point your phone at any QR code and a 3D model appears standing on top of it.

**Live:** https://novaillusion.github.io/Danangtui_QR_3D_scanner/

## Features
- Works in the browser – no app install (Chrome, Safari, Firefox on phone or desktop)
- Tracks the QR code's position and tilt in 3D and anchors the model to it
- Built-in models (Crystal, Duck, Fox, Helmet) or load your own `.glb`
- A QR code whose content is a URL ending in `.glb` / `.gltf` shows that model
- Size slider and front/back camera switch

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
