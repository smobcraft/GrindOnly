# Phase 01 quickstart (Windows)

Extract this ZIP into a new folder. Open PowerShell in the extracted folder containing README.md. Create an empty **private** repository named GrindOnly at https://github.com/new (do not initialize README or license). Install Git for Windows if needed. Run:

```powershell
git init -b main
git add .
git status
git commit -m "Initialize Grind Only v1.3.19 baseline"
git remote add origin https://github.com/YOUR_USERNAME/GrindOnly.git
git push -u origin main
```

Replace YOUR_USERNAME. Authenticate when prompted. Verify files on GitHub. Before making public, approve license and asset provenance, test the addon, and configure repository protections. Do not upload personal data. Phase 02 will create the actual installable release ZIP and stable download link.
