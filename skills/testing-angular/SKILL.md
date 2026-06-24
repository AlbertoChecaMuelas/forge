---
name: testing-angular
description: Angular (Karma + Jasmine) testing cookbook — operative guide for tester
disable-model-invocation: true
---

## Angular (Karma + Jasmine)

Detection signals: `angular.json` at repo root, AND `karma.conf.js` (or `karma.conf.ts`) present, AND `@angular/core` in `package.json` dependencies.

---

## Tester workflow

Tester runs all commands below directly. There is no intermediary — tester writes the spec files, executes the test runner, and interprets results in a single continuous flow.

### 1. Write the specs

- Place spec files alongside the source file: `src/app/<module>/<component>.spec.ts`.
- Use `describe` / `it` / `beforeEach` / `afterEach` (Jasmine API).
- Use `TestBed.configureTestingModule(...)` to declare the component/service under test and its dependencies.
- Use `HttpClientTestingModule` / `RouterTestingModule` for infrastructure stubs.
- Prefer `jasmine.createSpyObj` and `spyOn(service, 'method').and.returnValue(...)` for service mocks.
- Avoid `fit` / `fdescribe` (focused tests that silently skip everything else) in committed code.

### 2. Run the tests

Full suite (project-wide):

```bash
ng test --karma-config=karma.conf.js --no-progress --watch=false --browsers ChromeHeadlessCI
```

Scoped to a folder (fast pre-step when the plan touches a single area):

```bash
ng test --karma-config=karma.conf.js --no-progress --watch=false --browsers ChromeHeadlessCI \
  --include="src/app/<path>/**/*.spec.ts"
```

Single spec file:

```bash
ng test --karma-config=karma.conf.js --no-progress --watch=false --browsers ChromeHeadlessCI \
  --include="src/app/<module>/<component>.spec.ts"
```

With coverage report:

```bash
ng test --karma-config=karma.conf.js --no-progress --watch=false --browsers ChromeHeadlessCI \
  --code-coverage
```

Coverage output lands in `coverage/` at the repo root.

### 3. Interpret results

- **All green, coverage >= 90%**: tests pass the coverage target. Return `TESTING_PLAN: <1-line summary of specs written and final coverage>`.
- **Failures**: read the Karma/Jasmine error stack, identify the failing `describe > it` path, fix the spec or report the gap.
- **Coverage < 90%**: identify uncovered branches (open `coverage/index.html` or read `coverage/lcov.info`), add missing cases, re-run.
- **ChromeHeadless not found**: ensure `chromium` / `google-chrome-stable` is on PATH, or set `CHROME_BIN` env var before running.

---

## Naming conventions

| Artefact | Convention |
|---|---|
| Spec file | `<source-file>.spec.ts` |
| Top-level describe | `'<ClassName>'` or `'<ServiceName>'` |
| Nested describe | `'<methodName>'` or `'when <condition>'` |
| Test (it) | `'should <expected behaviour>'` |

---

## Coverage target

A high coverage target such as 90% is recommended. Configured in `karma.conf.js` under `coverageReporter.check`. If a file is explicitly excluded via `coverageExclude` patterns, document the reason in a comment.
