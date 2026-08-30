# Prior art for `--check-ci`'s one rule

## The question

`--check-ci` enforces one rule: every step with a `run:` key must be exactly one
invocation of one declared gate set. Two questions about it, and the second is
the one that matters.

1. **The rule.** Does any other tool prevent a CI workflow from duplicating the
   command list that already lives in a local task definition — and if so, what
   *shape* does its rule have?
2. **The classification.** Among tools that statically read `.github/workflows/*.yml`
   and look at `run:` steps, does any of them distinguish "this step is
   legitimate infrastructure" from "this step is logic that belongs elsewhere"?
   How do they avoid false positives on setup steps, and what is the escape
   hatch?

Everything below is from the tools' own repositories, official documentation, or
their own issue trackers. Where a fact could not be established it says **not
found** rather than guessing. One section is explicitly marked as an author's
blog rather than documentation.

---

## A. Task runners: does any of them check the CI file?

**No. Not one of fifteen.** Two ship a generator, neither with a check mode. The
universal documented answer to drift is a convention — "put one line in CI" —
enforced by nothing.

| Tool | Verifier | Generator | "workflow = one line" stated in docs? |
|---|---|---|---|
| [just](https://just.systems/man/en/) | not found | not found | **no such statement** |
| [go-task](https://taskfile.dev/docs/guide#ci-integration) | not found | not found | no — implied by its own repo only |
| [mise](https://mise.jdx.dev/cli/generate/github-action.html) | not found | **yes** | yes, via the generator |
| [cargo-make](https://sagiegurari.github.io/cargo-make/#usage-ci) | not found | not found | **yes, strongest** |
| [cargo-xtask](https://github.com/matklad/cargo-xtask) | n/a (spec, no code) | n/a | **stated 2019, retracted 2024** |
| [mage](https://magefile.org/magefiles/) | not found | not found (`-init` writes a magefile) | no |
| [invoke](https://www.pyinvoke.org/development.html) | not found | not found | no — docs say read the CI file yourself |
| [GNU make](https://www.gnu.org/software/make/manual/make.txt) | none exists | n/a | manual has zero mentions of CI |
| [moon](https://moonrepo.dev/docs/guides/ci) | not found | not found | yes — `moon ci` |
| [Nx](https://github.com/nrwl/nx/tree/master/packages/workspace/src/generators/ci-workflow) | not found | **yes** | no — "must invoke", not "must **only** invoke" |
| [Turborepo](https://turborepo.com/docs/guides/ci-vendors/github-actions) | not found | not found | no — its own example has three `run:` steps |
| [Earthly](https://github.com/earthly/earthly/blob/main/docs/ci-integration/guides/gh-actions-integration.md) | not found | not found | no — its example keeps `docker login` |
| [Dagger](https://github.com/dagger/dagger/blob/main/docs/versioned_docs/version-0.16/ci/adopting.mdx) | not found | yes (third-party module) | **no, explicitly** |
| [Bazel](https://github.com/bazelbuild/bazel/blob/master/site/en/remote/ci.md) / [Buck2](https://github.com/facebook/buck2/tree/main/docs) | not found | not found | not found — no general CI guide exists |

### A.1 `cargo-xtask` — the convention xtask is named after tried this and backed out

This is the closest thing to first-party precedent, and it is a retraction.

The spec once blessed a standard `cargo xtask ci` task. Verbatim, from the README
[at commit `33bb762`](https://github.com/matklad/cargo-xtask/blob/33bb7623e433467674a2597130e675cce1745624/README.md#cargo-xtask-ci):

> This task should run `cargo test` and any additional checks that are required
> on CI, like checking formatting, running `miri` test, checking links in the
> documentation. The CI configuration should generally look like this:
>
> ```yaml
> script:
>   - cargo xtask ci
> ```
>
> The expectation is that, if `cargo xtask ci` passes locally, the CI will be
> green as well.
>
> You don't need this task if `cargo test` is enough for your purposes.
> Moreover, there are certain tradeoffs associated with using xtasks instead of
> CI provider's built-in ways to specify CI process. So, we do not recommend to
> blindly use `xtask ci` over `.travis.yml` [...]

The caution in that last paragraph was added *in the same commit* as the
blessing. The whole section is gone from
[the current README](https://github.com/matklad/cargo-xtask/blob/master/README.md#standard-xtasks),
which now says only:

> To my knowledge, no such conventional xtasks emerged so far.

The reasoning survives in
[issue #1, "Does CI fit as a standard xtask?"](https://github.com/matklad/cargo-xtask/issues/1),
still open. epage's objections are the design constraints any such rule inherits:

> - Some CI steps you want to run under every environment (`test`) while others
>   you only run once for performance (`rustfmt`, `clippy`) but this instead
>   couples the CI tasks together
> - Some CI steps you only want to run under special environments [...]
> - Care is needed so that both the users and the CI do not think the CI is hung.
> - Can't leverage CI UX features to call out what step in the process failed
>   ("CI failed" vs "clippy failed")

The author's own writing (blog, **not** documentation — flagged as such) states
the philosophy without any enforcement mechanism:
["To avoid both the bloat and proliferation of ad-hoc workflows, write all automation in Rust in a dedicated crate. One pattern useful for this is cargo xtask."](https://matklad.github.io/2021/08/22/large-rust-workspaces.html)

### A.2 The flagship xtask user does the thing the rule refuses

[rust-analyzer's `ci.yaml`](https://github.com/rust-lang/rust-analyzer/blob/master/.github/workflows/ci.yaml)
has exactly one xtask invocation — `cargo codegen --check`, an alias defined in
[`.cargo/config.toml`](https://github.com/rust-lang/rust-analyzer/blob/master/.cargo/config.toml)
as `run --package xtask --bin xtask -- codegen`. Every other `run:` step is a
raw command: `cargo nextest run`, `cargo fmt -- --check`, `cargo machete`,
`cargo install rustup-toolchain-install-master@1.11.0`,
`echo "RUSTC_BOOTSTRAP=1" >> $GITHUB_ENV`, `echo "::add-matcher::.github/rust.json"`,
`sed -i '/\[profile.dev]/a opt-level=1' Cargo.toml`.

### A.3 `just` — the drift in its own repository

[`just`'s justfile](https://github.com/casey/just/blob/master/justfile) defines
the composite recipe:

```
ci: test build-book forbid
  cargo lclippy --all --all-targets --all-features -- --deny warnings
  cargo fmt --all -- --check
  cargo update --locked --package just
```

[`just`'s own workflow](https://github.com/casey/just/blob/master/.github/workflows/ci.yaml)
never invokes `just ci`. Its `lint` job re-implements the list as separate steps
— `cargo clippy --all --all-targets`, `cargo fmt --all -- --check`, `./bin/forbid`,
`shellcheck www/install.sh` — and the two copies have already diverged:
`--all-features` and `cargo update --locked` exist only in the justfile,
`shellcheck` only in the workflow. This is the exact defect `--check-ci` exists to
prevent, in the repository of the most widely used task runner, unnoticed.

`just` ships no linter for anything but the justfile's own formatting
([`--fmt --check`](https://just.systems/man/en/formatting-and-dumping-justfiles.html));
a general justfile linter is [an open request, #1587](https://github.com/casey/just/issues/1587).
Its manual's only GitHub Actions content is about installing `just`.

### A.4 `cargo-make` — the strongest "argue the problem away"

cargo-make ships `ci-flow` as a predefined flow whose stated purpose is to be the
one line: ["cargo-make comes with a predefined flow for continuous integration build"](https://sagiegurari.github.io/cargo-make/#usage-ci),
and ["**ci-flow** - Should be used in CI builds (such as travis/appveyor)"](https://sagiegurari.github.io/cargo-make/#usage-predefined-flows).
Every provider example in the docs is one line. Nothing verifies it. Its
`--diff-steps` flag diffs a custom flow against cargo-make's *built-in* flow, not
against a CI file.

### A.5 `mise` — the only generator among the local runners

[`mise generate github-action`](https://mise.jdx.dev/cli/generate/github-action.html):

> This command generates a GitHub Action workflow file that runs a mise task like
> `mise run ci` when you push changes to your repository.

Its `--task` and `--name` both default to `ci`. The emitted workflow is
`actions/checkout`, `jdx/mise-action`, `- run: mise run ci`. The source
([`src/cli/generate/github_action.rs`](https://github.com/jdx/mise/blob/main/src/cli/generate/github_action.rs))
has only `--write` or print-to-stdout — **no check or diff mode**. Regenerating
overwrites; it does not reconcile.

mise's own [Continuous Integration page](https://mise.jdx.dev/continuous-integration.html)
is about tool provisioning, and its GitHub Actions example ends with
`- run: shellcheck scripts/*.sh` — a raw command. The generator and the CI page
disagree about the recommended shape. mise's
[own test workflow](https://github.com/jdx/mise/blob/main/.github/workflows/test-impl.yml)
mixes `mise run test:e2e …` and `mise x -- …` with `brew install fd tmux`,
`sudo apt-get install -y mold`, and `echo "$PWD/target/debug" >> "$GITHUB_PATH"`.

### A.6 `moon` — the only tool that *joins* the two lists instead of comparing them

moon's mechanism is the closest structural analogue to `gate:`. Per-task
[`runInCI`](https://moonrepo.dev/docs/guides/ci) says which tasks a CI job runs,
and the workflow is one line:

> By default, all tasks run in CI, as you should always be building, linting,
> typechecking, testing, so on and so forth. However, this isn't always true, so
> this can be disabled on a per-task basis through the `runInCI` option.

The documented GitHub workflow is `actions/checkout`, `moonrepo/setup-toolchain`,
`- run: 'moon ci'`, and the Travis form is one line, `script: 'moon ci'`. There
is **no verifier**: nothing in moon reads the workflow back, and `moon check` is
not a validator —
["will run _all_ build and test tasks for one or many projects"](https://github.com/moonrepo/moon/blob/master/website/docs/commands/check.mdx).
`moon init` scaffolds `.moon/` only, and no CI-generator exists in
[the moonrepo org](https://github.com/orgs/moonrepo/repositories). And moon's
[own workflow](https://github.com/moonrepo/moon/blob/master/.github/workflows/moon.yml)
already breaks the one-line shape — the `ci` job has a second `run:` step
(`cat .moon/cache/daemon/server.log || true`, guarded by `if: success() || failure()`)
and the `docker` job is `cargo build`, `./target/debug/moon --version`,
`./target/debug/moon docker scaffold website --log trace`.

### A.7 Nx — its official generator emits the very steps the rule refuses

Nx ships a CI-workflow generator. Its GitHub template
([`__workflowFileName__.yml__tmpl__`](https://github.com/nrwl/nx/blob/master/packages/workspace/src/generators/ci-workflow/files/github/.github/workflows/__workflowFileName__.yml__tmpl__))
emits, verbatim:

```
      - run: corepack enable
      - run: <%= packageManagerInstall %>
      - run: <%= packageManagerPrefix %> cypress install
      - run: <%= packageManagerPrefix %> playwright install --with-deps
```

before any Nx command. The Nx commands themselves are exactly three
([`getCiCommands`](https://github.com/nrwl/nx/blob/master/packages/workspace/src/generators/ci-workflow/ci-workflow.ts)):
a cloud-record command, the affected-tasks command, and a cloud-fix command. So
the tool with the strongest opinion about CI integration generates a workflow in
which most `run:` steps are not invocations of it — and `playwright install --with-deps`,
the exact example that triggered this question, is one it writes itself.

Nx also has the only first-party *statement* of the rule, and it is deliberately
"must invoke", not "must **only** invoke". From
[Set up CI](https://github.com/nrwl/nx/blob/master/astro-docs/src/content/docs/getting-started/setup-ci.mdoc),
under the heading "Make sure CI invokes Nx CLI":

> Remote caching, affected, distribution, and self-healing only kick in when `nx`
> runs your tasks. `nx test` is fine, and so is `npm test` if it wraps `nx test`.
> Direct calls to `jest`, `tsc`, or `eslint` bypass Nx Cloud. If you have a
> workflow file, swap raw tool invocations for `nx run-many` or `nx affected`.

Two mechanisms sit behind it, and between them they are the closest anything in
this survey comes to auditing a workflow somebody else wrote:

- **The audit exists, as a prompt.** The same file carries an `llm_copy_prompt`
  block instructing an agent: *"**Yes, but it calls raw tooling directly**
  (`jest`, `tsc`, `eslint`, etc.): work with me to update it. Propose minimal
  edits swapping the raw calls for `nx run-many -t <task>` [...] Show me the diff
  and wait for approval before writing."* That is a workflow audit specified in
  prose. There is no deterministic implementation of it.
- **Drift detection by cache invalidation.**
  [`addWorkflowFileToSharedGlobals()`](https://github.com/nrwl/nx/blob/master/packages/workspace/src/generators/ci-workflow/ci-workflow.ts)
  writes the generated workflow's path into `nx.json`'s `namedInputs.sharedGlobals`,
  making the CI file a hash input of every task. Editing the workflow invalidates
  the cache. It does not verify anything, but it is the one place any tool treats
  the workflow file as part of the pipeline definition.

### A.8 Turborepo, Earthly, Dagger

[Turborepo's GitHub Actions guide](https://turborepo.com/docs/guides/ci-vendors/github-actions)
gives a canonical workflow with three `run:` steps — `pnpm install`, `pnpm build`,
`pnpm test` — and they go through `package.json` scripts, not through `turbo`
directly. No verifier, no generator.

Turborepo ships a rule about CI steps, and it is about *argument form only*.
From Vercel's first-party agent skill,
[`skills/turborepo/references/ci/RULE.md`](https://github.com/vercel/turborepo/blob/main/skills/turborepo/references/ci/RULE.md):
"**Never use the `turbo <tasks>` shorthand in CI or scripts.** Always use
`turbo run`" — the stated reason being future subcommand name collisions, not
drift ([public docs](https://turborepo.com/docs/crafting-your-repository/constructing-ci)).
The same skill's
[`ci/patterns.md`](https://github.com/vercel/turborepo/blob/main/skills/turborepo/references/ci/patterns.md)
explicitly endorses branch logic living in the workflow (`if: github.event_name == 'pull_request'`
→ `--affected`). Nothing constrains what else a step may do.

Earthly ([no longer actively maintained](https://github.com/earthly/earthly/blob/main/README.md))
keeps infrastructure in the workflow by design. Its
[GitHub Actions guide](https://github.com/earthly/earthly/blob/main/docs/ci-integration/guides/gh-actions-integration.md)
is setup, checkout, **`docker login --username "$DOCKERHUB_USERNAME" --password "$DOCKERHUB_TOKEN"`
as a `run:` step**, then one `earthly --ci --push +build` — a vendor-blessed
instance of a second false positive from the list that prompted this. The
[CI overview](https://github.com/earthly/earthly/blob/main/docs/ci-integration/overview.md)
says why: "Earthly has two software dependencies: `docker` and `git`. Because
`earthly` will not install these for you, please ensure they are present before
proceeding." Its own
[`reusable-test.yml`](https://github.com/earthly/earthly/blob/main/.github/workflows/reusable-test.yml)
carries three infrastructure `run:` steps to one pipeline step. No verifier found.

Dagger states the position most directly of anyone. From
["Dagger for CI: Day 2"](https://github.com/dagger/dagger/blob/main/docs/versioned_docs/version-0.16/ci/adopting.mdx):

> Taken to the extreme, this process reduces the entire CI configuration to a
> single `dagger call`, with everything else happening inside Dagger. Although
> this sometimes happens, **in practice most projects converge to a middle
> ground**, where the CI configuration shrinks to just enough `dagger call`
> invocations to take advantage of proprietary CI features.

with a structural reason the workflow cannot collapse: "Remember that *Dagger
pipelines are not distributed* [...] It's the responsibility of the CI system to
dispatch jobs across multiple machines." Its own documented realistic example is
two jobs joined by `needs:`, each with `actions/checkout` and a dagger step.

Dagger's 1.0-beta answer to drift is to delete the second definition rather than
check it — [Cloud Checks](https://github.com/dagger/dagger/blob/main/docs/current_docs/getting-started/cloud-checks.mdx):
"**You do not need a CI workflow file.** [...] Cloud Checks run the same Checks
that `dagger check` runs locally."

Its ecosystem also has [`shykes/gha`](https://github.com/shykes/gha),
"Generate Github Actions configurations from Dagger pipelines". Two details are
directly useful:

- **Its coexistence rule is a first-line ownership marker.** From
  [`main.go`](https://github.com/shykes/gha/blob/main/main.go): every file under
  `.github/workflows` whose contents do not start with `# This file was generated.`
  is copied through untouched — `if !strings.HasPrefix(contents, "# This file was generated.")`.
  The generator claims files, not the directory.
- **Even its generated output is not one `run:` step.** The committed
  [`demo-pipeline-1.gen.yml`](https://github.com/shykes/gha/blob/main/.github/workflows/demo-pipeline-1.gen.yml)
  contains an install-script step that writes `printf '%s/bin' "$prefix_dir" >> $GITHUB_PATH`.

Its `Validate` function checks the *pipeline definition* (secret names, that the
named command and module exist), not the workflow.

### A.9 The strictest real-world instance still has four infrastructure steps

TigerBeetle is about as close to the one-line ideal as production code gets. Its
[`release.yml`](https://github.com/tigerbeetle/tigerbeetle/blob/main/.github/workflows/release.yml)
funnels the work into a single
`./zig/zig build --summary all scripts -- release --build --publish --sha=…`
step — and still carries `rustup default 1.63 && rustup component add clippy rustfmt`,
`pip install twine`, `./zig/download.sh`, and an "Alert if anything failed" step.

### A.10 Bazel and Buck2 have no position at all

Bazel's documentation has exactly one CI page,
[`site/en/remote/ci.md`](https://github.com/bazelbuild/bazel/blob/master/site/en/remote/ci.md),
and it is scoped to "owners and maintainers of Bazel rule repositories [...] to
test your rules for compatibility against a remote execution scenario". There is
no general "using Bazel in CI" guide and no statement that a CI step must invoke
`bazel`. Bazel's *own* CI does have a config validator — the `validate_config`
option in [`buildkite/README.md`](https://github.com/bazelbuild/continuous-integration/blob/master/buildkite/README.md)
— but it validates `.bazelci/*.yml` against bazelci's schema, not a provider
workflow against BUILD files. Same shape as Renovate's: schema, one file, in
isolation.

[Buck2's docs](https://github.com/facebook/buck2/tree/main/docs) have no CI page
at all. The only first-party CI material,
[buck2-change-detector](https://github.com/facebookincubator/buck2-change-detector),
describes CI as a five-step shell procedure you write yourself and declines to
own the orchestration: "This repo doesn't provide any support for running the
subsequent `build`/`test`."

### A.11 GNU make and the aggregate

The [GNU Make manual](https://www.gnu.org/software/make/manual/make.txt) contains
zero occurrences of "continuous integration" or "github". Its only target
convention is
[§16.6 Standard Targets for Users](https://www.gnu.org/software/make/manual/html_node/Standard-Targets.html)
— `all`, `install`, `clean`, `check` — defined for humans packaging software, not
for CI. [checkmake](https://github.com/checkmake/checkmake) has five rules
(`maxbodylength`, `minphony`, `phonydeclared`, `timestampexpanded`,
`uniquetargets`) and never opens a CI file.

`invoke`'s docs are the honest baseline the rule replaces —
["Another good resource is to skim our `.circleci/config.yml` file for the commands it executes"](https://www.pyinvoke.org/development.html).

**The niche is empty.** Two generators, neither with a check mode; zero
verifiers; one audit written as a prompt for a language model. Every
runner does expose machine-readable task metadata a checker could consume —
`just --dump --dump-format json`, `task --list --json`, `mise tasks ls --json`,
`inv --list -F json` — and nobody has built the thing that consumes it.

---

## B. Workflow linters: how do they classify a `run:` step?

**No tool anywhere classifies a `run:` step as infrastructure versus logic.**
That axis does not exist. Everything that reads a `run:` body reads it for
*taint* (untrusted `${{ }}`) or for *known-bad commands*. Three rules come close
in shape, none in intent.

### B.1 The three rules that have the shape "a `run:` step must not do X"

**[zizmor `adhoc-packages`](https://github.com/zizmorcore/zizmor/blob/main/docs/audits.md#adhoc-packages)** —
the purest structural match to `--check-ci`'s rule found anywhere:

> Detects `run:` steps that install or manipulate packages in an ad-hoc manner,
> i.e. outside of a managed and locked manifest.

Its implementation
([`adhoc_packages.rs`](https://github.com/zizmorcore/zizmor/blob/main/crates/zizmor/src/audit/adhoc_packages.rs))
parses the body with tree-sitter as bash or pwsh, then classifies per tool. The
detail worth stealing: **bare `npm install` is exonerated and `npm install foo` is
not**, because without a package name the command is lockfile-aware. The
exoneration is a property of the *arguments*, not of the step's role.

**[zizmor `github-env`](https://github.com/zizmorcore/zizmor/blob/main/docs/audits.md#github-env)** —
the one tool with an opinion about writes to `$GITHUB_ENV`, and it is
context-gated three ways
([`github_env.rs`](https://github.com/zizmorcore/zizmor/blob/main/crates/zizmor/src/audit/github_env.rs)):

1. Nothing is flagged at all unless the workflow has `pull_request_target` or
   `workflow_run`.
2. A write is exonerated iff the command is `echo`/`printf` **and every argument
   is a string literal**. `echo "FOO=bar" >> $GITHUB_ENV` is clean;
   `echo "FOO=$(cmd)" >> $GITHUB_ENV` is not.
3. `$GITHUB_OUTPUT` is not audited at all — the remediation actively recommends
   it: "If you need to pass state between steps, consider using `GITHUB_OUTPUT`
   instead."

**[Checkov `CosignArtifacts` (CKV_GHA_5)](https://github.com/bridgecrewio/checkov/blob/main/checkov/github_actions/checks/job/CosignArtifacts.py)** —
the only *role* classification found, and it is `str.__contains__`. A step "is a
build" if its `run:` text contains one of seven strings
([`artifact_build.py`](https://github.com/bridgecrewio/checkov/blob/main/checkov/github_actions/common/artifact_build.py)):
`docker build`, `ko build`, `buildah bud`, `buildah build`, `podman image build`,
`podman build`, `nerdctl build`. No shell parsing, no negation handling, no
comment stripping.

### B.2 The inverse direction exists, and its rationale is not organisation

[zizmor `superfluous-actions`](https://github.com/zizmorcore/zizmor/blob/main/docs/audits.md#superfluous-actions)
is the only rule in the space that reasons about *where work belongs* — and it
points the other way, from `uses:` toward `run:`:

> Detects actions that are known to be "superfluous," i.e. perform an operation
> already provided by GitHub's own runner images.
>
> Usage of these actions is not *itself* a security concern.

It works from a fixed replacement table, not from any semantic notion.

### B.3 What everything else does with `run:`

**[actionlint](https://github.com/rhysd/actionlint)** delegates. Its `run:`-touching
checks are shellcheck and pyflakes
([docs/checks.md](https://github.com/rhysd/actionlint/blob/main/docs/checks.md#shellcheck-integration-for-run))
— shell *syntax*, not semantics — plus one genuine content rule,
[`deprecated-commands`](https://github.com/rhysd/actionlint/blob/main/rule_deprecated_commands.go),
a regex for `::set-output::`/`::set-env::`/`::add-path::`. Its remediation is to
write `echo "{name}={value}" >> $GITHUB_ENV`: actionlint tells you to write the
thing zizmor flags at high severity, and `--check-ci` refuses outright.

**[Semgrep](https://github.com/semgrep/semgrep-rules/tree/develop/yaml/github-actions/security)**
has the most precise mechanism — it nests a bash parser inside the YAML match via
`metavariable-pattern: language: bash`. See
[`gha-curl-pipe-shell.yaml`](https://github.com/semgrep/semgrep-rules/blob/develop/yaml/github-actions/security/gha-curl-pipe-shell.yaml).
Its maintenance cost is the warning:
[`run-shell-injection.yaml`](https://github.com/semgrep/semgrep-rules/blob/develop/yaml/github-actions/security/run-shell-injection.yaml)
carries roughly 33 patterns and a matching set of `pattern-not` carve-outs for
"looks like a violation, isn't".

**[KICS](https://github.com/Checkmarx/kics/blob/master/assets/queries/cicd/github/run_block_injection/query.rego)**
is the other context-gated rule: the same `run:` text is a finding under
`pull_request_target` and not under other triggers.

**[StepSecurity harden-runner](https://docs.stepsecurity.io/github/orchestrate-security/secure-workflow)**
has no static `run:` rule at all. Its three static transforms are token
permissions, injecting the agent, and SHA-pinning. Enforcement is runtime egress,
and its allowlist is *network endpoints* — discovered from an
`egress-policy: audit` run rather than hand-written.

**[ratchet](https://github.com/sethvargo/ratchet#excluding)** and
**[action-validator](https://github.com/mpalmer/action-validator)** never read
`run:`. action-validator is JSON Schema plus glob and `needs:` checks; it has
**no exemption mechanism of any kind** — grep for `ignore|disable|suppress`
returns nothing.

**[super-linter](https://github.com/super-linter/super-linter/blob/main/README.md#supported-linters)**
owns no rules; it delegates GitHub Actions to actionlint *and* zizmor.

**octoherd** is [a bulk-repo scripting framework](https://github.com/octoherd/cli#usage),
not a linter. Not applicable.

### B.4 GitHub itself offers nothing

Repository rulesets constrain refs, commits, status checks, and file *paths* —
[none inspects file content](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).
Actions policies allowlist which actions and reusable workflows may be referenced,
i.e. `uses:` —
[nothing about `run:` commands](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository).
There is no first-party way to assert "a workflow may only run these commands".

### B.5 Exemption ergonomics — this is where the answer is

| Tool | Inline directive | Rule-scoped | Reason field | Config-file form |
|---|---|---|---|---|
| [zizmor](https://docs.zizmor.sh/usage/#ignoring-results) | `# zizmor: ignore[a,b] why` | yes | yes | `rules.<id>.ignore: [file, file:line, file:line:col]` |
| [Checkov](https://www.checkov.io/2.Basics/Suppressing%20and%20Skipping%20Policies.html) | `# checkov:skip=CKV_GHA_3:reason` | yes | yes | `--skip-check` |
| [Semgrep](https://docs.semgrep.dev/ignoring-files-folders-code) | `# nosemgrep: rule-id` | yes | no | `.semgrepignore` |
| [KICS](https://docs.kics.io/latest/running-kics/#using-commands-on-scanned-files-as-comments) | `# kics-scan ignore-line` | **no — silences every rule** | no | `# kics-scan disable=<id>`, first line only |
| [actionlint](https://github.com/rhysd/actionlint/blob/main/docs/usage.md#ignore-some-errors) | **none** | no — regex over the message text | no | `paths.<glob>.ignore: [regex]` |
| [ratchet](https://github.com/sethvargo/ratchet#excluding) | `# ratchet:exclude` | n/a (one rule) | no | none |
| [Conftest](https://www.conftest.dev/exceptions/) | none | yes | comment only | `exception contains rules if { … }` |

Three findings matter more than the table.

**actionlint's lack of an inline directive is a known, long-standing gap.**
[Issue #237, "Inline ignores in files"](https://github.com/rhysd/actionlint/issues/237),
opened 2022-10-20, is still open. actionlint's YAML layer never reads comment
nodes at all, so the mechanism is structurally absent. What exists instead is
regex matching on the *error message*, keyed by path glob — the worst ergonomics
in the space, and precedent for what to avoid.

**zizmor's docs state the design position directly.** On why the escape hatch
exists at all:

> zizmor's defaults are not always 100% right for every possible use case.

On why it refuses to build a finer allowlist for `template-injection`
([`template_injection.rs`](https://github.com/zizmorcore/zizmor/blob/main/crates/zizmor/src/audit/template_injection.rs)):

> This is because `zizmor` considers all template expansions in code contexts to
> be code smells, and attempting to selectively permit them is more error-prone
> than forbidding them in a blanket fashion.

And on the danger of the blunt form of the hatch
([configuration docs](https://docs.zizmor.sh/configuration/)):

> For most users, disabling audits should be a measure of last resort. Disabled
> rules don't show up in ignored or suppressed finding counts, making it very
> easy to accidentally miss important new findings.

That is the whole recommendation in three quotes: keep the blanket rule, give it
a per-site hatch, and keep the suppressions visible in the report.

**Conftest's `exception` is the only mechanism that exempts a *class*.** Every
other tool exempts named sites. If the exemption you want is "…unless the step is
infrastructure", that is a predicate, and only Conftest lets you write one —
[at the cost of the definition of "infrastructure" becoming your problem](https://www.conftest.dev/exceptions/).

**One placement trap, worth knowing if both tools run on the same file.** zizmor's
directive must be a YAML comment, so on a block scalar it goes *after* the `|`:

```yaml
run: | # zizmor: ignore[template-injection]
  echo "${{ github.event.issue.title }}"
```

whereas shellcheck's directive, which actionlint passes through, must go *inside*
the block, on the line directly above the offending line — actionlint prepends
`set -eo pipefail` as line 1, so a file-wide directive at the top of a `run:`
block silently degrades to a statement-level one.

---

## C. The closest analogues outside CI

### C.1 pre-commit — the one-line pattern, and a staleness check on its own escape hatch

The CI one-liner, from
[Usage in continuous integration](https://pre-commit.com/#usage-in-continuous-integration):

> pre-commit can also be used as a tool for continuous integration. For instance,
> adding `pre-commit run --all-files` as a CI step will ensure everything stays in
> tip-top shape.

**pre-commit ships nothing that checks the CI file calls it.** Its
`validate-config` command is
[a fifteen-line schema wrapper](https://github.com/pre-commit/pre-commit/blob/main/pre_commit/commands/validate_config.py);
no command reads `.github/`.

Its escape hatches are `exclude:` regexes ([top level](https://pre-commit.com/#top_level-exclude)
and [per hook](https://pre-commit.com/#config-exclude)), the `SKIP` environment
variable ([Temporarily disabling hooks](https://pre-commit.com/#temporarily-disabling-hooks):
"pre-commit solves this by querying a `SKIP` environment variable"), and
[pre-commit.ci's `skip:` list](https://pre-commit.ci/#configuration).

The part worth copying is [meta hooks](https://pre-commit.com/#meta-hooks):

> `check-hooks-apply` — ensures that the configured hooks apply to at least one
> file in the repository.
>
> `check-useless-excludes` — ensures that `exclude` directives apply to _any_
> file in the repository.

Verbatim from
[`check_useless_excludes.py`](https://github.com/pre-commit/pre-commit/blob/main/pre_commit/meta_hooks/check_useless_excludes.py):
`'The exclude pattern {exclude!r} for {hook["id"]} does not match any files'`.

This is the only answer in the survey to the standard objection that ignore lists
rot: a second-order check that every exemption still names something real.

### C.2 Dependabot — what happens when the hatch is invisible

`@dependabot ignore this dependency` writes to a hidden per-repository store.
GitHub then had to add `@dependabot show DEPENDENCY_NAME ignore conditions` to
read it back and three flavours of `@dependabot unignore` to undo it
([comment commands](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-pull-request-comment-commands)),
and the docs now steer away from the mechanism entirely:

> If you run any of the commands for ignoring dependencies or versions, Dependabot
> stores the preferences for the repository centrally. While this is a quick
> solution, for repositories with more than one contributor it is better to
> explicitly define the dependencies and versions to ignore in the configuration
> file.

Neither Dependabot nor Renovate validates one file against another. Renovate's
[`renovate-config-validator`](https://docs.renovatebot.com/config-validation/) is
schema-only, on files in isolation; Dependabot ships no validator at all.

### C.3 tox-gh — join at runtime rather than compare files

The closest thing to a solved version of "the CI matrix and the local env list
must not be written twice". The mapping lives in the tox config, not the workflow
([tox-gh README](https://github.com/tox-dev/tox-gh)):

```toml
[gh.python]
"3.13" = ["py313"]
"3.12" = ["py312"]
```

And the join happens through the ambient interpreter, never by parsing YAML —
["it checks if running in GitHub Actions (`GITHUB_ACTIONS=true`) [...] detects the current Python version via `virtualenv`'s introspection, matches the version against the `[gh.python]` mapping, and overrides tox's `env_list`"](https://github.com/tox-dev/tox-gh#how-environment-selection-works).

Its escape hatch is an override: `tox -e py313,lint` or `TOXENV=…`, and
["when you specify environments explicitly, tox-gh respects your choice and skips its own selection logic"](https://github.com/tox-dev/tox-gh#how-to-bypass-tox-gh-environment-selection).

The predecessor is precedent for shipping *without* a hatch and regretting it —
[tox-gh-actions 2.0](https://github.com/ymyzk/tox-gh-actions#overriding-environments-to-run):

> _Changed in 2.0_: When a list of environments to run is specified explicitly via
> `-e` option or `TOXENV` environment variable, tox-gh-actions respects the given
> environments [...] Before 2.0, tox-gh-actions was always enforcing its
> configuration even when a list of environments is given explicitly.

### C.4 rustdoc — a graded ladder, and a reason at the site

Rust doctests are the cleanest per-instance inline opt-out
([documentation tests](https://doc.rust-lang.org/rustdoc/write-documentation/documentation-tests.html)).
The ladder gives up verification one rung at a time: hidden `#` lines (still fully
tested) → `no_run` (still compiled) → `compile_fail`/`should_panic` (still run,
expectation inverted) → `text` → `ignore`. The docs push you up it:

> Do note that this is almost never what you want as it's the most generic.

And they encode the convention that makes an inline hatch survive review:

> It is customary to add the reason why it should be ignored in a `(…)` comment.

### C.5 cog — generate, then `--check` the derived text

[cog](https://cog.readthedocs.io/en/latest/running.html) is the clean form of the
alternative ADR 0003 refused: `--check` ("Check that the files would not change if
run again"), `--diff`, and `-e` ("Warn if a file has no cog code in it") as the
inverse guard against someone deleting the markers. Its exemption is not an
ignore mechanism at all — you simply do not put markers around the region.
rust-analyzer runs this shape today as `cargo codegen --check`.

### C.6 editorconfig-checker and cargo-deny — the two fullest hatch designs

[editorconfig-checker](https://github.com/editorconfig-checker/editorconfig-checker)
ships all four shapes at once: `// editorconfig-checker-disable-line`,
`-disable-next-line` (which exists purely for readability), a
`-disable`/`-enable` block pair, `-disable-file` (first line only), an `"Exclude"`
config list, `--dry-run` to show what *would* be checked, and built-in default
excludes with `--ignore-defaults` to opt out of the opt-out.

[cargo-deny](https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html) is
the precedent for the severity dial rather than a binary: every check is
`deny` / `warn` / `allow`, and the per-item skip entries carry a `reason` field:

```toml
skip = [{ name = "ansi_term", version = "=0.11.0", reason = "we want to get rid of this crate but there is still one user of it" }]
```

zizmor has the same dial as
[`rules.<id>.remap.severity`](https://docs.zizmor.sh/configuration/) plus
[personas](https://docs.zizmor.sh/usage/#using-personas) (`regular`, `pedantic`,
`auditor`) — a finding can be demoted to a tier rather than deleted.

### C.7 EditorConfig / Prettier — defer, don't restate

Prettier's answer to "this list must not be written twice" is deference with
silent override: ["If a `.editorconfig` file is in your project, Prettier will parse it and convert its properties to the corresponding Prettier configuration"](https://prettier.io/docs/configuration),
overridable by `.prettierrc` and switchable off with `--no-editorconfig`. **No
linter enforcing "your `.prettierrc` must not restate `.editorconfig`" was found.**
Restating a value is legal, silent, and undetected; only the *conflict* is
specified. That is the null hypothesis for this whole question — most of the
software world tolerates the duplication and specifies only precedence.

---

## D. Options for the rule

The premise the current rule rests on — that a well-formed workflow's `run:`
steps are all gate invocations — is contradicted by every repository that most
believes it, including the two generators. Nx writes `playwright install --with-deps`;
Earthly's own guide writes `docker login`; shykes/gha writes a `$GITHUB_PATH`
append; TigerBeetle keeps four infrastructure steps around one build call; the
README of this repository already says the workflow owns "the checkout, the
toolchain, a browser driver", and there is no way to install a browser driver
except with a `run:` step.

The clearest statement of it is Dagger's, from a project whose entire pitch is
that the pipeline is code and CI just calls it:

> Taken to the extreme, this process reduces the entire CI configuration to a
> single `dagger call` [...] Although this sometimes happens, in practice most
> projects converge to a middle ground.

One further option appears in the survey and is not listed below because it does
not transfer: Nx makes the workflow file a *cache-hash input* of every task
([`addWorkflowFileToSharedGlobals`](https://github.com/nrwl/nx/blob/master/packages/workspace/src/generators/ci-workflow/ci-workflow.ts)),
so editing it invalidates results rather than failing a check. That is drift
detection for a tool that caches. This one does not.

Only `RunsACommand` is at issue. `RunsSomethingRefused` and
`RunsAnUndeclaredGate` are unaffected by everything below.

| Option | Who does this, with a source | What breaks |
|---|---|---|
| **1. Keep the rule; add an inline opt-out on the step** | [zizmor `# zizmor: ignore[rule] why`](https://docs.zizmor.sh/usage/#ignoring-results); [ratchet `# ratchet:exclude`](https://github.com/sethvargo/ratchet#excluding); [rustdoc ` ```ignore (reason) `](https://doc.rust-lang.org/rustdoc/write-documentation/documentation-tests.html); [editorconfig-checker `-disable-line`](https://github.com/editorconfig-checker/editorconfig-checker) | A directive in the workflow is a second surface the tool must define and parse. YAML comment attachment is fiddly — zizmor documents the block-scalar trap. Rots if never revisited. |
| **2. Keep the rule; a key in `xtask.yaml` naming exempt steps or jobs** | [zizmor `rules.<id>.ignore: [file:line:col]`](https://docs.zizmor.sh/configuration/); [StepSecurity Policy Store](https://docs.stepsecurity.io/github-actions/harden-runner/policy-store); [pre-commit `exclude:`](https://pre-commit.com/#config-exclude) | This is exactly the "second place saying what the workflow already says" that [ADR 0003](../adr/0003-check-the-ci-file-rather-than-generate-it.md) refuses for `unrun`. Steps have no stable identity — `name:` is optional, an index moves. `file:line` entries rot on every edit above them. |
| **3. Narrow: refuse only a command some task already runs** | **Nobody, in code.** Nx ships exactly this audit as an [LLM prompt](https://github.com/nrwl/nx/blob/master/astro-docs/src/content/docs/getting-started/setup-ci.mdoc) — "calls raw tooling directly (`jest`, `tsc`, `eslint`) [...] propose minimal edits". Nearest mechanisms: [zizmor `adhoc-packages`](https://github.com/zizmorcore/zizmor/blob/main/crates/zizmor/src/audit/adhoc_packages.rs) parses the command and compares it against a known set; [Checkov `CosignArtifacts`](https://github.com/bridgecrewio/checkov/blob/main/checkov/github_actions/common/artifact_build.py) substring-matches a command list | Fails the case the rule exists for: `- run: dart analyze` added *instead of* a task matches no task and passes. Near-misses (`dart analyze` vs `dart analyze --fatal-infos`) need a similarity judgement. `do:` verbs and `$each` markers have no comparable argv. Requires the checker to read task bodies, which it never does. |
| **4. Narrow: refuse only in jobs that also invoke xtask** | Context-gating has precedent: [zizmor `github-env`](https://github.com/zizmorcore/zizmor/blob/main/docs/audits.md#github-env) fires only under dangerous triggers; [KICS `run_block_injection`](https://github.com/Checkmarx/kics/blob/master/assets/queries/cicd/github/run_block_injection/query.rego) is trigger-conditional | Cheap and refuses almost nothing real. [`just`'s drift lives in a `lint` job that never calls `just`](https://github.com/casey/just/blob/master/.github/workflows/ci.yaml) — the whole-job case is the common one, and this option is blind to it. |
| **5. Report rather than refuse** | [cargo-deny `deny`/`warn`/`allow` per check](https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html); [zizmor `remap.severity` and personas](https://docs.zizmor.sh/configuration/); this tool already does it for `unrun` | A warning in a green run is a warning nobody reads. The rule's force comes from the gate; without it the drift arrives anyway, just annotated. |
| **6. Drop the rule** | Everybody: no task runner in section A verifies its CI file. [Prettier tolerates the duplication and specifies only precedence](https://prettier.io/docs/configuration). The radical form is Dagger 1.0's — ["You do not need a CI workflow file"](https://github.com/dagger/dagger/blob/main/docs/current_docs/getting-started/cloud-checks.mdx) — abolish the second definition instead of checking it, which needs a hosted runner and is not available here | The stated reason `--check-ci` exists. `just`'s repository is what the world looks like without it. |
| **7. Generate the workflow and `--check` the diff** | [cog `--check`](https://cog.readthedocs.io/en/latest/running.html); [Nx ci-workflow](https://github.com/nrwl/nx/tree/master/packages/workspace/src/generators/ci-workflow); [mise generate github-action](https://mise.jdx.dev/cli/generate/github-action.html); rust-analyzer's own `cargo codegen --check` | Refused by [ADR 0003](../adr/0003-check-the-ci-file-rather-than-generate-it.md): generating means templating, and templating is where an expression language starts. Note [shykes/gha's marker](https://github.com/shykes/gha/blob/main/main.go) shows a generator need not own every file — but it must own the file it generates, template and all. |

### Recommendation: option 1, with two conditions

The escape hatch is the answer, not a smarter rule. That is what the evidence
says, in the words of the one project that has thought hardest about it: zizmor
keeps a blanket rule *because* "attempting to selectively permit them is more
error-prone than forbidding them in a blanket fashion", and pays for it with a
first-class per-site ignore. Options 3 and 4 are attempts to make the rule
cleverer; neither has precedent, and each fails a case the rule was written for.

**Inline (option 1) rather than a key in `xtask.yaml` (option 2)** for a reason
the ADR already supplies. An exemption in `xtask.yaml` would have to identify a
step in a file `xtask.yaml` does not own — a second place saying what the workflow
says, which is the objection that made `unrun` a report rather than a refusal. An
annotation on the step is not that: it says nothing about what runs, only that
this step is not a gate. The duplicate-list defect is a *list of commands* in two
places; one word beside the step is not a list.

Follow zizmor's grammar, and ratchet's precedent that a single-rule tool needs no
rule id — and require the reason, which is rustdoc's convention made mandatory:

```yaml
- run: npx playwright install --with-deps # xtask: not-a-gate the driver this suite needs
```

**One implementation constraint, checked.** `package:yaml` discards comments —
its scanner calls `_skipComment()`
([`scanner.dart`](https://github.com/dart-lang/yaml/blob/master/lib/src/scanner.dart))
and `YamlNode` exposes no comment API. So the marker cannot come out of the
parsed tree. It can come out of the source: `YamlNode` does expose
[`span`](https://github.com/dart-lang/yaml/blob/master/lib/src/yaml_node.dart)
("The source span for this node"), so the checker reads the rest of the line the
`run` scalar ends on, and matches a regex. That is exactly how zizmor does it —
its directive is a single regex over the source at the finding's span
([`IGNORE_EXPR` in `finding/location.rs`](https://github.com/zizmorcore/zizmor/blob/main/crates/zizmor/src/finding/location.rs)),
which is also why its docs have to warn that the marker must fall outside a block
scalar. `_shellSteps` currently reads the file and throws the source away; it
would have to keep it.

Two conditions, both from primary sources, both cheap:

**Count the exemptions in the report.** zizmor's warning about `disable:` —
"Disabled rules don't show up in ignored or suppressed finding counts, making it
very easy to accidentally miss important new findings" — applies verbatim. A
`--check-ci` run should say how many steps were exempted and where, the way it
already names the gate sets no job runs.

**Refuse an exemption that exempts nothing.** This is pre-commit's
`check-useless-excludes`, and it is the only known answer to hatch rot: an
annotation on a step that is already one gate invocation is itself a finding.
The checker has the step in hand; the check is free.

Also worth doing regardless of the above: **the module header's own example is a
counterexample.** It names "a browser driver" as something that legitimately
belongs in the workflow, and the rule refuses the only way to put one there.
Either the hatch lands or that sentence should go.

**Not recommended, and why, briefly.** Option 5 (report) weakens the one thing
that makes the rule work, and this tool already knows the difference — it
deliberately reports `unrun` because nothing in the file can decide it, and it
deliberately refuses `RunsACommand` because the file *can*. Option 6 (drop) is
what everyone else does and what `just`'s repository shows the cost of. Option 7
is closed by ADR 0003 and nothing found here reopens it.
