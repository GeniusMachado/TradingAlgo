FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8001
CMD ["uv", "run", "uvicorn", "auth:app", "--host", "0.0.0.0", "--port", "8001", "--reload"]
