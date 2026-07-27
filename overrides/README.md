# overrides/

Your real, project-specific `profile create`/`profile update` input files:

```
overrides/components.yaml
overrides/dependencies.yaml
```

These are gitignored (see `.gitignore`) — this folder is the *only* place
they should live. Never rename them, never copy a working version elsewhere
(e.g. the repo root) -- one file per kind, one location, always.

`examples/multi-repo/components.yaml` / `dependencies.yaml` are the
git-tracked, secret-free *template* -- generic, safe to share, meant to be
copied into `overrides/` as your starting point:

```
cp examples/multi-repo/components.yaml   overrides/components.yaml
cp examples/multi-repo/dependencies.yaml overrides/dependencies.yaml
```

Then edit `overrides/components.yaml`/`overrides/dependencies.yaml` with your
real repo URLs, ports, and `env.overrides` (including any real secrets --
that's exactly why this folder is gitignored). Apply with:

```
odoo-synth profile create --components-file overrides/components.yaml \
                           --dependencies-file overrides/dependencies.yaml ...
odoo-synth profile update <id> --components-file overrides/components.yaml \
                                --dependencies-file overrides/dependencies.yaml
```
