---
name: testing-spring-boot
description: Spring Boot (Maven + JUnit + JaCoCo) testing cookbook — operative guide for tester
disable-model-invocation: true
---

## Spring Boot (Maven + JUnit + JaCoCo)

Detection signals: `pom.xml` at repo root, AND `pom.xml` contains `spring-boot-starter`.

> This cookbook covers Maven-based Spring Boot projects only. Do NOT add Gradle detection for Spring Boot in this cookbook. If a `build.gradle` / `build.gradle.kts` is found alongside `pom.xml`, treat the Maven layout as authoritative; if only Gradle is present, emit `BLOCKED_TESTER: framework Spring Boot Gradle not in cookbook — add it before planning`.

**READ mode — delegation pattern**: the tester agent does NOT execute `mvn` commands directly. The workflow is:

1. **Tester writes the test** (Edit / Write tool — creates or modifies test source files under `src/test/`).
2. **Tester delegates `mvn` to applier** with the exact command from the section below (e.g. `mvn clean verify`). Applier runs the build and returns.
3. **Tester reads the report files** produced by the build (`target/surefire-reports/`, `target/site/jacoco/`) using the Read tool and interprets the results.

The tester never touches `mvn` itself — the build can be slow and has side-effects (container lifecycle, file generation); those belong to applier.

### Commands tester delegates to applier

- Full suite (project-wide):
  ```
  mvn clean verify -Pcoverage
  ```
  If the `coverage` profile is not declared in `pom.xml`, fall back to:
  ```
  mvn clean verify
  ```

- Scoped to a single test class or package (use as a fast pre-step before the full suite when the plan touches a single area):
  ```
  mvn test -Dtest="<ClassNameOrGlob>"
  ```
  Examples of `<ClassNameOrGlob>`:
  - `MyServiceTest` — single test class
  - `com.example.<package>.**` — every test under a package (Surefire glob; quote the value to protect `**` from the shell)
  - `MyServiceTest#shouldReturn404` — single test method

  Note for multi-module repos: if `pom.xml` declares `<modules>` (Reactor build), prefix the command with `-pl <module> -am` so Maven scopes the build to the target module and its required dependencies. Decide multi-module vs single-module by reading `pom.xml`; do not guess.

- Integration tests only — **do not invoke failsafe goals directly**. In Spring Boot microservices the integration profile typically binds `pre-integration-test` (start containers via docker-maven-plugin or Testcontainers) and `post-integration-test` (stop containers) to the Maven lifecycle. Calling `failsafe:integration-test` and `failsafe:verify` as bare goals bypasses those bindings and either fails for missing infrastructure or leaks containers from a previous run. The supported way to run IT-only is the full verify lifecycle:
  ```
  mvn verify
  ```
  If the project has a profile that scopes the build to IT (e.g. `-Pit` or `-Pintegration`), use it; otherwise use bare `mvn verify`. Never use `-DskipTests` to approximate "IT only" — use `-DskipUTs=true` or `-Dsurefire.skip=true` if you genuinely need to skip unit tests.

  Reminder: emitting any integration-test step as an applier task still requires confirming infrastructure is available (see BLOCKED_TESTER condition below).

### Artifacts to read (after applier runs the build)

After applier returns `OK:`, tester reads the following report files using the Read tool.

#### Surefire reports (unit tests)

- **XML** (`target/surefire-reports/*.xml`): one file per test class. Read the `<testsuite>` root element:
  - `tests` — total test methods executed.
  - `failures` — assertion failures (`AssertionError`).
  - `errors` — unexpected exceptions.
  - `skipped` — tests marked `@Disabled` or `@Ignore`.
  - Failed/errored methods appear as `<testcase>` children containing `<failure>` or `<error>` with the message and stack trace. Read those elements to diagnose the root cause.

- **Plain-text** (`target/surefire-reports/*.txt`): human-readable summary per class. Use these when the XML is noisy or when the failure message is truncated in the XML. The `.txt` file contains the full exception trace.

