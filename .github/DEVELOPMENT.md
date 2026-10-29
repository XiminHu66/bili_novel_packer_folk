# Development and Actions resource rules

- Keep private repositories private and paid usage budget at $0 unless the owner explicitly changes it.
- Before pushing, run `python .github/scripts/actions_policy.py .` after installing PyYAML. Do not bypass this check.
- Ordinary player commits run lightweight CI. Full Windows packaging, real playback/authentication and upgrade acceptance run only on version tags or an explicit manual release. Report actual live outcomes separately from unit/fixture results.
- Set every runnable job timeout and workflow concurrency. Cancel obsolete PR/test runs; serialize production deployments instead of cancelling active deployment handoffs.
- Every upload must specify retention: intermediate installation/fixture binaries 1 day, screenshots 3 days, other reports at most 7 days. Final downloads live in Releases. Never delete an artifact before all downstream consumers finish.
- Cleanup must be repository-scoped, skip active runs, protect all Releases, and summarize deleted/remaining bytes. Never delete workflow histories to hide failures.
- Do not add duplicate scheduled scrapers. PT-Universe is the canonical source for legacy Tsugi, 3C and Stock Alert pages. QF automatic refresh is paused. A legacy page must keep its local last-good fallback.
- A scheduled collector is successful only when its output timestamp and source health are verified. Late starts must not silently become green no-ops. No data changes means no deployment. Preserve 08:00 Pacific primary / 08:30 conditional retry and DST behavior.
- Pages artifacts contain only the frontend distribution, never node_modules, tests, backend services or generated screenshots.
- Prefer local validation before cloud runs. Do not repeatedly re-run a failing pipeline without diagnosing the failed step. One failure must not erase other successful sources.
- Any new VPS service must first verify projected free disk and memory remain at least 15%; do not install self-hosted CI on the production VPS as a default.
