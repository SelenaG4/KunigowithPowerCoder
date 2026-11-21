<p align="center"><img src="https://kunigo-readme-compass.lovable.app/__l5e/assets-v1/aecc5b1b-a29b-4b87-ad18-9fa16bf00b1b/triage-logo.png" alt="Triage – Your path to the right support." width="360"></p>

# Triage

### Your path to the right support.

*A shared, public guide that helps people with a migration background in Lucerne find the right advice centre or service, in their own language, without giving away any personal data.*

Built at the Lucerne Hackathon (November 2026) for **mira – mobile Informationen, Rat und Austausch**, a pilot project run by KUNIGO and commissioned by the Canton and City of Lucerne.

<table>
<tr>
<td><img src="https://api.qrserver.com/v1/create-qr-code/?size=300x300&margin=10&data=https%3A%2F%2Flucerne-help-match.lovable.app%2F" alt="QR code to the Triage website" width="150"></td>
<td>

**▶ Try it live:** [lucerne-help-match.lovable.app](https://lucerne-help-match.lovable.app/)<br>
Scan the QR code with your phone, or open the [personal guide](https://lucerne-help-match.lovable.app/guide) or the [service directory](https://lucerne-help-match.lovable.app/services).

**For the data team:** [Admin sign-in](https://kunigo-readme-compass.lovable.app/admin)

| Demo admin login | |
|---|---|
| Admin web | https://kunigo-readme-compass.lovable.app/admin |
| Email | `admin@triangle.lovable` |
| Password | `Triage-f88e5db0-Lu` |

<sub>Hackathon demo account. The password will be changed after the judging.</sub>

</td>
</tr>
</table>

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

## Take the tour

Open each step on the [live site](https://lucerne-help-match.lovable.app/) and follow Selam's path:

| # | Screen | What you see |
|---|---|---|
| 1 | [Welcome](https://lucerne-help-match.lovable.app/) | Start a personal guide or search services directly. Multilingual, local, no registration |
| 2 | [Personal guide: 6 questions](https://lucerne-help-match.lovable.app/guide) | Language → citizenship → where you live → how long you have been here → residence permit (optional, private) → topics |
| 3 | [My guide](https://lucerne-help-match.lovable.app/my-guide) | Next steps, services that match the answers, and a QR code that opens the guide as a PDF on the person's own phone |
| 4 | [My checklist](https://lucerne-help-match.lovable.app/checklist) | Ticks are saved only on this device |
| 5 | [Service directory](https://lucerne-help-match.lovable.app/services) | Search by topic or keyword, "only matching my answers", costs clearly marked |
| 6 | [Admin platform](https://kunigo-readme-compass.lovable.app/admin) | Upload a partner's Excel list → check flagged rows → publish to the website (sign-in for the data team only) |

> Tip: complete the 6 questions first, then "My guide" and "My checklist" show results for your answers.

## Behind the scenes: keeping the guide true

A guide is only as good as its information, and that information lives in partner organisations' Excel lists, which change all the time. So Triage has a second side: a back office for the people who look after the data.

When a partner sends an updated list, an administrator signs in at [`/admin`](https://kunigo-readme-compass.lovable.app/admin) and:

1. **Drags the Excel file** into the admin platform. Triage finds the column names, and if a provider names its columns differently, the admin matches them once and Triage remembers.
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

Triage has **two doors**: a public website for immigrants and key persons ([lucerne-help-match.lovable.app](https://lucerne-help-match.lovable.app/)), and an admin platform for the people who keep the data up to date ([kunigo-readme-compass.lovable.app/admin](https://kunigo-readme-compass.lovable.app/admin)).

| Part | Where | What it does |
|---|---|---|
| **Public guide** | [`/`](https://lucerne-help-match.lovable.app/) and [`/guide`](https://lucerne-help-match.lovable.app/guide) | Welcome page, the 6 questions, a personal guide with a checklist and recommended services, and a QR code to take it home |
| **Service directory** | [`/services`](https://lucerne-help-match.lovable.app/services) | Search by everyday topic or keyword, filter to "only matching my answers", with requirements and costs clearly marked |
| **Admin platform** | [`/admin`](https://kunigo-readme-compass.lovable.app/admin) | Sign-in for the data team, Excel upload from partner organisations, review and publish |
| **Database design** | [`supabase/migrations/`](supabase/migrations/) | Organisations, services, categories, eligibility rules, translations, change log and the Excel import pipeline, as SQL |

**Tech:** built with [Lovable](https://lovable.dev): React, TypeScript, Vite, shadcn/ui, with server functions for search and data. The database design follows the schema in `supabase/migrations/`. Search is deterministic (keywords, categories and eligibility rules), so basic results never depend on a paid AI service.

```
Partner Excel ──► /admin ──► database ──► /guide & /services ──► QR code on Selam's phone
                  upload · review   rules · search    6 questions · search    nothing stored
```

## Try it yourself

The fastest way is the [live app](https://lucerne-help-match.lovable.app/). To run it locally:

```bash
git clone https://github.com/SelenaG4/KunigowithPowerCoder.git
cd KunigowithPowerCoder
npm install        # or: bun install
npm run dev
```

The project can also be opened and edited in Lovable using the "Edit with Lovable" link on the live site.

## What comes next

- [x] Database with eligibility rules and full-text search
- [x] Excel import from partner lists (tested with the Fabia and Sentitreff lists)
- [x] Admin platform: sign in, upload Excel, review, publish
- [x] Public guide: 6-step questions, personal guide, QR code
- [x] Service directory with topic filters and "only matching my answers"
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
