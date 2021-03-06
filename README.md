# actions_dart_dependency_updater

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [Introduction](#introduction)
- [Inputs](#inputs)
- [Example usage](#example-usage)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Introduction

Updates the dependencies of a Dart / Flutter repo automatically and optionally creates and merges the PR associated with the changes if all status checks on the PR are successful.

## Inputs

Name           | Default    | Description
---------------|------------|-------------
`branch`       | `main`     | Branch to check for the dependencies
`channel`      | `stable`   | Dart / Flutter channel to use for the build
`paths`        | `.`      | (Optional) Comma delimited list of paths
`merge`        | `true`     | (Optional) Set to `true` to automatically merge the PR when status checks pass, set to `false` otherwise
`pull_request` | `true`     | (Optional) Set to `true` to automatically create a pull request when paths change, set to `false` otherwise
`token`        | n/a        | Access token for GH.  Typically: `${{ secrets.GITHUB_TOKEN }}`


## Example usage

```yaml
name: Update Dart / Flutter dependencies

on:
  schedule:
    - cron: "0 0 * * 0"

jobs:
  dependencies:
    runs-on: ubuntu-latest

    steps:
      - name: Dependencies
        uses: peiffer-innovations/actions-dart-dependency-updater@v1.0.18
        with:
          merge: true
          pull_request: true
          token: ${{ secrets.GITHUB_TOKEN }}
```

