FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8002
CMD ["uv", "run", "uvicorn", "engine:app", "--host", "0.0.0.0", "--port", "8002", "--reload"]
