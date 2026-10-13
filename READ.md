\# Kubernetes AI Monitoring Assistant

hi indiana, you can do all this or you can use a script i made for you that does it all in one click, the script is called setup.ps1 you can run it with "powershell -ExecutionPolicy Bypass -File .\setup.ps1"  hopefully it works, but there are some things you stil have to do manually

CloudSys — Project 5: Monitoring Kubernetes Clusters with AI



\## Overview



An AI-powered Kubernetes observability assistant that allows users to monitor Kubernetes infrastructure and investigate incidents through natural-language questions.



The system uses Prometheus for metrics, Loki and Grafana Alloy for logs, the Kubernetes API for live resource status, and Qwen 2.5 through Ollama for AI-generated analysis.



Open WebUI provides the conversational interface.



\## Features



1\. \*\*Cluster health overview:\*\* Analyze node readiness, pod health, container restarts, and monitoring errors.

2\. \*\*Incident investigation:\*\* Investigate a specific Kubernetes pod using metrics, logs, container state, and Kubernetes events.

3\. \*\*Root-cause analysis:\*\* Correlate Kubernetes evidence and generate probable root causes, incident timelines, and recommended troubleshooting actions.



The assistant is read-only. It does not automatically modify Kubernetes resources.



\## Architecture



```text

&#x20;               Open WebUI

&#x20;                   |

&#x20;            Python FastAPI

&#x20;                   |

&#x20;             AI Agent

&#x20;         /         |         \\

&#x20;  Prometheus      Loki    Kubernetes API

&#x20;  (Metrics)      (Logs)    (Pod Status)

&#x20;         \\         |         /

&#x20;             Evidence

&#x20;                |

&#x20;          Ollama / Qwen

&#x20;                |

&#x20;         AI Diagnosis

```



\## Prerequisites



\- Docker Desktop

\- Minikube

\- kubectl

\- Helm

\- Python 3.12

\- Ollama

\- Git



A computer with at least 16 GB RAM is recommended for the complete local setup.



\## Installation



\### 1. Clone the repository



```bash

git clone <REPOSITORY\_URL>

cd k8s-ai-monitoring

```



\### 2. Start Kubernetes



Ensure Docker Desktop is running.



```bash

minikube start --driver=docker --cpus=4 --memory=6144

kubectl config use-context minikube

kubectl create namespace monitoring

```



If the namespace already exists, reuse it.



\### 3. Install Prometheus and Grafana



```bash

helm install monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 92.3.1 --namespace monitoring -f prometheus-values.yaml --wait --timeout 20m

```



\### 4. Install Loki



Add the Grafana Helm repository:



```bash

helm repo add grafana https://grafana.github.io/helm-charts

helm repo update grafana

```



Install Loki:



```bash

helm install loki grafana/loki -n monitoring -f loki-values.yaml --wait --timeout 20m

```



\### 5. Install Grafana Alloy



```bash

helm install alloy grafana/alloy -n monitoring -f alloy-values.yaml --wait --timeout 20m

```



Verify the installation:



```bash

kubectl get pods -n monitoring

```



All required monitoring pods should eventually become ready.



\### 6. Install Ollama and Qwen



Install Ollama from https://ollama.com/download.



```bash

ollama pull qwen2.5:3b

```



Ensure the Ollama service is running.



\### 7. Start Open WebUI



```bash

docker run -d --name open-webui -p 8080:8080 -e OLLAMA\_BASE\_URL=http://host.docker.internal:11434 -e RAG\_EMBEDDING\_ENGINE=openai -e HF\_HUB\_OFFLINE=1 -v open-webui:/app/backend/data --restart unless-stopped ghcr.io/open-webui/open-webui:main

```



Open http://localhost:8080 and create the local administrator account.



The RAG settings are intended for this monitoring-only deployment, which does not require document retrieval.



\### 8. Install the Python agent



From the repository's `agent` directory:



```powershell

python -m venv .venv

.\\.venv\\Scripts\\Activate.ps1

pip install -r requirements.txt

```



\### 9. Start the monitoring connections



Open separate terminals.



Prometheus:



```bash

kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090

```



Loki:



```bash

kubectl port-forward -n monitoring svc/loki 3100:3100

```



\### 10. Start the Python API



From the `agent` directory:



```powershell

$env:AGENT\_API\_KEY = "replace-with-a-private-local-key"

uvicorn api:app --host 0.0.0.0 --port 8000

```



Use the same private API key when configuring the Open WebUI connection.



\### 11. Configure Open WebUI



In the administrator settings, add an OpenAI-compatible connection:



\- API URL: `http://host.docker.internal:8000/v1`

\- API key: the value of `AGENT\_API\_KEY`

\- Model: `k8s-monitor`



Select `k8s-monitor` when starting a chat.



\## Example Questions



\*\*Cluster health\*\*



How healthy is my Kubernetes cluster?



\*\*Incident investigation\*\*



Investigate pod loki-0 in namespace monitoring.



\*\*Root-cause analysis\*\*



Perform a root-cause analysis of pod loki-0 in namespace monitoring.



\## Testing



Deploy the deliberately faulty test application:



```bash

kubectl create namespace ai-testing

kubectl apply -f faulty-app.yaml

kubectl get pods -n ai-testing

```



The application intentionally exits with code 1, producing repeated container restarts.



Use the actual pod name displayed by Kubernetes to ask the AI agent to investigate the failure.



Verify the diagnosis using:



```bash

kubectl describe pod POD\_NAME -n ai-testing

kubectl logs POD\_NAME -n ai-testing --previous

```



Remove the test environment:



```bash

kubectl delete namespace ai-testing

```



\## Limitations



\- AI-generated diagnoses can be inaccurate.

\- Missing monitoring data must not be interpreted as proof of health.

\- Root-cause hypotheses require verification against Kubernetes events, logs, and metrics.

\- The current implementation uses local port forwarding.

\- This setup is intended for local development and demonstration, not production deployment.



\## Project Deliverables



\- Kubernetes observability environment

\- AI-powered monitoring assistant

\- Cluster health, incident investigation, and root-cause analysis demonstrations

\- Requirements and architecture documentation

\- Functional and resilience test report



