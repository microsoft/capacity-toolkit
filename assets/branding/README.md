# Branding assets

Logo and social assets for the Azure Capacity & Enablement Toolkit. The mark is three
ascending "zone" bars on a dark tile — echoing the dashboard''s physical
availability-zone chips (AZ1 blue, AZ2 green, AZ3 orange).

## Files

| File | Description |
| --- | --- |
| `logo.svg` / `logo.png` | The toolkit brand mark (500x500 `.png`, plus scalable `.svg`). One icon, reused for the repo logo, docs, and all GitHub team avatars. |
| `social-preview.svg` / `social-preview.png` | 1280x640 social-preview banner for the repo. |

## Regenerate

```powershell
npm install             # installs sharp (SVG -> PNG); node_modules is git-ignored
node generate-logo.js   # writes logo.svg + logo.png
node generate-social.js # writes social-preview.svg + social-preview.png
```

## Using the assets

- **Repo logo / docs:** referenced from `README.md` and `mkdocs.yml` (`docs/assets/logo.*`).
- **Social preview:** upload `social-preview.png` via repo Settings -> Social preview.
- **GitHub team avatars:** upload `logo.png` manually per team
  (github.com -> orgs/<org>/teams/<team> -> Settings -> Profile picture). GitHub has no
  API for team avatars, so this step is web-UI only.
