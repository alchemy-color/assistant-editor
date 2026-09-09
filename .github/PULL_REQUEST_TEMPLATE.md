## What does this PR do?

<!-- One or two sentences. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Docs / porting guide
- [ ] Build / CI
- [ ] Refactor (no behavior change)

## Which layer does it touch?

- [ ] Swift UI (macOS reference)
- [ ] Python pipeline (`source/Python/`)
- [ ] Script interface contract (stdin/stdout)
- [ ] Docs

## Checklist

- [ ] The macOS reference app still builds (`xcodegen generate && xcodebuild … build`), or the change is docs-only.
- [ ] Python scripts still compile (`python3 -m py_compile source/Python/*.py`), or the change doesn't touch them.
- [ ] I described how to reproduce/test the change in the PR body.
- [ ] I did **not** commit local transcripts, footage, caches (`*.db*`, `.srtx`/`.srt` sample data), or secrets.

## Notes for reviewers

<!-- What should a reviewer look at closely? Any behavior that changed unintentionally? -->