# Triage migration roadmap

- [x] Add and test “Talk to someone” on search and personal-guide results with language matching, external booking links, and no appointment storage.
- [x] Add and test a calendar-style preferred date/time picker for an admin Zoom call, with German, English, French and Italian only; selections remain unconfirmed and clear on reload without appointment storage.
- [x] Make and test the appointment flow as a clickable prototype, clearly labelled as not a real booking or Zoom meeting; live booking deferred at the user’s request.
- [x] Require a written question in the appointment calendar before the call can be requested; the question shows in the preview and stays in local state only.
- [x] Show the free video call offer only at the end of the personal guide (not on search results); verified in the browser end to end.
- [x] Fix the clipped topic filter chip on the search page: pills now wrap instead of being cut off at the right edge; verified at desktop and phone widths.
- [x] Publish the revised self-search PDF download popup: the PDF now downloads before the popup opens; desktop, phone, failure handling, build, and all 18 tests pass. Publishing requested 2026-11-21 14:52 UTC.
- [x] Remove the "Still need more support?" banner from the personal guide page; the free video call option now appears only as a popup after the PDF has been downloaded. Verified in the browser (no banner before download, popup with question box after) and covered by 3 new tests (21 pass).
- [x] Keep the post-download video-call popup as a clearly labelled prototype at the user's request; no real booking link, appointment storage, or admin notification. The required question and local-only date/time selection remain.

- [x] Recreate the repository schema, access rules, sharing, submission, and import functions in Lovable Cloud.
- [x] Build the responsive Triage welcome and six-step personal guide from the supplied reference.
- [x] Add searchable services, eligibility guidance, checklist, service details, QR sharing, and community submissions.
- [x] Replace starter examples with 215 clean offers from the two supplied workbooks.
- [x] Test routing, recommendation rules, public permissions, sharing, submission, import publishing, search, service details, and core browser flows.
- [x] Import and verify records from the two supplied Google Sheets workbooks.
- [x] Automatically translate directory results and service details into every language available in platform settings, while preserving German originals.
- [x] Remove duplicate per-service translation buttons.
- [x] Add the supplied Lucerne photo to the home page.
- [x] Replace the logo throughout the platform with the supplied logo.
- [x] Review unclear workbook rows: 21 published (18 ready + 3 questionable), 5 left out for missing contact details or name.
- [x] Administrator-user export: left empty for now at the user's request; no admin accounts will be migrated until they supply them.
- [x] Publish the 18 ready review offers plus the 3 questionable ones (ZwüscheHalt, Asylex, FABIA afternoon)
- [x] QR code downloads the service list PDF on phone; Download PDF button on laptop (no sign-in)
- [x] Remove black circle around the logo everywhere
- [x] Logo keeps its solid white background (not transparent), plain rectangle with square corners, no dark shape behind it
- [x] Admin area: sign-in, Excel upload, review rows, publish, auto-translate (first admin: admin@triangle.lovable)
- [ ] Migrate website and admin to the user's previously supplied external database while preserving offers: official Cloud export downloaded; blocked on safe destination restoration and authorized connection; retain the current database until destination data and sign-in are verified.
