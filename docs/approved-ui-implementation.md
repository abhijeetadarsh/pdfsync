# Approved UI implementation

## Scope

Implement the approved `ui-design-fixed.html` in the existing Flutter client. Operate mode: open and resume PDFs, annotate, and synchronize across devices. Preserve the current offline store, sync protocol, annotation geometry, input policy, and renderer performance behavior. Mock library contents and static PDF text are references only; production screens use actual records and PDF pages.

## Direction contract

THESIS: A precise personal reading workspace, with a compact library and a paper-first reader.

OWN-WORLD: Near-black blue surfaces, lavender primary actions, muted blue text, square controls, fine dividers, and bundled JetBrains Mono UI typography. Light appearance uses the same geometry and semantic roles.

STORY: Sign in to the chosen self-hosted server, find a document, resume at its saved page, and navigate annotations without leaving the reader.

FIRST VIEWPORT: Phone library has title/sync/account, search, reading filters, a continue-reading block, document rows, and Add PDF. Expanded layouts use a navigation sidebar, library grid/list, and a document detail pane on desktop. Reader has real PDF pages, annotation tools and colors, page/zoom controls, and annotations in a sheet on phone or side panel on expanded displays.

FORM: seed: none (pinned). User: “That is good now create a new branch from (first take a pull) main and start the implementation of this design”. Approved reference: `ui-design-fixed.html`; `ui-showcase.html` is excluded.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Verification constraints

2026-11-24: phone `adea1d8a` reports unauthorized; tablet `HA2891X3` is disconnected. Native device tests require an authorized connection; do not claim browser screenshots as native evidence. Use Flutter analysis, widget tests, release compilation and browser testing where available, and report device coverage explicitly.

## Implemented and checked

- Shared theme and bundled typography; persistent dark/light/system appearance; sign-in/server/registration validation and feedback.
- Real library search/reading filters/resume, responsive rows/grid/list/details, and existing import/document/account mutations.
- Reader styling, square palette, responsive tool placement, live annotation sheet/panel, filtering, edit/delete/page navigation, and Markdown clipboard export.
- PDF size changes are owned by `ResponsivePdfSizing`, not a delayed callback that rescales an already-adjusted zoom. Width-relative fit and page-relative anchor are preserved from the old layout snapshot.
- Static analysis clean, full14 tests passed, web release and Android profile builds successful. Browser walkthrough uses actual server records and PDFs. Native tablet library portrait/landscape smoke checks and phone/tablet launcher-branding checks also passed.
- Independent Impeccable review scored the two requested corrections (login compatibility and reader resizing) resolved, with a **ship** verdict limited to that fix list. Design documentation is complete.

## Follow-up scope

The HTML's illustrative document tabs, page-thumbnail rail, global annotation library, collections and document content are not new backend features in this first implementation. Native reader workflows, gestures, font scaling, stylus behavior and performance still need full device testing. No production data was used in browser testing. Implementation branch: `feat/approved-ui-design`.
