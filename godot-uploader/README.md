# QR 3D Uploader (Godot 4.7)

A small PC app that uploads 3D models to the QR AR website and links each one to its own QR code.

## Open it
1. Install **Godot 4.7** (standard version, no .NET needed).
2. In the Godot Project Manager click **Import**, choose this folder's `project.godot`, then **Run** (F5).

## First-time setup
1. Click **Settings**.
2. Create a GitHub token: **Open GitHub token page** →
   - Token name: `QR 3D Uploader`
   - Repository access: **Only select repositories** → `Danangtui_QR_3D_scanner`
   - Permissions → Repository permissions → **Contents: Read and write**
   - Generate, copy the token (starts with `github_pat_`).
3. Paste it into **Access token** and click **Save**. The app checks it can write to the repo.

The token is stored only on this PC (in Godot's user data folder, `user://settings.cfg`).

## Add a model
1. **+ New** → **Choose file…** (`.glb` or `.fbx`), or drag the file from Explorer onto the window.
2. Use the tabs on the right:
   - **Model** – name, QR key (filled in automatically), animation.
   - **Transform** – position, rotation and scale (X/Y/Z; tick *Uniform scale* to scale evenly).
     Units are QR-code widths.
   - **Lighting** – ambient and sun brightness/colour, sun direction and height, exposure, ground shadow.
   - **Material** – pick *All materials* or one material, then change base colour, metalness, roughness,
     glow, opacity, or replace its texture with an image from this PC (or drop a .png/.jpg on the window).
3. **Upload to website**. The model, any new textures and all settings are uploaded; after about a
   minute the phone AR view looks the same as the preview.
4. **Show QR** opens the printable code in your browser.

## Edit or delete
Select a model in the list on the left. Change its settings and **Save changes**, choose a new file
to replace the model, or **Delete** it (its printed codes then show nothing).

## How it works
The website is static (GitHub Pages). The app uses the GitHub API to:
- save the model as `models/<key>.glb` (or `.fbx`) in the repo, then
- add/update the entry in `models.json`.

GitHub Pages republishes the site automatically after each change.
