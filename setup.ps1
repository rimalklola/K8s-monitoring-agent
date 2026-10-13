
# ============================================
# Kubernetes AI Monitoring - Project 5
# Automated Windows Setup
# ============================================

$ErrorActionPreference = "Stop"

$ROOT = $PSScriptRoot
$AGENT = Join-Path $ROOT "agent"
$MONITORING = "monitoring"
$MODEL = "qwen2.5:3b"
$MINIKUBE_MEMORY = 6144

Set-Location $ROOT

function Step($message) {
    Write-Host "`n==> $message" -ForegroundColor Cyan
}

function Check-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing prerequisite: $name. Install it before running setup."
    }
}

function Run-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Command $($Arguments -join ' ')"
    }
}

function Wait-ForHttp($url, $seconds = 90) {
    $deadline = (Get-Date).AddSeconds($seconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest `
                -Uri $url `
                -UseBasicParsing `
                -TimeoutSec 5

            if ($response.StatusCode -eq 200) {
                return $true
            }
        }
        catch {
            Start-Sleep -Seconds 3
        }
    }

    return $false
}

# ============================================
# 1. Check prerequisites
# ============================================

Step "Checking prerequisites"

foreach ($tool in @(
    "docker",
    "kubectl",
    "minikube",
    "helm",
    "python",
    "ollama"
)) {
    Check-Command $tool
}

Run-Checked docker @("info")

foreach ($file in @(
    "prometheus-values.yaml",
    "loki-values.yaml",
    "alloy-values.yaml",
    "agent\ai_agent.py",
    "agent\api.py",
    "agent\requirements.txt"
)) {
    if (-not (Test-Path (Join-Path $ROOT $file))) {
        throw "Missing project file: $file"
    }
}

Write-Host "Prerequisites and project files found."

# ============================================
# 2. Start Kubernetes
# ============================================

Step "Starting Minikube"

& minikube status --profile minikube *> $null

if ($LASTEXITCODE -ne 0) {
    Run-Checked minikube @(
        "start",
        "--driver=docker",
        "--cpus=4",
        "--memory=$MINIKUBE_MEMORY"
    )
}

Run-Checked kubectl @(
    "config", "use-context", "minikube"
)

Run-Checked kubectl @(
    "wait",
    "--for=condition=Ready",
    "node",
    "--all",
    "--timeout=300s"
)

# ============================================
# 3. Create namespace
# ============================================

Step "Preparing monitoring namespace"

& kubectl get namespace $MONITORING *> $null

if ($LASTEXITCODE -ne 0) {
    Run-Checked kubectl @(
        "create", "namespace", $MONITORING
    )
}

# ============================================
# 4. Install Prometheus and Grafana
# ============================================

Step "Deploying Prometheus and Grafana"

Run-Checked helm @(
    "upgrade", "--install", "monitoring",
    "oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack",
    "--version", "92.3.1",
    "--namespace", $MONITORING,
    "-f", "prometheus-values.yaml",
    "--wait",
    "--timeout", "30m"
)

# ============================================
# 5. Install Loki and Alloy
# ============================================

Step "Configuring Grafana Helm repository"

Run-Checked helm @(
    "repo", "add", "grafana",
    "https://grafana.github.io/helm-charts",
    "--force-update"
)

Run-Checked helm @(
    "repo", "update", "grafana"
)

Step "Deploying Loki"

Run-Checked helm @(
    "upgrade", "--install", "loki",
    "grafana/loki",
    "--namespace", $MONITORING,
    "-f", "loki-values.yaml",
    "--wait",
    "--timeout", "30m"
)

Step "Deploying Grafana Alloy"

Run-Checked helm @(
    "upgrade", "--install", "alloy",
    "grafana/alloy",
    "--namespace", $MONITORING,
    "-f", "alloy-values.yaml",
    "--wait",
    "--timeout", "20m"
)

# ============================================
# 6. Prepare Python agent
# ============================================

Step "Preparing Python AI agent"

$VENV = Join-Path $AGENT ".venv"
$PYTHON = Join-Path $VENV "Scripts\python.exe"

if (-not (Test-Path $PYTHON)) {
    Run-Checked python @(
        "-m", "venv", $VENV
    )
}

Run-Checked $PYTHON @(
    "-m", "pip", "install",
    "--default-timeout=300",
    "--retries=10",
    "-r", (Join-Path $AGENT "requirements.txt")
)

# ============================================
# 7. Start Ollama and download Qwen
# ============================================

Step "Checking Ollama"

if (-not (Wait-ForHttp "http://localhost:11434/api/tags" 10)) {
    Start-Process ollama -ArgumentList "serve" `
        -WindowStyle Minimized

    if (-not (Wait-ForHttp "http://localhost:11434/api/tags" 60)) {
        throw "Ollama failed to start."
    }
}

$models = Invoke-RestMethod `
    -Uri "http://localhost:11434/api/tags"

$foundModel = $false

foreach ($model in $models.models) {
    if ($model.name -eq $MODEL) {
        $foundModel = $true
    }
}

if (-not $foundModel) {
    Step "Downloading $MODEL"
    Run-Checked ollama @("pull", $MODEL)
}

# ============================================
# 8. Start monitoring port forwards
# ============================================

Step "Starting Prometheus and Loki connections"

function Start-PortForward($name, $service, $port) {
    $existing = Get-NetTCPConnection `
        -LocalPort $port `
        -State Listen `
        -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Host "Port $port already in use; checking existing service."
        return
    }

    $arguments = @(
        "port-forward",
        "-n", $MONITORING,
        "svc/$service",
        "${port}:${port}"
    )

    Start-Process kubectl `
        -ArgumentList $arguments `
        -WindowStyle Minimized
}

