# KUNIGO Luzern

**A shared, public triage tool that helps people with a migration background in Lucerne find the right advice centre or service, quickly and simply.**

Built as part of the Hackathon challenge for the project **"mira – mobile Informationen, Rat und Austausch"**.

---

## The problem

In Lucerne, many associations, organisations and city and cantonal services refer people with a migration background to the right place. Today each of them does this triage on its own. There is no shared, public, easy-to-use overview of what offers exist, who they are for, and who cannot use them.

## Our solution

An interactive web platform where anyone can:

- **Search intuitively** for offers by everyday topic (German courses, health insurance, housing, neighbourhood and leisure, and more)
- **Filter by eligibility** so they see right away whether an offer fits their situation (residence status, place of residence, social assistance provider, language, cost)
- **Share an offer instantly** with someone else, using a QR code or a short link, without anyone having to give contact details
- **Submit new offers** through a simple form, so the database stays up to date with the knowledge of the whole community

## Who it's for

| User | How they use it |
|---|---|
| **mira key persons** | Look up and show offers during conversations in their communities, then pass them on via QR code |
| **People with a migration background** | Find offers on their own phone, in their own language |
| **Organisations & city services** | Add and update their own offers, and use the tool for their own referrals |

## Key features

- 🔎 **Topic-based search:** big, clear categories with icons, plus free-text search
- 🚦 **Eligibility filters & exclusion criteria:** every offer shows clearly who can and cannot use it
  *Example: people receiving social assistance from the Dienststelle Asyl- und Flüchtlingswesen cannot use the counselling at Fachstelle fabia.*
- 📱 **Mobile first and low threshold:** simple language, few clicks, works on any phone
- 🌍 **Multilingual:** interface and offer summaries in several languages
- 🔗 **Share without data collection:** a QR code or link per offer (or a list of offers) that people can save on their own device
- ✍️ **Community submissions:** anyone can suggest an offer, and submissions are reviewed before they are published
- 🔒 **Privacy by design:** no user accounts are needed to search or share, and no personal data about the people seeking help is stored

## Data model (draft)

Each offer contains:

```yaml
name:            Fachstelle fabia
category:        [counselling, integration]
description:     Short description in simple language
languages:       [de, en, ...]
location:        Address / district / online
contact:         Phone, email, website
opening_hours:   ...
cost:            free | reduced | paid
eligibility:
  residence_status:   [B, C, F, ...]
  place_of_residence: [City of Lucerne, Canton of Lucerne]
  exclusions:         ["Social assistance via DAF"]
last_verified:   2026-11-21
source:          Organisation / submitted by
```

## Tech stack

*To be decided during the hackathon.* Proposed:

- **Frontend:** React / Next.js (responsive, PWA-capable)
- **Backend / database:** Supabase or PostgreSQL with a REST API
- **i18n:** i18next
- **QR codes:** client-side generation (e.g. `qrcode` library)
- **Hosting:** Vercel / Netlify

## Getting started

```bash
git clone https://github.com/<your-org>/mira-wegweiser.git
cd mira-wegweiser
npm install
npm run dev
```

Then open `http://localhost:3000`.

## Roadmap

- [ ] Define categories and eligibility criteria with mira and partner organisations
- [ ] Build the search and filter interface
- [ ] Add QR code and link sharing
- [ ] Build the submission form and moderation workflow
- [ ] Add multilingual support
- [ ] Load the first set of Lucerne offers
- [ ] Test with intercultural key persons

## Contributing

We welcome contributions! You can:

- **Suggest an offer:** use the submission form on the platform
- **Report outdated information:** open an issue
- **Contribute code:** fork the repo, create a branch and open a pull request

## Team

Built at the Lucerne Hackathon, November 2026.
<!-- Add team member names here -->

## License

MIT (or to be decided with the project partners)
