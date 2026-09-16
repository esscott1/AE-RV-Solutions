# A&E RV Solutions — Website

Marketing and interactive informational site for A&E RV Solutions, built with
[Astro 5](https://astro.build) in **static output mode**. React is wired in
as an integration so future interactive pieces (chatbot widget, contact form)
can ship as React islands without changing the rendering mode of the rest of
the site.

## Stack

- **Astro 5**, `output: "static"` (the project default — no SSR adapter is
  configured)
- **React** integration (`@astrojs/react`) reserved for islands: the chat
  widget and the contact form, per the architecture doc. No islands are
  wired up yet — this first page is pure Astro/HTML/CSS.
- No CSS framework; hand-written CSS with a small token system in
  `src/styles/global.css`.

## Structure

```
src/
  layouts/
    BaseLayout.astro     # <html> shell, meta tags, global stylesheet import
  components/
    Hero.astro           # header/hero: arched company name over campsite photo
    Convenience.astro     # content section: power / connectivity / water-recharge
    Footer.astro
  pages/
    index.astro           # single page for this milestone
  styles/
    global.css             # color tokens, type tokens, base element styles
  assets/
    (hero photo goes here — see below)
```

## Replacing the hero photo

The hero currently renders a **placeholder gradient** standing in for the
real photograph (a family at a remote, off-grid Colorado campsite next to a
Grand Design travel trailer, dusk lighting). No AI-generated or stock photo
is embedded in this build, to keep the repo clean of placeholder imagery
that would need to be replaced anyway and to avoid stock-license ambiguity.

To swap in the real photo:

1. Add the licensed/approved photo to `src/assets/hero-camping.jpg` (or
   `.webp` — prefer `.webp` for file size once you have a final crop).
2. In `src/components/Hero.astro`, add at the top of the frontmatter:
   ```astro
   ---
   import heroImage from '../assets/hero-camping.jpg';
   ---
   ```
3. Uncomment the `<img>` block in the template and delete the
   `<div class="hero__photo hero__photo--placeholder">` line below it.
4. Suggested crop/composition: family and trailer in the lower third,
   open sky and ridgeline in the upper two-thirds (the arched name and
   scrim are tuned for a photo with open sky at the top).

## Development

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # outputs to dist/
npm run preview   # serve the production build locally
```

## Deployment (planned)

Per the architecture: GitHub repo connected to **AWS Amplify Hosting**
(`us-east-1`). Push to `main` triggers a build (Vite builds the site,
Amplify deploys to CloudFront); pull requests get preview deployments.
Terraform for the Amplify app and supporting infrastructure lives in this
repo's `infra/` (or equivalent) directory, module-per-feature, per
`ae_rv_solutions_full_architecture.png`.
