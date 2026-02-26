Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:BackendProcess = $null
$script:FrontendProcess = $null
$script:ExitCode = 0
$script:UserCancelled = $false

function Write-Info {
    param([string]$Message)
    Write-Host "[run-dev] $Message"
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-ProcessTree -ProcessId $child.ProcessId
        }
    } catch {
        # Ignore child lookup failures during shutdown.
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch {
        # Ignore process stop errors during shutdown.
    }
}

function Stop-ChildProcesses {
    foreach ($proc in @($script:FrontendProcess, $script:BackendProcess)) {
        if ($null -eq $proc) {
            continue
        }

        try {
            $proc.Refresh()
            if (-not $proc.HasExited) {
                Write-Info "Stopping process tree for PID $($proc.Id)..."
                Stop-ProcessTree -ProcessId $proc.Id
            }
        } catch {
            # Ignore cleanup errors.
        }
    }
}

try {
    $repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = (Get-Location).Path
    }

    $backendDir = Join-Path $repoRoot "backend"
    $frontendDir = Join-Path $repoRoot "frontend"
    $venvDir = Join-Path $repoRoot ".venv"
    $venvPython = Join-Path $venvDir "Scripts\python.exe"

    if (-not (Test-Path $backendDir)) {
        throw "Missing backend directory at '$backendDir'."
    }
    if (-not (Test-Path $frontendDir)) {
        throw "Missing frontend directory at '$frontendDir'."
    }

    if (-not (Test-Path $venvPython)) {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            throw "Python is required but was not found in PATH."
        }

        Write-Info "Creating virtual environment at '$venvDir'..."
        & $pythonCommand.Source -m venv $venvDir
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create virtual environment."
        }
    }

    if (-not (Test-Path $venvPython)) {
        throw "Virtual environment python not found at '$venvPython'."
    }

    $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($null -eq $npmCommand) {
        $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
    }
    if ($null -eq $npmCommand) {
        throw "npm is required but was not found in PATH."
    }
    $npmExecutable = $npmCommand.Source

    $requirementsCandidates = @(
        (Join-Path $backendDir "requirments.txt"),
        (Join-Path $backendDir "requirements.txt")
    )
    $requirementsFile = $requirementsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($requirementsFile)) {
        throw "No backend requirements file found. Expected 'backend\\requirments.txt' or 'backend\\requirements.txt'."
    }

    Write-Info "Checking backend Python dependency imports..."
    & $venvPython -c "import fastapi,uvicorn,sqlalchemy" 2>$null
    $importsHealthy = ($LASTEXITCODE -eq 0)

    if (-not $importsHealthy) {
        Write-Info "Installing backend dependencies from '$requirementsFile'..."
        & $venvPython -m pip install -r $requirementsFile
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install backend dependencies."
        }
    } else {
        Write-Info "Backend Python dependencies already available."
    }

    $nodeModulesDir = Join-Path $frontendDir "node_modules"
    Push-Location $frontendDir
    try {
        if (-not (Test-Path $nodeModulesDir)) {
            Write-Info "Installing frontend dependencies with npm ci..."
            & $npmExecutable ci
            if ($LASTEXITCODE -ne 0) {
                throw "npm ci failed."
            }
        } else {
            Write-Info "Validating frontend dependencies with npm ls --depth=0..."
            & $npmExecutable ls --depth=0 *> $null
            $npmLsExitCode = $LASTEXITCODE

            if ($npmLsExitCode -ne 0) {
                Write-Info "Dependency tree check failed. Running npm install..."
                & $npmExecutable install
                if ($LASTEXITCODE -ne 0) {
                    throw "npm install failed."
                }
            } else {
                Write-Info "Frontend dependencies already healthy."
            }
        }
    } finally {
        Pop-Location
    }

    Write-Info "Starting backend at http://127.0.0.1:8000 ..."
    $postgresStartScript = Join-Path $backendDir "scripts\start-postgres.ps1"
    if (Test-Path $postgresStartScript) {
        Write-Info "Ensuring local PostgreSQL is running..."
        & powershell -ExecutionPolicy Bypass -File $postgresStartScript
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start local PostgreSQL."
        }
    }

    $script:BackendProcess = Start-Process `
        -FilePath $venvPython `
        -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "8000", "--reload") `
        -WorkingDirectory $backendDir `
        -PassThru `
        -NoNewWindow

    Start-Sleep -Seconds 1
    $script:BackendProcess.Refresh()
    if ($script:BackendProcess.HasExited) {
        throw "Backend failed to start (exit code $($script:BackendProcess.ExitCode))."
    }

    Write-Info "Starting frontend at http://127.0.0.1:5173 ..."
    $script:FrontendProcess = Start-Process `
        -FilePath $npmExecutable `
        -ArgumentList @("run", "dev", "--", "--host", "127.0.0.1", "--port", "5173") `
        -WorkingDirectory $frontendDir `
        -PassThru `
        -NoNewWindow

    Start-Sleep -Seconds 1
    $script:FrontendProcess.Refresh()
    if ($script:FrontendProcess.HasExited) {
        throw "Frontend failed to start (exit code $($script:FrontendProcess.ExitCode))."
    }

    Write-Info "Running startup health checks (timeout: 90 seconds)..."
    $backendHealthy = $false
    $frontendHealthy = $false
    $deadline = (Get-Date).AddSeconds(90)

    while ((Get-Date) -lt $deadline) {
        $script:BackendProcess.Refresh()
        if ($script:BackendProcess.HasExited) {
            throw "Backend exited before health checks passed (exit code $($script:BackendProcess.ExitCode))."
        }

        $script:FrontendProcess.Refresh()
        if ($script:FrontendProcess.HasExited) {
            throw "Frontend exited before health checks passed (exit code $($script:FrontendProcess.ExitCode))."
        }

        if (-not $backendHealthy) {
            try {
                $backendResponse = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8000/api/health" -TimeoutSec 2
                if ($backendResponse.StatusCode -ge 200 -and $backendResponse.StatusCode -lt 500) {
                    $backendHealthy = $true
                }
            } catch {
                # Keep retrying until deadline.
            }
        }

        if (-not $frontendHealthy) {
            try {
                $frontendResponse = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5173" -TimeoutSec 2
                if ($frontendResponse.StatusCode -ge 200 -and $frontendResponse.StatusCode -lt 500) {
                    $frontendHealthy = $true
                }
            } catch {
                # Keep retrying until deadline.
            }
        }

        if ($backendHealthy -and $frontendHealthy) {
            break
        }

        Start-Sleep -Milliseconds 750
    }

    if (-not ($backendHealthy -and $frontendHealthy)) {
        throw "Startup health checks timed out before both services became reachable."
    }

    Write-Info "Both services are healthy."
    Write-Info "Frontend: http://127.0.0.1:5173"
    Write-Info "Backend docs: http://127.0.0.1:8000/docs"
    Write-Info "Press Ctrl+C to stop both services."

    while ($true) {
        Start-Sleep -Seconds 1

        $script:BackendProcess.Refresh()
        if ($script:BackendProcess.HasExited) {
            throw "Backend exited unexpectedly (exit code $($script:BackendProcess.ExitCode))."
        }

        $script:FrontendProcess.Refresh()
        if ($script:FrontendProcess.HasExited) {
            throw "Frontend exited unexpectedly (exit code $($script:FrontendProcess.ExitCode))."
        }
    }
} catch {
    $script:UserCancelled = $_.FullyQualifiedErrorId -like "*PipelineStoppedException*" -or $_.Exception.Message -like "*Ctrl+C*"
    if ($script:UserCancelled) {
        Write-Info "Received Ctrl+C. Shutting down..."
        $script:ExitCode = 0
    } else {
        Write-Error "[run-dev] $($_.Exception.Message)"
        $script:ExitCode = 1
    }
} finally {
    Stop-ChildProcesses
    exit $script:ExitCode
}
