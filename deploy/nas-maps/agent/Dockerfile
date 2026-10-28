# GET.ride maps agent for the office NAS (see ../README.md). It only checks
# the maps services in this compose project and calls out to GET.ride.
FROM python:3.11.10-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY core.py agent.py ./

RUN useradd --system --create-home agent && mkdir -p /data && chown agent /data
USER agent

ENV PYTHONUNBUFFERED=1 AGENT_DATA=/data MAPS_DATA=/maps
CMD ["python", "agent.py"]