- **Stale check**: `target/surefire-reports/` must exist AND its mtime must be more recent than `src/test/` mtime. If the directory is missing or older than the source, emit `BLOCKED_TESTER: surefire-reports absent or stale — run the build first`.

#### Diagnosing a Surefire failure

1. Read the `*.xml` file for the failing class and locate the `<failure>` or `<error>` element.
2. If the message is `ComparisonFailure` or `AssertionError`, compare expected vs. actual values to identify the broken assertion.
3. If the message indicates a missing bean, context load error, or `NullPointerException` before any assertion, the issue is likely test setup (missing `@MockBean`, wrong `@SpringBootTest` slice). Read the corresponding `*.txt` file for the full stack trace.
4. Map the failure back to the source class under test and identify whether the fix is in the test itself or in the production code.

#### JaCoCo reports (coverage)

- **HTML** (`target/site/jacoco/index.html`): human-readable overview. Read it to get the project-level coverage percentage quickly. The summary row at the bottom shows line, branch, and instruction coverage for the whole project.

- **CSV** (`target/site/jacoco/jacoco.csv`): machine-readable per-class coverage. Columns: `GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED`. Read this file to identify which specific classes fall below the coverage target.

- **XML** (`target/site/jacoco/jacoco.xml`): authoritative for programmatic analysis. Must be present. If absent: emit `BLOCKED_TESTER: jacoco.xml absent — build with -Pcoverage or ensure JaCoCo is bound to the verify phase`.

- **Line coverage % (project total)**: from `jacoco.xml`, take the **last** `<counter type="LINE" .../>` element in the file — JaCoCo emits the report-level totals after every `<package>`, so the final `<counter type="LINE">` in the document is always the project total. Equivalent XPath: `/report/counter[@type='LINE']` (direct child of `/report`, not nested inside `<package>`, `<class>`, `<sourcefile>`, or `<method>`).

  - If using `grep` (no XPath tool available): `grep -E '^<counter[^>]*type="LINE"' jacoco.xml | tail -1` — JaCoCo's emitter writes one `<counter>` per line and emits root-level counters last.
  - If using `xmlstarlet` or similar: `xmlstarlet sel -t -v "/report/counter[@type='LINE']/@covered" -o "/" -v "/report/counter[@type='LINE']/@missed" jacoco.xml`
  - Formula: `covered / (covered + missed) * 100`
  - Do **not** sum per-package counters and treat that as the total: per-method/per-class counters double-count up the hierarchy if added together. Use the root counter only, or sum **only** `<package>` direct children of `<report>`.

#### Diagnosing a coverage gap from JaCoCo

1. Read `target/site/jacoco/jacoco.csv` to identify classes with `LINE_MISSED > 0`.
2. For each under-covered class, read `target/site/jacoco/<package>/<ClassName>.html` (the per-class HTML report) — JaCoCo highlights uncovered lines in red and partially covered branches in yellow.
3. Determine whether the uncovered lines represent business logic that must be tested or dead/generated code that can be excluded via `@Generated` or a JaCoCo exclusion pattern in `pom.xml`.

### Coverage target

A high coverage target such as 90% line coverage is recommended.

### BLOCKED_TESTER conditions specific to Spring Boot

- `BLOCKED_TESTER: surefire-reports absent or stale — run the build first`
- `BLOCKED_TESTER: jacoco.xml absent — build with -Pcoverage or ensure JaCoCo is bound to the verify phase`
- `BLOCKED_TESTER: integration tests require running infrastructure — confirm Docker/Testcontainers environment before emitting IT steps`
- `BLOCKED_TESTER: framework Spring Boot Gradle not in cookbook — add it before planning`

### Do NOT

- Do not run `mvn` commands yourself — always delegate `mvn` to applier. Tester writes tests (Edit/Write) and reads reports (Read); applier executes the build.
- Do not infer coverage from source-file line counts.
- Do not emit `-DskipTests` as an IT-only workaround.
- Do not invoke `failsafe:integration-test` or `failsafe:verify` as bare goals.
- Do not sum per-package `<counter>` values to compute the project total.
- Do not interpret a stale `target/` directory as the result of the current build — always verify the mtime after applier returns.
