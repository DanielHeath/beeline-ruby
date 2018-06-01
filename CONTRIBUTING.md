# Contributing to honeycomb-beeline

Features, bug fixes and other changes to this project are gladly accepted.
Please open issues or a pull request with your change. Remember to add your name
to the CONTRIBUTORS file!

All contributions will be released under the Apache License 2.0.

## Releasing a new version

Travis will automatically upload tagged releases to Rubygems. To release a new
version, run
```
bump patch --tag   # Or bump minor --tag, etc.
git push --follow-tags
```