Start-PortForward `
    "Prometheus" `
    "monitoring-kube-prometheus-prometheus" `
    9090

Start-PortForward `
    "Loki" `
    "loki" `
    3100

if (-not (Wait-ForHttp "http://localhost:9090/-/ready" 90)) {
    throw "Prometheus is not reachable on port 9090."
}

if (-not (Wait-ForHttp "http://localhost:3100/ready" 90)) {
    throw "Loki is not reachable on port 3100."
}

# ============================================
# 9. Generate private API key
# ============================================

Step "Configuring agent authentication"

$KEY_FILE = Join-Path $ROOT ".agent-api-key"

if (Test-Path $KEY_FILE) {
    $API_KEY = (Get-Content $KEY_FILE -Raw).Trim()
}
else {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    $API_KEY = [Convert]::ToHexString($bytes)

    Set-Content `
        -Path $KEY_FILE `
        -Value $API_KEY
}

# ============================================
# 10. Start Python API
# ============================================

Step "Starting Kubernetes AI agent"

$env:AGENT_API_KEY = $API_KEY

$apiRunning = Wait-ForHttp "http://localhost:8000/health" 3

if (-not $apiRunning) {
    $uvicorn = Join-Path $VENV "Scripts\uvicorn.exe"

    Start-Process `
        -FilePath $uvicorn `
        -ArgumentList @(
            "api:app",
            "--host", "0.0.0.0",
            "--port", "8000"
        ) `
        -WorkingDirectory $AGENT `
        -WindowStyle Minimized

    if (-not (Wait-ForHttp "http://localhost:8000/health" 90)) {
        throw "AI agent API failed to start."
    }
}

# ============================================
# 11. Start Open WebUI
# ============================================

Step "Starting Open WebUI"

$existingContainer = docker ps -a `
    --filter "name=^/open-webui$" `
    --format "{{.Names}}"

if ($existingContainer -eq "open-webui") {

    Run-Checked docker @(
        "start", "open-webui"
    )

}
else {

    Run-Checked docker @(
        "run", "-d",
        "--name", "open-webui",
        "-p", "8080:8080",
        "-e", "OLLAMA_BASE_URL=http://host.docker.internal:11434",
        "-e", "RAG_EMBEDDING_ENGINE=openai",
        "-e", "HF_HUB_OFFLINE=1",
        "-v", "open-webui:/app/backend/data",
        "--restart", "unless-stopped",
        "ghcr.io/open-webui/open-webui:main"
    )
}

# ============================================
# 12. Final status
# ============================================

Step "Checking Kubernetes pods"

Run-Checked kubectl @(
    "get", "pods", "-n", $MONITORING
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Kubernetes AI Monitoring Setup Ready" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

Write-Host ""
Write-Host "Open WebUI:  http://localhost:8080"
Write-Host "Agent API:   http://localhost:8000/health"
Write-Host ""
Write-Host "Open WebUI connection settings:"
Write-Host "API URL: http://host.docker.internal:8000/v1"
Write-Host "Model:   k8s-monitor"
Write-Host "API key: stored locally in .agent-api-key"
Write-Host ""
Write-Host "Select k8s-monitor in Open WebUI."
Write-Host ""
