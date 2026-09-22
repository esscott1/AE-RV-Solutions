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
    heroImage.jpg          # hero banner photo — see below
```

## Replacing the hero photo

`src/assets/heroImage.jpg` is rendered by `src/components/Hero.astro`
through Astro's `<Image>` component, which generates responsive WebP
variants at build time (the ~850KB source ships as roughly 30–170KB
depending on viewport).

To swap in a different photo, drop it in at the same path and filename —
no code changes needed. If you rename it, update the `import` at the top
of `Hero.astro` to match.

What to give it:

- **1920 × 600px** recommended (minimum 1600 × 500). The `<Image>` call
  requests widths up to 1920, so a narrower source gets upscaled.
- **Landscape.** The banner is short and full-width
  (`clamp(280px, 42vh, 460px)` tall, less on mobile), so a tall or square
  photo loses most of its content to the crop.
- **Keep the top ~25% visually calm.** `object-position: center 40%`
  weights the crop toward the upper part of the frame, which is also
  where the arched "A&E RV Solutions" title sits. A darker treeline or
  ridge there gives the text something to read against; bright sky or
  busy detail fights the scrim (only ~45% opacity at the top).

## Development

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # outputs to dist/
npm run preview   # serve the production build locally
```

## Deployment

The site can be deployed to **either AWS or Azure** — two independent,
parallel Terraform stacks in [`infrastructure/`](../infrastructure)
provision equivalent static hosting on each:

- **AWS**: Amplify Hosting (`infrastructure/aws/`), fronted by CloudFront.
- **Azure**: Static Web Apps (`infrastructure/azure/`), fronted by Front
  Door.

They're alternatives, not a dual-cloud deployment — you pick one hyperscaler
to actually run. Either way, a GitHub Actions workflow builds the site
(`npm run build` from this `site/` directory) and deploys on push to
`main`; a push that only touches `infrastructure/**` never triggers a
redeploy. See [`infrastructure/README.md`](../infrastructure/README.md)
for the full setup and deploy steps for each cloud.
