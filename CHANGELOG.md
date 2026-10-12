# Changelog

All notable changes to FS25_MasterHUD will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

## [1.2.0.0] - 2026-10-12

> **This is not a final release.** It gives everyone, testers and players, new or returning, everything we have built so far, so nobody has to wait on an old version any longer. The Realistic Farming suite is far from done: we are still building and expanding every mod, and completing it could take months, possibly a year. Expect changes and rough edges along the way, and please report anything that looks wrong.

### Fixed
- With Master HUD installed, the HUD show/hide keys of Soil & Fertilizer, Seasonal Crop Stress, Fuel Costs, Income, NPC Favor, Random World Events and Workplace Triggers work again. Each key shows or hides that mod's HUD, as the Control Center button does; Soil, Crop Stress and Random World Events also work in a vehicle. Needs Settings Hub.
- Hiding all HUDs no longer blanks a settings or tuning screen you have open: that screen stays drawn and keeps taking your mouse input until you close it.

## [1.1.0.0] - 2026-09-18

### Added
- Hide-all now has a restricted keep-drawing pass: `subscribe`/`registerPanel` accept an opt-in `visibleWhenHudsHidden` spec field, and flagged self-draws or panels keep rendering while every other overlay is hidden. In-cab tool readouts (sprayer rate, VRA, sensors) stay visible across the suite's Hide All HUDs toggle instead of disappearing with the glance chrome.

### Fixed
- RSF-F201: cab and on-foot controls stay valid across vehicle entry and exit. Each input context now registers through its own private target, so the PLAYER and VEHICLE registrations no longer share one engine identifier that a cab rebuild wiped. Membership is checked in the wrap's own context, a complete set costs no registration work, and the input wrappers install once per session instead of being restored on every mission teardown.

## [1.0.1.0] - 2026-08-26

### Added
- Changelog file established (suite ruling 2026-08-22).
- Playtest fixes: MH_TOGGLE_ALL_HUDS (RShift+G) and MH_EDIT_HUDS (RShift+B) chord defaults, in-cab vehicle input hook fix, exit-only listener idiom fix.
- Control Center actions (suite Control Center, requires SettingsHub): MH_TOGGLE_ALL_HUDS, MH_EDIT_HUDS.

## [1.0.0.5] - 2026-08-22

- First entry under changelog tracking.
