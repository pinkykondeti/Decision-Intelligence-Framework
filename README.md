# Unified Local Dev Launcher

This repository includes a one-command PowerShell launcher that starts backend and frontend together, auto-installs missing dependencies, verifies health checks, and uses fail-fast shutdown behavior.

## Run The Application

```powershell
powershell -ExecutionPolicy Bypass -File .\run-dev.ps1
```

## PostgreSQL Server (Local)

The backend is configured to use PostgreSQL via `backend/.env`:

```text
DATABASE_URL=postgresql://decision_user:decision_pass@127.0.0.1:55432/decision_intelligence
```

Start a dedicated local PostgreSQL instance for this project:

```powershell
powershell -ExecutionPolicy Bypass -File .\backend\scripts\start-postgres.ps1
```

Test the database connection:

```powershell
powershell -ExecutionPolicy Bypass -File .\backend\scripts\test-postgres.ps1
```

Run backend API smoke tests (auth, business, employees, upload, analytics, export):

```powershell
.\.venv\Scripts\python.exe -m pytest -q .\backend\tests\test_api_smoke.py
```

Stop the local PostgreSQL instance:

```powershell
powershell -ExecutionPolicy Bypass -File .\backend\scripts\stop-postgres.ps1
```

## Access URLs

- Frontend: `http://127.0.0.1:5173`
- Backend docs: `http://127.0.0.1:8000/docs`

## What `run-dev.ps1` Does

1. Resolves project paths for `backend`, `frontend`, and `.venv`.
2. Validates required executables (`python` for venv creation, `npm`).
3. Bootstraps backend dependencies:
   - Creates `.venv` if missing.
   - Uses `backend\requirments.txt` first, then `backend\requirements.txt`.
   - Runs import health check (`fastapi`, `uvicorn`, `sqlalchemy`).
   - Installs Python dependencies if imports fail.
4. Bootstraps frontend dependencies:
   - Runs `npm ci` when `frontend\node_modules` is missing.
   - Runs `npm install` only when `npm ls --depth=0` fails.
5. Starts backend and frontend processes.
6. Runs startup health checks (90 seconds timeout):
   - `http://127.0.0.1:8000/api/health`
   - `http://127.0.0.1:5173`
7. Monitors both processes and stops both if either exits.
8. Stops both processes on script termination (including Ctrl+C).

## Troubleshooting

### Port Already In Use

- Symptoms: backend or frontend exits immediately on start.
- Fix:
  - Stop the process currently using port `8000` or `5173`.
  - Re-run `powershell -ExecutionPolicy Bypass -File .\run-dev.ps1`.

### Dependency Install Failures

- Symptoms: `pip install`, `npm ci`, or `npm install` fails.
- Fix:
  - Confirm internet access.
  - Re-run the command after the network issue is resolved.
  - If needed, run installs manually:
    - Backend: `.\.venv\Scripts\python.exe -m pip install -r .\backend\requirments.txt`
    - Frontend: `cd .\frontend; npm ci`

### Backend Import Check Fails Repeatedly

- Symptoms: script keeps failing at Python import checks.
- Fix:
  - Verify `.venv` is healthy.
  - Delete `.venv` and rerun launcher to recreate and reinstall dependencies.

### Health Check Timeout

- Symptoms: launcher exits after startup timeout.
- Fix:
  - Check terminal logs for backend/frontend startup errors.
  - Confirm firewall or antivirus is not blocking localhost ports.
  - Re-run launcher after resolving startup errors.
