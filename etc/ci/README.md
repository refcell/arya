# CI

`ci.yml` is a GitHub Actions workflow that runs `just ci` (tidy, build, test) on
`macos-latest`. It lives here, not in `.github/workflows/`, so it stays inactive until
someone with permission to change workflows enables it:

```sh
mkdir -p .github/workflows
git mv etc/ci/ci.yml .github/workflows/ci.yml
git commit -m "ci: enable workflow"
git push origin HEAD:main
```

Pushing a workflow file needs a credential with the `workflow` scope.

The runner needs Swift 6.0 or newer with `swift format`; `macos-latest` ships it with Xcode.
Run the same checks locally with `just ci`.
