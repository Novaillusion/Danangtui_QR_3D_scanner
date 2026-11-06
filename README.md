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
Each frame is scanned with [jsQR](https://github.com/cozmo/jsQR), which returns the QR's four corners.
A homography from those corners gives the camera pose of the code, and [three.js](https://threejs.org)
renders the model over the live video with a matching camera.

## Notes
- Camera access requires HTTPS (GitHub Pages is fine) or `localhost`.
- If the model looks slightly too near or far, adjust `ASSUMED_FOV_DEG` in `index.html`.
- Best results: printed code ≥ 5 cm wide, good lighting.

## Run locally
```
npx serve .
```
then open http://localhost:3000
