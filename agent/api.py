
import os
import re
import json
import time
import uuid

from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional

from ai_agent import (
    cluster_health,
    investigate_pod,
    root_cause_analysis,
    ask_ai,
)

app = FastAPI(title="Kubernetes AI Monitoring Agent")

MODEL_ID = "k8s-monitor"
API_KEY = os.getenv("AGENT_API_KEY", "")


class Message(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model: str
    messages: list[Message]
    stream: bool = False


def authenticate(authorization: Optional[str]):
    if not API_KEY or authorization != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/v1/models")
def models(authorization: Optional[str] = Header(None)):
    authenticate(authorization)
    return {
        "object": "list",
        "data": [{
            "id": MODEL_ID,
            "object": "model",
            "created": 0,
            "owned_by": "local"
        }]
    }


def handle_question(question):
    lower = question.lower()

    # Accept questions such as:
    # "Investigate pod loki-0 in namespace monitoring"
    match = re.search(
        r"\bpod\s+([a-z0-9][a-z0-9.-]*)\b"
        r".*?\bnamespace\s+([a-z0-9][a-z0-9-]*)\b",
        lower
    )

    if match:
        pod, namespace = match.groups()

        if any(word in lower for word in [
            "root cause", "root-cause", "rca",
            "correlate", "why"
        ]):
            evidence = root_cause_analysis(namespace, pod)
        else:
            evidence = investigate_pod(namespace, pod)

    elif "pod" in lower or "root cause" in lower:
        return (
            "Please specify a pod and namespace, for example: "
            "'Investigate pod loki-0 in namespace monitoring'."
        )

    elif any(word in lower for word in [
        "cluster", "health", "healthy", "status",
        "overview"
    ]):
        evidence = cluster_health()

    else:
        return (
            "I can perform cluster health checks, pod investigations, "
            "and root-cause analysis. Please ask a monitoring question."
        )

    return ask_ai(question, evidence)


@app.post("/v1/chat/completions")
def chat_completions(
    request: ChatRequest,
    authorization: Optional[str] = Header(None)
):
    authenticate(authorization)

    questions = [
        m.content for m in request.messages if m.role == "user"
    ]

    if not questions:
        raise HTTPException(status_code=400, detail="No user question")

    question = questions[-1]

    try:
        answer = handle_question(question)
    except Exception as error:
        raise HTTPException(
            status_code=502,
            detail=f"Monitoring backend error: {type(error).__name__}"
        )

    completion_id = "chatcmpl-" + uuid.uuid4().hex
    created = int(time.time())

    if request.stream:
        def generate():
            chunk = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": MODEL_ID,
                "choices": [{
                    "index": 0,
                    "delta": {
                        "role": "assistant",
                        "content": answer
                    },
                    "finish_reason": None
                }]
            }
            yield f"data: {json.dumps(chunk)}\n\n"

            chunk["choices"][0]["delta"] = {}
            chunk["choices"][0]["finish_reason"] = "stop"
            yield f"data: {json.dumps(chunk)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(
            generate(),
            media_type="text/event-stream"
        )

    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": created,
        "model": MODEL_ID,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": answer
            },
            "finish_reason": "stop"
        }]
    }
