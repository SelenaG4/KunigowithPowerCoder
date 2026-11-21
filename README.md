# Triage

### Your path to the right support.

*A shared, public guide that helps people with a migration background in Lucerne find the right advice centre or service, in their own language, without giving away any personal data.*

Built at the Lucerne Hackathon (November 2026) for **mira – mobile Informationen, Rat und Austausch**, a pilot project run by KUNIGO and commissioned by the Canton and City of Lucerne.

---

## A Tuesday afternoon in Lucerne

Selam arrived in Switzerland two months ago. She lives in Emmen, her German is still shaky, and she has a stack of letters she doesn't fully understand. Today she is at a community café because a friend told her there would be someone there "who knows where to go".

That someone is Hana, one of mira's intercultural key persons. Hana speaks Selam's language, listens, and quickly sees three things Selam needs: a German course, help with her health insurance, and someone to explain the letters.

Hana knows the answers exist somewhere. They are spread across a printed list from one organisation, an Excel file from another, a few websites and her own memory. She finds a counselling service that sounds right and writes the address on a piece of paper.

What neither of them knows: that service cannot help people who receive social assistance from the cantonal asylum office (DAF). Selam does. Next week she takes the bus into town, waits, and is sent somewhere else.

*Selam and Hana are made up, but their afternoon isn't. It happens every day, in every community mira works with.*

## The problem behind the story

In Lucerne, many associations, organisations and city and cantonal services send people with a migration background to the right place. **But each of them does this triage on its own**, with its own lists. There is no shared, public, easy-to-use overview that answers three simple questions:

1. **What help exists** for my everyday problem?
2. **Can I actually use it**, given my residence permit, where I live and who supports me?
3. **How do I take this information home** without anyone recording my details?

When those answers are missing, people lose time, trust and sometimes a whole day, as Selam did.

## The same afternoon, with Triage

Hana opens Triage on her phone and taps **"I'm helping someone"**.

- **Six short questions, in Selam's language:** language, citizenship, where she lives, how long she has been here, her residence permit if she knows it, and what she needs help with. No name, no email, no account.
- **A personal guide appears:** a simple checklist of next steps and the services that fit Selam's situation. Offers she cannot use are not hidden. They are clearly marked, with the reason in plain words: *"Not for people who receive social assistance from the DAF."*
- **Selam scans a QR code** and the guide opens on her own phone. She can come back to it tonight, show it to her family, or open it again at the next appointment. Nobody stored anything about her.

Selam leaves with the right addresses, and Hana didn't have to remember every rule of every service in Lucerne.

## Behind the scenes: keeping the guide true

A guide is only as good as its information, and that information lives in partner organisations' Excel lists, which change all the time. So Triage has a second side: a back office for the people who look after the data.

When a partner sends an updated list, an administrator:

1. **Drags the Excel file** into the admin app. Triage finds the column names, and if a provider names its columns differently, the admin matches them once and Triage remembers.
2. **Lets the database do the reading.** Every row is turned into the platform's structure: organisation, offer, category, phone, email, website, cost, area, and eligibility rules such as *"only for residents of Kriens"* or *"not for people with permit N, F or B"*.
3. **Checks what's unclear.** Anything the system isn't sure about, such as an exception, an exclusion or a missing contact, is flagged with the reason. Nothing is guessed silently.
4. **Clicks Publish.** The offers appear in the public guide straight away.

The original row from every file is kept next to the result, so anyone can see where a piece of information came from.

## What we believe

- **Low threshold first.** Big buttons, short questions, simple language, works on any phone.
- **No data about the people seeking help.** No accounts, no tracking. Share links store only the filter choices, never a name.
- **Transparent rules, not black boxes.** Who can use an offer is decided by clear database rules that anyone can read. AI may help with translations and admin work, but it never decides who is eligible.
- **Show the "no" as clearly as the "yes".** Knowing where you *can't* go saves as much time as knowing where you can.
- **Built for key persons.** mira's strength is people talking to people. Triage supports those conversations; it doesn't replace them.

## How it's built

| Part | What it does | Tech |
|---|---|---|
| **Public guide** *(in progress)* | The 6-step questions, personal guide and QR code for immigrants and key persons | React, hosted on Vercel |
| **Admin app** (`admin/`) | Sign-in, Excel import with column matching, review, publish, edit live offers | Vite + React + TypeScript, SheetJS |
| **Database** (`supabase/migrations/`) | Organisations, services, categories, eligibility rules, translations, change log, import pipeline | Supabase (PostgreSQL, Auth for admins only, row-level security, Storage) |

Search starts with PostgreSQL full-text search, so basic results never depend on a paid AI service. A column for multilingual embeddings is already there for semantic search later.

```
Partner Excel ──► Admin app ──► Supabase ──► Public guide ──► QR code on Selam's phone
                  match · review    rules · search    6 questions        nothing stored
```

## Try it yourself

```bash
git clone https://github.com/SelenaG4/KunigowithPowerCoder.git
cd KunigowithPowerCoder/admin
cp .env.example .env.local
npm install
npm run dev        # admin app on http://localhost:5173
```

To deploy the admin app on Vercel and create the first administrator, see [`admin/README.md`](admin/README.md). The database setup lives in [`supabase/migrations/`](supabase/migrations/), in the order it should run.

## What comes next

- [x] Database with eligibility rules and full-text search
- [x] Excel import from partner lists (tested with the Fabia and Sentitreff lists)
- [x] Admin app: sign in, import, review, publish
- [ ] Public guide: 6-step questions, personal guide, QR code
- [ ] Languages of the mira pilot first, German, Spanish and Tigrinya, then English and more
- [ ] Test with mira's key persons at real community meetings
- [ ] Optional: book a call with a key person straight from the guide

## Contributing

- **An offer is missing or out of date?** Open an issue, or send the updated list to the mira team.
- **Want to help with code or translations?** Fork the repo, create a branch and open a pull request.

## Team

Built by **[KunigowithPowerCoder](https://github.com/SelenaG4/KunigowithPowerCoder)** at the Lucerne Hackathon, November 2026, for the mira project.
<!-- Add team member names here -->

## License

Code: MIT · Data: CC BY 4.0 *(to be confirmed with the project partners)*
