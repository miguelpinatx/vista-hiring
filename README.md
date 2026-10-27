# Vista Hiring Tracker

Applicant tracker for Vista Markets: paste or enter applications, move people through stages, record offers, track Food Handler / TABC cards, and send stage emails and texts in English or Spanish.

- **Site:** hosted on GitHub Pages (`index.html` is the whole app).
- **Data and sign-in:** Supabase. Applicant data never lives in this repository.
- **Who can see applicants:** only signed-in people whose email is on the Team list. Everyone else, including anyone who creates an account on their own, sees nothing. The rules are enforced by the database (`schema.sql`), not just the page.

## Setup (one time)

1. **Create the Supabase project** at supabase.com → New project (name it `vista-hiring`). Save the database password somewhere safe.
2. **Run the setup script:** SQL Editor → New query → paste `schema.sql` → Run. It makes `miguel@vistasupermarkets.com` the first admin; change that line first if you sign in with another email.
3. **Import existing applicants (optional):** run the separate import file in the SQL Editor the same way. Don't add it to this repo; it contains applicant personal information.
4. **Connect the site:** Project Settings → API. Copy the **Project URL** and the **anon public** key into the two lines at the top of the script in `index.html` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). The anon key is meant to be public; the database rules are what protect the data. Never put the `service_role` key here.
5. **Sign-in links:** Authentication → URL Configuration → set **Site URL** to the GitHub Pages address (for example `https://miguelpinatx.github.io/vista-hiring/`).
6. **Turn on Pages:** repo Settings → Pages → Deploy from branch → `main` / root.

## Adding a manager

1. Team tab → enter their name and email → **Add to team**.
2. Send them the site link. They tap **First time? Create your account**, choose a password, and click the confirmation email.
3. To remove access, click **Remove** next to their name on the Team tab.

## Backups

Use **Export CSV** in the app, or Supabase → Table Editor → `candidates` → Export.
