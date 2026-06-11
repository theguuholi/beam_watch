# BeamWatch: Live Incident Triage For System Logs

## Overview

Build a Phoenix LiveView application that helps an operator triage incidents from noisy Unraid-like system logs.

The app should read log files from a local directory, identify active incidents, show the evidence behind each incident, and let an operator acknowledge, silence, or resolve incidents. Treat the input as representative system logs from a machine that keeps running while your app is running.

We expect you to use AI tools if they help. We also expect you to understand, critique, and own the code you submit.

We're seeking insight into your technical taste, thoughtfulness, and judgment. You can modify the codebase, starter feeder, support files, and project structure as you desire. Note: this starter is AI-generated. We are evaluating the final solution, but we are also observing your development practices, code style, and judgment about what to change, what to make, how to make it, and how you use your time.

## Time Box

Spend up to 4 compensated hours. We care more about judgment and clarity than exhaustive feature coverage.

If you run out of time, leave notes explaining what is solid, what is incomplete, and what you would do next.

## Product Requirements

Build an operator dashboard that shows:

- Active incidents
- Incident severity and status
- Affected resource, such as a container, disk, share, or VM
- First seen and last seen timestamps
- Evidence lines that caused or updated the incident
- Source health for each input log file
- Recent system activity or event history

First seen means the timestamp of the earliest log evidence associated with an incident. Last seen means the timestamp of the latest matching evidence that created, updated, or resolved that incident. Prefer the timestamp embedded in the log line when available; otherwise, ingestion time is an acceptable fallback.

Source health means basic ingestion status for each watched log file, such as whether the file exists, file size, when it was last read, the latest observed log timestamp or file offset, and any parse failures, skipped malformed lines, truncation, or rotation detected. This does not need to be a full monitoring system; it should make input problems visible instead of silently dropping them.

Support operator actions:

- Acknowledge an incident
- Silence an incident or incident type
- Resolve an incident
- Clear a silence

Status can be simple: active means currently open, acknowledged means an operator has seen it, silenced means matching updates should not interrupt the operator, and resolved means the incident is no longer active. You may choose the exact state model, but operator actions should be visible and predictable.

A silence may apply either to one incident or to an incident type. It does not need expiration for this exercise, but the UI should make the scope clear and allow clearing it.

Do not assume every incident will have a later log line that clearly proves recovery. Some incidents should remain actionable through the operator lifecycle even when the logs only show failure evidence.

The app should ingest logs from a local directory such as `priv/logs/`. You can use the included feeder to generate input files.

## Required Incident Types

Implement at least these four incident types.

Some incidents have evidence across multiple log files.

### Container Restart Loop

Open or update an incident when the same container has at least four `die` events within 60 seconds.

Supporting evidence can include healthcheck failures, upstream unavailable messages, or related container start events near the same time.

### Disk SMART Warning

Open or update an incident when SMART warnings or errors appear for a disk.

Group repeated warnings for the same disk on the same day. Resolve the incident if a later log line clearly indicates the SMART check passed for that disk.

### Share Permission Failure

Open or update an incident when SMB, NFS, or application logs report permission-denied failures for the same share.

Group repeated failures for the same share within a sensible time window. This incident may not have an obvious same-share success line in the fixture stream; operators should still be able to acknowledge, silence, or resolve it.

### VM Boot Failure

Open or update an incident when libvirt/QEMU logs report a VM startup failure.

Supporting evidence can include missing image, missing bridge, permission, or device errors near the same time.

## Log Evidence

Each incident must show enough raw evidence to make the incident trustworthy. You do not need to build a full log-management product. A compact evidence pane or expandable details section is enough.

Malformed or unsupported lines should not crash ingestion or disappear silently; surface them through source health or recent activity.

## Starter Fixtures

The starter includes a readable, replaceable log feeder under `lib/beamwatch/log_feed`.

Run:

```bash
mix beamwatch.feed_logs --profile validation --target priv/logs
```

The feeder writes deterministic fixture lines to one or more log files. It is compiled with the app, so you can inspect it, use it in tests, or replace it with your own. Your application should read the log directory, not depend on feeder internals.

The Mix task is the canonical way to generate logs. In development, the starter dashboard also includes a small dev-only control surface that can append the same validation fixture to `priv/logs/` or clear `priv/logs/` before another run.

Available profiles:

- `sample`: short grouped smoke fixture
- `validation`: primary deterministic validation stream with interleaved incident and noise coverage

Use `--speed` to make playback faster:

```bash
mix beamwatch.feed_logs --profile validation --target priv/logs --speed 20
```

If you prefer a longer-running local environment, Docker is optional:

```bash
docker compose up log-environment
```

It writes representative logs into `priv/logs/`. See
`log_environment/README.md` for details.

## Running The App

Install the pinned runtime with `mise`:

```bash
mise install
```

Install dependencies and start Phoenix:

```bash
mix setup
mix phx.server
```

Visit `http://localhost:4000`.

Run tests with:

```bash
mix test
```

## Tests

Submit the tests you believe are necessary to give confidence in the system.

## Supporting Notes

Submit a `.notes/` directory with any supporting notes or artifacts, such as:

- AI tools or models used
- Prompt transcript(s), checkpoint log, or summary
- AI suggestions you rejected or corrected
- Issues where AI produced shallow or wrong Elixir/Phoenix guidance
- Known limitations and tradeoffs
- Your final solution and architecture explanation in your own words

Tools such as Entire CLI are acceptable if you want automatic context capture, but not required.

## Submission

Submit:

- Source code
- Setup/run instructions if they changed
- Test instructions if they changed
- `.notes/`
- Any notes on tradeoffs or incomplete work

Send your submission as a zip file to candice@lime-technology.com (for example, by uploading to google drive and sharing the link).
Also in the email, please include a 5-minute video recording (where we can see you!) explaining what you did, your decision making, and gaps you would address in the future.

We will run the app in a sandbox and determine whether you will move forward to the next step in the interview process, which would be a technical follow-up discussion.
