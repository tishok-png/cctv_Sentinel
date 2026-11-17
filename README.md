# Sentinel

Camera monitoring for schools and other facilities. A camera watches defined zones, and Sentinel turns what it sees into **reviewable events**: who entered which zone, who stayed too long, who came in after hours. Every event comes with an explanation and a short video clip, so a person can review it in seconds instead of scrubbing through footage.

```
 camera ──► YOLOv8 + ByteTrack ──► zone rules ──► events + clips ──► dashboard, notifications
```

## What it does

| | |
|---|---|
| **Zones** | Draw polygons on a live snapshot in the browser. Each zone has its own rules. |
| **Rules** | *Entry* (someone enters), *Dwell* (someone stays longer than N seconds, escalating to critical at 1.5×), *After hours* (someone enters outside the opening hours you set). |
| **Events** | One per visit, not one per frame. Edge flicker and short tracker drop-outs are merged. Severity: info / warning / critical. |
| **Clips** | 5 s before and 5 s after each event, H.264 so every browser plays them. Stored locally or in S3. |
| **Review** | Acknowledge, dismiss, escalate, flag for review, mark as false detection, add notes. |
| **Notifications** | Telegram, email (SMTP / Amazon SES) and webhook, with severity filtering and flood protection. |
| **Metrics** | Real counts from your events and decisions: volume over time, by zone/type/severity, review rate, false-detection rate, median time to review. |
| **Security** | Password login (signed HttpOnly cookie), brute-force lockout, separate key for the camera agent, production mode refuses weak secrets. |

## Three ways to run it (`SENTINEL_MODE`)

| Mode | What runs | Use it for |
|---|---|---|
| `all` (default) | Camera, detection, API and dashboard in one process | Local development and demos |
| `api` | API + dashboard only. No camera, no ML libraries | The AWS server |
| `agent` | Camera and detection only; sends events, clips and live frames to an `api` server over HTTPS | The machine that has the camera |

```
 Camera PC / Pi / Jetson                         AWS (one small EC2 instance)
 ┌──────────────────────┐   HTTPS (agent key)   ┌──────────────────────────────┐
 │ agent: YOLO + rules  │ ────────────────────► │ Caddy (HTTPS) ► API + dashboard│ ◄── browser
 │ clips encoded here   │  events, clips, frames│ SQLite events      S3: clips   │
 └──────────────────────┘                       └──────────────────────────────┘
```

The camera stays on your network; only events, clips, and a low-rate preview (sent **only while someone is watching**) go to the cloud.

## Run it locally

Python 3.10+ and Node 20+.

```bash
# 1. backend
cd backend
python -m venv .venv && source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env                                     # defaults work as they are
python main.py                                           # API on http://localhost:8000, camera window opens (q quits)

# 2. dashboard, in a second terminal
cd frontend
cp .env.local.example .env.local
pnpm install && pnpm dev                                 # http://localhost:3000
```

No webcam? Set `SENTINEL_CAMERA=path/to/video.mp4` (add `SENTINEL_LOOP=1` to repeat it) or an `rtsp://…` URL in `backend/.env`.

**Single-process alternative:** `cd frontend && pnpm build` creates `frontend/out/`; the backend then serves the dashboard itself at http://localhost:8000, exactly as it does on AWS.

First steps in the dashboard: **Zones** → click the corners of an area on the snapshot → choose rules → Save. Walk into the zone and watch **Live** and **Events**.

With no `SENTINEL_ADMIN_PASSWORD` the dashboard has no login. That is fine on localhost only.

## Deploy to AWS

See **[docs/AWS.md](docs/AWS.md)**: one CloudFormation template creates the server, a fixed IP and a private clip bucket; the first boot takes several minutes while Docker builds the image. `backend/simulate_agent.py` then proves the deployment works before you connect a real camera.

## Configuration

Everything is an environment variable (or a line in `backend/.env`). `backend/.env.example` lists all of them with explanations. The important ones:

| Variable | Meaning |
|---|---|
| `SENTINEL_MODE` | `all`, `api` or `agent` |
| `SENTINEL_ENV` | `production` enforces strong secrets and secure cookies |
| `SENTINEL_ADMIN_PASSWORD`, `SENTINEL_SECRET` | Dashboard login and session signing (required in production) |
| `SENTINEL_AGENT_KEY` | Shared secret between server and agent |
| `SENTINEL_CAMERA` | Webcam index, video file, or RTSP URL |
| `SENTINEL_CLOUD_URL` | Where an agent sends data |
| `SENTINEL_S3_BUCKET` | Store clips in S3 instead of on disk |
| `SENTINEL_TELEGRAM_*`, `SENTINEL_SMTP_*`, `SENTINEL_WEBHOOK_URL` | Notification channels |

Opening hours, notification threshold and zones are changed in the dashboard and stored in the database.

## Project layout

```
backend/
  main.py          entry point (mode switch)          api.py        FastAPI routes
  vision.py        camera → YOLO → rules → sink       rules.py      entry / dwell / after-hours engine
  zones.py         polygon geometry (no OpenCV)       store.py      SQLite: events, zones, settings
  clips.py         pre/post-roll buffer + H.264       storage.py    local disk or S3 for clips
  sinks.py         LocalSink / RemoteSink (agent)     notify.py     Telegram, email, webhook
  auth.py          sessions, agent key, lockout       metrics.py    dashboard numbers
  validation.py    every API input is checked here    config.py     environment → typed config
frontend/          Next.js dashboard (static export): Live, Events, Zones, Metrics, Settings
deploy/            CloudFormation, Caddyfile            Dockerfile, docker-compose.yml (cloud image)
tests/             pytest suite
```

The rules engine, store, auth, clips and notifier are plain Python with no web framework or ML imports, so they are unit-tested directly and the cloud image stays small.

## Tests

```bash
pip install -r backend/requirements-dev.txt
pytest
```

Covers the rules engine (entry, dwell, escalation, after-hours, overnight schedules, jitter, lost tracks), the database, validation, auth and lockout, the notifier, clip encoding with real ffmpeg, the agent → server protocol against a stub server, and a full video → detector → events → clips run with a fake detector. `tests/test_api.py` exercises every HTTP endpoint and is skipped automatically if FastAPI/httpx are not installed.

## How decisions are made

- **Where a person is:** the bottom-centre of the box (their feet), not its centre, so leaning or reaching does not move them across a boundary.
- **Zones are stored as fractions of the frame** (0–1), so they survive a resolution change and can be drawn on a scaled snapshot.
- **One event per visit.** Stepping out and back in within 10 s continues the same visit; a track that disappears inside a zone is closed after 5 s.
- **Track stability** (shown in the UI) is how consistently a track was matched since it appeared, scaled down while it is young. It is a heuristic score, not a calibrated probability.
- **Severity only goes up.** A dwell event moves from warning to critical in place instead of creating a second card.

## Known limitations

- **One camera.** Tracks are per camera; there is no re-identification across cameras and no face recognition (track numbers are temporary).
- **One server process.** Live frames and status are held in memory, so run a single worker. One instance comfortably serves a school-sized deployment; scaling out would need a shared store.
- **Dashboard shows the newest 300 events**; the Metrics page covers the last 30 days.
- **Detection quality is the YOLOv8-nano model's.** Sentinel does not measure precision/recall; the false-detection rate shown is what your operators flagged.
- **Clips are encoded on the agent**, which needs ffmpeg (`imageio-ffmpeg` provides one).
- **No Content-Security-Policy** header yet (the static Next.js export needs inline scripts); other security headers are set.
