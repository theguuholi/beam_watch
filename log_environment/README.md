# Log Environment

These files run a small Docker log environment for the BeamWatch take-home.

The environment writes representative validation logs into `priv/logs/` and
periodically runs `logrotate` so you can exercise longer-running ingestion,
truncation, and rotation behavior. It uses the same deterministic feeder modules
under `lib/beamwatch/log_feed` as the Mix task.

## Run The Docker Environment

From the root of the candidate repo:

```bash
docker compose up log-environment
```

The compose file mounts `priv/logs/` into the container as `/var/log/beamwatch`.
Stop the container with `Ctrl-C` when you are finished.

## Run The Mix Feed

The Docker environment is optional. For deterministic local fixture generation,
you can also run the feeder directly.

Available profiles:

- `sample`: short grouped smoke fixture
- `validation`: primary deterministic validation stream with interleaved incident and noise coverage

```bash
mix beamwatch.feed_logs --profile validation --target priv/logs
```

This Mix task is the canonical way to generate logs. In development, the starter dashboard also includes dev-only controls that can append the same validation fixture to `priv/logs/` or clear `priv/logs/` before another run.

Use `--speed` to make playback faster:

```bash
mix beamwatch.feed_logs --profile validation --target priv/logs --speed 20
```

The feeder creates or appends to files under the target directory.
