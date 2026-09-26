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
    BaseLayout.astro     # <html> shell, meta tags, global stylesheet, chat widget
  components/
    Hero.astro           # header/hero: arched company name over campsite photo
    Convenience.astro     # content section: power / connectivity / water-recharge
    Footer.astro
    ChatWidget.jsx        # React island: the chat assistant (see "Chat widget")
    ChatWidget.css        # its styles (global, .chat-widget__ prefixed)
  lib/
    api.js                # all calls to backend APIs (chat status + chat)
  pages/
    index.astro           # single page for this milestone
  styles/
    global.css             # color tokens, type tokens, base element styles
  assets/
    heroImage.jpg          # hero banner photo — see below
public/
  robots.txt               # opts out of AI training crawlers (advisory)
```

## Chat widget

`ChatWidget.jsx` is the site's first React island. `BaseLayout.astro` renders
it on every page with `client:idle`, so React loads only after the page is
idle (about 70 KB gzipped, almost all React itself).

- It talks to the chatbot API (`infrastructure/aws/modules/chatbot`) through
  `src/lib/api.js`, using two build-time variables: `PUBLIC_CHAT_API_URL`
  and `PUBLIC_CHAT_API_KEY`. Production gets them from the Amplify app
  (Terraform). **Locally, copy `.env.example` to `.env`** and fill it in.
  Without them the widget isn't rendered at all, which is also what CI
  builds do.
- It asks `GET /chat/status` whether chat is switched on **when the panel is
  opened**, never on page load. When the chatbot is off (Actions →
  "Chatbot on/off"), the panel shows an offline note instead of the chat.
- Conversations live in `sessionStorage` for the tab only. Nothing is stored
  on the server. The widget sends at most the last 8 messages, within the
  API's limits.
- Replies are rendered from a small markdown subset (bold, lists, line
  breaks) as React elements, never as HTML (`FormattedReply.jsx`, shared with
  Herman). Technician-referral and emergency replies get a "Safety notice"
  style.
- **Signed-in employees** get **Eddie | Herman** tabs in the same window,
  and a "Teach Eddie about this" link under each of Eddie's answers that
  switches to Herman with that exchange. The tabs are display-only
  (`src/lib/herman.js` looks for a sign-in session) and grant nothing:
  Herman's API checks the employee's token.

## Teaching Eddie with Herman

Herman is the employee-only assistant on the employee API
(`POST /assistant/chat`). He lives in the chat window's Herman tab
(`HermanChat.jsx`). It's loaded on demand, with the sign-in library, only
when an employee opens that tab, so customers never download it.

- He interviews the employee, and his draft shows as a card in the chat,
  updated each turn.
- **Submit for review** on the card sends the draft through the same
  `POST /kb/entries` as the Add Knowledge form, marked `origin: "chat"`, with
  Herman's note for the reviewer if he wrote one.
- **Edit in the form** opens `/add-knowledge/` with the draft filled in. The
  form is otherwise unchanged: the kind-of-knowledge tiles and guided fields.
- An admin approves or rejects it on KBValidation, which shows a "Drafted
  with Herman" badge, the note, and the author's employee ID.
- **When Herman is switched off** on Feature Mgr, the tab says "Herman is
  switched off right now", with a **Check again** button, instead of the
  chat. If he's switched off mid-conversation, the next message comes back
  with that notice, and nothing typed is lost.
- The conversation lives in `sessionStorage` (`ae-rv-kb-intake`) for the tab
  only, up to Herman's 40-message limit.
- Backend, prompts and eval: `infrastructure/README.md` → "Herman, the
  employee assistant".

## Feature Mgr page (admins)

`/features/` (`FeatureFlags.jsx`) turns features on and off for everyone. It's
listed in the account menu for the `admins` group only. Today it has one
switch, **Eddie**, the public chatbot.

- **Server checks access:** the switches come from the employee API's
  `/admin/features` routes, which check the admins group themselves.
- **Confirm first:** every change asks for confirmation before anything is
  sent, and the card shows the new state only once the server confirms it.
- **Takes effect fast:** within seconds, with no deploy. Eddie's chat window
  shows "Chat is offline" the next time a visitor opens it.
- **History:** each switch shows when it last changed, who changed it, and
  its recent changes, including changes made with the GitHub workflow,
  Terraform or the AWS CLI.
- **Local testing flips the real switch:** `npm run dev` talks to the
  production API.

Backend, backups and how to add a switch: `infrastructure/README.md` →
"Turning it on or off".

## Replacing the hero photo

`src/assets/heroImage.jpg` is rendered by `src/components/Hero.astro`
through Astro's `<Image>` component, which generates responsive WebP
variants at build time (the ~850KB source ships as roughly 30–170KB
depending on viewport).

To swap in a different photo, drop it in at the same path and filename —
no code changes needed. If you rename it, update the `import` at the top
of `Hero.astro` to match.

The banner is **never cropped**: it renders at 80% of the viewport width
with `height: auto`, so the whole frame is always visible at its native
aspect ratio and simply scales down on narrower screens.

What to give it:

- **Aspect ratio is yours to choose** — whatever you supply is what gets
  shown, uncropped. The current photo is 1856 × 576 (≈3.2:1). A much
  squarer photo will render proportionally taller and push the page
  content further down, so keep it wide/panoramic.
- **~1856px wide or more.** At 80% of the viewport, a 2560px-wide display
  renders the banner around 2048px, so a wider source avoids upscaling.
  If you change the source's pixel width, update the `widths={[...]}` array
  in `Hero.astro` to match (values above the source width are skipped).
- **Keep the top ~25% visually calm.** The arched "A&E RV Solutions" title
  is overlaid across the top of the frame. A darker treeline or ridge there
  gives the text something to read against; bright sky or busy detail
  fights the scrim (only ~45% opacity at the top).

## Development

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # outputs to dist/
npm run preview   # serve the production build locally
npm run check     # astro check (type/diagnostic check)
```

Every PR runs `npm run check` and `npm run build` via
`.github/workflows/site-ci.yml`. A failure blocks the merge into `main`.

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
