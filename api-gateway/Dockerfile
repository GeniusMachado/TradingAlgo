FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8000
CMD ["uv", "run", "uvicorn", "gateway:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
