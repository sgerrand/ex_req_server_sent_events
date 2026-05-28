%{
  parallel: true,
  hooks: [
    pre_commit: [
      {GitHoox.Hooks.Shell, run: "actionlint {files}", files: ~w(.github/workflows/*.yml)},
      {GitHoox.Hooks.Shell,
       run: "check-jsonschema --builtin-schema vendor.github-workflows {files}",
       files: ~w(.github/workflows/*.yml)},
      {GitHoox.Hooks.Shell,
       run: "check-jsonschema --builtin-schema vendor.dependabot {files}",
       files: ~w(.github/dependabot.yml .github/dependabot.yaml)},
      {GitHoox.Hooks.Shell,
       run:
         "check-jsonschema --schemafile https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json {files}",
       files: ~w(release-please-config.json)},
      {GitHoox.Hooks.Shell,
       run:
         "check-jsonschema --schemafile https://raw.githubusercontent.com/googleapis/release-please/main/schemas/manifest.json {files}",
       files: ~w(.release-please-manifest.json)},
      {GitHoox.Hooks.Shell, run: "mado check {files}", files: ~w(*.md)},
      {GitHoox.Hooks.Shell, run: "mix compile --warnings-as-errors"},
      {GitHoox.Hooks.Format, check_only: true}
    ],
    pre_push: [
      {GitHoox.Hooks.Shell, run: "mix deps.unlock --check-unused"},
      {GitHoox.Hooks.Credo, strict: true},
      {GitHoox.Hooks.Dialyzer, []},
      {GitHoox.Hooks.Shell, run: "mix docs --warnings-as-errors"},
      {GitHoox.Hooks.Shell, run: "mix test --warnings-as-errors"}
    ]
  ]
}
